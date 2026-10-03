import Foundation
import Observation
import ScienceReaderCore

struct SupportReport: Decodable, Identifiable, Sendable {
    let id: UUID; let title: String; let note: String; let status: String
    let app_version: String; let build: String; let fixed_build: String?; let created_at: String
    var statusLabel: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct SupportThread: Decodable, Sendable {
    struct Message: Decodable, Identifiable, Sendable { let id: UUID; let body: String; let is_operator: Bool; let created_at: String }
    struct Attachment: Decodable, Identifiable, Sendable { let id: UUID; let object_id: UUID }
    let report: SupportReport; let messages: [Message]; let attachments: [Attachment]
}

@MainActor @Observable
final class SupportService {
    let accountID: UUID
    private let backend: BackendClient
    private let outbox: SupportOutbox
    var reports: [SupportReport] = []
    var waiting: [SupportDraft] = []
    var error: String?
    var isSending = false
    var hasMore = true
    private var sending: Task<Void, Never>?

    init(accountID: UUID, environment: String, backend: BackendClient) throws {
        self.accountID = accountID; self.backend = backend
        let name = "\(environment).\(accountID.wire).support-outbox-key"
        let key: Data
        if let saved = try KeychainVault.read(name) { key = saved }
        else { key = ReaderCrypto.randomKey(); try KeychainVault.write(key, name: name) }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        outbox = try SupportOutbox(directory: root.appendingPathComponent("\(environment)/\(accountID.wire)/support-outbox", isDirectory: true), accountID: accountID, key: key)
    }

    func queue(_ draft: SupportDraft) async throws {
        try await outbox.enqueue(draft)
        waiting = try await outbox.pending()
        Task { await flush() }
    }
    func refresh() async {
        await flush()
        do {
            let rows: [SupportReport] = try await backend.rpc("v2_reports", params: EmptyResponse(), accountID: accountID)
            reports = rows; hasMore = rows.count == 50
        } catch { self.error = message(error) }
    }
    func nextPage() async {
        guard let last = reports.last, hasMore else { return }
        struct Page: Encodable, Sendable { let p_before_created_at: String; let p_before_id: UUID }
        do {
            let rows: [SupportReport] = try await backend.rpc("v2_reports", params: Page(p_before_created_at: last.created_at, p_before_id: last.id), accountID: accountID)
            let known = Set(reports.map(\.id)); reports += rows.filter { !known.contains($0.id) }; hasMore = rows.count == 50
        } catch { self.error = message(error) }
    }
    func thread(_ id: UUID) async throws -> SupportThread { try await backend.rpc("v1_report_thread", params: ["p_report_id": id.wire], accountID: accountID) }
    func image(_ id: UUID) async throws -> Data { try await backend.reportImage(id, accountID: accountID) }

    func flush() async {
        if let sending { await sending.value; return }
        let task = Task { await self.transfer() }; sending = task
        await task.value; sending = nil
    }
    func cancel() { sending?.cancel(); reports = []; waiting = []; error = nil }

    private func transfer() async {
        isSending = true; error = nil; defer { isSending = false }
        do {
            // Re-read after each acknowledgment so a report queued while an
            // earlier upload is running is sent by the same drain operation.
            waiting = try await outbox.pending()
            while let draft = waiting.first {
                try Task.checkCancellation()
                switch draft.action {
                case .report:
                    struct Create: Encodable, Sendable { let p_id: UUID; let p_title: String; let p_note: String; let p_app_version: String; let p_build: String; let p_os_version: String; let p_screen: String }
                    let receipt: UUID = try await backend.rpc("v1_create_report", params: Create(p_id: draft.reportID, p_title: draft.title!, p_note: draft.text,
                        p_app_version: draft.appVersion!, p_build: draft.build!, p_os_version: draft.osVersion!, p_screen: draft.screen!), accountID: accountID)
                    guard receipt == draft.reportID else { throw ReaderError.corruptData }
                    if let image = draft.image { try await backend.uploadReportImage(image.bytes, mediaType: image.mediaType, accountID: accountID, reportID: draft.reportID, attachmentID: image.id) }
                case .reply:
                    let receipt: UUID = try await backend.rpc("v1_reply_to_report", params: ["p_id": draft.id.wire, "p_report_id": draft.reportID.wire, "p_body": draft.text], accountID: accountID)
                    guard receipt == draft.id else { throw ReaderError.corruptData }
                case .status:
                    let _: EmptyResponse? = try await backend.rpc("v1_set_report_status", params: ["p_id": draft.id.wire, "p_report_id": draft.reportID.wire, "p_status": draft.text], accountID: accountID)
                }
                try Task.checkCancellation()
                try await outbox.acknowledge(draft)
                waiting = try await outbox.pending()
            }
        } catch is CancellationError { }
        catch { self.error = message(error) }
    }
    private func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "This report is saved on this device. Retry when your connection is available." }
}
