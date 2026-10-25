import Foundation
import Testing
@testable import ScienceReaderCore

/// The interest registry: what the reader's devices share about topics, end to end encrypted as ordinary `note` events
/// (docs/architecture/INTEREST_INDEX.md "Device layer › Sync").
@Suite struct InterestRegistryTests {
    private let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!
    private let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!

    private func applied(_ record: InterestRegistryRecord) throws -> AppliedEvent {
        AppliedEvent(id: UUID(), deviceID: record.device, payload: try record.event())
    }
    private func state(_ events: [AppliedEvent]) throws -> PrivateState {
        var s = PrivateState()
        for e in events { try s.apply(e) }
        return s
    }

    @Test func lastWriterWinsPerTopicWhateverTheArrivalOrder() throws {
        let rename = try InterestRegistryRecord(device: a, topics: [.init(id: 7, epoch: 1, name: "Sparse attention", hidden: false, colour: nil)])
        let hide = try InterestRegistryRecord(device: b, topics: [.init(id: 7, epoch: 2, name: "Sparse attention", hidden: true, colour: 3)])
        // Concurrent writes at the same epoch: the greater device ID wins, on every device.
        let tieA = try InterestRegistryRecord(device: a, topics: [.init(id: 9, epoch: 5, name: "From A", hidden: false, colour: nil)])
        let tieB = try InterestRegistryRecord(device: b, topics: [.init(id: 9, epoch: 5, name: "From B", hidden: false, colour: nil)])
        let records = [rename, hide, tieA, tieB]
        let forward = InterestRegistry(records: records), backward = InterestRegistry(records: records.reversed())
        #expect(forward == backward)
        #expect(forward.topic(7, map: nil) == InterestRegistry.TopicState(name: "Sparse attention", hidden: true, colour: 3, epoch: 2, device: b))
        #expect(forward.topic(9, map: nil)?.name == "From B")
        #expect(forward.nextEpoch == 6)
        // Through the event journal: the same state from events in any order.
        let events = try records.map(applied)
        #expect(InterestRegistry(try state(events)) == InterestRegistry(try state(events.reversed())))
        #expect(InterestRegistry(try state(events)) == forward)
    }

    @Test func shownAndReadingMergeAsRegisters() throws {
        var r = InterestRegistry()
        r.apply(try InterestRegistryRecord(device: a, shown: [.init(id: 1, epoch: 1, on: true), .init(id: 2, epoch: 1, on: true)],
                                           reading: [.init(paper: "2610.00001", epoch: 1, level: 2)]))
        r.apply(try InterestRegistryRecord(device: b, shown: [.init(id: 2, epoch: 2, on: false)],
                                           reading: [.init(paper: "2610.00001", epoch: 2, level: 4), .init(paper: "2610.00002", epoch: 2, level: 1)]))
        #expect(r.shownIDs(map: nil) == [1])
        // A paper's level is the deepest any device read it; each device's own entry is kept.
        #expect(r.readingLevel("2610.00001") == 4 && r.readingLevel("2610.00001", device: a) == 2 && r.readingLevel("2610.00002") == 1)
        // A device writes only what increased for it; nothing when it knows nothing new.
        let changes = r.readingChanges(local: ["2610.00001": 3, "2610.00002": 0, "2610.00003": 1], device: a)
        #expect(changes.map(\.paper) == ["2610.00001", "2610.00003"] && changes.allSatisfy { $0.epoch == r.nextEpoch })
        #expect(r.readingChanges(local: ["2610.00001": 2], device: a).isEmpty)
        #expect(r.shownChanges(selected: [1, 3], map: nil).map { "\($0.id)\($0.on)" } == ["3true"])
        #expect(r.shownChanges(selected: [3], map: nil).map { "\($0.id)\($0.on)" } == ["3true", "1false"])
    }

    @Test func namesFollowRetiredTopicIDs() throws {
        let nodes = [InterestMap.Node(id: 1, level: 1, parent: nil, size: 10), InterestMap.Node(id: 2, level: 2, parent: 1, size: 10),
                     InterestMap.Node(id: 30, level: 3, parent: 2, size: 10)]
        let map = try InterestMap(version: 2, nodes: nodes, centroids: nodes.map { _ in [Float](repeating: 0.05, count: 384) },
                                  retired: [.init(id: 12, successors: [30], shares: [1])])
        var r = InterestRegistry()
        r.apply(try InterestRegistryRecord(device: a, topics: [.init(id: 12, epoch: 1, name: "KV cache", hidden: false, colour: 2)],
                                           shown: [.init(id: 12, epoch: 1, on: true)]))
        #expect(r.topic(30, map: map)?.name == "KV cache" && r.shownIDs(map: map) == [30])
        // A record for the live ID itself is newer and wins.
        r.apply(try InterestRegistryRecord(device: b, topics: [.init(id: 30, epoch: 2, name: nil, hidden: false, colour: nil)]))
        #expect(r.topic(30, map: map)?.name == nil)
    }

    @Test func otherReducersIgnoreRegistryRecordsAndViceVersa() throws {
        let record = try applied(InterestRegistryRecord(device: a, topics: [.init(id: 1, epoch: 1, name: "Robotics", hidden: false, colour: nil)]))
        let catalog = AppliedEvent(id: UUID(), deviceID: a, payload: try LibraryCatalogBatch(operations: [.init(.create, catalogID: UUID(), name: "Robotics")]).event(in: PrivateState()))
        let note = AppliedEvent(id: UUID(), deviceID: a, payload: try NotesRecord.note(NoteRecord(title: "Ideas", createdAt: 1)).event(createdAt: 1))
        let legacy = AppliedEvent(id: UUID(), deviceID: a, payload: PrivateEvent(kind: .note, entityID: InterestRegistryFormat.entityID, text: "plain text"))
        let later = AppliedEvent(id: UUID(), deviceID: a, payload: PrivateEvent(kind: .note, entityID: InterestRegistryFormat.entityID,
                                                                                text: #"{"format":"gradstep-interest-v2","x":1}"#))
        let with = try state([record, catalog, note, legacy, later]), without = try state([catalog, note])
        #expect(LibraryCatalogState(with) == LibraryCatalogState(without))
        #expect(NotesState(with).notes == NotesState(without).notes && NotesState(with).malformedCount == 0)
        let registry = InterestRegistry(with)
        #expect(registry.topic(1, map: nil)?.name == "Robotics" && registry.unreadable == 2)
        #expect(InterestRegistry(without) == InterestRegistry())
        // Records travel as ordinary format-1 envelopes, which every released client opens, keeps and ignores.
        let keys = KeyBundle.generate(accountID: UUID())
        #expect(try ReaderCrypto.seal(record.payload, id: record.id, deviceID: a, keys: keys).format == 1)
    }

    @Test func recordsValidateNamesAndBounds() throws {
        #expect(InterestRegistryRecord.normalizedName("  KV cache  ") == "KV cache")
        #expect(InterestRegistryRecord.normalizedName("") == nil && InterestRegistryRecord.normalizedName(String(repeating: "x", count: 61)) == nil)
        #expect(throws: ReaderError.self) { try InterestRegistryRecord(device: a) }
        #expect(throws: ReaderError.self) { try InterestRegistryRecord(device: a, topics: [.init(id: 1, epoch: 1, name: " padded ", hidden: false, colour: nil)]) }
        #expect(throws: ReaderError.self) { try InterestRegistryRecord(device: a, topics: [.init(id: 1, epoch: 1, name: nil, hidden: false, colour: 99)]) }
        #expect(throws: ReaderError.self) { try InterestRegistryRecord(device: a, reading: [.init(paper: "x", epoch: 1, level: 5)]) }
        #expect(throws: ReaderError.self) { try InterestRegistryRecord(device: a, shown: [.init(id: 1, epoch: 0, on: true)]) }
        // Not a registry record: another entity, a document-bound note.
        var bound = try InterestRegistryRecord(device: a, shown: [.init(id: 1, epoch: 1, on: true)]).event()
        bound.documentID = UUID()
        #expect(InterestRegistryRecord.decode(bound) == nil)
    }

    /// The whole registry of a large library stays under 100 KB per encrypted event.
    @Test func encryptedRecordsStayUnderOneHundredKilobytes() throws {
        let keys = KeyBundle.generate(accountID: UUID())
        let topics = (0 ..< 200).map { InterestRegistryRecord.Topic(id: 100_000 + $0, epoch: 12_345, name: String(repeating: "Ä", count: 60),
                                                                     hidden: $0 % 2 == 0, colour: $0 % 8) }
        let shown = (0 ..< 200).map { InterestRegistryRecord.Shown(id: 100_000 + $0, epoch: 12_345, on: true) }
        let reading = (0 ..< 1_000).map { InterestRegistryRecord.Reading(paper: String(format: "openalex:W%010d", $0), epoch: 12_345, level: 4) }
        let records = try InterestRegistry.records(device: a, topics: topics, shown: shown, reading: reading)
        #expect(records.count == 3)
        var largest = 0
        for record in records {
            let envelope = try ReaderCrypto.seal(try record.event(createdAt: 1_792_886_400_000), id: UUID(), deviceID: a, keys: keys)
            largest = max(largest, envelope.ciphertext.count)
            #expect(InterestRegistryRecord.decode(try ReaderCrypto.open(envelope, keys: keys)) == record)
        }
        #expect(largest < 100_000, "largest encrypted record \(largest) B")
        let merged = InterestRegistry(records: records)
        #expect(merged.topics.count == 200 && merged.reading.count == 1_000 && merged.shownIDs(map: nil).count == 200)
    }
}
