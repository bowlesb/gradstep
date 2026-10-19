import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct LibraryCatalogTests {
    private let initial = LibraryCatalogBatch.initialCatalogID
    private let device = UUID()
    private let key = "arxiv:2305.18290"
    private func record(_ ops: [LibraryCatalogBatch.Operation], parents: [UUID] = [], id: UUID = UUID(), batchID: UUID = UUID()) throws -> AppliedEvent {
        let batch = try LibraryCatalogBatch(operations: ops, batchID: batchID)
        let event = PrivateEvent(kind: .note, entityID: LibraryCatalogBatch.entityID, parents: parents,
                                 text: String(decoding: try ReaderCrypto.encode(batch), as: UTF8.self))
        return AppliedEvent(id: id, deviceID: device, payload: event)
    }
    private func state(_ events: [AppliedEvent]) throws -> PrivateState {
        var value = PrivateState(); for event in events { try value.apply(event) }; return value
    }

    @Test func defaultChoiceDoesNotMoveExistingUnassignedPapers() throws {
        let other = UUID()
        let created = try record([.init(.create, catalogID: other, name: "Robotics"), .init(.makeDefault, catalogID: other)])
        let projection = LibraryCatalogState(try state([created]))
        #expect(projection.defaultID == other)
        #expect(projection.catalogID(for: key) == initial)
        #expect(projection.catalog(initial)?.name == "Default")
    }

    @Test func renameAndAssignmentAreCausalRegardlessOfArrivalAndEnvelopeOrder() throws {
        let other = UUID()
        let created = try record([.init(.create, catalogID: other, name: "First")])
        let renamed = try record([.init(.rename, catalogID: other, name: "Scientific figures"),
                                  .init(.assign, catalogID: other, paperKey: key)], parents: [created.id])
        for events in [[created, renamed], [renamed, created]] {
            let projection = LibraryCatalogState(try state(events))
            #expect(projection.catalog(other)?.name == "Scientific figures")
            #expect(projection.catalogID(for: key) == other)
        }
        #expect(LibraryCatalogBatch.arxivKey("https://arxiv.org/abs/2305.18290v2") == key)
    }

    @Test func missingParentsDeferAndFutureFormatsDoNotBlockKnownChildren() throws {
        let future = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .note,
            entityID: LibraryCatalogBatch.entityID, text: "{\"format\":\"library-catalog-v2\"}"))
        let rename = try record([.init(.rename, catalogID: initial, name: "My papers")], parents: [future.id])
        var journal = try state([rename])
        #expect(LibraryCatalogState(journal).catalog(initial)?.name == "Default")
        try journal.apply(future)
        #expect(LibraryCatalogState(journal).catalog(initial)?.name == "My papers")
    }

    @Test func concurrentRenameChoiceSurvivesResealingWithNewEnvelopeIDs() throws {
        let first = try record([.init(.rename, catalogID: initial, name: "Earlier tie")],
                               batchID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let second = try record([.init(.rename, catalogID: initial, name: "Chosen tie")],
                                batchID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        var journal = try state([second, first])
        let before = LibraryCatalogState(journal)
        let replacedFirst = AppliedEvent(id: UUID(), deviceID: UUID(), payload: first.payload)
        let replacedSecond = AppliedEvent(id: UUID(), deviceID: UUID(), payload: second.payload)
        try journal.apply(replacedSecond); try journal.apply(replacedFirst)
        try journal.applyLocalReplacements([first.id: replacedFirst.id, second.id: replacedSecond.id])
        #expect(LibraryCatalogState(journal) == before)
        #expect(before.catalog(initial)?.name == "Chosen tie")
        #expect(LibraryCatalogState(try state([first, second])) == before)
    }

    @Test func retirementRedirectsConcurrentAndFutureAssignmentsWithoutLosingPapers() throws {
        let source = UUID(), destination = UUID()
        let setup = try record([.init(.create, catalogID: source, name: "Old"),
                                .init(.create, catalogID: destination, name: "Keep"), .init(.makeDefault, catalogID: source)])
        let move = try record([.init(.retire, catalogID: source, destinationID: destination)], parents: [setup.id])
        let assign = try record([.init(.assign, catalogID: source, paperKey: key)], parents: [setup.id])
        for events in [[setup, move, assign], [assign, move, setup]] {
            let projection = LibraryCatalogState(try state(events))
            #expect(projection.catalog(source) == nil)
            #expect(projection.catalogID(for: key) == destination)
            #expect(projection.defaultID == destination)
        }
    }

    @Test func concurrentDeletionCyclesLeaveARecoveryCatalogAndVisibleAssignments() throws {
        let other = UUID()
        let setup = try record([.init(.create, catalogID: other, name: "Other"), .init(.assign, catalogID: other, paperKey: key)])
        let a = try record([.init(.retire, catalogID: initial, destinationID: other)], parents: [setup.id])
        let b = try record([.init(.retire, catalogID: other, destinationID: initial)], parents: [setup.id])
        let projection = LibraryCatalogState(try state([a, b, setup]))
        #expect(projection.catalogs.count == 1)
        #expect(projection.catalog(projection.catalogID(for: key)) != nil)
        #expect(projection.catalog(projection.defaultID) != nil)
    }

    @Test func payloadUsesAnExistingNoteAndNamesAndOperationsStayBounded() throws {
        let batch = try LibraryCatalogBatch(operations: [.init(.rename, catalogID: initial, name: "Research")])
        let event = try batch.event(in: PrivateState())
        #expect(event.kind == .note && event.documentID == nil && event.conversationID == nil)
        #expect(try JSONDecoder().decode(PrivateEvent.self, from: ReaderCrypto.encode(event)) == event)
        #expect(LibraryCatalogBatch.normalizedName("  Reading  ") == "Reading")
        #expect(LibraryCatalogBatch.normalizedName(" ") == nil)
        #expect(LibraryCatalogBatch.normalizedName("Two\nlines") == nil)
        #expect(throws: LibraryCatalogError.invalidOperation) {
            try LibraryCatalogBatch(operations: [.init(.assign, catalogID: initial, paperKey: "https://private.invalid/file")])
        }
        #expect(throws: LibraryCatalogError.invalidName) {
            try LibraryCatalogBatch(operations: [.init(.rename, catalogID: initial, name: String(repeating: "a", count: 81))])
        }
        #expect(throws: LibraryCatalogError.invalidOperation) {
            try LibraryCatalogBatch(operations: Array(repeating: .init(.makeDefault, catalogID: initial), count: 65))
        }
    }
}
