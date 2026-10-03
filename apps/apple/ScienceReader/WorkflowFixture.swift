#if DEBUG && targetEnvironment(simulator)
import Foundation
import ScienceReaderCore

/// Synthetic UI journeys only. Compiled out of physical-device and release builds;
/// the launch branch returns before constructing any network or account services.
extension ReaderModel {
    func configureWorkflowFixture() throws {
        openSample()
        guard let sample = selectedPaper else { return }
        papers.append(Paper(id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!,
            title: "Sparse metadata: an unpublished research note", authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: nil))
        let conversation = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let root = UUID(), device = UUID()
        try privateState.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, documentID: sample.id, text: "Understanding attention")))
        var parent = root
        let turns: [(PrivateEvent.Role, String)] = [
            (.user, "How does self-attention scale with sequence length?"),
            (.assistant, "Self-attention compares each query with every key. Doubling the sequence length creates roughly four times as many pairwise scores.\n\nThe attention score matrix therefore takes quadratic memory in the sequence length. The cost of projecting tokens into queries, keys, and values also depends on the model width.\n\nFor a fair comparison, separate training from decoding, and measure latency and peak memory on the same hardware."),
            (.user, "What should I measure in a small experiment?"),
            (.assistant, "Use several sequence lengths and keep the batch size fixed. Record wall-clock time, peak memory, and the number of tokens processed.\n\nWarm up the model before measuring. GPU work is asynchronous, so synchronize around the timed region. Report the median and variation over repeated runs.\n\nFinally, check that the output remains numerically consistent. A faster implementation is useful only if it preserves the behavior your experiment requires."),
            (.user, "How would this affect reading a long paper?"),
            (.assistant, "A long document may need bounded context retrieval. Keep source passages and citations attached to each answer so that claims can be checked against the paper.\n\nThis is a synthetic conversation for layout testing; no AI request was made.")
        ]
        for (role, text) in turns {
            let id = UUID()
            try privateState.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, parents: [parent], conversationID: conversation, documentID: sample.id, text: text, role: role, status: .complete)))
            parent = id
        }
        activeConversation = conversation
        if ProcessInfo.processInfo.arguments.contains("--branch-fixture") {
            try configureBranchWorkflowFixture(documentID: sample.id)
        }
        tab = .library; wideMode = .library
    }

    private func configureBranchWorkflowFixture(documentID: UUID) throws {
        let conversation = UUID(uuidString: "dddddddd-0000-0000-0000-000000000001")!
        let device = UUID(uuidString: "dddddddd-0000-0000-0000-000000000002")!
        let root = UUID(uuidString: "dddddddd-0000-0000-0000-000000000003")!
        let question = UUID(uuidString: "dddddddd-0000-0000-0000-000000000600")!
        let observed = UUID(uuidString: "dddddddd-0000-0000-0000-000000000900")!
        let sibling = UUID(uuidString: "dddddddd-0000-0000-0000-000000000100")!
        try privateState.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation,
            entityID: conversation, documentID: documentID, text: "A retained paper discussion")))
        try privateState.apply(AppliedEvent(id: question, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: question, parents: [root], conversationID: conversation, documentID: documentID,
            text: "Keep this earlier question visible.", role: .user, status: .complete)))
        try privateState.apply(AppliedEvent(id: observed, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: observed, parents: [question], conversationID: conversation, documentID: documentID,
            text: "This observed reply was removed.", role: .assistant, status: .complete)))
        // Observe the first answer before a sibling arrives. Removing that answer
        // must retain its earlier context without silently selecting the sibling.
        openConversation(conversation)
        chatInput = "Draft for the retained paper discussion"
        try privateState.apply(AppliedEvent(id: sibling, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: sibling, parents: [question], conversationID: conversation, documentID: documentID,
            text: "A sibling reply requires an explicit choice.", role: .assistant, status: .complete)))
        try privateState.apply(AppliedEvent(id: UUID(uuidString: "dddddddd-0000-0000-0000-000000000901")!,
            deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: observed)))
        newChat(general: true)
        chatInput = "A separate general draft"
    }
}
#endif
