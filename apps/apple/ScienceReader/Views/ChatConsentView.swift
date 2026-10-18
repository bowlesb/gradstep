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
                    Text("All cloud answers use OpenRouter. Gemini Flash and Claude run on Google Vertex; DeepSeek runs on DeepInfra. To answer, Gradstep sends:")
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your question and any passage you selected", systemImage: "text.bubble")
                        Label("Earlier messages in this conversation", systemImage: "bubble.left.and.bubble.right")
                        Label("For paper chats, the paper’s full text", systemImage: "doc.text")
                        Label("When you ask about a figure or table, its image from the paper", systemImage: "photo")
                        Label("When a question needs it, web searches the model writes go to Tavily, a search service", systemImage: "magnifyingglass")
                        Label("All model requests pass through OpenRouter. Titles and suggested questions use Claude on Google Vertex. A random account ID accompanies requests for cost accounting", systemImage: "arrow.triangle.branch")
                    }
                    .labelStyle(ConsentLabelStyle())
                    Text("OpenRouter and the selected processor handle this under their API terms. Gradstep requests routes with no data collection and zero data retention; search services see only the searches and may keep them under their own terms. Gradstep’s servers pass it through without saving it; your saved conversation stays encrypted with your device keys.")
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
