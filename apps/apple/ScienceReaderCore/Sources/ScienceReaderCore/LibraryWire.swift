import Foundation

/// The limits of the migration-010 library protocol, not paid-plan allowances.
public enum LibraryWire {
    public static let format = 2
    public static let maximumPageBytes = 1_048_576
    public static let maximumPageCount = 100
    public static let maximumRetainedEntries = 4_000

    public static func decodeBaseline(_ data: Data) throws -> LibraryBaselinePage {
        let page: LibraryBaselinePage = try decode(data)
        try page.validate()
        return page
    }

    public static func decodeChanges(_ data: Data) throws -> LibraryChangesPage {
        let page: LibraryChangesPage = try decode(data)
        try page.validate()
        return page
    }

    /// Migration 010 does not put account/format fields in command responses.
    /// The reconciler therefore requires a locally issued, account-bound ticket.
    public static func decodeCommand(_ data: Data) throws -> LibraryCommandResponse {
        let response: LibraryCommandResponse = try decode(data)
        try response.validate()
        return response
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard data.count <= maximumPageBytes else { throw LibraryProtocolError.payloadTooLarge }
        // Inspect encoded subobject bounds too. Unknown fields must not turn a
        // tiny typed value into an unbounded metadata/receipt/batch envelope.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryProtocolError.invalidPage
        }
        func bytes(_ value: Any) throws -> Int {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).count
        }
        func checkEntry(_ value: Any) throws {
            guard let entry = value as? [String: Any] else { throw LibraryProtocolError.invalidEntry }
            if let metadata = entry["metadata"], !(metadata is NSNull) {
                guard let fields = metadata as? [String: Any],
                      Set(fields.keys).isSubset(of: ["title", "authors", "abstract", "published_at", "updated_at", "categories", "venue"]),
                      try bytes(fields) <= 32_768 else { throw LibraryProtocolError.invalidMetadata }
            }
        }
        if let entries = object["entries"] as? [Any] { try entries.forEach(checkEntry) }
        if let changes = object["changes"] as? [[String: Any]] {
            for change in changes {
                if let entries = change["entries"] as? [Any] {
                    guard try bytes(entries) + 128 <= 131_072 else { throw LibraryProtocolError.payloadTooLarge }
                    try entries.forEach(checkEntry)
                }
            }
        }
        if let result = object["result"] {
            guard result is [String: Any], try bytes(result) <= 2_048 else { throw LibraryProtocolError.invalidCommand }
        }
        if let entry = object["entry"], !(entry is NSNull) { try checkEntry(entry) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public enum LibraryProtocolError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedFormat
    case invalidEntry
    case invalidMetadata
    case invalidCursor
    case invalidPage
    case invalidCommand
    case accountMismatch
    case resyncRequired
    case capacityExceeded
    case identityConflict(LibraryEntryID)
    case conflictingRevision(LibraryEntryID, Int64)
}

public enum LibraryEntryKind: String, Codable, Sendable {
    case item
    case `import`
}

/// UUIDs are only unique within their kind in the library protocol.
public struct LibraryEntryID: Hashable, Sendable {
    public let kind: LibraryEntryKind
    public let entityID: UUID

    public init(kind: LibraryEntryKind, entityID: UUID) {
        self.kind = kind
        self.entityID = entityID
    }
}

/// Normalize PostgreSQL timestamp spellings before comparing equal revisions.
public struct LibraryTimestamp: Codable, Equatable, Sendable {
    public let date: Date

    public init(from decoder: any Decoder) throws {
        if decoder.userInfo[OfflineCacheCodec.dateKey] as? Bool == true {
            let value = try decoder.singleValueContainer().decode(Double.self)
            guard value.isFinite else { throw LibraryProtocolError.invalidEntry }
            date = Date(timeIntervalSinceReferenceDate: value)
            return
        }
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count <= 64 else { throw LibraryProtocolError.invalidEntry }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = parser.date(from: value)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? parser.date(from: value) else { throw LibraryProtocolError.invalidEntry }
        self.date = date
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if encoder.userInfo[OfflineCacheCodec.dateKey] as? Bool == true {
            try container.encode(date.timeIntervalSinceReferenceDate)
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
    }
}

public struct LibraryMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let authors: [String]
    public let abstract: String?
    /// Source calendar dates, not instants in the device's time zone.
    public let publishedAt: String?
    public let updatedAt: String?
    public let categories: [String]
    public let venue: String?

    private enum CodingKeys: String, CodingKey {
        case title, authors, abstract, categories, venue
        case publishedAt = "published_at", updatedAt = "updated_at"
    }

    func validate() throws {
        guard bounded(title, 2_000, minimum: 1), authors.count <= 512,
              authors.allSatisfy({ bounded($0, 256) }), categories.count <= 64,
              categories.allSatisfy({ bounded($0, 64) }),
              abstract.map({ bounded($0, 24_000) }) ?? true,
              venue.map({ bounded($0, 1_024) }) ?? true,
              publishedAt.map(validCalendarDate) ?? true,
              updatedAt.map(validCalendarDate) ?? true else { throw LibraryProtocolError.invalidMetadata }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard try encoder.encode(self).count <= 32_768 else { throw LibraryProtocolError.invalidMetadata }
    }
}

public enum LibraryDocumentScope: String, Codable, Sendable {
    case sharedCatalog = "shared_catalog"
    case ownerPrivate = "owner_private"
}

public enum LibraryReadiness: Equatable, Codable, Sendable {
    case unverified
    case pdfReady
    case convertedReady
    case unavailable
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count <= 64 else { throw LibraryProtocolError.invalidEntry }
        switch value {
        case "unverified": self = .unverified
        case "pdf_ready": self = .pdfReady
        case "converted_ready": self = .convertedReady
        case "unavailable": self = .unavailable
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        let value: String
        switch self {
        case .unverified: value = "unverified"
        case .pdfReady: value = "pdf_ready"
        case .convertedReady: value = "converted_ready"
        case .unavailable: value = "unavailable"
        case .unknown(let raw): value = raw
        }
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
}

/// Optional additive capabilities. Unknown values never authorize a read.
public enum LibraryAssetAvailability: Equatable, Codable, Sendable {
    case available, unavailable, quarantined
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count <= 64 else { throw LibraryProtocolError.invalidEntry }
        switch value {
        case "available": self = .available
        case "unavailable": self = .unavailable
        case "quarantined": self = .quarantined
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        let value: String
        switch self {
        case .available: value = "available"
        case .unavailable: value = "unavailable"
        case .quarantined: value = "quarantined"
        case .unknown(let raw): value = raw
        }
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
}

public struct LibraryItemRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let createdSequence: Int64
    public let stateSequence: Int64
    public let membershipRevision: Int64
    public let visible: Bool
    public let addedAt: LibraryTimestamp
    public let lastRemoveSequence: Int64
    public let approvalID: UUID?
    public let versionID: UUID?
    public let metadataID: UUID?
    public let source: String?
    public let sourceID: String?
    public let sourceRevision: Int?
    public let metadata: LibraryMetadata?
    public let metadataRecordedAt: LibraryTimestamp?
    public let sourceURL: String?
    public let scope: LibraryDocumentScope
    public let pageCount: Int
    public let originalObjectID: UUID?
    public let artifactID: UUID?
    public let readiness: LibraryReadiness
    public let originalAvailability: LibraryAssetAvailability?
    public let renderAvailability: LibraryAssetAvailability?
    public let originalAvailabilityRevision: Int64?
    public let renderAvailabilityRevision: Int64?
    /// Migration 020: present (true) only while archived — hidden from the default list, still in the library.
    public let archived: Bool?
    public var isArchived: Bool { archived == true && visible }

    /// A descriptor/download still needs current server authorization. These
    /// are presentation capabilities from the last committed row projection.
    public var canReadOriginal: Bool {
        guard hasVerifiedReadableIdentity else { return false }
        if let originalAvailability { return originalAvailability == .available }
        return readiness == .pdfReady || readiness == .convertedReady
    }
    public var canReadStructured: Bool {
        guard hasVerifiedReadableIdentity, artifactID != nil else { return false }
        if let renderAvailability { return renderAvailability == .available }
        return readiness == .convertedReady
    }

    private var hasVerifiedReadableIdentity: Bool {
        // Private conversions (owner_private) are readable by their owner; the
        // server only ever returns an account's own private items.
        guard visible, approvalID != nil, versionID != nil,
              metadataID != nil, originalObjectID != nil else { return false }
        switch readiness {
        case .pdfReady, .convertedReady, .unavailable: return true
        case .unverified, .unknown: return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, visible, source, metadata, scope, readiness
        case documentID = "document_id", createdSequence = "created_seq", stateSequence = "state_seq"
        case membershipRevision = "membership_revision", addedAt = "added_at", lastRemoveSequence = "last_remove_seq"
        case approvalID = "approval_id", versionID = "version_id", metadataID = "metadata_id"
        case sourceID = "source_id", sourceRevision = "source_revision", metadataRecordedAt = "metadata_recorded_at"
        case sourceURL = "source_url", pageCount = "page_count", originalObjectID = "original_object_id", artifactID = "artifact_id"
        case originalAvailability = "original_availability", renderAvailability = "render_availability"
        case originalAvailabilityRevision = "original_availability_revision", renderAvailabilityRevision = "render_availability_revision"
        case archived
    }

    func validate() throws {
        guard createdSequence > 0, stateSequence >= createdSequence, membershipRevision > 0,
              lastRemoveSequence >= 0, lastRemoveSequence <= stateSequence,
              originalAvailabilityRevision.map({ $0 >= 0 }) ?? true,
              renderAvailabilityRevision.map({ $0 >= 0 }) ?? true,
              (1...250).contains(pageCount) else { throw LibraryProtocolError.invalidEntry }
        try metadata?.validate()
        if approvalID == nil {
            guard versionID == nil, metadataID == nil, source == nil, sourceID == nil,
                  sourceRevision == nil, metadata == nil, metadataRecordedAt == nil, sourceURL == nil,
                  originalObjectID == nil else { throw LibraryProtocolError.invalidEntry }
            if readiness == .pdfReady || readiness == .convertedReady { throw LibraryProtocolError.invalidEntry }
        } else {
            guard versionID != nil, metadataID != nil, let source, let sourceID,
                  bounded(sourceID, 128, minimum: 1), let revision = sourceRevision, validRevision(revision),
                  metadata != nil, metadataRecordedAt != nil, originalObjectID != nil,
                  LibrarySource.validItem(source: source, sourceID: sourceID, revision: revision, url: sourceURL) else {
                throw LibraryProtocolError.invalidEntry
            }
            if readiness == .convertedReady && artifactID == nil { throw LibraryProtocolError.invalidEntry }
            if readiness == .unverified { throw LibraryProtocolError.invalidEntry }
        }
    }
}

public enum LibraryImportPhase: String, Codable, Sendable {
    case accepted, resolving, acquiring, failed, ready, cancelled
    case sourceOnly = "source_only"
    case membershipConflict = "membership_conflict"
}

/// Unknown future codes decode as `.other` so a newer server never breaks the library.
public enum LibraryImportErrorCode: Equatable, Codable, Sendable {
    case metadataUnavailable, downloadFailed, pdfInvalid, rateLimited, licenseUnverified, membershipConflict
    case insufficientCredits, conversionFailed, tooLarge
    case other(String)

    static let known: [String: LibraryImportErrorCode] = [
        "metadata_unavailable": .metadataUnavailable, "download_failed": .downloadFailed, "pdf_invalid": .pdfInvalid,
        "rate_limited": .rateLimited, "license_unverified": .licenseUnverified, "membership_conflict": .membershipConflict,
        "insufficient_credits": .insufficientCredits, "conversion_failed": .conversionFailed, "too_large": .tooLarge,
    ]
    public var rawValue: String {
        if case .other(let raw) = self { return raw }
        return Self.known.first { $0.value == self }!.key
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count <= 64 else { throw LibraryProtocolError.invalidEntry }
        self = Self.known[value] ?? .other(value)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

/// Server-side conversion progress for an active import (finding, downloading,
/// converting, rendering, finishing). Presentation only; unknown values are kept.
public enum LibraryImportProgress: Equatable, Codable, Sendable {
    case finding, downloading, converting, rendering, finishing
    case other(String)

    public var rawValue: String {
        switch self {
        case .finding: "finding"; case .downloading: "downloading"; case .converting: "converting"
        case .rendering: "rendering"; case .finishing: "finishing"; case .other(let raw): raw
        }
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.utf8.count <= 64 else { throw LibraryProtocolError.invalidEntry }
        switch value {
        case "finding": self = .finding; case "downloading": self = .downloading; case "converting": self = .converting
        case "rendering": self = .rendering; case "finishing": self = .finishing; default: self = .other(value)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

/// How far an active import has got (migration 030, `progress_detail`): the step in the reader's words, the
/// percent done and, when the server trusts its estimate, the seconds left. Presentation only, and never a reason
/// to reject an entry: decoding keeps unknown steps and drops values out of range, so a newer or malformed detail
/// can't stop library sync.
public struct LibraryImportProgressDetail: Codable, Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case finding, downloading, readingEquations, preparing, waiting
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "finding": self = .finding; case "downloading": self = .downloading
            case "reading_equations": self = .readingEquations; case "preparing": self = .preparing
            case "waiting": self = .waiting; default: self = .other(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .finding: "finding"; case .downloading: "downloading"; case .readingEquations: "reading_equations"
            case .preparing: "preparing"; case .waiting: "waiting"; case .other(let raw): raw
            }
        }
    }

    public let step: Step
    /// 0–99 while the import is in progress; never lower than an earlier detail of the same attempt.
    public let percent: Int
    /// Seconds left when the server trusts its estimate; without `pages` it is the estimate for a typical paper.
    public let etaSeconds: Int?
    /// Backing off after an error, or paused: there is no estimate to give.
    public let delayed: Bool
    /// Pages being read (the paper's pages, up to the conversion limit), once known.
    public let pages: Int?
    /// Pages the provider has read so far, while equations and figures are being read.
    public let pagesDone: Int?
    /// The PDF's size, while it is being downloaded.
    public let bytes: Int64?

    public init(step: Step, percent: Int, etaSeconds: Int? = nil, delayed: Bool = false, pages: Int? = nil,
                pagesDone: Int? = nil, bytes: Int64? = nil) {
        self.step = step; self.percent = min(100, max(0, percent)); self.etaSeconds = etaSeconds; self.delayed = delayed
        self.pages = pages; self.pagesDone = pagesDone; self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey {
        case step, percent, delayed, pages, bytes
        case etaSeconds = "eta_seconds", pagesDone = "pages_done"
    }

    public init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self.init(step: .other(""), percent: 0); return }
        func number<N: FixedWidthInteger & Decodable>(_ key: CodingKeys, _ range: ClosedRange<N>) -> N? {
            guard let value = try? c.decodeIfPresent(N.self, forKey: key), range.contains(value) else { return nil }
            return value
        }
        let step = (try? c.decodeIfPresent(String.self, forKey: .step)).flatMap { $0.utf8.count <= 64 ? $0 : nil }
        let pages = number(.pages, 1...250)
        let done = number(.pagesDone, 0...250).flatMap { done in pages.map { done <= $0 ? done : nil } ?? done }
        self.init(step: Step(rawValue: step ?? ""), percent: number(.percent, 0...100) ?? 0, etaSeconds: number(.etaSeconds, 0...86_400),
                  delayed: (try? c.decodeIfPresent(Bool.self, forKey: .delayed)) == true, pages: pages, pagesDone: done,
                  bytes: number(.bytes, 1...67_108_864))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(step.rawValue, forKey: .step)
        try c.encode(percent, forKey: .percent)
        try c.encodeIfPresent(etaSeconds, forKey: .etaSeconds)
        if delayed { try c.encode(true, forKey: .delayed) }
        try c.encodeIfPresent(pages, forKey: .pages)
        try c.encodeIfPresent(pagesDone, forKey: .pagesDone)
        try c.encodeIfPresent(bytes, forKey: .bytes)
    }
}

public struct LibraryImportRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdSequence: Int64
    public let stateSequence: Int64
    public let intentRevision: Int64
    public let visible: Bool
    public let phase: LibraryImportPhase
    public let source: String
    public let sourceID: String
    public let requestedRevision: Int?
    public let sourceRevision: Int?
    public let metadataID: UUID?
    public let versionID: UUID?
    public let metadata: LibraryMetadata?
    public let metadataRecordedAt: LibraryTimestamp?
    public let sourceURL: String
    public let documentID: UUID?
    public let libraryItemID: UUID?
    public let errorCode: LibraryImportErrorCode?
    public let retryable: Bool
    public let progress: LibraryImportProgress?
    /// Percent, time left and the step in the reader's words (servers from migration 030; nil before).
    public let progressDetail: LibraryImportProgressDetail?

    private enum CodingKeys: String, CodingKey {
        case id, visible, phase, source, metadata, retryable, progress
        case createdSequence = "created_seq", stateSequence = "state_seq", intentRevision = "intent_revision"
        case sourceID = "source_id", requestedRevision = "requested_revision", sourceRevision = "source_revision"
        case metadataID = "metadata_id", versionID = "version_id", metadataRecordedAt = "metadata_recorded_at"
        case sourceURL = "source_url", documentID = "document_id", libraryItemID = "library_item_id", errorCode = "error_code"
        case progressDetail = "progress_detail"
    }

    func validate() throws {
        guard createdSequence > 0, stateSequence >= createdSequence, intentRevision > 0,
              bounded(sourceID, 128, minimum: 1),
              requestedRevision.map(validRevision) ?? true, sourceRevision.map(validRevision) ?? true,
              LibrarySource.validImport(source: source, sourceID: sourceID, requestedRevision: requestedRevision,
                                        sourceRevision: sourceRevision, url: sourceURL),
              (documentID == nil) == (libraryItemID == nil),
              !retryable || phase == .failed else { throw LibraryProtocolError.invalidEntry }
        if phase == .ready {
            guard !visible, libraryItemID != nil else { throw LibraryProtocolError.invalidEntry }
        } else if phase == .cancelled {
            guard !visible else { throw LibraryProtocolError.invalidEntry }
        }
        if metadataID == nil {
            guard versionID == nil, sourceRevision == nil, metadata == nil, metadataRecordedAt == nil else {
                throw LibraryProtocolError.invalidEntry
            }
        } else {
            guard versionID != nil, sourceRevision != nil, metadata != nil, metadataRecordedAt != nil,
                  requestedRevision == nil || requestedRevision == sourceRevision else { throw LibraryProtocolError.invalidEntry }
        }
        try metadata?.validate()
    }
}

public enum LibraryEntry: Codable, Equatable, Sendable, Identifiable {
    case item(LibraryItemRecord)
    case `import`(LibraryImportRecord)

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(LibraryEntryKind.self, forKey: .kind)
        switch kind {
        case .item: self = .item(try LibraryItemRecord(from: decoder))
        case .import: self = .import(try LibraryImportRecord(from: decoder))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.kind, forKey: .kind)
        switch self {
        case .item(let item): try item.encode(to: encoder)
        case .import(let imported): try imported.encode(to: encoder)
        }
    }

    public var id: LibraryEntryID {
        switch self {
        case .item(let value): .init(kind: .item, entityID: value.id)
        case .import(let value): .init(kind: .import, entityID: value.id)
        }
    }
    public var createdSequence: Int64 {
        switch self { case .item(let value): value.createdSequence; case .import(let value): value.createdSequence }
    }
    public var stateSequence: Int64 {
        switch self { case .item(let value): value.stateSequence; case .import(let value): value.stateSequence }
    }
    public var visible: Bool {
        switch self { case .item(let value): value.visible; case .import(let value): value.visible }
    }

    func validate() throws {
        switch self { case .item(let value): try value.validate(); case .import(let value): try value.validate() }
    }
}

public struct LibraryBaselineCursor: Codable, Equatable, Sendable {
    public let format: Int
    public let accountID: UUID
    public let through: Int64
    public let createdSequence: Int64
    public let entityID: UUID
    public let kind: LibraryEntryKind

    private enum CodingKeys: String, CodingKey {
        case format, through, kind
        case accountID = "account_id", createdSequence = "created_seq", entityID = "id"
    }

    // PostgreSQL's continuation validation requires lowercase UUID strings;
    // Foundation's default UUID encoder emits uppercase.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(accountID.wire, forKey: .accountID)
        try container.encode(through, forKey: .through)
        try container.encode(createdSequence, forKey: .createdSequence)
        try container.encode(entityID.wire, forKey: .entityID)
        try container.encode(kind, forKey: .kind)
    }

    func validate() throws {
        guard format == LibraryWire.format else { throw LibraryProtocolError.unsupportedFormat }
        guard through >= 0, createdSequence > 0, createdSequence <= through else { throw LibraryProtocolError.invalidCursor }
    }
}

public struct LibraryBaselinePage: Decodable, Equatable, Sendable {
    public let format: Int
    public let accountID: UUID
    public let baselineCursor: Int64
    public let retainedAfter: Int64
    public let entries: [LibraryEntry]
    /// A nonempty final page also has a next_cursor in migration 010.
    public let nextCursor: LibraryBaselineCursor?
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case format, entries
        case accountID = "account_id", baselineCursor = "baseline_cursor", retainedAfter = "retained_after"
        case nextCursor = "next_cursor", hasMore = "has_more"
    }

    func validate() throws {
        guard format == LibraryWire.format else { throw LibraryProtocolError.unsupportedFormat }
        guard baselineCursor >= 0, retainedAfter >= 0, entries.count <= LibraryWire.maximumPageCount else {
            throw LibraryProtocolError.invalidPage
        }
        guard retainedAfter <= baselineCursor else { throw LibraryProtocolError.resyncRequired }
        guard entries.isEmpty == (nextCursor == nil), !hasMore || !entries.isEmpty else {
            throw LibraryProtocolError.invalidCursor
        }
        var previous: LibraryOrderingKey?
        for entry in entries {
            try entry.validate()
            let key = LibraryOrderingKey(entry)
            guard entry.createdSequence <= baselineCursor, previous.map({ $0 < key }) ?? true else {
                throw LibraryProtocolError.invalidPage
            }
            previous = key
        }
        if let cursor = nextCursor {
            try cursor.validate()
            guard cursor.accountID == accountID, cursor.through == baselineCursor,
                  previous == LibraryOrderingKey(cursor) else { throw LibraryProtocolError.invalidCursor }
        }
    }
}

public struct LibraryChangeBatch: Decodable, Equatable, Sendable {
    public let sequence: Int64
    public let entries: [LibraryEntry]
    private enum CodingKeys: String, CodingKey { case sequence = "seq", entries }
}

public struct LibraryChangesPage: Decodable, Equatable, Sendable {
    public let format: Int
    public let accountID: UUID
    public let through: Int64
    public let retainedAfter: Int64
    public let changes: [LibraryChangeBatch]
    public let nextCursor: Int64
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case format, through, changes
        case accountID = "account_id", retainedAfter = "retained_after", nextCursor = "next_cursor", hasMore = "has_more"
    }

    func validate() throws {
        guard format == LibraryWire.format else { throw LibraryProtocolError.unsupportedFormat }
        guard through >= 0, retainedAfter >= 0, retainedAfter <= through, nextCursor >= 0, nextCursor <= through,
              changes.count <= LibraryWire.maximumPageCount else { throw LibraryProtocolError.invalidPage }
        var previous: Int64 = 0
        for batch in changes {
            guard batch.sequence > previous, batch.sequence <= through, (1...4).contains(batch.entries.count),
                  Set(batch.entries.map(\.id)).count == batch.entries.count else { throw LibraryProtocolError.invalidPage }
            for entry in batch.entries {
                try entry.validate()
                // A batch can include an unchanged item alongside an import.
                guard entry.stateSequence <= batch.sequence else { throw LibraryProtocolError.invalidPage }
            }
            previous = batch.sequence
        }
        if hasMore {
            guard let last = changes.last, nextCursor == last.sequence, nextCursor < through else {
                throw LibraryProtocolError.invalidCursor
            }
        } else {
            guard nextCursor == through else { throw LibraryProtocolError.invalidCursor }
        }
        guard changes.last.map({ $0.sequence <= nextCursor }) ?? true else { throw LibraryProtocolError.invalidCursor }
    }
}

public struct LibraryCommandResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case applied; case revisionConflict = "revision_conflict" }
    public let status: Status
    public let kind: LibraryEntryKind
    /// A conflict against an absent item has a null id and revision zero.
    public let id: UUID?
    public let sequence: Int64?
    public let revision: Int64
    private enum CodingKeys: String, CodingKey { case status, kind, id, sequence = "seq", revision }
}

public struct LibraryCommandResponse: Decodable, Equatable, Sendable {
    public let result: LibraryCommandResult
    public let replayed: Bool
    /// This is current state, not the historical state recorded by result.seq.
    public let entry: LibraryEntry?

    func validate() throws {
        guard result.revision >= 0, result.sequence.map({ $0 > 0 }) ?? true else { throw LibraryProtocolError.invalidCommand }
        if result.status == .applied {
            guard result.id != nil, result.sequence != nil, result.revision > 0 else { throw LibraryProtocolError.invalidCommand }
        }
        if let entry {
            try entry.validate()
            guard let id = result.id, entry.id == LibraryEntryID(kind: result.kind, entityID: id),
                  result.sequence.map({ $0 <= entry.stateSequence }) ?? true else { throw LibraryProtocolError.invalidCommand }
        } else if result.id != nil {
            throw LibraryProtocolError.invalidCommand
        }
    }
}

struct LibraryOrderingKey: Comparable, Sendable {
    let sequence: Int64
    let uuid: String
    let kind: String

    init(_ entry: LibraryEntry) {
        sequence = entry.createdSequence; uuid = entry.id.entityID.wire; kind = entry.id.kind.rawValue
    }
    init(_ cursor: LibraryBaselineCursor) {
        sequence = cursor.createdSequence; uuid = cursor.entityID.wire; kind = cursor.kind.rawValue
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
        return lhs.kind < rhs.kind
    }
}

private func bounded(_ value: String, _ maximum: Int, minimum: Int = 0) -> Bool {
    let count = value.unicodeScalars.count
    return count >= minimum && count <= maximum
}

private func validRevision(_ value: Int) -> Bool { value > 0 && value <= 2_147_483_647 }

private func arxivURL(_ source: String, _ revision: Int?) -> String {
    "https://arxiv.org/abs/" + source + (revision.map { "v\($0)" } ?? "")
}

/// Where a library paper came from. v3 library reads carry arXiv papers and web
/// papers: open-access copies found through OpenAlex (`openalex:W…`, revision 1),
/// converted privately for this account. v2 reads (older builds) carry arXiv only.
public enum LibrarySource {
    public static let arxiv = "arxiv", web = "web"

    public static func isWebSourceID(_ value: String) -> Bool {
        let digits = value.utf8.dropFirst("openalex:W".utf8.count)
        return value.hasPrefix("openalex:W") && (1...15).contains(digits.count) && digits.first != 48
            && digits.allSatisfy { (48...57).contains($0) }
    }

    /// The OpenAlex page of a web paper's work (its source URL until the paper is pinned).
    public static func openAlexURL(_ sourceID: String) -> String {
        "https://openalex.org/works/" + sourceID.dropFirst("openalex:".count)
    }

    /// Short source label: "arXiv v3", "arXiv", or "Open access" for a web paper.
    public static func badge(sourceID: String?, revision: Int?) -> String? {
        guard let sourceID else { return nil }
        if isWebSourceID(sourceID) { return "Open access" }
        return revision.map { "arXiv v\($0)" } ?? "arXiv"
    }

    /// Title shown before a paper's metadata arrives.
    public static func placeholderTitle(sourceID: String) -> String {
        isWebSourceID(sourceID) ? "Open-access paper" : "arXiv \(sourceID)"
    }

    static func validItem(source: String, sourceID: String, revision: Int, url: String?) -> Bool {
        switch source {
        case arxiv: return url == arxivURL(sourceID, revision)
        case web: return isWebSourceID(sourceID) && revision == 1 && url.map(validHTTPS) == true
        default: return false
        }
    }

    static func validImport(source: String, sourceID: String, requestedRevision: Int?, sourceRevision: Int?, url: String) -> Bool {
        switch source {
        case arxiv: return url == arxivURL(sourceID, sourceRevision ?? requestedRevision)
        case web: return isWebSourceID(sourceID) && requestedRevision == nil && (sourceRevision ?? 1) == 1 && url == openAlexURL(sourceID)
        default: return false
        }
    }

    static func validHTTPS(_ value: String) -> Bool {
        guard bounded(value, 512, minimum: 9), value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return false }
        return true
    }
}

private func validCalendarDate(_ value: String) -> Bool {
    guard value.utf8.count == 10 else { return false }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year > 0 else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    return actual.year == year && actual.month == month && actual.day == day
}
