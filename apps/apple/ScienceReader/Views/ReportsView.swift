import ScienceReaderCore
import SwiftUI

struct ReportsView: View {
    @Bindable var service: SupportService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if !service.waiting.isEmpty {
                    Section(service.isSending ? "Sending" : "Waiting to send") {
                        ForEach(service.waiting) { draft in
                            VStack(alignment: .leading, spacing: 5) { Text(draft.title ?? (draft.action == .reply ? "Reply" : "Status update")); Text(draft.text).lineLimit(2).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Button("Retry sending") { Task { await service.refresh() } }.disabled(service.isSending)
                    }
                }
                Section("Submitted reports") {
                    ForEach(service.reports) { report in
                        NavigationLink { ReportThreadView(service: service, reportID: report.id) } label: {
                            VStack(alignment: .leading, spacing: 5) { Text(report.title); Text(report.statusLabel + (report.fixed_build.map { " · Build \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if service.reports.isEmpty { Text("Your reports and replies from support appear here.").foregroundStyle(.secondary) }
                    if service.hasMore, !service.reports.isEmpty { Button("Load earlier reports") { Task { await service.nextPage() } } }
                }
                if let error = service.error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            }.navigationTitle("My reports").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await service.refresh() }.refreshable { await service.refresh() }
        }
    }
}

struct ReportThreadView: View {
    @Bindable var service: SupportService
    let reportID: UUID
    @State private var thread: SupportThread?
    @State private var reply = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        List {
            if let thread {
                Section {
                    Text(thread.report.title).font(.headline)
                    Text(thread.report.note).textSelection(.enabled)
                    LabeledContent("Status", value: thread.report.statusLabel)
                    if let build = thread.report.fixed_build { LabeledContent("Fix available in build", value: build) }
                    Text("Report \(thread.report.id.wire)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !thread.attachments.isEmpty { Section("Shared screenshots") { ForEach(thread.attachments) { image in PrivateReportImage(service: service, id: image.id) } } }
                Section("Replies") {
                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 6) { Text(message.is_operator ? "Support" : "You").font(.caption).foregroundStyle(.secondary); Text(message.body).textSelection(.enabled) }
                    }
                    TextField("Reply to support", text: $reply, axis: .vertical).lineLimit(2...8)
                    Button("Send reply") { Task { await send(.reply, text: reply) } }.disabled(busy || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    if thread.report.status == "ready_to_retest" { Button("Confirm fixed") { Task { await send(.status, text: "verified") } }.disabled(busy) }
                    if thread.report.status != "open" { Button("Reopen issue") { Task { await send(.status, text: "open") } }.disabled(busy) }
                }
            } else { ProgressView("Loading report…") }
            if let error { Text(error).foregroundStyle(.red) }
            if service.waiting.contains(where: { $0.reportID == reportID }) { Text("Your update is saved and waiting to send.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Report").navigationBarTitleDisplayMode(.inline).task { await load() }.refreshable { await service.flush(); await load() }
    }
    private func load() async { do { thread = try await service.thread(reportID); error = nil } catch { self.error = "The report could not load. Pull to retry." } }
    private func send(_ action: SupportDraft.Action, text: String) async {
        busy = true; defer { busy = false }
        do {
            try await service.queue(SupportDraft(accountID: service.accountID, reportID: reportID, action: action, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(10000))))
            if action == .reply { reply = "" }
            await service.flush(); await load()
        } catch { self.error = "The update could not be saved. Please try again." }
    }
}

private struct PrivateReportImage: View {
    let service: SupportService
    let id: UUID
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Screenshot shared with support") }
            else if failed { Button("Retry screenshot") { attempt += 1 } }
            else { ProgressView("Loading screenshot…") }
        }.task(id: attempt) { do { image = UIImage(data: try await service.image(id)); failed = image == nil } catch { failed = true } }
    }
}
