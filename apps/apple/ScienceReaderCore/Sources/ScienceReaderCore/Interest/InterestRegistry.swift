import Foundation

// What the reader's devices share about their topics (docs/architecture/INTEREST_INDEX.md "Device layer › Sync"),
// end to end encrypted through the existing event journal: each record is a `PrivateEvent` of kind `note` with a fixed
// entity ID and `text` = one JSON object, `format: "gradstep-interest-v1"` (the Notes and catalog reducers, older builds
// and the browser ignore it, as they ignore every `note` payload that isn't theirs). The server stores only the sealed
// envelope, as for every event. Records are batches of last-writer-wins registers, each with a Lamport `epoch` and the
// writing device; the greatest (epoch, device, batch) wins, whatever order the events arrive in:
//   topics[]    per map node ID: the reader's name, hidden flag and colour (user-facing state, written on a user action)
//   shown[]     per map node ID: whether the topic is shown (the hysteresis state: on at 3 papers, off below 2)
//   reading[]   per (paper, device): how far that device's reader read the paper (0–4), so device-only reading depth
//               weighs the paper on every device without syncing reading history; the paper's level is the maximum
// Topics themselves (which papers, shares, labels) are never synced: every device recomputes them from the library,
// the public map and these records.

public enum InterestRegistryFormat {
    public static let v1 = "gradstep-interest-v1"
    public static let entityID = UUID(uuidString: "6f1e2d3c-4b5a-4968-8778-a69584736251")!
    /// One record's encoded JSON at most (the encrypted event stays under 100 KB).
    public static let maximumRecordBytes = 64 * 1024
    public static let maximumNameScalars = 60
    /// Colour slots the chart offers (`InterestPalette`).
    public static let colourSlots = 0 ..< 8
    public static let maximumReadingLevel = 4
}

public struct InterestRegistryRecord: Codable, Equatable, Sendable {
    public struct Topic: Codable, Equatable, Sendable {
        public let id: Int
        public let epoch: Int
        /// The reader's name for the topic; nil = the computed label.
        public let name: String?
        public let hidden: Bool
        /// A colour slot; nil = by size.
        public let colour: Int?
        public init(id: Int, epoch: Int, name: String?, hidden: Bool, colour: Int?) {
            self.id = id; self.epoch = epoch; self.name = name; self.hidden = hidden; self.colour = colour
        }
        enum CodingKeys: String, CodingKey { case id, epoch = "e", name = "n", hidden = "h", colour = "c" }
    }
    public struct Shown: Codable, Equatable, Sendable {
        public let id: Int
        public let epoch: Int
        public let on: Bool
        public init(id: Int, epoch: Int, on: Bool) { self.id = id; self.epoch = epoch; self.on = on }
        enum CodingKeys: String, CodingKey { case id, epoch = "e", on }
    }
    public struct Reading: Codable, Equatable, Sendable {
        /// The paper's key (`InterestPool.key`) or, for a paper without a public identifier, `paper:<uuid>`.
        public let paper: String
        public let epoch: Int
        public let level: Int
        public init(paper: String, epoch: Int, level: Int) { self.paper = paper; self.epoch = epoch; self.level = level }
        enum CodingKeys: String, CodingKey { case paper = "p", epoch = "e", level = "l" }
    }

    public let format: String
    public let batch: UUID
    public let device: UUID
    public let topics: [Topic]
    public let shown: [Shown]
    public let reading: [Reading]

    public init(batch: UUID = UUID(), device: UUID, topics: [Topic] = [], shown: [Shown] = [], reading: [Reading] = []) throws {
        format = InterestRegistryFormat.v1; self.batch = batch; self.device = device
        self.topics = topics; self.shown = shown; self.reading = reading
        try validate()
    }

    public func validate() throws {
        guard format == InterestRegistryFormat.v1, !(topics.isEmpty && shown.isEmpty && reading.isEmpty) else { throw ReaderError.invalidEvent }
        let maxEpoch = Int(Int32.max)
        for t in topics {
            guard t.id >= 0, (1...maxEpoch).contains(t.epoch), t.colour.map(InterestRegistryFormat.colourSlots.contains) ?? true else { throw ReaderError.invalidEvent }
            if let name = t.name { guard Self.normalizedName(name) == name else { throw ReaderError.invalidEvent } }
        }
        for s in shown { guard s.id >= 0, (1...maxEpoch).contains(s.epoch) else { throw ReaderError.invalidEvent } }
        for r in reading {
            guard !r.paper.isEmpty, r.paper.utf8.count <= 200, (1...maxEpoch).contains(r.epoch),
                  (0...InterestRegistryFormat.maximumReadingLevel).contains(r.level) else { throw ReaderError.invalidEvent }
        }
        guard Set(topics.map(\.id)).count == topics.count, Set(shown.map(\.id)).count == shown.count,
              Set(reading.map(\.paper)).count == reading.count else { throw ReaderError.invalidEvent }
    }

    /// A name as the reader typed it, trimmed; nil when empty, too long or holding control characters.
    public static func normalizedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= InterestRegistryFormat.maximumNameScalars,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    public func encoded() throws -> Data { try ReaderCrypto.encode(self) }

    /// The record as an event (no parents: registers merge by epoch, not by causal history).
    public func event(createdAt: Int64? = nil) throws -> PrivateEvent {
        try validate()
        let data = try encoded()
        guard data.count <= InterestRegistryFormat.maximumRecordBytes else { throw ReaderError.invalidEvent }
        return PrivateEvent(kind: .note, entityID: InterestRegistryFormat.entityID, text: String(decoding: data, as: UTF8.self), createdAt: createdAt)
    }

    /// The record an event holds, or nil when it isn't one (another `note`, a later format, a malformed record).
    public static func decode(_ event: PrivateEvent) -> InterestRegistryRecord? {
        guard event.kind == .note, event.entityID == InterestRegistryFormat.entityID, event.documentID == nil,
              event.conversationID == nil, let text = event.text, text.utf8.count <= InterestRegistryFormat.maximumRecordBytes,
              let record = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), (try? record.validate()) != nil else { return nil }
        return record
    }
}

/// The merged registry: every device reduces the same records to the same state.
public struct InterestRegistry: Sendable, Equatable {
    public struct TopicState: Sendable, Equatable {
        public let name: String?
        public let hidden: Bool
        public let colour: Int?
        public let epoch: Int
        public let device: UUID
    }
    public struct Order: Comparable, Sendable, Equatable {
        let epoch: Int, device: String, batch: String
        public static func < (a: Order, b: Order) -> Bool {
            (a.epoch, a.device, a.batch) < (b.epoch, b.device, b.batch)
        }
    }

    public private(set) var topics: [Int: (state: TopicState, order: Order)] = [:]
    public private(set) var shown: [Int: (on: Bool, order: Order)] = [:]
    /// Per paper, per device: (level, order).
    public private(set) var reading: [String: [UUID: (level: Int, order: Order)]] = [:]
    /// The greatest epoch in any record (a new write uses one more).
    public private(set) var maxEpoch = 0
    /// Registry events this build couldn't read (a later format): counted, never dropped.
    public private(set) var unreadable = 0

    public static func == (a: InterestRegistry, b: InterestRegistry) -> Bool {
        a.topics.mapValues(\.state) == b.topics.mapValues(\.state)
            && a.shown.mapValues(\.on) == b.shown.mapValues(\.on)
            && a.reading.mapValues { $0.mapValues(\.level) } == b.reading.mapValues { $0.mapValues(\.level) }
            && a.maxEpoch == b.maxEpoch
    }

    public init() {}

    public init(_ state: PrivateState) {
        self.init(records: state.events.values.filter { $0.payload.entityID == InterestRegistryFormat.entityID && $0.payload.kind == .note }
            .compactMap { applied -> InterestRegistryRecord? in
                InterestRegistryRecord.decode(applied.payload)
            })
        unreadable = state.events.values.filter {
            $0.payload.entityID == InterestRegistryFormat.entityID && $0.payload.kind == .note && InterestRegistryRecord.decode($0.payload) == nil
        }.count
    }

    public init(records: [InterestRegistryRecord]) {
        for record in records { apply(record) }
    }

    public mutating func apply(_ record: InterestRegistryRecord) {
        let device = record.device.wire, batch = record.batch.wire
        for t in record.topics {
            let order = Order(epoch: t.epoch, device: device, batch: batch)
            maxEpoch = max(maxEpoch, t.epoch)
            if let held = topics[t.id], held.order >= order { continue }
            topics[t.id] = (TopicState(name: t.name, hidden: t.hidden, colour: t.colour, epoch: t.epoch, device: record.device), order)
        }
        for s in record.shown {
            let order = Order(epoch: s.epoch, device: device, batch: batch)
            maxEpoch = max(maxEpoch, s.epoch)
            if let held = shown[s.id], held.order >= order { continue }
            shown[s.id] = (s.on, order)
        }
        for r in record.reading {
            let order = Order(epoch: r.epoch, device: device, batch: batch)
            maxEpoch = max(maxEpoch, r.epoch)
            if let held = reading[r.paper]?[record.device], held.order >= order { continue }
            reading[r.paper, default: [:]][record.device] = (r.level, order)
        }
    }

    public var nextEpoch: Int { maxEpoch + 1 }

    /// The paper's reading level on any of the reader's devices (the maximum).
    public func readingLevel(_ paper: String) -> Int { reading[paper]?.values.map(\.level).max() ?? 0 }
    /// What one device last shared for the paper.
    public func readingLevel(_ paper: String, device: UUID) -> Int? { reading[paper]?[device]?.level }

    /// The user-facing state for a live map node: its own record, or the newest record of a retired ID that the map
    /// follows to it (`InterestMap.live`), so a name survives a rebuild that renumbers the topic.
    public func topic(_ id: Int, map: InterestMap?) -> TopicState? {
        var best: (state: TopicState, order: Order)? = topics[id]
        if let map {
            for (old, held) in topics where old != id && map.node(old) == nil && map.live(old) == id {
                if best == nil || held.order > best!.order { best = held }
            }
        }
        return best?.state
    }

    /// Node IDs shown as topics (hysteresis), followed to live IDs.
    public func shownIDs(map: InterestMap?) -> Set<Int> {
        var latest: [Int: (on: Bool, order: Order)] = [:]
        for (id, held) in shown {
            let live = map.map { $0.node(id) != nil ? id : $0.live(id) } ?? id
            guard let live else { continue }
            if let current = latest[live], current.order >= held.order { continue }
            latest[live] = held
        }
        return Set(latest.filter(\.value.on).keys)
    }

    // MARK: Writing

    /// Records for a selection that changed which topics are shown: `on` for new topics, `off` for those that left.
    public func shownChanges(selected: Set<Int>, map: InterestMap?) -> [InterestRegistryRecord.Shown] {
        let current = shownIDs(map: map)
        let epoch = nextEpoch
        return selected.subtracting(current).sorted().map { .init(id: $0, epoch: epoch, on: true) }
            + current.subtracting(selected).sorted().map { .init(id: $0, epoch: epoch, on: false) }
    }

    /// Reading levels this device knows that the registry doesn't yet carry for it (only increases).
    public func readingChanges(local: [String: Int], device: UUID) -> [InterestRegistryRecord.Reading] {
        let epoch = nextEpoch
        return local.keys.sorted().compactMap { paper in
            let level = max(0, min(InterestRegistryFormat.maximumReadingLevel, local[paper] ?? 0))
            guard level > 0, level > (readingLevel(paper, device: device) ?? 0) else { return nil }
            return .init(paper: paper, epoch: epoch, level: level)
        }
    }

    /// Records split so each stays under the record bound (reading entries are the bulk).
    public static func records(device: UUID, topics: [InterestRegistryRecord.Topic] = [], shown: [InterestRegistryRecord.Shown] = [],
                               reading: [InterestRegistryRecord.Reading] = [], chunk: Int = 800) throws -> [InterestRegistryRecord] {
        var out: [InterestRegistryRecord] = []
        if !topics.isEmpty || !shown.isEmpty { out.append(try InterestRegistryRecord(device: device, topics: topics, shown: shown)) }
        var start = 0
        while start < reading.count {
            let end = min(reading.count, start + chunk)
            out.append(try InterestRegistryRecord(device: device, reading: Array(reading[start ..< end])))
            start = end
        }
        return out
    }
}
