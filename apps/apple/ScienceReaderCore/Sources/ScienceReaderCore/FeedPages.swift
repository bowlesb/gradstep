import CryptoKit
import Foundation

/// The last page one Feed view showed (For you, a topic chip, a category chip), kept on this device across launches so
/// an offline cold start shows it rather than an empty Feed (owner, 2026-10-25; docs/architecture/PERSONALIZED_FEED.md
/// "The last page, kept on the device"). Presentation only: never sent anywhere, never part of sync.
public struct FeedKeptPage: Codable, Equatable, Sendable {
    /// The view: "for_you", "topic:<name>" or "category:<code>" (the app's `FeedSelection.storageKey`).
    public let view: String
    /// When the server returned these results.
    public var fetchedAt: Date
    /// When the reader last opened this view (fetched or shown from here): views not opened for 14 days are dropped.
    public var openedAt: Date
    /// The server's results, in its order (at most 50).
    public var results: [DiscoveryResult]

    public init(view: String, fetchedAt: Date, openedAt: Date, results: [DiscoveryResult]) {
        self.view = view; self.fetchedAt = fetchedAt; self.openedAt = openedAt; self.results = results
    }

    private enum CodingKeys: String, CodingKey { case view, results, fetchedAt = "fetched_at", openedAt = "opened_at" }

    func validate() throws {
        guard (1...80).contains(view.count), fetchedAt.timeIntervalSinceReferenceDate.isFinite,
              openedAt.timeIntervalSinceReferenceDate.isFinite, !results.isEmpty,
              results.count <= FeedPageStore.maximumResults else { throw ReaderError.corruptData }
    }
}

/// The Feed's kept pages for one account: one AES-GCM sealed file in the account's local folder, beside the encrypted
/// private-state store and under the same device-held local-store key (through a domain-separated HKDF subkey), with
/// the account bound into the authenticated data, complete file protection and no backup (as `ReadingActivityStore`).
/// Bounded: the last page per view, at most 16 views and 4 MB, and a view not opened for 14 days is dropped. Losing or
/// failing to read the file only forgets these pages (the Feed asks the server as before), so an unreadable file is
/// replaced on the next save. The app erases it when the account signs out; deleting the account removes the folder.
public actor FeedPageStore {
    public static let fileName = "feed-pages.enc"
    public static let maximumViews = 16
    public static let maximumResults = 50
    public static let maximumBytes = 4 * 1024 * 1024
    /// A view the reader hasn't opened for this long is dropped.
    public static let expiry: TimeInterval = 14 * 86_400
    private let url: URL
    private let accountID: UUID
    private let key: SymmetricKey

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        url = directory.appendingPathComponent(Self.fileName)
        self.accountID = accountID
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: localKey), salt: Data(accountID.wire.utf8),
                                     info: Data("science-reader/local-feed/v1".utf8), outputByteCount: 32)
    }

    private var aad: Data { Data("science-reader/local-feed/v1\n\(accountID.wire)\n".utf8) }

    /// The kept pages by view, within the bounds as of `now`. Missing → empty. Unreadable (wrong key or account,
    /// corruption, a row that no longer passes the checks) → empty, replaced at the next save.
    public func load(now: Date = Date()) -> [String: FeedKeptPage] {
        guard let sealed = try? Data(contentsOf: url),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad),
              let pages = try? JSONDecoder().decode([FeedKeptPage].self, from: plain),
              pages.count <= Self.maximumViews, (try? pages.forEach { try $0.validate() }) != nil,
              Set(pages.map(\.view)).count == pages.count else { return [:] }
        return Self.keyed((try? Self.bounded(pages, now: now)) ?? [])
    }

    /// Keeps what fits the bounds (the most recently opened views first) and replaces the file atomically; nothing left
    /// removes it. Returns the views kept.
    @discardableResult
    public func save(_ pages: [String: FeedKeptPage], now: Date = Date()) throws -> [String: FeedKeptPage] {
        for (view, page) in pages { guard page.view == view else { throw ReaderError.corruptData }; try page.validate() }
        let kept = try Self.bounded(Array(pages.values), now: now)
        guard !kept.isEmpty else { erase(); return [:] }
        guard let sealed = try AES.GCM.seal(ReaderCrypto.encode(kept), using: key, authenticating: aad).combined else {
            throw ReaderError.corruptData
        }
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ReaderError.storageUnavailable }
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = url; try? file.setResourceValues(values)
        return Self.keyed(kept)
    }

    /// Forgets every kept page (sign-out).
    public func erase() {
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    /// Views opened within `expiry` of `now`, most recently opened first, at most `maximumViews`, each at most
    /// `maximumResults` papers, and together at most `maximumBytes` encoded (a view that doesn't fit is dropped whole).
    static func bounded(_ pages: [FeedKeptPage], now: Date) throws -> [FeedKeptPage] {
        var kept: [FeedKeptPage] = [], bytes = 2
        for var page in pages.sorted(by: { $0.openedAt == $1.openedAt ? $0.view < $1.view : $0.openedAt > $1.openedAt })
        where now.timeIntervalSince(page.openedAt) < expiry && kept.count < maximumViews {
            page.results = Array(page.results.prefix(maximumResults))
            let size = try ReaderCrypto.encode(page).count + 1
            guard bytes + size <= maximumBytes else { continue }
            kept.append(page); bytes += size
        }
        return kept
    }

    private static func keyed(_ pages: [FeedKeptPage]) -> [String: FeedKeptPage] {
        Dictionary(pages.map { ($0.view, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
