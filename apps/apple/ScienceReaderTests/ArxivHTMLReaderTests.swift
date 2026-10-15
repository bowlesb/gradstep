import Foundation
import ScienceReaderCore
import Testing
@testable import ScienceReader

@MainActor @Suite struct ArxivHTMLReaderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCIENCE_READER_LIVE_HTML"] == "1"))
    func liveOfficialHTMLCompletesOnTheNativeAcquisitionPath() async throws {
        let start = Date()
        print("Native live HTML preparation started")
        let source = try ArxivReaderSource(sourceID: "2305.18290", revision: 3)
        let bundle = try await ArxivHTMLReader().prepare(source)
        #expect(bundle.arxivSource == source)
        #expect(bundle.index.equations.count == 261)
        print("Native live HTML preparation completed in \(Date().timeIntervalSince(start)) seconds")
    }
    @Test func webKitCompilesMathAndImagesWithIndependentNativeAdmission() async throws {
        let bundle = try await compileFixture("source.html")
        #expect(bundle.index.equations.count == 2)
        #expect(bundle.index.figures.count == 1)
        #expect(bundle.index.title == "Authored HTML fixture")
    }
    @Test func webKitPreservesGroupedCaptionsInlineVectorsAndLegendText() async throws {
        let bundle = try await compileFixture("figures.html")
        #expect(bundle.manifest.renderer.id == "gradstep-arxiv-html-mathml-v2")
        #expect(bundle.index.equations.count == 2)
        #expect(bundle.index.figures.count == 4)
        #expect(bundle.index.blocks.last?.text.contains("Retained legend text") == true)
        #expect(bundle.index.figures.last?.assetPaths.count == 2)
    }
    private func compileFixture(_ name: String) async throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let html = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/\(name)"))
        let image = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-mathpix/figure-exif.jpg"))
        let source = try ArxivReaderSource(sourceID: "2601.01234", revision: 2)
        let reader = ArxivHTMLReader { url, ref, maximum in
            #expect(ref == source)
            let data = url == source.htmlURL ? html : image
            #expect(data.count <= maximum)
            #expect(url == source.htmlURL || source.admitsAsset(url.absoluteString))
            return data
        }
        let bundle = try await reader.prepare(source)
        #expect(bundle.arxivSource == source)
        return bundle
    }
}

@MainActor @Suite struct ArxivCompilerIdentityTests {
    /// A bundle compiled by an older app is prepared again when opened (owner, build 40: a paper first opened on
    /// build 39 kept its old header). The shipped identity file names this app's compiler; the committed fixture
    /// package was compiled by an earlier revision.
    @Test func shippedIdentityTellsOldBundlesFromThisCompilers() throws {
        let shipped = try #require(ArxivCompilerIdentity.shipped)
        #expect(shipped.rendererID == "gradstep-arxiv-html-mathml-v2")
        #expect(shipped.revision >= 3)
        #expect(shipped.buildSHA256.count == 64)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let old = try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
        #expect(!ArxivCompilerIdentity.isCurrent(old), "the committed fixture predates this compiler")
    }
}
