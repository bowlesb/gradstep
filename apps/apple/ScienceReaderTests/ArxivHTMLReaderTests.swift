import Foundation
import ScienceReaderCore
import Testing
@testable import ScienceReader

@MainActor @Suite struct ArxivHTMLReaderTests {
    /// Opt-in replay of owner-reported papers through the exact native WebKit and bundle-admission path.
    /// Uses only cached official HTML/assets; a missing cache is an error, never a network request.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCIENCE_READER_HTML_CASES"] != nil))
    func reportedPapersPrepareFromCachedOfficialSources() async throws {
        struct Paper: Decodable {
            let source_id: String
            let source_revision: Int
            let title: String
            let authors: [String]
        }
        let path = try #require(ProcessInfo.processInfo.environment["SCIENCE_READER_HTML_CASES"])
        let papers = try JSONDecoder().decode([Paper].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(!papers.isEmpty && papers.count <= 10)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".artifacts/reader-sweep")
        for paper in papers {
            let source = try ArxivReaderSource(sourceID: paper.source_id, revision: paper.source_revision)
            let key = "\(source.sourceID)v\(source.revision)"
            let reader = ArxivHTMLReader { url, ref, maximum in
                #expect(ref == source)
                let path: URL
                if url == source.htmlURL {
                    path = root.appendingPathComponent("sources/\(key).html")
                } else {
                    #expect(source.admitsAsset(url.absoluteString))
                    // Same encodeURIComponent filename as scripts/reader-device-compile.mjs.
                    let name = try #require(url.absoluteString.split(separator: "/").last)
                    let encoded = try #require(String(name).addingPercentEncoding(withAllowedCharacters:
                        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")))
                    path = root.appendingPathComponent("assets/\(key)/\(encoded)")
                }
                let data = try Data(contentsOf: path)
                #expect(data.count <= maximum)
                return data
            }
            let start = Date()
            do {
                let bundle = try await reader.prepare(source, authors: paper.authors, title: paper.title)
                #expect(bundle.arxivSource == source)
                #expect(!bundle.index.blocks.isEmpty && !bundle.index.figures.isEmpty && !bundle.index.equations.isEmpty)
                print("Cached native paper \(key): \(bundle.index.blocks.count) blocks, \(bundle.index.figures.count) figures, \(bundle.index.equations.count) equations, \(Date().timeIntervalSince(start)) s")
            } catch {
                print("Cached native paper \(key) failed: \((error as? ArxivHTMLError)?.code ?? String(describing: type(of: error)))")
                throw error
            }
        }
    }

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
    /// Build 64: with -O, `(index, try await acquire(...))` inside do/catch returned zero for each successful download.
    /// The old fixtures fetched only one unique URL, so they never exercised another slot. Keep several downloads
    /// in flight, complete them out of order, and include one deliberately missing image. Run this suite with -O.
    @Test func concurrentImagesKeepTheirSlotsAndOnlyTheMissingFigureIsOmitted() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let image = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-mathpix/figure-exif.jpg"))
        let source = try ArxivReaderSource(sourceID: "2601.01234", revision: 2)
        let figures = (0..<10).map { index in
            "<figure id=\"F\(index + 1)\"><img src=\"2601.01234v2/asset-\(index).jpg\"><figcaption>Figure \(index + 1): Item \(index).</figcaption></figure>"
        }.joined()
        let html = Data("<html><body><article class=\"ltx_document\"><h1>Concurrent image fixture</h1><p>Ten separate figure downloads.</p>\(figures)</article></body></html>".utf8)
        let evidence = ArxivAssetFetchEvidence()
        let reader = ArxivHTMLReader { url, ref, maximum in
            #expect(ref == source)
            if url == source.htmlURL { return html }
            #expect(source.admitsAsset(url.absoluteString))
            let index = try #require(Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "asset-", with: "")))
            await evidence.started(index)
            // The first of each batch completes last; assertions concern identities and bounds, not elapsed time.
            try await Task.sleep(for: .milliseconds(index % 4 == 0 ? 40 : 5))
            await evidence.finished()
            if index == 5 { throw ArxivHTMLError.assetMissing }
            #expect(image.count <= maximum)
            return image
        }
        let bundle = try await reader.prepare(source)
        #expect(bundle.arxivSource == source)
        #expect(bundle.index.figures.map(\.caption) == (1...10).filter { $0 != 6 }.map { "Figure \($0): Item \($0 - 1)." })
        #expect(bundle.index.blocks.contains { $0.text.contains("couldn’t be shown here; the PDF has it") })
        #expect(await evidence.requests.sorted() == Array(0..<10), "each image is requested exactly once")
        #expect(await evidence.peak <= ArxivAcquisitionPolicy.assetConcurrency)
        #expect(await evidence.peak > 1, "exercise concurrent completion")
    }
    /// Revision 16: an image arXiv didn't serve is its figure's note and the paper opens; arXiv being busy still stops it.
    @Test func anImageArxivDidntServeIsItsFiguresLossNotThePapers() async throws {
        let full = try await compileFixture("source.html")
        let missing = try await compileFixture("source.html") { _ in throw ArxivHTMLError.assetMissing }
        #expect(full.index.figures.count == 1)
        #expect(missing.index.figures.isEmpty)
        #expect(missing.index.equations.count == full.index.equations.count)
        await #expect(throws: ArxivHTMLError.self) { _ = try await compileFixture("source.html") { _ in throw ArxivHTMLError.retryLater } }
    }
    private func compileFixture(_ name: String, asset: (@Sendable (URL) throws -> Data)? = nil) async throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let html = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/\(name)"))
        let image = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-mathpix/figure-exif.jpg"))
        let source = try ArxivReaderSource(sourceID: "2601.01234", revision: 2)
        let reader = ArxivHTMLReader { url, ref, maximum in
            #expect(ref == source)
            if url != source.htmlURL, let asset { return try asset(url) }
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

private actor ArxivAssetFetchEvidence {
    private(set) var requests: [Int] = []
    private(set) var peak = 0
    private var active = 0
    func started(_ index: Int) { requests.append(index); active += 1; peak = max(peak, active) }
    func finished() { active -= 1 }
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
