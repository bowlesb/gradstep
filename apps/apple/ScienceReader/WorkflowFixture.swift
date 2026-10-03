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
        tab = .library; wideMode = .library
    }
}
#endif
