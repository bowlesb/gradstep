import Foundation

// The Share extension's inbox (docs/architecture/PDF_UPLOADS.md "Share extension"). Compiled into the app
// and the extension. The extension never talks to the network and holds no credentials: it writes what
// was shared (a PDF, or a link) into the app group's container; the app adds it on its next launch or
// foreground, for whoever is signed in then, through the same paths as Add (upload queue, add-paper).

/// One shared item: a PDF copied into the inbox, or a link.
struct SharedItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case pdf, link }
    let id: UUID
    let kind: Kind
    let createdAt: Date
    /// The shared link (`link`), or where the PDF came from when known.
    let url: String?
    /// The PDF's file name, or the page title the sharing app gave.
    let title: String?
}

struct ShareInbox: Sendable {
    static let appGroup = "group.com.sciencereader.ios"
    /// Items older than this are dropped unread (a share from long ago is no longer what the reader wants now).
    static let maximumAge: TimeInterval = 14 * 86_400
    static let maximumItems = 20
    static let maximumPDFBytes: Int64 = 64 * 1024 * 1024

    let root: URL

    /// The app group's inbox; nil where the group isn't provisioned (the Mac app, a misconfigured build).
    static func shared() -> ShareInbox? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return ShareInbox(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    /// Saves a shared PDF (copied; the sharing app's file is left alone). Atomic: an item appears whole or not at all.
    func addPDF(from source: URL, title: String?, origin: String? = nil) throws -> SharedItem {
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0, size <= Self.maximumPDFBytes else { throw ShareInboxError.tooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 5) == Data("%PDF-".utf8) else { throw ShareInboxError.notPDF }
        let item = SharedItem(id: UUID(), kind: .pdf, createdAt: Date(), url: origin, title: title)
        try write(item) { folder in try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("paper.pdf")) }
        return item
    }

    func addLink(_ url: URL, title: String?) throws -> SharedItem {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.absoluteString.utf8.count <= 2_000 else { throw ShareInboxError.unsupported }
        let item = SharedItem(id: UUID(), kind: .link, createdAt: Date(), url: url.absoluteString, title: title)
        try write(item) { _ in }
        return item
    }

    private func write(_ item: SharedItem, contents: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard pending().count < Self.maximumItems else { throw ShareInboxError.full }
        let staging = root.appendingPathComponent(".incoming-\(item.id.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try contents(staging)
            try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"), options: .atomic)
            try fileManager.moveItem(at: staging, to: folder(item.id))
        } catch { try? fileManager.removeItem(at: staging); throw error }
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func pdf(_ item: SharedItem) -> URL { folder(item.id).appendingPathComponent("paper.pdf") }

    /// Complete items, oldest first. Stale or broken ones (and abandoned staging folders) are removed.
    func pending(now: Date = Date()) -> [SharedItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var items: [SharedItem] = []
        for folder in folders {
            if folder.lastPathComponent.hasPrefix(".incoming-") {
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if now.timeIntervalSince(created) > 3_600 { try? FileManager.default.removeItem(at: folder) }
                continue
            }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")),
                  let item = try? JSONDecoder().decode(SharedItem.self, from: data), folder.lastPathComponent == item.id.uuidString,
                  item.kind == .link || FileManager.default.fileExists(atPath: pdf(item).path),
                  now.timeIntervalSince(item.createdAt) < Self.maximumAge else {
                try? FileManager.default.removeItem(at: folder); continue
            }
            items.append(item)
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(_ item: SharedItem) { try? FileManager.default.removeItem(at: folder(item.id)) }
}

enum ShareInboxError: Error, Equatable {
    case tooLarge, notPDF, unsupported, full

    var message: String {
        switch self {
        case .tooLarge: "This PDF is larger than 64 MB, the most Gradstep can convert."
        case .notPDF: "This file isn’t a PDF."
        case .unsupported: "Gradstep can add PDFs and web links."
        case .full: "Open Gradstep to add what you shared earlier, then share this again."
        }
    }
}
