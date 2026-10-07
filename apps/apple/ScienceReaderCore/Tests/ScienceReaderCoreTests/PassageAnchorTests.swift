import Foundation
import Testing
@testable import ScienceReaderCore

/// Passage-linked conversations: the anchor a selection action saves on its conversation.
@Suite struct PassageAnchorTests {
    let account = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let device = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let artifact = UUID(uuidString: "eeeeeeee-0000-4000-8000-cccccccccccc")!

    private func selection(prefix: String, suffix: String, blocks: [String] = ["b-intro", "b-next"]) -> ReaderSelection {
        ReaderSelection(manifestSHA256: String(repeating: "a", count: 64),
                        parts: blocks.map { .init(kind: "text", blockID: $0, text: "x") },
                        context: .init(prefix: prefix, suffix: suffix))
    }

    @Test func selectionAnchorKeepsFirstBlockQuoteAndThirtyTwoCharactersEachSide() throws {
        let anchor = try #require(TextAnchor.passage(
            artifactID: artifact,
            selection: selection(prefix: "A long sentence before   the\nquoted passage begins: ",
                                 suffix: " and then the paper continues with much more text after it."),
            quote: "  scaled dot-product attention \n"))
        #expect(anchor.artifactID == artifact)
        #expect(anchor.quote == "scaled dot-product attention")
        #expect(anchor.elementID == "b-intro", "The first block the selection touches")
        #expect(anchor.prefix == "efore the quoted passage begins:", "Whitespace collapsed, the last 32 characters")
        #expect(anchor.suffix == "and then the paper continues wit")
        #expect(anchor.suffix.count == TextAnchor.contextCharacters)
        #expect(anchor.displayQuote == "scaled dot-product attention")
    }

    @Test func anchorWithoutContextOrWithOversizedValuesStaysValid() throws {
        let bare = ReaderSelection(manifestSHA256: String(repeating: "a", count: 64), parts: [.init(kind: "equation", blockID: "b-eq", equationID: "e-1")])
        let anchor = try #require(TextAnchor.passage(artifactID: artifact, selection: bare, quote: "\\[x^2\\]"))
        #expect(anchor.prefix == "" && anchor.suffix == "" && anchor.elementID == "b-eq")
        #expect(TextAnchor.passage(artifactID: artifact, selection: bare, quote: "   ") == nil, "Nothing to anchor")
        #expect(TextAnchor.passage(artifactID: artifact, selection: bare, quote: String(repeating: "q", count: 20_001)) == nil)
        let longBlock = String(repeating: "b", count: 201)
        let unlisted = try #require(TextAnchor.passage(artifactID: artifact, selection: selection(prefix: "", suffix: "", blocks: [longBlock]), quote: "q"))
        #expect(unlisted.elementID == nil, "An element ID the event format can't hold is left out, not the anchor")
    }

    @Test func bridgeSelectionMessageDecodesWithOrWithoutContext() throws {
        let withContext = Data(#"{"manifest_sha256":"m","parts":[{"kind":"text","block_id":"b1","text":"hi"}],"context":{"prefix":"before","suffix":"after"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderSelection.self, from: withContext)
        #expect(decoded.context == .init(prefix: "before", suffix: "after"))
        let nullContext = Data(#"{"manifest_sha256":"m","parts":[],"context":null}"#.utf8)
        #expect(try JSONDecoder().decode(ReaderSelection.self, from: nullContext).context == nil)
        let older = Data(#"{"manifest_sha256":"m","parts":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ReaderSelection.self, from: older).context == nil)
    }

    @Test func anchorTravelsInsideTheEncryptedConversationEventAndRoundTrips() throws {
        let keys = KeyBundle.generate(accountID: account)
        let anchor = TextAnchor(artifactID: artifact, quote: "a private passage ∑ attention", prefix: "before the quote", suffix: "after the quote",
                                elementID: "b-12")
        let payload = PrivateEvent(kind: .conversation, entityID: UUID(), documentID: UUID(), text: "Explain in plain terms: a private passage",
                                   anchor: anchor, createdAt: 1_759_000_000_000)
        let envelope = try ReaderCrypto.seal(payload, id: UUID(), deviceID: device, keys: keys)
        #expect(envelope.format == 1, "No wire-format change")
        #expect(try ReaderCrypto.open(envelope, keys: keys) == payload)
        let ciphertext = String(decoding: envelope.ciphertext, as: UTF8.self)
        #expect(!ciphertext.contains("private passage") && !ciphertext.contains("b-12") && !ciphertext.contains("anchor"),
                "The quote, block and field name are only inside the ciphertext")
    }

    @Test func payloadWithAnAnchorDecodesWithTheFieldsEveryBuildKnows() throws {
        // The shape builds since the first one decode: `anchor` has been part of `PrivateEvent` from the start, and
        // keys a build doesn't know (here a future one inside the anchor) are ignored.
        let json = #"""
        {"kind":"conversation","entityID":"ABCDEF01-2345-4678-9ABC-DEF012345678","parents":[],
         "documentID":"DDDDDDDD-0000-4000-8000-BBBBBBBBBBBB","text":"Explain in plain terms: x",
         "anchor":{"artifactID":"EEEEEEEE-0000-4000-8000-CCCCCCCCCCCC","quote":"x","prefix":"p","suffix":"s","elementID":"b-1","later":true}}
        """#
        let event = try JSONDecoder().decode(PrivateEvent.self, from: Data(json.utf8))
        try event.validate()
        #expect(event.anchor?.quote == "x" && event.anchor?.elementID == "b-1" && event.anchor?.page == nil)
    }

    @Test func conversationSummaryCarriesTheRootAnchor() throws {
        var state = PrivateState()
        let anchor = TextAnchor(artifactID: artifact, quote: "the passage", prefix: "", suffix: "", elementID: "b-3")
        let anchored = UUID(), plain = UUID(), rootA = UUID(), rootB = UUID()
        try state.apply(AppliedEvent(id: rootA, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: anchored,
            documentID: UUID(), text: "Explain in plain terms, including any symbols: the passage", anchor: anchor)))
        try state.apply(AppliedEvent(id: rootB, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: plain, text: "Hello")))
        let summaries = Dictionary(uniqueKeysWithValues: state.conversationSummaries().map { ($0.id, $0) })
        #expect(summaries[anchored]?.anchor == anchor)
        #expect(summaries[plain]?.anchor == nil)
    }
}
