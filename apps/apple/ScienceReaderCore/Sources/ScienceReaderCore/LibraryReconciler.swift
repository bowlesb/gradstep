import Foundation

/// Requests are issued by a reconciler, not reconstructed from a row revision.
/// Tickets are deliberately not Codable: they own one in-memory account session.
public struct LibraryPageRequest: Equatable, Sendable {
    public enum Query: Equatable, Sendable {
        case baseline(cursor: LibraryBaselineCursor?)
        case changes(after: Int64, through: Int64?)
    }

    public let accountID: UUID
    public let sessionID: UUID
    public let requestID: UUID
    public let query: Query
    public let limit: Int

    fileprivate init(accountID: UUID, sessionID: UUID, query: Query, limit: Int) {
        self.accountID = accountID; self.sessionID = sessionID
        requestID = UUID(); self.query = query; self.limit = limit
    }
}

public struct LibraryCommandTicket: Equatable, Sendable {
    public let accountID: UUID
    public let sessionID: UUID
    public let operationID: UUID

    fileprivate init(accountID: UUID, sessionID: UUID, operationID: UUID) {
        self.accountID = accountID; self.sessionID = sessionID; self.operationID = operationID
    }
}

public struct LibraryMergeResult: Equatable, Sendable {
    public let disposition: Disposition
    public let insertedOrUpdated: Int
    public let ignoredOlderEntries: Int
    public let identicalEntries: Int

    public enum Disposition: Equatable, Sendable { case applied, ignoredStaleResponse }
    fileprivate static let stale = Self(disposition: .ignoredStaleResponse, insertedOrUpdated: 0,
                                        ignoredOlderEntries: 0, identicalEntries: 0)
    fileprivate static let empty = Self(disposition: .applied, insertedOrUpdated: 0,
                                        ignoredOlderEntries: 0, identicalEntries: 0)
    fileprivate func adding(_ other: Self) -> Self {
        Self(disposition: .applied, insertedOrUpdated: insertedOrUpdated + other.insertedOrUpdated,
             ignoredOlderEntries: ignoredOlderEntries + other.ignoredOlderEntries,
             identicalEntries: identicalEntries + other.identicalEntries)
    }
}

/// A bounded, device-memory projection of one account's v2 library.
///
/// Rows can be observed ahead of the complete account cursor, including on a
/// baseline or in a command response. Only accepted delta pages advance that
/// cursor. Entries remain available during a pull but `phase` explicitly marks
/// an incomplete baseline/catch-up. Nothing here persists data or performs I/O.
public struct LibraryReconciler: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case baseline, catchingUp, ready }

    public private(set) var accountID: UUID
    public private(set) var sessionID: UUID
    public private(set) var phase: Phase = .baseline
    public private(set) var entries: [LibraryEntryID: LibraryEntry] = [:]
    /// Nil until every baseline page has been consumed. It is never a row max.
    public private(set) var committedCursor: Int64?
    public private(set) var baselineBoundary: Int64?
    public private(set) var catchUpBoundary: Int64?
    public private(set) var inFlightRequest: LibraryPageRequest?

    private var baselineContinuation: LibraryBaselineCursor?

    public init(accountID: UUID) {
        self.accountID = accountID
        sessionID = UUID()
    }

    /// Reset is an explicit new session, including for a same-account resync.
    /// A caller may keep an old presentation separately, but may not reuse its
    /// request tickets, entries or cursor in the new protocol session.
    public mutating func reset(accountID: UUID) {
        self = Self(accountID: accountID)
    }

    /// Return the same ticket for a transport retry until it is accepted/reset.
    /// Calling after `ready` begins another bounded catch-up cycle.
    public mutating func nextRequest(limit: Int = LibraryWire.maximumPageCount) throws -> LibraryPageRequest {
        guard (1...LibraryWire.maximumPageCount).contains(limit) else { throw LibraryProtocolError.invalidPage }
        if let inFlightRequest { return inFlightRequest }
        let query: LibraryPageRequest.Query
        switch phase {
        case .baseline:
            query = .baseline(cursor: baselineContinuation)
        case .catchingUp, .ready:
            guard let committedCursor else { throw LibraryProtocolError.invalidCursor }
            query = .changes(after: committedCursor, through: catchUpBoundary)
            phase = .catchingUp
        }
        let request = LibraryPageRequest(accountID: accountID, sessionID: sessionID, query: query, limit: limit)
        inFlightRequest = request
        return request
    }

    public func commandTicket(operationID: UUID) -> LibraryCommandTicket {
        LibraryCommandTicket(accountID: accountID, sessionID: sessionID, operationID: operationID)
    }

    /// Only a resync error belonging to the active pull can clear this session.
    @discardableResult
    public mutating func requireResync(for request: LibraryPageRequest) -> Bool {
        guard owns(request) else { return false }
        reset(accountID: accountID)
        return true
    }

    @discardableResult
    public mutating func accept(_ page: LibraryBaselinePage, for request: LibraryPageRequest) throws -> LibraryMergeResult {
        guard owns(request) else { return .stale }
        guard case .baseline(let requestedCursor) = request.query, phase == .baseline else {
            throw LibraryProtocolError.invalidPage
        }
        try page.validate()
        guard page.accountID == accountID else { throw LibraryProtocolError.accountMismatch }
        guard page.entries.count <= request.limit else { throw LibraryProtocolError.invalidPage }
        if let boundary = baselineBoundary {
            guard page.baselineCursor == boundary else { throw LibraryProtocolError.invalidCursor }
        }
        if let cursor = requestedCursor {
            guard cursor == baselineContinuation, cursor.through == page.baselineCursor,
                  page.entries.first.map({ LibraryOrderingKey(cursor) < LibraryOrderingKey($0) }) ?? true else {
                throw LibraryProtocolError.invalidCursor
            }
        } else {
            guard baselineBoundary == nil, baselineContinuation == nil else { throw LibraryProtocolError.invalidCursor }
        }
        // Apply the entire page to a value copy. An invalid final row cannot
        // publish earlier rows, a continuation, or a partial import mapping.
        var candidate = self
        let result = try candidate.merge(page.entries)
        candidate.baselineBoundary = page.baselineCursor
        candidate.baselineContinuation = page.nextCursor
        candidate.inFlightRequest = nil
        if !page.hasMore {
            candidate.committedCursor = page.baselineCursor
            candidate.phase = .catchingUp
            candidate.catchUpBoundary = nil
        }
        self = candidate
        return result
    }

    @discardableResult
    public mutating func accept(_ page: LibraryChangesPage, for request: LibraryPageRequest) throws -> LibraryMergeResult {
        guard owns(request) else { return .stale }
        guard case .changes(let after, let through) = request.query, phase == .catchingUp,
              committedCursor == after else { throw LibraryProtocolError.invalidPage }
        try page.validate()
        guard page.accountID == accountID else { throw LibraryProtocolError.accountMismatch }
        guard page.retainedAfter <= after else { throw LibraryProtocolError.resyncRequired }
        guard page.through >= after, through.map({ $0 == page.through }) ?? true,
              catchUpBoundary == through, page.changes.count <= request.limit,
              page.changes.first.map({ $0.sequence > after }) ?? true,
              page.nextCursor >= after, !page.hasMore || page.nextCursor > after else {
            throw LibraryProtocolError.invalidCursor
        }
        var candidate = self
        var result = LibraryMergeResult.empty
        for batch in page.changes {
            // Neither one member of a group nor a later invalid group can leak
            // out of this page's value transaction.
            result = result.adding(try candidate.merge(batch.entries))
        }
        candidate.committedCursor = page.nextCursor
        candidate.catchUpBoundary = page.hasMore ? page.through : nil
        candidate.phase = page.hasMore ? .catchingUp : .ready
        candidate.inFlightRequest = nil
        self = candidate
        return result
    }

    @discardableResult
    public mutating func accept(_ response: LibraryCommandResponse, for ticket: LibraryCommandTicket) throws -> LibraryMergeResult {
        guard ticket.accountID == accountID, ticket.sessionID == sessionID else { return .stale }
        try response.validate()
        guard let entry = response.entry else { return .empty }
        var candidate = self
        let result = try candidate.merge([entry])
        // result.seq is a receipt position, and entry.state_seq may be newer.
        // Neither proves that the intervening account changes were consumed.
        self = candidate
        return result
    }

    /// Includes hidden resolved/cancelled imports, even before their target
    /// item arrives on a later baseline or delta page.
    public var importItemMapping: [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: entries.values.compactMap { entry in
            guard case .import(let value) = entry, let item = value.libraryItemID else { return nil }
            return (value.id, item)
        })
    }

    public var orderedEntries: [LibraryEntry] {
        entries.values.sorted { LibraryOrderingKey($0) < LibraryOrderingKey($1) }
    }

    private func owns(_ request: LibraryPageRequest) -> Bool {
        request.accountID == accountID && request.sessionID == sessionID && request == inFlightRequest
    }

    private mutating func merge(_ observations: [LibraryEntry]) throws -> LibraryMergeResult {
        var updated = 0, older = 0, identical = 0
        for entry in observations {
            try entry.validate()
            if let old = entries[entry.id] {
                try validateIdentity(old, entry)
                if entry.stateSequence < old.stateSequence { older += 1; continue }
                if entry.stateSequence == old.stateSequence {
                    guard entry == old else { throw LibraryProtocolError.conflictingRevision(entry.id, entry.stateSequence) }
                    identical += 1
                    continue
                }
            }
            entries[entry.id] = entry
            updated += 1
        }
        guard entries.count <= LibraryWire.maximumRetainedEntries else { throw LibraryProtocolError.capacityExceeded }
        // A forward mapping is allowed while its item has not arrived. If both
        // have arrived, their immutable document identities must agree.
        var documents: [UUID: UUID] = [:]
        for entry in entries.values {
            if case .item(let item) = entry {
                if let previous = documents.updateValue(item.id, forKey: item.documentID), previous != item.id {
                    throw LibraryProtocolError.identityConflict(entry.id)
                }
            }
        }
        for entry in entries.values {
            guard case .import(let value) = entry, let itemID = value.libraryItemID,
                  case .item(let item) = entries[.init(kind: .item, entityID: itemID)] else { continue }
            guard item.documentID == value.documentID else { throw LibraryProtocolError.identityConflict(entry.id) }
        }
        return .init(disposition: .applied, insertedOrUpdated: updated, ignoredOlderEntries: older, identicalEntries: identical)
    }
}

private func validateIdentity(_ old: LibraryEntry, _ new: LibraryEntry) throws {
    guard old.createdSequence == new.createdSequence else { throw LibraryProtocolError.identityConflict(new.id) }
    switch (old, new) {
    case (.item(let lhs), .item(let rhs)):
        guard lhs.documentID == rhs.documentID, lhs.scope == rhs.scope, lhs.pageCount == rhs.pageCount,
              lhs.addedAt == rhs.addedAt else { throw LibraryProtocolError.identityConflict(new.id) }
        if rhs.stateSequence > lhs.stateSequence {
            guard rhs.membershipRevision >= lhs.membershipRevision,
                  rhs.lastRemoveSequence >= lhs.lastRemoveSequence,
                  preserves(lhs.approvalID, rhs.approvalID), preserves(lhs.versionID, rhs.versionID),
                  preserves(lhs.metadataID, rhs.metadataID), preserves(lhs.source, rhs.source),
                  preserves(lhs.sourceID, rhs.sourceID), preserves(lhs.sourceRevision, rhs.sourceRevision),
                  preserves(lhs.metadata, rhs.metadata), preserves(lhs.metadataRecordedAt, rhs.metadataRecordedAt),
                  preserves(lhs.sourceURL, rhs.sourceURL), preserves(lhs.originalObjectID, rhs.originalObjectID),
                  preserves(lhs.artifactID, rhs.artifactID),
                  advances(lhs.originalAvailabilityRevision, rhs.originalAvailabilityRevision),
                  advances(lhs.renderAvailabilityRevision, rhs.renderAvailabilityRevision) else {
                throw LibraryProtocolError.identityConflict(new.id)
            }
        }
    case (.import(let lhs), .import(let rhs)):
        guard lhs.source == rhs.source, lhs.sourceID == rhs.sourceID, lhs.requestedRevision == rhs.requestedRevision,
              lhs.libraryItemID == nil || rhs.libraryItemID == nil || lhs.libraryItemID == rhs.libraryItemID,
              lhs.documentID == nil || rhs.documentID == nil || lhs.documentID == rhs.documentID else {
            throw LibraryProtocolError.identityConflict(new.id)
        }
        if rhs.stateSequence > lhs.stateSequence {
            guard rhs.intentRevision >= lhs.intentRevision,
                  preserves(lhs.metadataID, rhs.metadataID), preserves(lhs.versionID, rhs.versionID),
                  preserves(lhs.sourceRevision, rhs.sourceRevision), preserves(lhs.metadata, rhs.metadata),
                  preserves(lhs.metadataRecordedAt, rhs.metadataRecordedAt),
                  preserves(lhs.libraryItemID, rhs.libraryItemID), preserves(lhs.documentID, rhs.documentID) else {
                throw LibraryProtocolError.identityConflict(new.id)
            }
        }
    default: throw LibraryProtocolError.identityConflict(new.id)
    }
}

/// Established pins survive removal and availability changes. These checks
/// only apply to forward revisions; an older row may predate its first pin.
private func preserves<Value: Equatable>(_ old: Value?, _ new: Value?) -> Bool {
    old == nil || old == new
}

private func advances(_ old: Int64?, _ new: Int64?) -> Bool {
    guard let old else { return true }
    guard let new else { return false }
    return new >= old
}
