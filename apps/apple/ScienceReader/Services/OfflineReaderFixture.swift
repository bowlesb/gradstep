#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// Public synthetic data for a process-restart journey. This is absent from
/// device/release builds and never creates a real account or catalog record.
enum OfflineReaderFixture {
    static let account = UUID(uuidString: "dddddddd-0000-4000-8000-000000000001")!
    static let document = UUID(uuidString: "dddddddd-0000-4000-8000-000000000002")!
    static let artifact = UUID(uuidString: "dddddddd-0000-4000-8000-000000000003")!
    static let item = UUID(uuidString: "dddddddd-0000-4000-8000-000000000004")!
    /// `--offline-reader-unprepared`: a membership whose reading isn't on this device (opened offline in journeys).
    static let unprepared = UUID(uuidString: "dddddddd-0000-4000-8000-000000000009")!
    // Pinned after rendering the real DPO Mathpix capture (arXiv 2305.18290,
    // CC BY 4.0) with the Edge renderer, never a digest discovered in a download.
    static let mathpixManifestSHA256 = "cd902bcdeeda373f6612f00221010f3fba918dcafbd500142d46ee53b2178a71"

    // Opt-in regression corpus, fetched on this Mac. Never compiled into a shipping app.
    static var reportedEquations: Bool { ProcessInfo.processInfo.arguments.contains("--reported-equations-fixture") }
    static let reportedManifestSHA256 = "828898ebb96e0d0f13b5c83a6076db9f7a8dd2dc0b81e4fbe15074fbfbf97bbf"

    enum Variant {
        case authored, mathpix

        var directoryName: String {
            OfflineReaderFixture.reportedEquations ? "offline-reported-equations-fixture" : self == .authored ? "offline-reader-fixture" : "offline-mathpix-reader-fixture"
        }
        var deployment: String { "https://" + directoryName + ".invalid" }
        var manifestSHA256: String {
            OfflineReaderFixture.reportedEquations ? OfflineReaderFixture.reportedManifestSHA256 : self == .authored ? ReaderBundleLoader.sampleManifestSHA256 : OfflineReaderFixture.mathpixManifestSHA256
        }
        var sourceID: String { OfflineReaderFixture.reportedEquations ? "1805.03662" : self == .authored ? "2404.00001" : "2305.18290" }
        var title: String {
            OfflineReaderFixture.reportedEquations ? "Encoding Electronic Spectra in Quantum Circuits with Linear T Complexity" : self == .authored ? "Offline reading fixture" : "Direct Preference Optimization (Mathpix MathML fixture)"
        }
    }

    static func reader(variant: Variant) throws -> VerifiedReaderBundle {
        if reportedEquations {
            guard let path = ProcessInfo.processInfo.environment["REPORTED_EQUATIONS_BUNDLE"] else { throw ReaderBundleError.invalidResource }
            return try ReaderBundleLoader.load(directory: URL(fileURLWithPath: path), expectedSHA256: reportedManifestSHA256)
        }
        if variant == .authored { return try ReaderBundleLoader.sample() }
        guard let resources = Bundle.main.resourceURL else { throw ReaderBundleError.invalidResource }
        let reader = try ReaderBundleLoader.load(directory: resources.appendingPathComponent("ReaderSamples/" + variant.manifestSHA256),
                                                  expectedSHA256: variant.manifestSHA256)
        guard reader.manifest.renderer.id == "timestep-mathpix-mathml-v1", reader.manifest.source.kind == "mathpix-mmd" else {
            throw ReaderBundleError.incompatibleFormat
        }
        return reader
    }

    static func device() throws -> LocalDevice {
        let encoded = try JSONSerialization.data(withJSONObject: [
            "accountID": account.uuidString, "epoch": 1,
            "contentKeys": ["1": Data(repeating: 41, count: 32).base64EncodedString()],
            "managementToken": Data(repeating: 43, count: 32).base64EncodedString()
        ])
        var device = LocalDevice.create(accountID: account, localStoreKey: Data(repeating: 47, count: 32))
        device.bundle = try JSONDecoder().decode(KeyBundle.self, from: encoded)
        return device
    }

    static func observation(variant: Variant) throws -> LibraryCompleteObservation {
        var row: [String: Any] = ["kind": "item", "id": item.wire, "document_id": document.wire,
            "created_seq": 1, "state_seq": 1, "membership_revision": 1, "visible": true,
            "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": 0,
            "approval_id": "dddddddd-0000-4000-8000-000000000005", "version_id": "dddddddd-0000-4000-8000-000000000006",
            "metadata_id": "dddddddd-0000-4000-8000-000000000007", "source": "arxiv", "source_id": variant.sourceID, "source_revision": variant == .authored ? 1 : 3,
            "metadata": ["title": variant.title, "authors": [variant == .authored ? "Synthetic library · authored sample" : "Rafailov et al. · Mathpix MathML renderer"],
                "abstract": "A local fixture for testing encrypted downloads, equations and chat after restarting the app.",
                // The rendered paper's real dates and venue (the reader's publication line shows them).
                "published_at": variant == .authored ? "2024-04-03" : "2023-05-29", "updated_at": "2024-04-03", "categories": ["cs.LG"],
                "venue": variant == .authored ? NSNull() as Any : "NeurIPS" as Any],
            "metadata_recorded_at": "2026-10-03T10:00:00Z", "source_url": "https://arxiv.org/abs/\(variant.sourceID)v\(variant == .authored ? 1 : 3)",
            "scope": "shared_catalog", "page_count": variant == .authored ? 1 : 27, "original_object_id": "dddddddd-0000-4000-8000-000000000008",
            "artifact_id": artifact.wire, "readiness": "converted_ready", "original_availability": "available",
            "render_availability": "available", "original_availability_revision": 1, "render_availability_revision": 1]
        if variant == .mathpix {
            // Topic tags (migration 030): the catalog's, one the reader removed, and one of their own.
            row["tags"] = ["Natural language processing", "Large language models", "Preference optimization", "Alignment", "Reward modeling"]
            row["hidden_tags"] = ["Reward modeling"]
            row["user_tags"] = ["Reading group"]
        }
        let baseline: [String: Any] = ["format": 2, "account_id": account.wire, "baseline_cursor": 1, "retained_after": 0,
            "entries": [row], "has_more": false, "next_cursor": ["format": 2, "account_id": account.wire, "through": 1,
                "created_seq": 1, "id": item.wire, "kind": "item"]]
        let changes: [String: Any] = ["format": 2, "account_id": account.wire, "through": 1, "retained_after": 0,
            "changes": [], "next_cursor": 1, "has_more": false]
        var reconciler = LibraryReconciler(accountID: account)
        let first = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeBaseline(JSONSerialization.data(withJSONObject: baseline)), for: first)
        let next = try reconciler.nextRequest()
        try reconciler.accept(LibraryWire.decodeChanges(JSONSerialization.data(withJSONObject: changes)), for: next)
        return try reconciler.completeObservation()
    }
}
#endif
