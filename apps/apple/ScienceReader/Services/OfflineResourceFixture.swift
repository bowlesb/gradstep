#if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && targetEnvironment(simulator)
import CryptoKit
import Darwin
import Foundation
import Observation
import ScienceReaderCore
import SwiftUI

/// An opt-in, synthetic account for resource measurements. Only the seed
/// process constructs data. Restoration and opening use normal encrypted
/// persistence, model publication, input copying and native image admission.
enum OfflineResourceFixture {
    enum Mode: String, Sendable { case seed, restore, empty }
    enum Failure: Int, Error { case invalidArguments = 1, invalidFixture, missingSeed, unexpectedState, unavailableMetric }

    static let account = UUID(uuidString: "cccccccc-4000-4000-8000-000000000001")!
    static let deployment = "https://offline-resource-fixture.invalid"
    static let directoryName = "offline-resource-fixture-v1"
    static let emptyDirectoryName = "offline-resource-empty-v1"
    static let rowCount = 4_000
    static let metadataBytes = 32_768
    static let authorsPerRow = 512
    static let categoriesPerRow = 64
    static let payloadBytes = 33_554_432
    static let imagePixels = 16_000_000
    static let baseManifestSHA256 = "4f8d21dd1ddb9ffc2be834bd824a3cef67a4619313dd58fa0b45471294a68006"
    static let noMatchQuery = "zzresourceunmatched"
    static let document = identifier(role: 1, row: rowCount)
    static let artifact = identifier(role: 2, row: rowCount)
    static let item = identifier(role: 3, row: rowCount)

    static func launchMode(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Mode? {
        guard arguments.contains("--offline-resource-fixture") else { return nil }
        guard arguments.filter({ $0 == "--offline-resource-mode" }).count == 1,
              let index = arguments.firstIndex(of: "--offline-resource-mode"),
              arguments.indices.contains(index + 1), let mode = Mode(rawValue: arguments[index + 1]) else {
            throw Failure.invalidArguments
        }
        let settledFlags = arguments.filter { $0 == "--offline-resource-settled" }.count
        guard settledFlags <= 1, settledFlags == 0 || mode != .seed else { throw Failure.invalidArguments }
        return mode
    }

    static func directory(for mode: Mode) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent(mode == .empty ? emptyDirectoryName : directoryName, isDirectory: true)
    }

    /// Call before activation. A measured launch must not silently create an
    /// empty database, seed data or substitute the compiled sample.
    static func requireExistingSeed(at directory: URL, mode: Mode) throws {
        if mode == .restore {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.sqlite").path) else {
                throw Failure.missingSeed
            }
        }
    }

    static func device() throws -> LocalDevice {
        let data = try JSONSerialization.data(withJSONObject: [
            "accountID": account.uuidString, "epoch": 1,
            "contentKeys": ["1": Data(repeating: 61, count: 32).base64EncodedString()],
            "managementToken": Data(repeating: 67, count: 32).base64EncodedString()
        ])
        var result = LocalDevice.create(accountID: account, localStoreKey: Data(repeating: 71, count: 32))
        result.bundle = try JSONDecoder().decode(KeyBundle.self, from: data)
        return result
    }

    struct SeedSummary: Sendable {
        let rows: Int
        let memberBytes: Int
        let manifestSHA256: String
    }

    @MainActor
    static func seed(using coordinator: ReaderBundleCoordinator) async throws -> SeedSummary {
        // The full observation and renderer input exist only in the seed app
        // process. The subsequent process cannot inherit their allocations.
        let observation = try await Task.detached(priority: .userInitiated) { try Self.observation() }.value
        _ = try await coordinator.observe(observation).value
        let input = try await Task.detached(priority: .userInitiated) { try installedInput() }.value
        let binding = try ReaderArtifactBinding(scope: coordinator.scope, documentID: document,
            artifactID: artifact, manifestSHA256: input.expectedSHA256)
        _ = try await coordinator.install(binding: binding, manifestData: input.manifestData, members: input.members).value
        return SeedSummary(rows: observation.entries.count, memberBytes: input.members.values.reduce(0) { $0 + $1.count },
                           manifestSHA256: input.expectedSHA256)
    }

    /// Bounded pages exercise the actual wire decoder and reconciler. Each
    /// row owns distinct non-inline author strings; sharing one small array
    /// across 4,000 rows would understate native model/publication costs.
    static func observation() throws -> LibraryCompleteObservation {
        var reconciler = LibraryReconciler(accountID: account)
        let pageSize = 20
        for first in stride(from: 1, through: rowCount, by: pageSize) {
            let last = min(first + pageSize - 1, rowCount)
            try autoreleasepool {
                let rows = try (first...last).map(row)
                let page: [String: Any] = ["format": 2, "account_id": account.wire,
                    "baseline_cursor": rowCount, "retained_after": 0, "entries": rows,
                    "has_more": last < rowCount, "next_cursor": ["format": 2, "account_id": account.wire,
                        "through": rowCount, "created_seq": last, "id": identifier(role: 3, row: last).wire, "kind": "item"]]
                let request = try reconciler.nextRequest(limit: pageSize)
                try reconciler.accept(LibraryWire.decodeBaseline(json(page)), for: request)
            }
        }
        let changes: [String: Any] = ["format": 2, "account_id": account.wire, "through": rowCount,
            "retained_after": 0, "changes": [], "next_cursor": rowCount, "has_more": false]
        let request = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(json(changes)), for: request)
        let result = try reconciler.completeObservation()
        guard result.entries.count == rowCount else { throw Failure.invalidFixture }
        return result
    }

    private static func row(_ index: Int) throws -> [String: Any] {
        let number = String(format: "%04d", index)
        let prefix = "Resource measurement \(number) "
        let authors = (1...authorsPerRow).map { "Resource author \(number)-" + String(format: "%03d", $0) }
        let categories = (1...categoriesPerRow).map { "fixture.topic." + String(format: "%02d", $0) }
        var metadata: [String: Any] = ["title": prefix + String(repeating: "t", count: 2_000 - prefix.utf8.count),
            "authors": authors, "categories": categories, "venue": String(repeating: "v", count: 1_024),
            "published_at": "2024-04-03", "updated_at": "2024-04-03", "abstract": ""]
        let padding = metadataBytes - (try json(metadata).count)
        guard (1...24_000).contains(padding) else { throw Failure.invalidFixture }
        metadata["abstract"] = String(repeating: "a", count: padding)
        let encoded = try json(metadata)
        let decoded = try JSONDecoder().decode(LibraryMetadata.self, from: encoded)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        guard encoded.count == metadataBytes, try encoder.encode(decoded).count == metadataBytes,
              decoded.authors.count == authorsPerRow, decoded.categories.count == categoriesPerRow else {
            throw Failure.invalidFixture
        }
        let source = "2404." + String(format: "%05d", index)
        return ["kind": "item", "id": identifier(role: 3, row: index).wire,
            "document_id": identifier(role: 1, row: index).wire, "artifact_id": identifier(role: 2, row: index).wire,
            "created_seq": index, "state_seq": index, "membership_revision": 1, "visible": true,
            "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": 0,
            "approval_id": identifier(role: 4, row: index).wire, "version_id": identifier(role: 5, row: index).wire,
            "metadata_id": identifier(role: 6, row: index).wire, "source": "arxiv", "source_id": source,
            "source_revision": 1, "metadata": metadata, "metadata_recorded_at": "2026-10-03T10:00:00Z",
            "source_url": "https://arxiv.org/abs/\(source)v1", "scope": "shared_catalog", "page_count": 1,
            "original_object_id": identifier(role: 7, row: index).wire, "readiness": "converted_ready",
            "original_availability": "available", "render_availability": "available",
            "original_availability_revision": 1, "render_availability_revision": 1]
    }

    private static func identifier(role: Int, row: Int) -> UUID {
        UUID(uuidString: String(format: "cccccccc-4000-4000-8000-%012x", role * 10_000 + row))!
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func installedInput() throws -> ReaderBundleInput {
        guard let resources = Bundle.main.resourceURL else { throw Failure.invalidFixture }
        let base = try ReaderBundleLoader.load(directory: resources.appendingPathComponent("offline-resource/" + baseManifestSHA256),
                                               expectedSHA256: baseManifestSHA256)
        guard base.index.equations.count == 1, base.index.figures.count == 1,
              base.manifest.members.filter({ $0.role == "image" }).reduce(0, { $0 + ($1.width ?? 0) * ($1.height ?? 0) }) == imagePixels,
              var manifest = try JSONSerialization.jsonObject(with: base.manifestData) as? [String: Any],
              var listed = manifest["members"] as? [[String: Any]] else { throw Failure.invalidFixture }
        var members: [String: Data] = [:]
        for member in base.manifest.members {
            guard let bytes = base.data(for: member.path) else { throw Failure.invalidFixture }
            members[member.path] = bytes
        }
        var remaining = payloadBytes - members.values.reduce(0) { $0 + $1.count }
        guard remaining > 16_777_216, remaining <= 33_554_432 else { throw Failure.invalidFixture }
        for ordinal in 1...2 {
            let count = min(16_777_216, remaining), path = "offline-resource/padding-\(ordinal).txt"
            let bytes = Data(repeating: 32, count: count)
            members[path] = bytes
            listed.append(["path": path, "role": "notice", "media_type": "text/plain", "bytes": count, "sha256": digest(bytes)])
            remaining -= count
        }
        guard remaining == 0, members.values.reduce(0, { $0 + $1.count }) == payloadBytes else { throw Failure.invalidFixture }
        manifest["members"] = listed.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let data = try json(manifest)
        // The independent source of this seed-only digest is the compiled
        // trusted base and fixed padding recipe, not a caller's manifest.
        return try ReaderBundleInput(manifestData: data, expectedSHA256: digest(data), members: members)
    }
}

/// Finite numeric measurements, never catalog/private text. This reports the
/// app process only. A process-lifetime Mach peak is not an interval peak or
/// WKWebView WebContent total. Unsupported/zero metrics remain JSON null.
@MainActor @Observable
final class OfflineResourceProbe {
    enum Phase: Int, Codable, CaseIterable { case restore = 1, publication, open, readerReady, search, figure }
    static let shared = OfflineResourceProbe()
    private(set) var statusJSON = "{}"
    private(set) var mode: OfflineResourceFixture.Mode?
    @ObservationIgnored private var started: [Phase: Stamp] = [:]
    @ObservationIgnored private var completed: [Phase: Event] = [:]
    @ObservationIgnored private var origin = DispatchTime.now().uptimeNanoseconds
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var publishedSerial = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var installations = 0
    @ObservationIgnored private var ciphertextBytes = 0
    @ObservationIgnored private var openedMemberBytes: Int?
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var failure = 0
    @ObservationIgnored private var searchSourceElapsedMS: Double?
    @ObservationIgnored private var searchWorkerElapsedMS: Double?
    @ObservationIgnored private var searchPublicationElapsedMS: Double?
    @ObservationIgnored private var settledStartMS: Double?
    @ObservationIgnored private var settledSamples: [SettledFootprint]?

    private struct Stamp {
        let nanoseconds: UInt64
        let footprint: UInt64?
        let lifetimePeak: UInt64?
    }
    private struct Event: Encodable {
        let phase: Int
        let startMS: Double
        let elapsedMS: Double
        let count: Int?
        let startAppFootprintBytes: UInt64?
        let endAppFootprintBytes: UInt64?
        let appLifetimePeakBytes: UInt64?
        enum CodingKeys: String, CodingKey {
            case phase, startMS, elapsedMS, count, startAppFootprintBytes, endAppFootprintBytes, appLifetimePeakBytes
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(phase, forKey: .phase); try c.encode(startMS, forKey: .startMS)
            try c.encode(elapsedMS, forKey: .elapsedMS); try c.encode(count, forKey: .count)
            try c.encode(startAppFootprintBytes, forKey: .startAppFootprintBytes)
            try c.encode(endAppFootprintBytes, forKey: .endAppFootprintBytes)
            try c.encode(appLifetimePeakBytes, forKey: .appLifetimePeakBytes)
        }
    }
    private struct SettledFootprint: Encodable {
        let requestedOffsetMS: Int
        let elapsedMS: Double
        let appFootprintBytes: UInt64?
        let appLifetimePeakBytes: UInt64?
        enum CodingKeys: String, CodingKey { case requestedOffsetMS, elapsedMS, appFootprintBytes, appLifetimePeakBytes }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(requestedOffsetMS, forKey: .requestedOffsetMS)
            try c.encode(elapsedMS, forKey: .elapsedMS)
            try c.encode(appFootprintBytes, forKey: .appFootprintBytes)
            try c.encode(appLifetimePeakBytes, forKey: .appLifetimePeakBytes)
        }
    }
    private struct Report: Encodable {
        let format = 3
        let pid: Int32
        let mode: Int
        let rows: Int
        let installations: Int
        let ciphertextBytes: Int
        let expectedMemberBytes: Int
        let openedMemberBytes: Int?
        let debugAssertions: Bool
        let seeded: Bool
        let failure: Int
        let events: [Event]
        let searchSourceElapsedMS: Double?
        let searchWorkerElapsedMS: Double?
        let searchPublicationElapsedMS: Double?
        let settledStartMS: Double?
        let settledSamples: [SettledFootprint]?
        let webContentPeakBytes: UInt64? = nil
        let appIntervalPeakBytes: UInt64? = nil
        enum CodingKeys: String, CodingKey { case format, pid, mode, rows, installations, ciphertextBytes, expectedMemberBytes, openedMemberBytes, debugAssertions, seeded, failure, events, searchSourceElapsedMS, searchWorkerElapsedMS, searchPublicationElapsedMS, settledStartMS, settledSamples, webContentPeakBytes, appIntervalPeakBytes }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format); try c.encode(pid, forKey: .pid); try c.encode(mode, forKey: .mode)
            try c.encode(rows, forKey: .rows); try c.encode(installations, forKey: .installations)
            try c.encode(ciphertextBytes, forKey: .ciphertextBytes); try c.encode(expectedMemberBytes, forKey: .expectedMemberBytes)
            try c.encode(openedMemberBytes, forKey: .openedMemberBytes)
            try c.encode(debugAssertions, forKey: .debugAssertions)
            try c.encode(seeded, forKey: .seeded); try c.encode(failure, forKey: .failure); try c.encode(events, forKey: .events)
            try c.encode(searchSourceElapsedMS, forKey: .searchSourceElapsedMS)
            try c.encode(searchWorkerElapsedMS, forKey: .searchWorkerElapsedMS)
            try c.encode(searchPublicationElapsedMS, forKey: .searchPublicationElapsedMS)
            try c.encode(settledStartMS, forKey: .settledStartMS)
            try c.encode(settledSamples, forKey: .settledSamples)
            try c.encode(webContentPeakBytes, forKey: .webContentPeakBytes)
            // The interval metric is retained by XCTest in xcresult, not
            // fabricated from the largest of a few app-side snapshots.
            try c.encode(appIntervalPeakBytes, forKey: .appIntervalPeakBytes)
        }
    }

    func configure(_ mode: OfflineResourceFixture.Mode) {
        self.mode = mode; started = [:]; completed = [:]; origin = DispatchTime.now().uptimeNanoseconds
        generation = UUID(); serial = 0; publishedSerial = 0; rows = 0; installations = 0; ciphertextBytes = 0
        openedMemberBytes = nil; seeded = false; failure = 0
        searchSourceElapsedMS = nil; searchWorkerElapsedMS = nil; searchPublicationElapsedMS = nil
        settledStartMS = nil; settledSamples = nil
        publish()
    }

    func begin(_ phase: Phase) {
        guard mode != nil, mode != .seed, failure == 0, started[phase] == nil, completed[phase] == nil else { return }
        started[phase] = stamp()
    }

    func finish(_ phase: Phase, count: Int? = nil) {
        guard failure == 0, let first = started.removeValue(forKey: phase), completed[phase] == nil else { return }
        let last = stamp()
        completed[phase] = Event(phase: phase.rawValue, startMS: Double(first.nanoseconds - origin) / 1_000_000,
            elapsedMS: Double(last.nanoseconds - first.nanoseconds) / 1_000_000, count: count,
            startAppFootprintBytes: first.footprint, endAppFootprintBytes: last.footprint, appLifetimePeakBytes: last.lifetimePeak)
        publish()
    }

    func restored(rows: Int, installations: Int, ciphertextBytes: Int) {
        self.rows = rows; self.installations = installations; self.ciphertextBytes = ciphertextBytes
        let empty = mode == .empty
        guard rows == (empty ? 0 : OfflineResourceFixture.rowCount),
              installations == (empty ? 0 : 1),
              (empty ? ciphertextBytes >= 0 : ciphertextBytes > OfflineResourceFixture.payloadBytes) else {
            fail(.unexpectedState); return
        }
        finish(.restore, count: rows)
    }

    func opened(memberBytes: Int, imagePixels: Int) {
        guard memberBytes == OfflineResourceFixture.payloadBytes,
              imagePixels == OfflineResourceFixture.imagePixels else { fail(.unexpectedState); return }
        openedMemberBytes = memberBytes
        finish(.open, count: memberBytes)
        begin(.readerReady)
    }

    func didSeed(_ summary: OfflineResourceFixture.SeedSummary) {
        guard mode == .seed, summary.rows == OfflineResourceFixture.rowCount,
              summary.memberBytes == OfflineResourceFixture.payloadBytes else { fail(.invalidFixture); return }
        rows = summary.rows; installations = 1; seeded = true; publish()
    }

    /// The search phase is submit-to-accepted-result latency. Worker time and
    /// main-actor snapshot/publication time are reported separately; moving a
    /// scan off the UI thread does not make its computation disappear.
    func beginSearch(query: String) { if query == OfflineResourceFixture.noMatchQuery { begin(.search) } }
    func searchSourceBuilt(rows: Int, elapsedMS: Double) {
        guard mode == .restore, rows == OfflineResourceFixture.rowCount else { return }
        searchSourceElapsedMS = elapsedMS; publish()
    }
    func searchCompleted(query: String, workerElapsedMS: Double, publicationElapsedMS: Double, count: Int) {
        guard mode == .restore, query == OfflineResourceFixture.noMatchQuery else { return }
        searchWorkerElapsedMS = workerElapsedMS; searchPublicationElapsedMS = publicationElapsedMS
        finish(.search, count: count)
    }

    /// Call only after the restore function has returned and the model has
    /// joined its search, coordinator and accepted persistence work, checked
    /// activation ended, and validated the unchanged complete library. This
    /// observes current app footprint without collecting or purging anything;
    /// it does not establish a retained-heap size, peak or stable plateau.
    func sampleSettledFootprints(isCurrent: @MainActor () -> Bool) async {
        guard failure == 0 else { return }
        guard ProcessInfo.processInfo.arguments.contains("--offline-resource-settled"),
              mode == .empty || mode == .restore, settledStartMS == nil,
              completed[.restore] != nil, started.isEmpty, openedMemberBytes == nil, isCurrent() else {
            fail(.unexpectedState); return
        }
        let samplingGeneration = generation
        let samplingOrigin = DispatchTime.now().uptimeNanoseconds
        settledStartMS = Double(samplingOrigin - origin) / 1_000_000
        var samples: [SettledFootprint] = []
        samples.reserveCapacity(4)
        for offset in [0, 250, 500, 1_000] {
            let deadline = samplingOrigin + UInt64(offset) * 1_000_000
            do {
                // Sleep toward one absolute schedule. Scheduler delay is
                // retained in elapsedMS rather than called an exact offset.
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < deadline { try await Task.sleep(nanoseconds: deadline - now) }
                }
                try Task.checkCancellation()
            } catch {
                guard generation == samplingGeneration else { return }
                settledSamples = samples; fail(.unexpectedState); return
            }
            guard generation == samplingGeneration, failure == 0 else { return }
            guard started.isEmpty, openedMemberBytes == nil, isCurrent() else {
                settledSamples = samples; fail(.unexpectedState); return
            }
            let reading = stamp()
            samples.append(SettledFootprint(requestedOffsetMS: offset,
                elapsedMS: Double(reading.nanoseconds - samplingOrigin) / 1_000_000,
                appFootprintBytes: reading.footprint, appLifetimePeakBytes: reading.lifetimePeak))
            guard reading.footprint != nil else {
                settledSamples = samples; fail(.unavailableMetric); return
            }
        }
        guard isCurrent() else { settledSamples = samples; fail(.unexpectedState); return }
        settledSamples = samples
        // Publish once: intermediate JSON/observation work is not introduced
        // between the four passive readings. Existing app work runs normally.
        publish()
    }

    func fail(_ code: OfflineResourceFixture.Failure) { failure = code.rawValue; publish() }

    private func publish() {
        guard let mode else { return }
        let report = Report(pid: ProcessInfo.processInfo.processIdentifier, mode: mode == .seed ? 1 : (mode == .restore ? 2 : 3),
            rows: rows, installations: installations, ciphertextBytes: ciphertextBytes,
            expectedMemberBytes: mode == .empty ? 0 : OfflineResourceFixture.payloadBytes,
            openedMemberBytes: openedMemberBytes, debugAssertions: _isDebugAssertConfiguration(), seeded: seeded, failure: failure,
            events: completed.values.sorted { $0.phase < $1.phase }, searchSourceElapsedMS: searchSourceElapsedMS,
            searchWorkerElapsedMS: searchWorkerElapsedMS, searchPublicationElapsedMS: searchPublicationElapsedMS,
            settledStartMS: settledStartMS, settledSamples: settledSamples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(report), bytes.count <= 16_384,
              let value = String(data: bytes, encoding: .utf8) else { return }
        serial += 1
        let current = serial, generation = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation, current > self.publishedSerial else { return }
            self.publishedSerial = current; self.statusJSON = value
        }
    }

    private func stamp() -> Stamp {
        let time = DispatchTime.now().uptimeNanoseconds
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Stamp(nanoseconds: time, footprint: nil, lifetimePeak: nil) }
        let returnedBytes = Int(count) * MemoryLayout<integer_t>.stride
        let footprintOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint)
        let peakOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak)
        let footprint = footprintOffset.map { returnedBytes >= $0 + MemoryLayout.size(ofValue: info.phys_footprint) } == true
            && info.phys_footprint > 0 ? UInt64(info.phys_footprint) : nil
        let peak = peakOffset.map { returnedBytes >= $0 + MemoryLayout.size(ofValue: info.ledger_phys_footprint_peak) } == true
            && info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : nil
        return Stamp(nanoseconds: time, footprint: footprint, lifetimePeak: peak)
    }
}

/// A tiny test-only status overlay. The label/value contain only fixed numeric
/// counters and probe JSON; it does not expose the library accessibility tree.
@MainActor struct OfflineResourceStatusView: View {
    var probe = OfflineResourceProbe.shared
    var body: some View {
        Text(probe.mode == .empty ? "0 · 0" : "4000 · 33554432")
            .font(.system(size: 8, design: .monospaced)).padding(2)
            .accessibilityIdentifier("offline.resource.status")
            .accessibilityValue(probe.statusJSON)
            .allowsHitTesting(false)
    }
}
#endif
