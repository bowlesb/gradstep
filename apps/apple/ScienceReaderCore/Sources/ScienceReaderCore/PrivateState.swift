import Foundation

public struct PrivateEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case conversation, message, note, position, diagram, tombstone }
    public enum Role: String, Codable, Sendable { case user, assistant }
    public enum TurnStatus: String, Codable, Sendable { case complete, interrupted }
    public let kind: Kind
    public let entityID: UUID
    public var parents: [UUID]
    public var conversationID: UUID?
    public var documentID: UUID?
    public var text: String?
    public var role: Role?
    public var status: TurnStatus?
    public var anchor: TextAnchor?

    public init(kind: Kind, entityID: UUID = UUID(), parents: [UUID] = [], conversationID: UUID? = nil,
                documentID: UUID? = nil, text: String? = nil, role: Role? = nil,
                status: TurnStatus? = nil, anchor: TextAnchor? = nil) {
        self.kind = kind; self.entityID = entityID; self.parents = parents
        self.conversationID = conversationID; self.documentID = documentID; self.text = text
        self.role = role; self.status = status; self.anchor = anchor
    }

    public func validate() throws {
        guard parents.count <= 100, Set(parents).count == parents.count, (text?.utf8.count ?? 0) <= 200_000 else { throw ReaderError.invalidEvent }
        if kind == .message { guard conversationID != nil, role != nil, status != nil, text != nil else { throw ReaderError.invalidEvent } }
        if kind == .note || kind == .diagram || kind == .conversation { guard text != nil else { throw ReaderError.invalidEvent } }
        if kind == .position { guard documentID != nil, anchor != nil else { throw ReaderError.invalidEvent } }
        if let anchor { try anchor.validate() }
    }
}

public struct TextAnchor: Codable, Equatable, Sendable {
    public let artifactID: UUID
    public let quote: String
    public let prefix: String
    public let suffix: String
    public let elementID: String?
    public let page: Int?

    public init(artifactID: UUID, quote: String, prefix: String = "", suffix: String = "", elementID: String? = nil, page: Int? = nil) {
        self.artifactID = artifactID; self.quote = quote; self.prefix = prefix; self.suffix = suffix; self.elementID = elementID; self.page = page
    }

    func validate() throws {
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

    public init() {}

    public mutating func apply(_ event: AppliedEvent) throws {
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
        return heads.map { head in
            var path: [AppliedEvent] = [], next: UUID? = head.id, visited = Set<UUID>(), complete = true
            while let id = next {
                guard visited.insert(id).inserted, let event = events[id] else { complete = false; break }
                guard event.payload.kind == .message, event.payload.conversationID == conversationID else { complete = false; break }
                if !deleted.contains(event.payload.entityID) { path.append(event) }
                var predecessors: [UUID] = []
                for parentID in event.payload.parents {
                    guard let parent = events[parentID] else { complete = false; continue }
                    if parent.payload.kind == .message, parent.payload.conversationID == conversationID { predecessors.append(parentID) }
                    else if parent.payload.kind != .conversation || parent.payload.entityID != conversationID { complete = false }
                }
                guard predecessors.count <= 1 else { complete = false; break }
                next = predecessors.first
            }
            return ConversationBranch(head: head.id, messages: path.reversed(), complete: complete)
        }
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
