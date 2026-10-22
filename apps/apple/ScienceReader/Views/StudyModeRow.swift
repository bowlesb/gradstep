import SwiftUI
import ScienceReaderCore

/// Study mode (reworked 2026-10-22; docs/proposals/LEARNING_GUIDE.md): while a chat is studying, one slim row above the
/// message box replaces the retired knowledge-map bar — the words "Study mode", then Hint and Explain instead (each sent
/// at once as the reader's turn) and Stop (leaves Study mode; nothing is sent). The conversation itself is the product.
struct StudyModeRow: View {
    @Bindable var model: ReaderModel
    /// Lets the message box go (a quick reply needs no keyboard).
    var dismissKeyboard: () -> Void = {}

    var body: some View {
        let busy = model.isAnswering || model.isGenerating
        HStack(spacing: 8) {
            // The words when there is room beside the three buttons (an iPhone in portrait shows the symbol alone).
            ViewThatFits(in: .horizontal) {
                Label("Study mode", systemImage: "graduationcap").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                Image(systemName: "graduationcap").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.tint)
            .accessibilityLabel("Study mode").accessibilityIdentifier("chat.study.title")
            Spacer(minLength: 4)
            Group {
                Button("Hint") { reply(StudyMode.hint) }
                    .disabled(busy).accessibilityHint("Asks the tutor for a hint").accessibilityIdentifier("chat.study.hint")
                Button("Explain instead") { reply(StudyMode.explainInstead) }
                    .disabled(busy).accessibilityHint("Asks the tutor to explain this one").accessibilityIdentifier("chat.study.explain")
                Button("Stop") { model.endStudy() }
                    .accessibilityHint("Leaves Study mode; the conversation stays").accessibilityIdentifier("chat.study.stop")
            }
            .font(.subheadline).lineLimit(1).fixedSize()
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .chromeSurface(Capsule(style: .continuous), outlined: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.study.row")
    }

    private func reply(_ text: String) {
        dismissKeyboard()
        Task { await model.sendStudyReply(text) }
    }
}
