import CryptoKit
import Foundation

public enum LibraryCommandError: Error, Equatable, Sendable {
    case invalidScope, invalidMutation, targetBusy, staleHandle, staleAttempt
    case invalidTransition, invalidReceipt, incompleteObservation, capacityExceeded
}

/// The origin is deployment authority, independent of a display label such as staging.
public struct LibraryCommandScope: Codable, Equatable, Sendable {
    public let accountID: UUID
    public let deploymentID: String
    public init(accountID: UUID, deploymentID: String) throws {
        guard deploymentID.utf8.count <= 512, let url = URLComponents(string: deploymentID),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ (1...65535).contains($0) }) ?? true
        else { throw LibraryCommandError.invalidScope }
        self.accountID = accountID
        self.deploymentID = "https://" + host.lowercased() + (url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? "")
    }
    func validate() throws {
        guard try Self(accountID: accountID, deploymentID: deploymentID) == self else { throw LibraryCommandError.invalidScope }
    }
}

/// Already-observed preconditions. Retrying never replaces them with newer state.
public enum LibraryMutation: Codable, Equatable, Sendable {
    case beginImport(sourceID: String, requestedRevision: Int?, observedCursor: Int64)
    case setMembership(documentID: UUID, present: Bool, expectedRevision: Int64, approvalID: UUID?)
    case cancelImport(importID: UUID, expectedRevision: Int64)
    case retryImport(importID: UUID, expectedRevision: Int64)

    func validate() throws {
        switch self {
        case .beginImport(let source, let revision, let cursor):
            _ = try ArxivReference(sourceID: source, revision: revision)
            guard cursor >= 0 else { throw LibraryCommandError.invalidMutation }
        case .setMembership(_, _, let revision, _):
            guard revision >= 0, revision < Int64.max else { throw LibraryCommandError.invalidMutation }
        case .cancelImport(_, let revision), .retryImport(_, let revision):
            guard revision > 0, revision < Int64.max else { throw LibraryCommandError.invalidMutation }
        }
    }

    var expectedRevision: Int64 {
        switch self {
        case .beginImport: 0
        case .setMembership(_, _, let value, _), .cancelImport(_, let value), .retryImport(_, let value): value
        }
    }

    func request(operationID: UUID, scope: LibraryCommandScope) throws -> FrozenLibraryRequest {
        try validate()
        var parameters: [String: Any] = ["p_operation_id": operationID.wire]
        let endpoint: String
        switch self {
        case .beginImport(let source, let revision, let cursor):
            endpoint = "v2_begin_import"
            parameters["p_source_id"] = source; parameters["p_requested_revision"] = revision ?? (NSNull() as Any)
            parameters["p_observed_cursor"] = cursor
        case .setMembership(let document, let present, let revision, let approval):
            endpoint = "v2_set_library_item"
            parameters["p_document_id"] = document.wire; parameters["p_present"] = present
            parameters["p_expected_revision"] = revision; parameters["p_approval_id"] = approval?.wire ?? (NSNull() as Any)
        case .cancelImport(let imported, let revision), .retryImport(let imported, let revision):
            if case .cancelImport = self { endpoint = "v2_cancel_import" } else { endpoint = "v2_retry_import" }
            parameters["p_import_id"] = imported.wire; parameters["p_expected_revision"] = revision
        }
        let body = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= 2_048 else { throw LibraryCommandError.invalidMutation }
        let domain = Data("science-reader/library-request/v1\n\(scope.accountID.wire)\n\(scope.deploymentID)\n\(endpoint)\n".utf8)
        return FrozenLibraryRequest(operationID: operationID, endpoint: endpoint, body: body, digest: Data(SHA256.hash(data: domain + body)))
    }
}

public struct LocalLibraryCommandHandle: Codable, Equatable, Hashable, Sendable {
    public let intentID: UUID
    public let localSequence: Int64
    // Only persistence creates handles; retries cannot insert a missing row.
    init(intentID: UUID, localSequence: Int64) { self.intentID = intentID; self.localSequence = localSequence }
}

public struct FrozenLibraryRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let endpoint: String
    public let body: Data
    public let digest: Data
}

public enum LibrarySuccessor: Codable, Equatable, Sendable {
    case setMembership(present: Bool, approvalID: UUID?)
    case cancelImport
}

public enum LibraryCommandPhase: String, Codable, Sendable {
    case held, prepared, submittedUnknown, receiptAwaitingCatchup, needsReview, blocked, finished, cancelled
}

/// Typed reasons only. Do not persist arbitrary transport/provider response bodies.
public enum LibraryCommandFailure: String, Codable, Sendable {
    case connection, authentication, rateLimited, capacity, serverRejected, invalidResponse, operationConflict, suspended
}

public struct LocalLibraryReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let result: LibraryCommandResult
    public internal(set) var requiredCursor: Int64
}

public struct LocalLibraryCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { handle.intentID }
    public let handle: LocalLibraryCommandHandle
    public let laneID: UUID
    public let scope: LibraryCommandScope
    public let display: String?
    public internal(set) var revision: Int64 = 1
    public internal(set) var mutation: LibraryMutation?
    public internal(set) var request: FrozenLibraryRequest?
    public internal(set) var predecessor: LocalLibraryCommandHandle?
    public internal(set) var successor: LibrarySuccessor?
    public internal(set) var phase: LibraryCommandPhase
    public internal(set) var everSubmitted = false
    public internal(set) var attemptID: UUID?
    public internal(set) var attemptCount: Int64 = 0
    public internal(set) var failure: LibraryCommandFailure?
    public internal(set) var receipt: LocalLibraryReceipt?

    public var isUnfinished: Bool { ![.finished, .cancelled, .needsReview].contains(phase) }
    public var canAttempt: Bool {
        // An interrupted local acknowledgement may leave an attempt marker.
        // The coordinator serializes transport; a new exact retry fences that
        // marker instead of requiring a restart to recover the command.
        request != nil && receipt == nil &&
        [.prepared, .submittedUnknown, .blocked].contains(phase) && failure != .operationConflict
    }
}

/// This attempt owns one actor lifetime as well as one durable command.
public struct LibraryCommandAttempt: Equatable, Sendable {
    public let scope: LibraryCommandScope
    public let handle: LocalLibraryCommandHandle
    public let attemptID: UUID
    public let request: FrozenLibraryRequest
    let writerID: UUID
}

public struct LibraryCommandReconciliation: Equatable, Sendable {
    public let handle: LocalLibraryCommandHandle
    public let receiptID: UUID
    public init(handle: LocalLibraryCommandHandle, receiptID: UUID) { self.handle = handle; self.receiptID = receiptID }
}

public struct LocalLibraryCommandSnapshot: Equatable, Sendable {
    public let generation: Int64
    public let commands: [LocalLibraryCommand]
}

/// Pure bounded state machine. SQLite seals and commits the resulting value in
/// one transaction before a request or UI acknowledgement can escape.
struct LibraryCommandJournal: Equatable {
    static let maximumTargets = 64, maximumRows = 512, maximumRowBytes = 16_384
    static let maximumBytes = 8 * 1024 * 1024
    var scope: LibraryCommandScope?
    var sequence: Int64 = 0
    var rows: [UUID: LocalLibraryCommand] = [:]

    func requireScope(_ expected: LibraryCommandScope, accountID: UUID) throws {
        try expected.validate()
        guard expected.accountID == accountID else { throw ReaderError.wrongAccount }
        guard scope == nil || scope == expected else { throw LibraryCommandError.invalidScope }
    }

    mutating func enqueue(_ mutation: LibraryMutation, scope: LibraryCommandScope, display: String?) throws -> LocalLibraryCommandHandle {
        try mutation.validate(); try validateDisplay(display)
        for row in rows.values where row.isUnfinished && sameTarget(row, mutation) {
            if row.mutation == mutation { return row.handle }
            throw LibraryCommandError.targetBusy
        }
        let handle = try nextHandle(), request = try mutation.request(operationID: handle.intentID, scope: scope)
        self.scope = scope
        rows[handle.intentID] = LocalLibraryCommand(handle: handle, laneID: handle.intentID, scope: scope,
                                                   display: display, mutation: mutation, request: request, phase: .prepared)
        try validate()
        return handle
    }

    mutating func hold(_ successor: LibrarySuccessor, after handle: LocalLibraryCommandHandle, display: String?) throws -> LocalLibraryCommandHandle {
        let parent = try row(handle)
        guard let mutation = parent.mutation, ![.cancelled, .needsReview].contains(parent.phase),
              parent.phase != .finished || parent.receipt?.result.status == .applied else { throw LibraryCommandError.invalidTransition }
        _ = try materialize(successor, from: mutation, operationID: parent.id, revision: mutation.expectedRevision + 1)
        try validateDisplay(display)
        if let child = rows.values.first(where: { $0.predecessor == handle && $0.isUnfinished }) {
            guard child.successor == successor else { throw LibraryCommandError.targetBusy }
            return child.handle
        }
        guard !rows.values.contains(where: { $0.laneID == parent.laneID && $0.isUnfinished && $0.id != parent.id }) else { throw LibraryCommandError.targetBusy }
        let childHandle = try nextHandle()
        var child = LocalLibraryCommand(handle: childHandle, laneID: parent.laneID, scope: parent.scope,
                                        display: display, predecessor: handle, successor: successor, phase: .held)
        if let receipt = parent.receipt {
            if receipt.result.status == .applied { try freeze(&child, parent: parent, receipt: receipt) }
            else { child.phase = .needsReview }
        }
        rows[child.id] = child
        try validate()
        return childHandle
    }

    /// Resolve Cancel against current state in one transaction. A snapshot from
    /// before an attempt started must not accidentally discard issued work.
    mutating func cancel(_ handle: LocalLibraryCommandHandle) throws {
        let value = try row(handle)
        if value.phase == .cancelled { return }
        if !value.everSubmitted { try discard(handle, revision: value.revision); return }
        let successor: LibrarySuccessor
        switch value.mutation {
        case .beginImport, .retryImport: successor = .cancelImport
        case .setMembership(_, let present, _, let approval): successor = .setMembership(present: !present, approvalID: approval)
        default: throw LibraryCommandError.invalidTransition
        }
        _ = try hold(successor, after: handle, display: value.display)
    }

    mutating func begin(_ handle: LocalLibraryCommandHandle, writerID: UUID) throws -> LibraryCommandAttempt {
        var value = try row(handle)
        guard value.canAttempt, let request = value.request, value.attemptCount < Int64.max else { throw LibraryCommandError.invalidTransition }
        value.attemptID = UUID(); value.attemptCount += 1; value.everSubmitted = true
        value.phase = .submittedUnknown; value.failure = nil
        try bump(&value); rows[value.id] = value
        return LibraryCommandAttempt(scope: value.scope, handle: handle, attemptID: value.attemptID!, request: request, writerID: writerID)
    }

    mutating func receive(_ response: LibraryCommandResponse, for attempt: LibraryCommandAttempt, writerID: UUID) throws {
        var value = try owns(attempt, writerID: writerID)
        try validateReceipt(response, for: value)
        if let existing = value.receipt {
            guard existing.result == response.result else { throw LibraryCommandError.invalidReceipt }
        }
        let floor = max(response.result.sequence ?? 0, response.entry?.stateSequence ?? 0)
        value.receipt = LocalLibraryReceipt(id: value.receipt?.id ?? UUID(), result: response.result,
                                            requiredCursor: max(floor, value.receipt?.requiredCursor ?? 0))
        value.phase = .receiptAwaitingCatchup; value.failure = nil
        // Retain the attempt ID for an exact repeated callback until a fresh
        // owner opens. It never permits another network attempt after receipt.
        try bump(&value); rows[value.id] = value
        for child in rows.values.filter({ $0.predecessor == value.handle && $0.phase == .held }) {
            var next = child
            if response.result.status == .applied { try freeze(&next, parent: value, receipt: value.receipt!) }
            else { next.phase = .needsReview }
            try bump(&next); rows[next.id] = next
        }
        try validate()
    }

    mutating func failed(_ failure: LibraryCommandFailure, for attempt: LibraryCommandAttempt, writerID: UUID) throws {
        var value = try owns(attempt, writerID: writerID)
        guard value.receipt == nil else { throw LibraryCommandError.invalidTransition }
        value.failure = failure; value.attemptID = nil
        value.phase = failure == .operationConflict ? .needsReview :
            [.authentication, .capacity, .serverRejected].contains(failure) ? .blocked : .submittedUnknown
        try bump(&value); rows[value.id] = value
        if failure == .operationConflict {
            // This UUID cannot be replayed with these arguments. Preserve its
            // evidence for explicit review, without stranding a held reversal
            // or inventing an applied receipt/precondition for that reversal.
            for var child in rows.values.filter({ $0.predecessor == value.handle && $0.phase == .held }) {
                child.phase = .needsReview; child.failure = failure
                try bump(&child); rows[child.id] = child
            }
        }
    }

    mutating func discard(_ handle: LocalLibraryCommandHandle, revision: Int64) throws {
        var value = try row(handle)
        guard value.revision == revision else { throw LibraryCommandError.staleHandle }
        guard !value.everSubmitted, value.receipt == nil else { throw LibraryCommandError.invalidTransition }
        value.phase = .cancelled; try bump(&value); rows[value.id] = value
        for child in rows.values.filter({ $0.predecessor == handle && $0.isUnfinished }) {
            guard !child.everSubmitted else { throw LibraryCommandError.invalidTransition }
            var cancelled = child; cancelled.phase = .cancelled; try bump(&cancelled); rows[child.id] = cancelled
        }
    }

    mutating func reconcile(_ receipts: [LibraryCommandReconciliation], observation: LibraryCompleteObservation) throws {
        guard scope == nil || observation.accountID == scope?.accountID else { throw ReaderError.wrongAccount }
        guard receipts.count <= 128, Set(receipts.map(\.handle)).count == receipts.count else { throw LibraryCommandError.invalidTransition }
        for reference in receipts {
            var value = try row(reference.handle)
            guard let receipt = value.receipt, receipt.id == reference.receiptID,
                  [.receiptAwaitingCatchup, .finished, .needsReview].contains(value.phase) else { throw LibraryCommandError.staleHandle }
            guard observation.committedCursor >= receipt.requiredCursor else { throw LibraryCommandError.incompleteObservation }
            if let id = receipt.result.id {
                let entry = observation.entries[LibraryEntryID(kind: receipt.result.kind, entityID: id)]
                try validateReceipt(LibraryCommandResponse(result: receipt.result, replayed: true, entry: entry), for: value)
            }
            let phase: LibraryCommandPhase = receipt.result.status == .applied ? .finished : .needsReview
            if value.phase != phase { value.phase = phase; value.attemptID = nil; try bump(&value); rows[value.id] = value }
        }
    }

    mutating func dismiss(_ handle: LocalLibraryCommandHandle, revision: Int64) throws {
        var value = try row(handle)
        guard value.revision == revision, value.phase == .needsReview else { throw LibraryCommandError.invalidTransition }
        value.phase = .finished; try bump(&value); rows[value.id] = value
    }

    mutating func prune() {
        let needed = Set(rows.values.filter { $0.phase == .held }.compactMap(\.predecessor))
        rows = rows.filter { _, value in ![.finished, .cancelled].contains(value.phase) || needed.contains(value.handle) }
    }

    /// Fresh actor ownership invalidates old callbacks without changing request bytes.
    mutating func reopen() throws {
        for var value in rows.values where value.attemptID != nil {
            value.attemptID = nil; try bump(&value); rows[value.id] = value
        }
    }

    func validate() throws {
        guard sequence >= 0, rows.count <= Self.maximumRows,
              Set(rows.values.map { $0.handle.localSequence }).count == rows.count else { throw ReaderError.corruptData }
        if let scope { try scope.validate() } else { guard rows.isEmpty && sequence == 0 else { throw ReaderError.corruptData } }
        let lanes = Dictionary(grouping: rows.values.filter(\.isUnfinished), by: \.laneID)
        let reserved = lanes.values.filter { $0.count == 1 }.count
        guard lanes.count <= Self.maximumTargets, lanes.values.allSatisfy({ $0.count <= 2 }),
              rows.count + reserved <= Self.maximumRows else { throw LibraryCommandError.capacityExceeded }
        for (id, value) in rows {
            guard value.id == id, value.scope == scope, value.handle.localSequence > 0,
                  value.handle.localSequence <= sequence, value.revision > 0, value.attemptCount >= 0,
                  value.everSubmitted == (value.attemptCount > 0),
                  value.attemptID == nil || value.everSubmitted else { throw ReaderError.corruptData }
            try validateDisplay(value.display)
            if let mutation = value.mutation {
                guard value.request == (try mutation.request(operationID: id, scope: value.scope)) else { throw ReaderError.corruptData }
            } else {
                guard value.request == nil, value.successor != nil, value.predecessor != nil,
                      !value.everSubmitted, [.held, .needsReview, .cancelled, .finished].contains(value.phase) else { throw ReaderError.corruptData }
            }
            if value.phase == .held {
                guard let parent = value.predecessor, let found = rows[parent.intentID], found.handle == parent,
                      found.laneID == value.laneID, parent.localSequence < value.handle.localSequence else { throw ReaderError.corruptData }
            }
            if let receipt = value.receipt {
                guard value.everSubmitted, receipt.requiredCursor >= (receipt.result.sequence ?? 0),
                      receipt.requiredCursor >= 0, try ReaderCrypto.encode(receipt.result).count <= 2_048,
                      [.receiptAwaitingCatchup, .needsReview, .finished].contains(value.phase) else { throw ReaderError.corruptData }
                try validateResult(receipt.result, for: value)
            } else if value.phase == .receiptAwaitingCatchup { throw ReaderError.corruptData }
            guard try ReaderCrypto.encode(value).count + 28 <= Self.maximumRowBytes else { throw LibraryCommandError.capacityExceeded }
        }
    }

    private func validateDisplay(_ value: String?) throws {
        guard value.map({ $0.utf8.count <= 1_024 }) ?? true else { throw LibraryCommandError.invalidMutation }
    }
    private mutating func nextHandle() throws -> LocalLibraryCommandHandle {
        guard sequence < Int64.max else { throw LibraryCommandError.capacityExceeded }
        sequence += 1
        return LocalLibraryCommandHandle(intentID: UUID(), localSequence: sequence)
    }
    private func row(_ handle: LocalLibraryCommandHandle) throws -> LocalLibraryCommand {
        guard let value = rows[handle.intentID], value.handle == handle else { throw LibraryCommandError.staleHandle }
        return value
    }
    private func owns(_ attempt: LibraryCommandAttempt, writerID: UUID) throws -> LocalLibraryCommand {
        let value = try row(attempt.handle)
        guard attempt.writerID == writerID, value.scope == attempt.scope, value.attemptID == attempt.attemptID,
              value.request == attempt.request else { throw LibraryCommandError.staleAttempt }
        return value
    }
    private func bump(_ value: inout LocalLibraryCommand) throws {
        guard value.revision < Int64.max else { throw LibraryCommandError.capacityExceeded }
        value.revision += 1
    }
    private func sameTarget(_ value: LocalLibraryCommand, _ mutation: LibraryMutation) -> Bool {
        guard let other = value.mutation else { return false }
        switch (other, mutation) {
        case let (.setMembership(a, _, _, _), .setMembership(b, _, _, _)): return a == b
        case let (.beginImport(a, ar, _), .beginImport(b, br, _)): return a == b && ar == br
        case let (.cancelImport(a, _), .cancelImport(b, _)), let (.cancelImport(a, _), .retryImport(b, _)),
             let (.retryImport(a, _), .cancelImport(b, _)), let (.retryImport(a, _), .retryImport(b, _)): return a == b
        case (.beginImport, .cancelImport(let id, _)), (.beginImport, .retryImport(let id, _)): return value.request?.operationID == id
        default: return false
        }
    }
    private func materialize(_ successor: LibrarySuccessor, from parent: LibraryMutation, operationID: UUID, revision: Int64) throws -> LibraryMutation {
        switch (successor, parent) {
        case let (.setMembership(present, approval), .setMembership(document, before, _, oldApproval)):
            guard present != before else { throw LibraryCommandError.invalidMutation }
            return .setMembership(documentID: document, present: present, expectedRevision: revision, approvalID: approval ?? oldApproval)
        case (.cancelImport, .beginImport): return .cancelImport(importID: operationID, expectedRevision: revision)
        case (.cancelImport, .retryImport(let id, _)): return .cancelImport(importID: id, expectedRevision: revision)
        default: throw LibraryCommandError.invalidMutation
        }
    }
    private func freeze(_ child: inout LocalLibraryCommand, parent: LocalLibraryCommand, receipt: LocalLibraryReceipt) throws {
        guard let successor = child.successor, let mutation = parent.mutation, let request = parent.request,
              child.request == nil, receipt.result.status == .applied else { throw LibraryCommandError.invalidTransition }
        let next = try materialize(successor, from: mutation, operationID: request.operationID, revision: receipt.result.revision)
        child.mutation = next; child.request = try next.request(operationID: child.id, scope: child.scope); child.phase = .prepared
    }
    private func validateResult(_ result: LibraryCommandResult, for value: LocalLibraryCommand) throws {
        guard let mutation = value.mutation, let request = value.request, result.revision >= 0 else { throw LibraryCommandError.invalidReceipt }
        let kind: LibraryEntryKind
        switch mutation {
        case .setMembership: kind = .item
        case .beginImport, .cancelImport, .retryImport: kind = .import
        }
        guard result.kind == kind else { throw LibraryCommandError.invalidReceipt }
        if result.status == .applied {
            guard result.id != nil, result.sequence.map({ $0 > 0 }) == true,
                  result.revision == mutation.expectedRevision + 1 else { throw LibraryCommandError.invalidReceipt }
        } else {
            guard result.sequence == nil, result.revision != mutation.expectedRevision,
                  result.id != nil || result.revision == 0 else { throw LibraryCommandError.invalidReceipt }
        }
        switch mutation {
        case .beginImport:
            guard result.status == .applied, result.id == request.operationID else { throw LibraryCommandError.invalidReceipt }
        case .cancelImport(let id, _), .retryImport(let id, _):
            guard result.id == id, result.revision > 0 else { throw LibraryCommandError.invalidReceipt }
        case .setMembership: break
        }
    }
    private func validateReceipt(_ response: LibraryCommandResponse, for value: LocalLibraryCommand) throws {
        try response.validate(); try validateResult(response.result, for: value)
        guard let entry = response.entry else { return }
        switch (value.mutation, entry) {
        case let (.setMembership(document, _, _, _), .item(item)):
            guard item.documentID == document, item.membershipRevision >= response.result.revision else { throw LibraryCommandError.invalidReceipt }
        case let (.beginImport(source, revision, _), .import(imported)):
            guard imported.sourceID == source, imported.requestedRevision == revision,
                  imported.intentRevision >= response.result.revision else { throw LibraryCommandError.invalidReceipt }
        case (.cancelImport, .import(let imported)), (.retryImport, .import(let imported)):
            guard imported.intentRevision >= response.result.revision else { throw LibraryCommandError.invalidReceipt }
        default: throw LibraryCommandError.invalidReceipt
        }
    }
}
