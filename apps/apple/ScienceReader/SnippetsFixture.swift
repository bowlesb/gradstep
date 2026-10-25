#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore
import UIKit

/// `--snippets-fixture` (with `--draft-fixture`): three synthetic collections written through the real encrypted fixture
/// store, for the Snippets journeys and visual scenarios (owner feedback on TestFlight 91, 2026-10-24). "Quick snippets"
/// holds six entries over three days (four drawn regions with images, two quotations), "Reading group" two, and "New
/// collection" none. The regions point at blocks of the offline sample, so their text, equations' LaTeX and figure
/// captions are on this device; one image carries a word that is only in its pixels ("Kaleidoscope"), for recognised
/// text. Every word here is made up for the fixture. Compiled out of device and release builds.
extension ReaderModel {
    static let snippetsFixtureQuick = UUID(uuidString: "5e1e5e1e-0000-4000-8000-000000000001")!
    static let snippetsFixtureGroup = UUID(uuidString: "5e1e5e1e-0000-4000-8000-000000000002")!
    static let snippetsFixtureEmpty = UUID(uuidString: "5e1e5e1e-0000-4000-8000-000000000003")!

    func installSnippetsFixture(into store: EncryptedStore, deviceID: UUID, accountID: UUID) async throws {
        guard NotesState(await store.state()).notes.isEmpty else { return }
        // Collapsed cards are remembered per device; a fresh fixture starts with every card open.
        for id in [Self.snippetsFixtureQuick, Self.snippetsFixtureGroup, Self.snippetsFixtureEmpty] {
            UserDefaults.standard.removeObject(forKey: NoteCollapseMemory.key(id))
        }
        let bundle = try ReaderBundleLoader.sample()
        let manifest = bundle.manifestSHA256
        let revision = ReaderVersions.revision(of: bundle) ?? 0
        let now = PrivateEvent.timestamp(Date()), day: Int64 = 86_400_000, hour: Int64 = 3_600_000
        let offset = TimeZone.current.secondsFromGMT() / 60
        func block(_ n: Int) -> String { "b-48a7e3f6320f-\(n)" }
        func source(label: String? = nil, section: String? = nil) -> NoteSource {
            NoteSource(kind: .document, title: "Reading machine learning papers", authors: ["Gradstep", "Offline sample"],
                       sourceID: "aaaaaaaa-0000-0000-0000-000000000001", section: section, label: label)
        }

        enum Item {
            case region(lines: [String], blocks: [Int], label: String?, section: String?, comment: String, ago: Int64)
            case quote(String, blocks: [Int], comment: String, ago: Int64)
        }
        let collections: [(UUID, String, Int64, [Item])] = [
            (Self.snippetsFixtureEmpty, "New collection", now - 2 * hour, []),
            (Self.snippetsFixtureGroup, "Reading group", now - 3 * day, [
                .quote("Use tables to compare the conditions as well as the headline score.", blocks: [19],
                       comment: "Bring this to Thursday's discussion.", ago: 3 * day),
                .region(lines: ["Condition    Training data    Compute", "Baseline     Public split     Fixed", "Variant      Public split     Fixed"],
                        blocks: [20], label: "Table 1", section: "3. Check the evaluation", comment: "", ago: 3 * day - hour),
            ]),
            (Self.snippetsFixtureQuick, "Quick snippets", now - 4 * day, [
                .region(lines: ["Attention(Q, K, V) = softmax(QKᵀ / √d) V", "Kaleidoscope schedule: warm-up, then decay"],
                        blocks: [9, 10], label: nil, section: "2. Read the equations in context",
                        comment: "Why the square root? Scale keeps the softmax from saturating.", ago: 4 * day),
                .quote("A useful first pass identifies the problem, the proposed method, and the evidence.", blocks: [5],
                       comment: "Café-table checklist for the next paper.", ago: 4 * day - hour),
                .region(lines: ["Figure 1", "Queries and keys produce attention weights;", "those weights combine values."],
                        blocks: [12], label: "Figure 1", section: "2. Read the equations in context", comment: "", ago: 2 * day),
                .quote("Keep the objective next to the results rather than treating a single score as the whole story.", blocks: [21],
                       comment: "", ago: 2 * day - hour),
                .region(lines: ["Mean squared error over N examples", "L(θ) = 1/N Σ (f(x) − y)²"], blocks: [22], label: nil,
                        section: "3. Check the evaluation",
                        comment: "The loss the results table reports. Compare runs with the same split before reading the headline number.",
                        ago: hour),
                .region(lines: ["Data → Model → Runs", "Checked across several runs"], blocks: [24], label: "Figure 2",
                        section: "3. Check the evaluation", comment: "Variation across runs.", ago: hour / 2),
            ]),
        ]

        for (noteID, title, created, items) in collections {
            let note = NoteRecord(noteID: noteID, title: title, createdAt: created)
            try await store.saveNoteEntry([(UUID(), try NotesRecord.note(note).event(createdAt: created))], blobs: [], deviceID: deviceID)
            for (index, item) in items.enumerated() {
                let counter = Int64(index + 1)
                var blobs: [NoteBlobWrite] = []
                let record: NoteEntryRecord
                switch item {
                case let .region(lines, blocks, label, section, comment, ago):
                    let image = Self.snippetsFixtureImage(lines)
                    let full = try SnippetImageEncoder.full(image), thumb = try SnippetImageEncoder.thumbnail(image)
                    let sealedFull = try NoteBlobCrypto.seal(full.data, type: full.type, width: full.width, height: full.height, accountID: accountID)
                    let sealedThumb = try NoteBlobCrypto.seal(thumb.data, type: thumb.type, width: thumb.width, height: thumb.height, accountID: accountID)
                    blobs = [NoteBlobWrite(blobID: sealedFull.media.blobID, blob: sealedFull.blob),
                             NoteBlobWrite(blobID: sealedThumb.media.blobID, blob: sealedThumb.blob)]
                    let anchor = NoteAnchor(manifestSHA256: manifest, rendererRevision: revision, blockIDs: blocks.map(block),
                                            rects: [[0.05, 0.2, 0.9, 0.3]], viewport: [800, 1100, 2], quote: nil)
                    record = NoteEntryRecord(noteID: noteID, kind: .region, counter: counter, capturedAt: now - ago, offsetMinutes: offset,
                                             comment: comment, source: source(label: label, section: section), anchor: anchor,
                                             media: NoteMediaSet(full: sealedFull.media, thumb: sealedThumb.media))
                case let .quote(text, blocks, comment, ago):
                    let anchor = NoteAnchor(manifestSHA256: manifest, rendererRevision: revision, blockIDs: blocks.map(block), rects: [],
                                            viewport: nil, quote: text)
                    record = NoteEntryRecord(noteID: noteID, kind: .quote, counter: counter, capturedAt: now - ago, offsetMinutes: offset,
                                             comment: comment, source: source(), anchor: anchor, quote: text)
                }
                try await store.saveNoteEntry([(UUID(), try NotesRecord.entry(record).event(createdAt: record.capturedAt))], blobs: blobs,
                                              deviceID: deviceID, destination: noteID)
            }
        }
    }

    /// A page-like crop: dark text on white, as the reader's pages are captured.
    private static func snippetsFixtureImage(_ lines: [String]) -> CGImage {
        let size = CGSize(width: 520, height: 70 + CGFloat(lines.count) * 46)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Georgia", size: 24) ?? UIFont.systemFont(ofSize: 24),
                                                             .foregroundColor: UIColor(white: 0.1, alpha: 1)]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 24, y: 34 + CGFloat(index) * 46), withAttributes: attributes)
            }
        }.cgImage!
    }
}
#endif
