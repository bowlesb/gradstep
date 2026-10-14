import Foundation

public struct PrivateEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case conversation, message, note, position, diagram, tombstone; case localPaper = "local_paper" }
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum TurnStatus: String, Codable, Sendable { case complete, interrupted }
    public let kind: Kind
    public let entityID: UUID
    public var parents: [UUID]
    public var conversationID: UUID?
    private var legacyDocumentID: UUID?
    public private(set) var paperReference: SourcePaperReference?
    /// Presentation identity only. Serialization preserves the explicit source
    /// reference and never writes a membership UUID as a server document ID.
    public var documentID: UUID? {
        get { paperReference?.membershipID ?? legacyDocumentID }
        set { legacyDocumentID = newValue; paperReference = nil }
    }
    private enum CodingKeys: String, CodingKey {
        case kind, entityID, parents, conversationID, paperReference, text, role, status, anchor, createdAt, titleSource, model, profile
        case legacyDocumentID = "documentID"
    }
    public mutating func bind(to reference: SourcePaperReference) throws {
        try reference.validate()
        guard documentID == nil || documentID == reference.membershipID else { throw ReaderError.invalidEvent }
        legacyDocumentID = nil; paperReference = reference
    }
    public var text: String?
    public var role: Role?
    public var status: TurnStatus?
    public var anchor: TextAnchor?
    /// When the author device wrote the event: Unix time in milliseconds by that device's clock. Inside the
    /// encrypted payload, so the service learns nothing new; shown as "Last used"/"Started" in All chats, never
    /// used for ordering decisions. Absent on events written before 2026-10-07 (older decoders ignore the key).
    public var createdAt: Int64?
    /// On a conversation revision (2026-10-08): where its title (`text`) came from, `generated` (a topic title the
    /// chat service wrote) or `renamed` (the reader's own). Absent on the original revision, whose title is the first
    /// question. A string, not an enum, so a later value never stops an older reader decoding the event.
    public var titleSource: String?
    /// On an answer (2026-10-08): the model that wrote it (`claude-sonnet-5-5`; a fallback model when one served) and
    /// the chat profile it was asked with (`sonnet-low-standard`). Shown under the answer; absent on older answers.
    public var model: String?
    public var profile: String?

    public init(kind: Kind, entityID: UUID = UUID(), parents: [UUID] = [], conversationID: UUID? = nil,
                documentID: UUID? = nil, text: String? = nil, role: Role? = nil,
                status: TurnStatus? = nil, anchor: TextAnchor? = nil, createdAt: Int64? = nil,
                titleSource: String? = nil, model: String? = nil, profile: String? = nil, paperReference: SourcePaperReference? = nil) {
        self.kind = kind; self.entityID = entityID; self.parents = parents
        self.conversationID = conversationID; self.legacyDocumentID = paperReference == nil ? documentID : nil; self.paperReference = paperReference; self.text = text
        self.role = role; self.status = status; self.anchor = anchor; self.createdAt = createdAt
        self.titleSource = titleSource; self.model = model; self.profile = profile
    }

    /// Bound on `titleSource`, `model` and `profile` (UTF-8 bytes). Only the length is checked, on every kind, so a
    /// later build's values never make this build reject (and stop syncing) an event.
    public static let maximumLabelBytes = 64

    public static let generatedTitle = "generated"
    public static let renamedTitle = "renamed"

    /// `createdAt` for a date (whole milliseconds).
    public static func timestamp(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// The author's creation time, when recorded.
    public var createdDate: Date? { createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    public func validate() throws {
        if let paperReference { try paperReference.validate(); guard legacyDocumentID == nil else { throw ReaderError.invalidEvent } }
        guard parents.count <= 100, Set(parents).count == parents.count, (text?.utf8.count ?? 0) <= 200_000 else { throw ReaderError.invalidEvent }
        // Any device clock is accepted (display only); the bound keeps the value a representable date.
        if let createdAt { guard createdAt >= 0, createdAt < 253_402_300_800_000 else { throw ReaderError.invalidEvent } }
        for label in [titleSource, model, profile] {
            if let label { guard label.utf8.count <= Self.maximumLabelBytes else { throw ReaderError.invalidEvent } }
        }
        if kind == .message { guard conversationID != nil, role != nil, status != nil, text != nil else { throw ReaderError.invalidEvent } }
        if kind == .note || kind == .diagram || kind == .conversation { guard text != nil else { throw ReaderError.invalidEvent } }
        if kind == .position { guard documentID != nil, anchor != nil else { throw ReaderError.invalidEvent } }
        if let anchor { try anchor.validate() }
        if kind == .localPaper { _ = try LocalPDFMembership.decode(self) }
    }
}

public struct TextAnchor: Codable, Equatable, Sendable {
    public let artifactID: UUID?
    public let manifestSHA256: String?
    public let quote: String
    public let prefix: String
    public let suffix: String
    public let elementID: String?
    public let page: Int?

    public init(artifactID: UUID? = nil, manifestSHA256: String? = nil, quote: String, prefix: String = "", suffix: String = "", elementID: String? = nil, page: Int? = nil) {
        self.artifactID = artifactID; self.manifestSHA256 = manifestSHA256; self.quote = quote; self.prefix = prefix; self.suffix = suffix; self.elementID = elementID; self.page = page
    }

    func validate() throws {
        guard (artifactID == nil) != (manifestSHA256 == nil) else { throw ReaderError.invalidEvent }
        if let manifestSHA256 {
            guard manifestSHA256.utf8.count == 64, manifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ReaderError.invalidEvent }
        }
        guard quote.utf8.count <= 20_000, prefix.utf8.count <= 1000, suffix.utf8.count <= 1000,
              (elementID?.utf8.count ?? 0) <= 200, page == nil || (page! > 0 && page! <= 250) else { throw ReaderError.invalidEvent }
    }
}

public struct AppliedEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let payload: PrivateEvent
    public init(id: UUID, deviceID: UUID, payload: PrivateEvent) { self.id = id; self.deviceID = deviceID; self.payload = payload }
}

public struct ConversationBranch: Equatable, Sendable {
    public let head: UUID
    public let messages: [AppliedEvent]
    public let complete: Bool
}

/// Immutable revisions plus tombstones. Arrival order never chooses the winner of
/// concurrent edits. The UI presents all surviving heads for explicit resolution.
public struct PrivateState: Codable, Equatable, Sendable {
    public private(set) var events: [UUID: AppliedEvent] = [:]
    private var localReplacements: [UUID: UUID] = [:]
    /// The order this state applied its events: on this device, the local journal's order (records at load, then
    /// appends and pulls). Only a presentation hint for history written before events carried `createdAt`; it is
    /// not encoded or compared, so states with the same events are equal whatever their arrival order.
    private var arrival: [UUID: Int] = [:]
    private var nextArrival = 0

    private enum CodingKeys: String, CodingKey { case events, localReplacements }

    public static func == (lhs: PrivateState, rhs: PrivateState) -> Bool {
        lhs.events == rhs.events && lhs.localReplacements == rhs.localReplacements
    }

    public init() {}

    /// Position of an event in this state's arrival order (larger is later); nil for unknown events.
    public func arrivalIndex(_ eventID: UUID) -> Int? { arrival[eventID] }

    public func resolvedEventID(_ id: UUID) -> UUID {
        var current = id, visited = Set<UUID>()
        while let next = localReplacements[current], visited.insert(current).inserted { current = next }
        return current
    }

    /// Only the local store calls this after an authenticated replacement marker.
    /// Both revisions must preserve logical identity/content; only causal event
    /// IDs and author devices may change. Cloud events never carry this marker.
    mutating func applyLocalReplacements(_ mapping: [UUID: UUID]) throws {
        guard !mapping.isEmpty, Set(mapping.values).count == mapping.count,
              Set(mapping.keys).isDisjoint(with: Set(mapping.values)) else { throw ReaderError.corruptData }
        for (oldID, newID) in mapping {
            guard let old = events[oldID], let new = events[newID], localReplacements[oldID] == nil else { throw ReaderError.corruptData }
            var expected = old.payload
            expected.parents = expected.parents.map { mapping[$0] ?? $0 }
            guard expected == new.payload else { throw ReaderError.corruptData }
        }
        let retired = Set(mapping.keys)
        guard events.values.filter({ !retired.contains($0.id) }).allSatisfy({ Set($0.payload.parents).isDisjoint(with: retired) }) else { throw ReaderError.corruptData }
        for (oldID, newID) in mapping {
            events.removeValue(forKey: oldID); localReplacements[oldID] = newID
            // A re-sealed event keeps its original place in the arrival order.
            if let original = arrival.removeValue(forKey: oldID) { arrival[newID] = min(original, arrival[newID] ?? original) }
        }
    }

    public mutating func apply(_ event: AppliedEvent) throws {
        guard localReplacements[event.id] == nil else { throw ReaderError.eventConflict }
        guard event.payload.parents.allSatisfy({ localReplacements[$0] == nil }) else { throw ReaderError.invalidEvent }
        try event.payload.validate()
        if let existing = events[event.id] {
            guard existing == event else { throw ReaderError.eventConflict }
            return
        }
        guard !event.payload.parents.contains(event.id) else { throw ReaderError.invalidEvent }
        events[event.id] = event
        // Reject malformed cycles even when a parent arrives after its child.
        if containsCycle(from: event.id) {
            events.removeValue(forKey: event.id)
            throw ReaderError.invalidEvent
        }
        arrival[event.id] = nextArrival; nextArrival += 1
    }

    private func containsCycle(from id: UUID) -> Bool {
        var stack: [(UUID, Bool)] = [(id, false)], active = Set<UUID>(), finished = Set<UUID>()
        while let (current, leaving) = stack.popLast() {
            if leaving { active.remove(current); finished.insert(current); continue }
            if finished.contains(current) { continue }
            if !active.insert(current).inserted { return true }
            stack.append((current, true))
            for parent in events[current]?.payload.parents ?? [] { stack.append((parent, false)) }
        }
        return false
    }

    /// Each continuation follows its causal predecessor. Concurrent children are
    /// separate branches; UUID sorting is only a stable order for the picker.
    public func conversationBranches(_ conversationID: UUID) -> [ConversationBranch] {
        let deleted = Set(events.values.filter { $0.payload.kind == .tombstone }.map { $0.payload.entityID })
        guard !deleted.contains(conversationID) else { return [] }
        let messages = events.values.filter { $0.payload.kind == .message && $0.payload.conversationID == conversationID && !deleted.contains($0.payload.entityID) }
        var parents = Set<UUID>()
        for message in messages {
            var candidates = message.payload.parents, visited = Set<UUID>()
            while let id = candidates.popLast() {
                guard visited.insert(id).inserted, let parent = events[id], parent.payload.kind == .message,
                      parent.payload.conversationID == conversationID else { continue }
                if deleted.contains(parent.payload.entityID) { candidates.append(contentsOf: parent.payload.parents) }
                else { parents.insert(id) }
            }
        }
        let heads = messages.filter { !parents.contains($0.id) }.sorted { $0.id.wire < $1.id.wire }
        return heads.compactMap { conversationBranch(conversationID, through: $0.id, deleted: deleted) }
    }

    /// Projects the history through a retained causal tip, even when the tip is
    /// now an interior or deleted message. Deleted text stays omitted; keeping
    /// its event ID does not select a sibling or resurrect the deleted entity.
    public func conversationBranch(_ conversationID: UUID, through head: UUID) -> ConversationBranch? {
        let deleted = Set(events.values.filter { $0.payload.kind == .tombstone }.map { $0.payload.entityID })
        return conversationBranch(conversationID, through: head, deleted: deleted)
    }

    private func conversationBranch(_ conversationID: UUID, through head: UUID, deleted: Set<UUID>) -> ConversationBranch? {
        let resolvedHead = resolvedEventID(head)
        guard !deleted.contains(conversationID), let first = events[resolvedHead],
              first.payload.kind == .message, first.payload.conversationID == conversationID else { return nil }
        var path: [AppliedEvent] = [], next: UUID? = resolvedHead, visited = Set<UUID>(), complete = true
        while let id = next {
            guard visited.insert(id).inserted, let event = events[id] else { complete = false; break }
            guard event.payload.kind == .message, event.payload.conversationID == conversationID else { complete = false; break }
            if !deleted.contains(event.payload.entityID) { path.append(event) }
            var predecessors: [UUID] = []
            for originalParentID in event.payload.parents {
                let parentID = resolvedEventID(originalParentID)
                guard let parent = events[parentID] else { complete = false; continue }
                if parent.payload.kind == .message, parent.payload.conversationID == conversationID { predecessors.append(parentID) }
                else if parent.payload.kind != .conversation || parent.payload.entityID != conversationID { complete = false }
            }
            guard predecessors.count <= 1 else { complete = false; break }
            next = predecessors.first
        }
        return ConversationBranch(head: resolvedHead, messages: path.reversed(), complete: complete)
    }

    public func isDeleted(_ entityID: UUID) -> Bool {
        events.values.contains { $0.payload.entityID == entityID && $0.payload.kind == .tombstone }
    }

    public func revisions(for entityID: UUID) -> [AppliedEvent] {
        guard !isDeleted(entityID) else { return [] }
        let revisions = events.values.filter { $0.payload.entityID == entityID && $0.payload.kind != .tombstone }
        let superseded = Set(revisions.flatMap { $0.payload.parents })
        return revisions.filter { !superseded.contains($0.id) }.sorted { $0.id.wire < $1.id.wire }
    }

    public func entities(kind: PrivateEvent.Kind) -> [UUID] {
        Set(events.values.filter { $0.payload.kind == kind }.map { $0.payload.entityID })
            .filter { !isDeleted($0) }.sorted { $0.wire < $1.wire }
    }
}
