import Foundation

public enum LibraryCatalogError: Error, Equatable, LocalizedError {
    case invalidName, invalidOperation, unavailable, pendingChanges, changedDuringDeletion
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Choose a different name, up to 80 characters."
        case .invalidOperation: "This catalog change couldn’t be saved."
        case .unavailable: "Your library isn’t ready for this change. Unlock it and try again."
        case .pendingChanges: "Some paper changes haven’t finished syncing. The catalog is still here with its remaining papers."
        case .changedDuringDeletion: "Papers were added or moved into this catalog while it was being deleted. Review the remaining papers before deleting it."
        }
    }
}

public struct LibraryCatalog: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
}

/// An encrypted, old-reader-compatible note payload. Logical batch IDs survive key rotation;
/// envelope IDs and device clocks never decide which concurrent rename/assignment wins.
public struct LibraryCatalogBatch: Codable, Equatable, Sendable {
    public static let format = "library-catalog-v1"
    public static let entityID = UUID(uuidString: "ad734100-688f-4fd1-9379-a0f1b0186c42")!
    public static let initialCatalogID = UUID(uuidString: "c2436200-0be6-4cbb-8b72-75605729a980")!
    public let format: String
    public let batchID: UUID
    public let operations: [Operation]

    public struct Operation: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable { case create, rename, makeDefault, assign, retire }
        public let action: Action
        public let catalogID: UUID
        public var name: String?
        public var paperKey: String?
        public var destinationID: UUID?
        public init(_ action: Action, catalogID: UUID, name: String? = nil, paperKey: String? = nil, destinationID: UUID? = nil) {
            self.action = action; self.catalogID = catalogID; self.name = name
            self.paperKey = paperKey; self.destinationID = destinationID
        }
        func validate() throws {
            switch action {
            case .create, .rename:
                guard let name, LibraryCatalogBatch.normalizedName(name) == name, paperKey == nil, destinationID == nil else {
                    throw LibraryCatalogError.invalidName
                }
            case .makeDefault:
                guard name == nil, paperKey == nil, destinationID == nil else { throw LibraryCatalogError.invalidOperation }
            case .assign:
                guard name == nil, destinationID == nil, let paperKey, LibraryCatalogBatch.validPaperKey(paperKey) else {
                    throw LibraryCatalogError.invalidOperation
                }
            case .retire:
                guard name == nil, paperKey == nil, let destinationID, destinationID != catalogID else {
                    throw LibraryCatalogError.invalidOperation
                }
            }
        }
    }

    public init(operations: [Operation], batchID: UUID = UUID()) throws {
        self.format = Self.format; self.batchID = batchID; self.operations = operations
        try validate()
    }
    func validate() throws {
        guard format == Self.format, !operations.isEmpty, operations.count <= 64 else { throw LibraryCatalogError.invalidOperation }
        for operation in operations { try operation.validate() }
    }
    public static func normalizedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 80, name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    public static func arxivKey(_ input: String) -> String? {
        (try? ArxivReference(input)).map { "arxiv:" + $0.sourceID }
    }
    public static func documentKey(_ id: UUID) -> String { "paper:" + id.wire }
    /// A web (open-access, `openalex:W…`) paper: its source identity is the same for the pending import and the
    /// installed paper, where the import and document IDs differ. Older readers ignore a batch with this key (the
    /// paper then shows in their Default catalog), so it is written in a batch of its own.
    public static func sourceKey(_ sourceID: String) -> String? {
        LibrarySource.isWebSourceID(sourceID) ? "source:" + sourceID : nil
    }
    public static func validPaperKey(_ key: String) -> Bool {
        if key.hasPrefix("arxiv:") { return arxivKey(String(key.dropFirst(6))) == key }
        if key.hasPrefix("source:") { return sourceKey(String(key.dropFirst(7))) == key }
        if key.hasPrefix("paper:"), let id = UUID(uuidString: String(key.dropFirst(6))) { return documentKey(id) == key }
        return false
    }
    public func event(in state: PrivateState) throws -> PrivateEvent {
        try validate()
        guard !state.isDeleted(Self.entityID) else { throw LibraryCatalogError.unavailable }
        let heads = state.revisions(for: Self.entityID).map(\.id)
        guard heads.count <= 100 else { throw LibraryCatalogError.unavailable }
        let text = String(decoding: try ReaderCrypto.encode(self), as: UTF8.self)
        return PrivateEvent(kind: .note, entityID: Self.entityID, parents: heads, text: text)
    }
    static func decode(_ event: PrivateEvent) -> Self? {
        guard event.kind == .note, event.entityID == entityID, event.documentID == nil,
              event.conversationID == nil, let text = event.text, text.utf8.count <= 32_768,
              let batch = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              (try? batch.validate()) != nil else { return nil }
        return batch
    }
}

public struct LibraryCatalogState: Equatable, Sendable {
    public let catalogs: [LibraryCatalog]
    public let defaultID: UUID
    private let assignments: [String: UUID]
    private let redirects: [UUID: UUID]
    private let activeIDs: Set<UUID>
    private let fallbackID: UUID

    public init(_ state: PrivateState = PrivateState()) {
        let initial = LibraryCatalogBatch.initialCatalogID
        var names = [initial: "Default"], assigned: [String: UUID] = [:], redirects: [UUID: UUID] = [:]
        var retired = Set<UUID>(), preferred = initial
        let records = state.events.filter { $0.value.payload.entityID == LibraryCatalogBatch.entityID }
        if !state.isDeleted(LibraryCatalogBatch.entityID) {
            // Unknown future payloads still supply causal ancestry. Missing parents defer their descendants.
            var remaining: [UUID: Int] = [:], children: [UUID: [UUID]] = [:], height: [UUID: Int] = [:], queue: [UUID] = []
            for (id, record) in records {
                let parents = record.payload.parents
                remaining[id] = parents.count
                for parent in parents { children[parent, default: []].append(id) }
                if parents.isEmpty { height[id] = 0; queue.append(id) }
            }
            var offset = 0
            while offset < queue.count {
                let id = queue[offset]; offset += 1
                for child in children[id] ?? [] {
                    height[child] = max(height[child] ?? 0, (height[id] ?? 0) + 1)
                    remaining[child, default: 0] -= 1
                    if remaining[child] == 0 { queue.append(child) }
                }
            }
            let batches = queue.compactMap { id -> (UUID, Int, LibraryCatalogBatch)? in
                guard let record = records[id], let batch = LibraryCatalogBatch.decode(record.payload) else { return nil }
                return (id, height[id] ?? 0, batch)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.2.batchID != $1.2.batchID { return $0.2.batchID.wire < $1.2.batchID.wire }
                return $0.0.wire < $1.0.wire
            }
            var seen = Set<UUID>()
            for (_, _, batch) in batches where seen.insert(batch.batchID).inserted {
                for op in batch.operations {
                    switch op.action {
                    case .create:
                        if names[op.catalogID] == nil && !retired.contains(op.catalogID) { names[op.catalogID] = op.name! }
                    case .rename:
                        if names[op.catalogID] != nil { names[op.catalogID] = op.name! }
                    case .makeDefault: preferred = op.catalogID
                    case .assign: assigned[op.paperKey!] = op.catalogID
                    case .retire:
                        if retired.insert(op.catalogID).inserted {
                            names.removeValue(forKey: op.catalogID); redirects[op.catalogID] = op.destinationID!
                        }
                    }
                }
            }
        }
        // Concurrent deletion cannot make an existing paper inaccessible. This virtual recovery catalog is
        // used only when every real catalog was retired; normal last-catalog deletion creates a replacement.
        if names.isEmpty { names[initial] = "Default" }
        activeIDs = Set(names.keys)
        fallbackID = names[initial] != nil ? initial : names.keys.sorted { $0.wire < $1.wire }.first!
        self.assignments = assigned; self.redirects = redirects
        catalogs = names.map { LibraryCatalog(id: $0.key, name: $0.value) }.sorted {
            $0.name == $1.name ? $0.id.wire < $1.id.wire : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        defaultID = Self.resolve(preferred, redirects: redirects, active: activeIDs, fallback: fallbackID)
    }
    private static func resolve(_ requested: UUID, redirects: [UUID: UUID], active: Set<UUID>, fallback: UUID) -> UUID {
        var current = requested, visited = Set<UUID>()
        while let next = redirects[current] {
            guard visited.insert(current).inserted else { return fallback }
            current = next
        }
        return active.contains(current) ? current : fallback
    }
    public func resolved(_ id: UUID) -> UUID { Self.resolve(id, redirects: redirects, active: activeIDs, fallback: fallbackID) }
    public func catalogID(for paperKey: String) -> UUID { resolved(assignments[paperKey] ?? LibraryCatalogBatch.initialCatalogID) }
    /// Whether any batch assigned this key (a paper with two possible keys uses the assigned one).
    public func isAssigned(_ paperKey: String) -> Bool { assignments[paperKey] != nil }
    public func catalog(_ id: UUID) -> LibraryCatalog? { catalogs.first { $0.id == id } }
}
