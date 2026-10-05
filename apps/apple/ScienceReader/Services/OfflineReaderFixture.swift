#if DEBUG && targetEnvironment(simulator)
import Foundation
import ScienceReaderCore

/// Public synthetic data for a process-restart journey. This is absent from
/// device/release builds and never creates a real account or catalog record.
enum OfflineReaderFixture {
    static let account = UUID(uuidString: "dddddddd-0000-4000-8000-000000000001")!
    static let document = UUID(uuidString: "dddddddd-0000-4000-8000-000000000002")!
    static let artifact = UUID(uuidString: "dddddddd-0000-4000-8000-000000000003")!
    static let item = UUID(uuidString: "dddddddd-0000-4000-8000-000000000004")!
    // Pinned after rendering the real DPO Mathpix capture (arXiv 2305.18290,
    // CC BY 4.0) with the Edge renderer, never a digest discovered in a download.
    static let mathpixManifestSHA256 = "a6ca6825b3c112f591b884ebd648b9d85785544050da3444f91ae9e7f2bed695"

    enum Variant {
        case authored, mathpix

        var directoryName: String {
            self == .authored ? "offline-reader-fixture" : "offline-mathpix-reader-fixture"
        }
        var deployment: String { "https://" + directoryName + ".invalid" }
        var manifestSHA256: String {
            self == .authored ? ReaderBundleLoader.sampleManifestSHA256 : OfflineReaderFixture.mathpixManifestSHA256
        }
        var sourceID: String { self == .authored ? "2404.00001" : "2305.18290" }
        var title: String {
            self == .authored ? "Offline reading fixture" : "Direct Preference Optimization (Mathpix MathML fixture)"
        }
    }

    static func reader(variant: Variant) throws -> VerifiedReaderBundle {
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
        let row: [String: Any] = ["kind": "item", "id": item.wire, "document_id": document.wire,
            "created_seq": 1, "state_seq": 1, "membership_revision": 1, "visible": true,
            "added_at": "2026-10-03T10:00:00Z", "last_remove_seq": 0,
            "approval_id": "dddddddd-0000-4000-8000-000000000005", "version_id": "dddddddd-0000-4000-8000-000000000006",
            "metadata_id": "dddddddd-0000-4000-8000-000000000007", "source": "arxiv", "source_id": variant.sourceID, "source_revision": variant == .authored ? 1 : 3,
            "metadata": ["title": variant.title, "authors": [variant == .authored ? "Synthetic library · authored sample" : "Rafailov et al. · Mathpix MathML renderer"],
                "abstract": "A local fixture for testing encrypted downloads, equations and chat after restarting the app.",
                "published_at": "2024-04-03", "updated_at": "2024-04-03", "categories": ["cs.LG"], "venue": NSNull()],
            "metadata_recorded_at": "2026-10-03T10:00:00Z", "source_url": "https://arxiv.org/abs/\(variant.sourceID)v\(variant == .authored ? 1 : 3)",
            "scope": "shared_catalog", "page_count": variant == .authored ? 1 : 27, "original_object_id": "dddddddd-0000-4000-8000-000000000008",
            "artifact_id": artifact.wire, "readiness": "converted_ready", "original_availability": "available",
            "render_availability": "available", "original_availability_revision": 1, "render_availability_revision": 1]
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
