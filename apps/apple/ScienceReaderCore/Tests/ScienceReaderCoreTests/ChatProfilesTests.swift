import Foundation
import Testing
@testable import ScienceReaderCore

/// Chat controls (model, effort, length) and topic titles, 2026-10-08.
@Suite struct ChatProfilesTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json")))
    }

    @Test func flashDefaultRequiresItsNamedConsentAndPreservesExplicitChoices() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: try fixture("chat-profiles-gemini")) as? [String: Any])
        let table = try #require(ChatProfileTable.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(table.defaultChoice.id == "gemini-medium-standard")
        #expect(table.requested(table.defaultChoice).id == "gemini-auto-standard")
        #expect(table.requested(.standard).id == "sonnet-auto-standard", "explicit Sonnet remains Sonnet")
        #expect(table.offeredModels.contains(.gemini))
        #expect(ChatProfileChoice.Model.gemini.processor == "Google through OpenRouter")
        var models = try #require(json["models"] as? [[String: Any]])
        let index = try #require(models.firstIndex { ($0["id"] as? String) == "gemini" })
        models[index]["consent_version"] = "cloud-ai-v6"
        json["models"] = models
        let unsupported = try #require(ChatProfileTable.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(unsupported.defaultChoice == .standard)
        #expect(!unsupported.offeredModels.contains(.gemini))
    }

    @Test func thePublishedTableDecodesWithItsEstimates() throws {
        let table = try #require(ChatProfileTable.decode(try fixture("chat-profiles-v1")))
        #expect(table.version == "chat-profiles-v1")
        #expect(table.defaultChoice == .standard)
        #expect(table.estimates.count == 48, "27 Claude profiles, 9 DeepSeek, 12 automatic (builds 57–58 decode the first 27 only)")
        #expect(table.estimateText(.standard) == "Usually 4–24 credits · up to 37")
        #expect(table.estimateText(ChatProfileChoice(model: .haiku, effort: .low, length: .brief)) == "Usually 1–2 credits · up to 2")
        #expect(table.estimateText(ChatProfileChoice(model: .opus, effort: .high, length: .detailed)) == "Usually 24–63 credits · up to 114")
        #expect(table.label(.opus) == "Opus" && table.detail(.haiku) == "Quick, economical explanations")
        #expect(table.label(.medium) == "Medium" && table.label(.detailed) == "Detailed")
        #expect(table.note?.contains("Web searches") == true)
        #expect(ChatProfileText.estimate(.init(low: 1, high: 1, max: 1)) == "About 1 credit · up to 1")
    }

    @Test func aTableThisBuildDoesNotUnderstandIsRefused() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: try fixture("chat-profiles-v1")) as? [String: Any])
        json["version"] = "chat-profiles-v2"
        #expect(ChatProfileTable.decode(try JSONSerialization.data(withJSONObject: json)) == nil)
        #expect(ChatProfileTable.decode(Data("{}".utf8)) == nil)
        #expect(ChatProfileTable.decode(Data(repeating: 0x20, count: 70_000)) == nil)
        // Unknown models from a later server are skipped; known profiles stay offered.
        json["version"] = "chat-profiles-v1"
        var profiles = try #require(json["profiles"] as? [[String: Any]])
        profiles.append(["model": "fable", "effort": "low", "length": "brief", "credits": ["low": 1, "high": 2, "max": 3]])
        profiles.removeAll { ($0["model"] as? String) == "opus" }
        json["profiles"] = profiles
        let table = try #require(ChatProfileTable.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(table.estimates.count == profiles.count - 1, "every known profile but the unknown model's")
        #expect(!table.offers(ChatProfileChoice(model: .opus, effort: .low, length: .standard)))
    }

    /// Chat redesign (2026-10-16): with the server's automatic effort and DeepSeek in the table, a request asks for
    /// the reader's model and length with `auto`; an older table keeps the stored effort, so nothing breaks before it.
    @Test func requestsUseTheAutomaticEffortWhenTheTableOffersIt() throws {
        // The published table (2026-10-16): the 27 Claude profiles first, then DeepSeek's and the automatic ones.
        let table = try #require(ChatProfileTable.decode(try fixture("chat-profiles-v1")))
        #expect(table.defaultChoice == .standard, "older builds still read the same default")
        #expect(table.requested(.standard) == ChatProfileChoice(model: .sonnet, effort: .auto, length: .standard))
        #expect(table.requested(ChatProfileChoice(model: .deepseek, effort: .low, length: .brief)).id == "deepseek-auto-brief")
        #expect(table.offeredModels == [.haiku, .sonnet, .opus, .deepseek])
        #expect(table.estimate(model: .sonnet, length: .standard).map(ChatProfileText.estimate) == "Usually 4–24 credits · up to 41")
        #expect(table.label(.deepseek) == "DeepSeek" && ChatProfileText.summary(.standard, table: table) == "Sonnet · Standard")
        #expect(ChatProfileText.modelName("deepseek-flash") == "DeepSeek V4.1 Flash")
        // A table from before (no automatic effort, no DeepSeek): requests keep the stored effort, nothing breaks.
        var json = try #require(try JSONSerialization.jsonObject(with: try fixture("chat-profiles-v1")) as? [String: Any])
        json["profiles"] = (json["profiles"] as? [[String: Any]] ?? []).filter { $0["effort"] as? String != "auto" && $0["model"] as? String != "deepseek" }
        let old = try #require(ChatProfileTable.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(old.estimates.count == 27)
        #expect(old.requested(.standard) == .standard)
        #expect(old.requested(ChatProfileChoice(model: .opus, effort: .auto, length: .brief)) == ChatProfileChoice(model: .opus, effort: .low, length: .brief))
        #expect(old.offeredModels == [.haiku, .sonnet, .opus])
        #expect(old.requested(ChatProfileChoice(model: .deepseek, effort: .auto, length: .standard)) == .standard, "not offered: the server's default")
    }

    @Test func choicesRoundTripTheirServerIdentifiers() {
        for model in ChatProfileChoice.Model.allCases {
            for effort in ChatProfileChoice.Effort.allCases {
                for length in ChatProfileChoice.Length.allCases {
                    let choice = ChatProfileChoice(model: model, effort: effort, length: length)
                    #expect(ChatProfileChoice(id: choice.id) == choice)
                }
            }
        }
        #expect(ChatProfileChoice.standard.id == "sonnet-low-standard")
        for id in ["diagram_fix", "sonnet-low", "sonnet-low-standard-x", "fable-low-brief", ""] { #expect(ChatProfileChoice(id: id) == nil) }
    }

    @Test func theLineUnderAnAnswerNamesItsProfileAndAFallbackModel() {
        #expect(ChatProfileText.answeredBy(model: "claude-sonnet-5-5", profile: "sonnet-low-standard") == "Sonnet · Standard")
        #expect(ChatProfileText.answeredBy(model: "claude-sonnet-5", profile: "sonnet-medium-brief") == "Sonnet · Brief · by Claude Sonnet 5")
        #expect(ChatProfileText.answeredBy(model: "claude-opus-4-8", profile: "opus-high-detailed") == "Opus · Detailed · by Claude Opus 4.8")
        #expect(ChatProfileText.answeredBy(model: "claude-opus-5-5", profile: nil) == "Claude Opus 5.5")
        #expect(ChatProfileText.answeredBy(model: nil, profile: "haiku-low-brief") == "Haiku · Brief")
        #expect(ChatProfileText.answeredBy(model: nil, profile: nil) == nil)
        #expect(ChatProfileText.answeredBy(model: "claude-sonnet-5-5", profile: "diagram_fix") == "Claude Sonnet 5.5")
        #expect(ChatProfileText.answeredBy(model: "local/qwen35-4b/123456789abc", profile: "haiku-low-standard") == "Qwen3.5 4B (local)")
        #expect(ChatProfileText.modelName("claude-haiku-4-5-20251001") == "Claude Haiku 4.5")
    }

    @Test func requestsSendAChoiceOnlyWhenItIsNotTheDefault() throws {
        let turns = [ChatTurnInput(role: .user, text: "Why?")]
        func body(_ request: ChatGenerationRequest) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: try request.encoded()) as? [String: Any])
        }
        let plain = try body(try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil))
        #expect(plain["profile"] == nil && plain["topic_title"] == nil)
        #expect(plain["follow_ups"] as? Bool == true, "every ordinary answer asks for follow-up suggestions")
        let named = try body(try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil, profile: .standard))
        #expect(named["profile"] == nil, "the default is sent exactly as before profiles")
        let chosen = try body(try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: turns, selection: nil,
            profile: ChatProfileChoice(model: .opus, effort: .high, length: .detailed), topicTitle: true))
        #expect(chosen["profile"] as? [String: String] == ["model": "opus", "effort": "high", "length": "detailed"])
        #expect(chosen["topic_title"] as? Bool == true)
        let repair = try #require(ChatGenerationRequest.diagramRepair(operationID: UUID(), title: "T", source: "flowchart TD\nA-->B", error: "x"))
        let repairBody = try body(repair)
        #expect(repairBody["profile"] == nil && repairBody["topic_title"] == nil && repairBody["follow_ups"] == nil)
    }

    @Test func titleAndLabelledDoneEventsAreParsedOlderOnesStillAre() throws {
        var parser = ChatSSEParser()
        let stream = """
        event: title
        data: {"text":"Explainer for\\u202e a persona\\npaper"}

        event: title
        data: {"text":"   "}

        event: title
        data: {"nope":1}

        event: done
        data: {"stop_reason":"end_turn","credits":3,"usage":{},"model":"claude-opus-5-5","profile":"opus-high-detailed"}

        event: done
        data: {"stop_reason":"end_turn","credits":1,"model":"Bad Model!","profile":"\(String(repeating: "x", count: 65))"}

        event: done
        data: {"stop_reason":"end_turn","credits":2}


        """
        let events = try parser.consume(Data(stream.utf8))
        #expect(events == [
            .title("Explainer for a persona paper"),
            .done(stopReason: "end_turn", credits: 3, model: "claude-opus-5-5", profile: "opus-high-detailed"),
            .done(stopReason: "end_turn", credits: 1, model: nil, profile: nil),
            .done(stopReason: "end_turn", credits: 2),
        ])
    }

    @Test func topicTitlesAreOnePlainBoundedLine() {
        #expect(ChatTopicTitle.clean("  Why DPO\n needs\tno reward model  ") == "Why DPO needs no reward model")
        #expect(ChatTopicTitle.clean("\u{2066}Hidden\u{2069} bidi") == "Hidden bidi")
        #expect(ChatTopicTitle.clean(" \n ") == nil)
        #expect(ChatTopicTitle.clean(String(repeating: "a", count: 120))?.count == 80)
    }

    @Test func nodeSealedLabelledEventsDecodeWithTheirNewKeys() throws {
        struct Keys: Decodable { let keys: KeyBundle; let deviceID: UUID }
        struct Labelled: Decodable { let eventID: UUID; let payload: PrivateEvent; let ciphertext: Data }
        let keys = try JSONDecoder().decode(Keys.self, from: try fixture("envelopes-v1"))
        let events = try JSONDecoder().decode([Labelled].self, from: try fixture("labelled-events-v1"))
        #expect(events.count == 4)
        for item in events {
            let opened = try ReaderCrypto.open(EventEnvelope(id: item.eventID, deviceID: keys.deviceID, epoch: 1, ciphertext: item.ciphertext), keys: keys.keys)
            #expect(opened == item.payload)
            try opened.validate()
        }
        #expect(events[0].payload.titleSource == PrivateEvent.generatedTitle)
        #expect(events[1].payload.titleSource == PrivateEvent.renamedTitle)
        #expect(events[2].payload.titleSource == "imported-by-a-later-build", "a later build's source still decodes")
        #expect(events[3].payload.model == "claude-sonnet-5" && events[3].payload.profile == "opus-high-detailed")
    }

    @Test func labelsAreBoundedButAnyValueFromALaterBuildIsAccepted() throws {
        let long = String(repeating: "x", count: PrivateEvent.maximumLabelBytes + 1)
        for event in [PrivateEvent(kind: .conversation, text: "t", titleSource: long),
                      PrivateEvent(kind: .message, conversationID: UUID(), text: "a", role: .assistant, status: .complete, model: long),
                      PrivateEvent(kind: .message, conversationID: UUID(), text: "a", role: .assistant, status: .complete, profile: long)] {
            #expect(throws: ReaderError.self) { try event.validate() }
        }
        try PrivateEvent(kind: .note, text: "n", titleSource: "whatever", model: "m", profile: "p").validate()
    }

    @Test func aTopicTitleIsANewConversationRevisionThatKeepsItsPaperPassageAndStart() throws {
        let device = UUID(), conversation = UUID(), paper = UUID(), artifact = UUID()
        var state = PrivateState()
        let anchor = TextAnchor(artifactID: artifact, quote: "softmax(QKᵀ/√d)")
        let root = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation,
            documentID: paper, text: "Explain in plain terms, including any symbols: softmax", anchor: anchor, createdAt: 1_790_000_000_000))
        let question = UUID()
        try state.apply(root)
        try state.apply(AppliedEvent(id: question, deviceID: device, payload: PrivateEvent(kind: .message, entityID: question, parents: [root.id],
            conversationID: conversation, documentID: paper, text: "Explain in plain terms, including any symbols: softmax", role: .user,
            status: .complete, createdAt: 1_790_000_000_000)))
        #expect(state.conversationSummaries().first?.hasTopicTitle == false)

        let generated = try #require(state.titledConversation(conversation, title: " Scaled  attention\nexplained ", source: PrivateEvent.generatedTitle))
        #expect(generated.parents == [root.id] && generated.documentID == paper && generated.anchor == anchor)
        #expect(generated.createdAt == 1_790_000_000_000 && generated.text == "Scaled attention explained")
        let generatedID = UUID()
        try state.apply(AppliedEvent(id: generatedID, deviceID: device, payload: generated))
        var summary = try #require(state.conversationSummaries().first)
        #expect(summary.title == "Scaled attention explained" && summary.titleSource == "generated")
        #expect(summary.documentID == paper && summary.anchor == anchor && summary.messageCount == 1)
        #expect(summary.startedAt == Date(timeIntervalSince1970: 1_790_000_000))
        // The conversation's messages are unaffected (their parent is the original root).
        #expect(state.conversationBranches(conversation).first?.complete == true)

        // Two devices title it at once; a rename then supersedes both.
        let other = UUID()
        try state.apply(AppliedEvent(id: other, deviceID: UUID(), payload: try #require(state.titledConversation(conversation,
            title: "Other device's title", source: PrivateEvent.generatedTitle).map { var e = $0; e.parents = [root.id]; return e })))
        #expect(state.revisions(for: conversation).count == 2)
        let renamed = try #require(state.titledConversation(conversation, title: "My notes", source: PrivateEvent.renamedTitle))
        #expect(Set(renamed.parents) == [generatedID, other])
        try state.apply(AppliedEvent(id: UUID(), deviceID: device, payload: renamed))
        summary = try #require(state.conversationSummaries().first)
        #expect(summary.title == "My notes" && summary.titleSource == "renamed")
        #expect(state.titledConversation(conversation, title: "   ", source: PrivateEvent.renamedTitle) == nil)
        #expect(state.titledConversation(UUID(), title: "x", source: PrivateEvent.renamedTitle) == nil)
    }
}
