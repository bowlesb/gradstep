import SwiftUI

/// First-use consent for cloud answers, bound to one saved question. The
/// choice is stored per account on this device (Keychain), not in chat history.
struct ChatConsentView: View {
    @Bindable var model: ReaderModel
    let prompt: ChatConsentPrompt

    var body: some View {
        CloudConsentContent(accept: { model.acceptChatConsent(prompt) }, decline: { model.declineChatConsent(prompt) })
    }
}

/// The consent's words and choice, shared by a chat's first question and the equation view (the same consent).
struct CloudConsentContent: View {
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Answers come from Claude, an AI model by Anthropic. To answer, Gradstep sends:")
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your question and any passage you selected", systemImage: "text.bubble")
                        Label("Earlier messages in this conversation", systemImage: "bubble.left.and.bubble.right")
                        Label("For paper chats, the paper’s full text", systemImage: "doc.text")
                        Label("When you ask about a figure or table, its image from the paper", systemImage: "photo")
                        Label("When a question needs it, web searches Claude writes go to Tavily, a search service (or Anthropic’s search provider as a backup)", systemImage: "magnifyingglass")
                    }
                    .labelStyle(ConsentLabelStyle())
                    Text("Anthropic processes this to write the answer and may keep it for a limited time under its API terms; search services see only the searches and may keep them under their own terms. Gradstep’s servers pass it through without saving it; your saved conversation stays encrypted with your device keys.")
                        .foregroundStyle(.secondary)
                    Text("Each answer uses credits from your balance.").foregroundStyle(.secondary)
                }
                .font(.body).frame(maxWidth: 560, alignment: .leading).padding(20)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: accept) {
                        ProminentLabel(title: "Continue", fullWidth: true)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("chat.consent.accept")
                    Button(action: decline) {
                        Text("Not now").frame(maxWidth: .infinity, minHeight: 44)
                    }.accessibilityIdentifier("chat.consent.decline")
                }
                .frame(maxWidth: 560).padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity).background(.bar)
            }
            .navigationTitle("Use AI answers?").navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ConsentLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.icon.foregroundStyle(Color.accentColor).frame(width: 28).accessibilityHidden(true)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
