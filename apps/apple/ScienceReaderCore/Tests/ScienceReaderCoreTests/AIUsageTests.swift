import Foundation
import Testing
@testable import ScienceReaderCore

/// Your AI usage (AIUsage.swift) against the fixture the browser's lib/ai-usage.ts writes and is checked against
/// (tests/fixtures/ai-usage.json): the same page decodes, and every word on the screen is the same.
@Suite struct AIUsageTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var fixture: [String: Any] {
        let data = try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/ai-usage.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func pageData() throws -> Data { try JSONSerialization.data(withJSONObject: fixture["page"]!) }
    static func provenance() throws -> [UUID: AIUsageProvenance] {
        let raw = try #require(fixture["provenance"] as? [String: [String: String]])
        var out: [UUID: AIUsageProvenance] = [:]
        for (id, p) in raw {
            out[try #require(UUID(uuidString: id))] = AIUsageProvenance(kind: try #require(AIUsageProvenance.Kind(rawValue: p["kind"] ?? "")), membershipID: p["membership"])
        }
        return out
    }

    @Test func theWordsAreTheBrowsers() throws {
        let page = try AIUsagePage.decode(try Self.pageData())
        let expected = try #require(Self.fixture["expected"] as? [String: Any])
        let rows = try #require(expected["rows"] as? [[String: Any]])
        let provenance = try Self.provenance()
        #expect(rows.count == page.operations.count)
        for (op, row) in zip(page.operations, rows) {
            #expect(op.id.uuidString.lowercased() == row["id"] as? String)
            #expect(AIUsageFormat.activityLabel(op.activity, provenance: provenance[op.id]) == row["activity"] as? String, "\(op.id)")
            #expect(op.outcome.label == row["outcome"] as? String, "\(op.id)")
            #expect(AIUsageFormat.creditsText(op) == row["credits"] as? String, "\(op.id)")
            #expect(AIUsageFormat.modelLabel(op.model) == row["model"] as? String, "\(op.id)")
            #expect(AIUsageFormat.tokensText(op, estimated: op.estimated) == row["tokens"] as? String, "\(op.id)")
            let parts = try #require(row["parts"] as? [[String: String]])
            #expect(parts.count == op.parts.count)
            for (part, words) in zip(op.parts, parts) {
                #expect(part.part.label == words["label"])
                #expect(AIUsageFormat.modelLabel(part.model) == words["model"])
                #expect(AIUsageFormat.tokensText(part, estimated: part.estimated, exact: true) == words["tokens"])
            }
        }
        #expect(AIUsageFormat.totalsText(try #require(page.totals)) == expected["totals"] as? String)
        let models = try #require(Self.fixture["models"] as? [String])
        #expect(models.map { AIUsageFormat.modelLabel($0) } == expected["models"] as? [String])
        let numbers = try #require(Self.fixture["numbers"] as? [NSNumber]).map(\.int64Value)
        #expect(numbers.map(AIUsageFormat.compact) == expected["compact"] as? [String])
        #expect(try #require(page.activities).map(\.activity.name) == expected["chips"] as? [String])
    }

    @Test func thePageDecodes() throws {
        let page = try AIUsagePage.decode(try Self.pageData())
        #expect(page.days == 30 && page.activity == nil && page.operations.count == 9)
        #expect(page.next?.createdAt == "2026-10-22T04:32:00.000000+00:00")
        let study = try #require(page.operations.first { $0.activity == .study })
        #expect(study.credits == nil && study.creditsHeld == 30 && study.outcome == .inProgress && study.settledAt == nil && study.pending)
        #expect(page.operations[0].createdAt == AIUsageFormat.date("2026-10-22T04:39:30Z"))
    }

    @Test func aNewerServersActivityIsOtherNotARefusal() throws {
        var page = Self.fixture["page"] as! [String: Any]
        var ops = page["operations"] as! [[String: Any]]
        ops[0]["activity"] = "mining"
        var parts = ops[0]["parts"] as! [[String: Any]]
        parts[0]["part"] = "dreaming"
        ops[0]["parts"] = parts
        page["operations"] = ops
        let decoded = try AIUsagePage.decode(try JSONSerialization.data(withJSONObject: page))
        #expect(decoded.operations[0].activity == .other && decoded.operations[0].parts[0].part == .answer)
        ops[0]["credits"] = -1
        page["operations"] = ops
        #expect(throws: (any Error).self) { try AIUsagePage.decode(try JSONSerialization.data(withJSONObject: page)) }
        ops[0]["credits"] = 1; ops[0]["outcome"] = "won"
        page["operations"] = ops
        #expect(throws: (any Error).self) { try AIUsagePage.decode(try JSONSerialization.data(withJSONObject: page)) }
    }

    @Test func chatIsNamedByWhatTheDeviceKnew() throws {
        #expect(AIUsageFormat.activityLabel(.chat, provenance: nil) == "Chat")
        #expect(AIUsageFormat.activityLabel(.figureExplainer, provenance: .init(kind: .paper)) == "Figure explainer")
        let general = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "Hi")], selection: nil)
        #expect(AIUsageProvenance(general) == AIUsageProvenance(kind: .general))
        let document = UUID()
        let paper = try ChatGenerationRequest.make(operationID: UUID(), documentID: document, transcript: [ChatTurnInput(role: .user, text: "Hi")], selection: nil)
        #expect(AIUsageProvenance(paper) == AIUsageProvenance(kind: .paper, documentID: document))
        let passage = try ChatGenerationRequest.make(operationID: UUID(), documentID: document, transcript: [ChatTurnInput(role: .user, text: "Explain")], selection: "a passage")
        #expect(AIUsageProvenance(passage).kind == .explain)
        let related = try ChatGenerationRequest.make(operationID: UUID(), documentID: document, transcript: [ChatTurnInput(role: .user, text: "Related")],
                                                     selection: "a passage", action: .related)
        #expect(AIUsageProvenance(related).kind == .paper)
    }

    @Test func theDeviceRemembersOnlyKindsAndIDs() throws {
        let suite = "ai-usage-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID(), other = UUID(), op = UUID()
        let store = AIUsageProvenanceStore(environment: "staging", accountID: account, limit: 50, defaults: { UserDefaults(suiteName: suite)! })
        store.remember(op, AIUsageProvenance(kind: .explain, membershipID: "m-1"))
        #expect(store.all()[op] == AIUsageProvenance(kind: .explain, membershipID: "m-1"))
        #expect(AIUsageProvenanceStore(environment: "staging", accountID: other, defaults: { UserDefaults(suiteName: suite)! }).all().isEmpty)
        #expect(AIUsageProvenanceStore(environment: "production", accountID: account, defaults: { UserDefaults(suiteName: suite)! }).all().isEmpty)
        for _ in 0..<55 { store.remember(UUID(), AIUsageProvenance(kind: .general)) }
        #expect(store.all().count == 50)
        #expect(store.all()[op] == nil) // the oldest went first
        store.forget()
        #expect(store.all().isEmpty)
    }

    @Test func numbers() {
        #expect(AIUsageFormat.grouped(0) == "0" && AIUsageFormat.grouped(999) == "999" && AIUsageFormat.grouped(1_234_567) == "1,234,567")
        #expect(AIUsageFormat.creditsText(outcome: .completed, credits: 1, held: 0) == "1 credit")
        #expect(AIUsageFormat.creditsText(outcome: .failed, credits: 0, held: 0) == "0 credits")
        #expect(AIUsageFormat.creditsText(outcome: .inProgress, credits: nil, held: 1200) == "Up to 1,200")
        #expect(AIUsageFormat.periodLabel(30) == "Last 30 days" && AIUsageFormat.periodLabel(365) == "Last 12 months")
        #expect(AIUsageFormat.audioText(40_000) == "40 s audio" && AIUsageFormat.audioText(300_000) == "5 min audio")
    }
}
