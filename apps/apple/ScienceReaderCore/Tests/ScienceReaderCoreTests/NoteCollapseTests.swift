import Foundation
import Testing
@testable import ScienceReaderCore

/// Collapsed snippets (NOTES_AND_SNIPPETS.md "Collapsible snippet cards"): the one-line form against the cases the
/// browser also reads (tests/fixtures/notes/collapsed-lines.json), and the per-device memory.
@Suite struct NoteCollapseTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func collapsedLinesMatchTheSharedCases() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("tests/fixtures/notes/collapsed-lines.json"))
        let cases = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["cases"] as? [[String: Any]])
        #expect(cases.count >= 8)
        for item in cases {
            let line = NoteCollapsedLine.line(time: item["time"] as! String, title: item["title"] as! String, comment: item["comment"] as! String,
                                              quote: item["quote"] as? String, label: item["label"] as? String,
                                              titleLimit: item["titleLimit"] as? Int ?? NoteCollapsedLine.titleLimit)
            #expect(line == item["line"] as! String, "\(item["name"] as! String)")
        }
    }

    @Test func lineFromARecordUsesItsSource() {
        let note = UUID()
        let record = NoteEntryRecord(noteID: note, kind: .region, counter: 1, capturedAt: 1_760_000_000_000, offsetMinutes: 0, comment: "",
                                     source: NoteSource(kind: .arxiv, title: "Scaling Laws", label: "Figure 2"))
        #expect(NoteCollapsedLine.line(time: "3:04 PM", record: record) == "3:04 PM · Scaling Laws · Figure 2")
    }

    @Test func memoryIsPerCollectionAndDropsGoneEntries() throws {
        let suite = "NoteCollapseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NoteCollapseMemory(defaults: defaults)
        let first = UUID(), second = UUID(), a = UUID(), b = UUID(), gone = UUID()
        #expect(memory.collapsed(in: first).isEmpty)
        memory.set([a, b, gone], in: first, existing: [a, b])
        #expect(memory.collapsed(in: first) == [a, b])
        #expect(memory.collapsed(in: second).isEmpty, "Another collection is separate")
        // A second memory over the same defaults (the next launch) sees the same.
        #expect(NoteCollapseMemory(defaults: defaults).collapsed(in: first) == [a, b])
        memory.set([], in: first)
        #expect(defaults.object(forKey: NoteCollapseMemory.key(first)) == nil, "Expanding everything removes the key")
    }
}
