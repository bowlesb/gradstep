import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

/// The on-device PDF route inside the iOS app (docs/architecture/DEVICE_PDF_ROUTE.md): the bundled models and
/// converter, iOS's PDF rendering, JavaScriptCore without a JIT and Core ML on this device. The Mac tool measures
/// conformance on the desktop's fixtures; this checks the same code runs here and produces a bundle the reader admits.
final class DeviceModelRouteTests: XCTestCase {
    /// A two-page paper drawn on the device: a title, an abstract, paragraphs with a formula, a heading.
    private func syntheticPaper() -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            let body = UIFont(name: "Times New Roman", size: 10) ?? .systemFont(ofSize: 10)
            func draw(_ text: String, font: UIFont, in rect: CGRect) {
                (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
            let paragraph = "We study a simple objective and show that its gradient is well defined for every input. The method is easy to "
                + "implement and matches strong baselines on three benchmarks while using a fraction of their compute. "
            for n in 0..<2 {
                context.beginPage()
                var y: CGFloat = 72
                if n == 0 {
                    draw("A Synthetic Paper About Simple Objectives", font: UIFont(name: "Times New Roman Bold", size: 17) ?? .boldSystemFont(ofSize: 17), in: CGRect(x: 90, y: y, width: 432, height: 30)); y += 44
                    draw("Ada Example and Grace Sample", font: body, in: CGRect(x: 220, y: y, width: 300, height: 14)); y += 34
                    draw("Abstract", font: UIFont(name: "Times New Roman Bold", size: 11) ?? .boldSystemFont(ofSize: 11), in: CGRect(x: 286, y: y, width: 100, height: 16)); y += 20
                    draw(String(repeating: paragraph, count: 2), font: body, in: CGRect(x: 110, y: y, width: 392, height: 80)); y += 96
                }
                draw("\(n + 1)  \(n == 0 ? "Introduction" : "Method")", font: UIFont(name: "Times New Roman Bold", size: 12) ?? .boldSystemFont(ofSize: 12), in: CGRect(x: 72, y: y, width: 300, height: 18)); y += 26
                for _ in 0..<4 {
                    draw(String(repeating: paragraph, count: 3), font: body, in: CGRect(x: 72, y: y, width: 468, height: 90)); y += 100
                }
                draw("L(x) = x² + y² − 2xy", font: UIFont(name: "Times New Roman Italic", size: 11) ?? .italicSystemFont(ofSize: 11), in: CGRect(x: 250, y: y, width: 200, height: 18))
            }
        }
    }

    private func run(_ pdf: Data, maxPages: Int = 0) async throws -> (VerifiedReaderBundle, Data) {
        guard #available(iOS 18.0, *) else { throw XCTSkip("The recogniser's state needs iOS 18") }
        guard DeviceModelEngine.available, let models = DeviceModelEngine.modelsDirectory, let compiler = DeviceModelEngine.compilerURL else {
            throw XCTSkip("This build carries no device models (node scripts/device-models.mjs)")
        }
        let route = DevicePDFRoute(models: try await DevicePDFModels.load(directory: models), compilerSource: try String(contentsOf: compiler, encoding: .utf8))
        let output = try route.convert(pdf: pdf, name: "paper.pdf", options: .init(title: "A Synthetic Paper About Simple Objectives", sourceID: "2305.18290", revision: 3, maxPages: maxPages))
        let verified = try VerifiedReaderBundle.verify(manifest: output.manifest, expectedSHA256: output.manifestSHA256, members: output.members)
        return (try ReaderBundleLoader.admitImages(in: verified), output.summary)
    }

    func testADevicePDFBecomesAReaderBundleTheStoreKeeps() async throws {
        let (bundle, summary) = try await run(syntheticPaper())
        XCTAssertEqual(bundle.manifest.renderer.id, "gradstep-device-pdf-mathml-v1")
        XCTAssertEqual(bundle.devicePDFSource?.paper?.sourceID, "2305.18290")
        XCTAssertFalse(bundle.index.title.isEmpty)
        XCTAssertGreaterThanOrEqual(bundle.index.blocks.filter { $0.kind == "paragraph" }.count, 4, String(decoding: summary, as: UTF8.self))
        // The model readings' own store accepts it beside nothing else.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try DeviceReaderStore(directory: directory, accountID: UUID(), localKey: Data(repeating: 7, count: 32))
        let record = try await store.install(bundle: bundle)
        XCTAssertEqual(record.identity.sourceID, "2305.18290")
        let reread = try await store.read(record.identity)
        XCTAssertEqual(reread.manifestSHA256, bundle.manifestSHA256)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real paper from the desktop's fixture set, when this Mac has it (TEST_RUNNER_DEVICE_PDF_FIXTURE=<paper.pdf>):
    /// the first three pages through the iOS path, with timings in the log.
    func testARealPaperOnTheDevicePath() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEVICE_PDF_FIXTURE"], let pdf = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("Set TEST_RUNNER_DEVICE_PDF_FIXTURE to a paper's PDF to run this")
        }
        let started = Date()
        let (bundle, summary) = try await run(pdf, maxPages: 3)
        print("device route on the Simulator: \(Int(Date().timeIntervalSince(started))) s; \(String(decoding: summary, as: UTF8.self))")
        XCTAssertGreaterThan(bundle.index.blocks.count, 10)
        XCTAssertGreaterThan(bundle.index.headings.count, 0)
    }

    @MainActor func testModelKeyFailureKeepsARetryableBoundedMessage() {
        for failure in [DevicePDFModelAccessFailure.keyUnavailable, .decryptionFailed, .serviceUnavailable] {
            let message = ReaderModel.deviceModelMessage(DevicePDFModelError.access(failure))
            XCTAssertTrue(message.lowercased().contains("try again"))
            XCTAssertTrue(message.contains("internet for first use"))
            XCTAssertTrue(message.contains("still on this device"))
            XCTAssertLessThan(message.count, 200)
        }
    }
}
