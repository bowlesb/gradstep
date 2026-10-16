import ScienceReaderCore
import SwiftUI

// The figure view's screens (owner, build 59; docs/architecture/FIGURE_VIEW.md): a figure page offers Explain and Ask in
// chat side by side; Explain opens the walkthrough in the equation view's look: the figure, what it shows, then each
// part with its crop where the walkthrough points at a small detail. A part's menu explains it more simply, shows it in
// the paper, or asks about it in chat.

/// Who a figure page belongs to: the open paper's model, and how the sheet it is in closes with what was chosen
/// (applied once the sheet has gone, as the equation view's outcomes are).
struct FigureViewHost {
    let model: ReaderModel
    let paperID: UUID
    let finish: @MainActor (FigureViewOutcome) -> Void
}

private struct FigureViewHostKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: FigureViewHost? = nil }
/// A half-height sheet's way to take the full height (Contents, a figure reference): the walkthrough reads best there.
private struct ExpandSheetKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var figureViewHost: FigureViewHost? {
        get { self[FigureViewHostKey.self] }
        set { self[FigureViewHostKey.self] = newValue }
    }
    var expandSheet: (@MainActor () -> Void)? {
        get { self[ExpandSheetKey.self] }
        set { self[ExpandSheetKey.self] = newValue }
    }
}

extension View {
    /// A figure page's Explain and Ask in chat, under the figure, and the walkthrough Explain opens (in the page's own
    /// navigation stack, so Back returns to the figure). Nothing without a host (a figure outside the open paper).
    func figurePageActions(figureID: String) -> some View { modifier(FigurePageActions(figureID: figureID)) }
}

private struct FigurePageActions: ViewModifier {
    let figureID: String
    @Environment(\.figureViewHost) private var host
    @Environment(\.expandSheet) private var expandSheet
    @State private var context: FigureViewContext?
    @State private var explaining = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let host, let context {
                    HStack(spacing: 10) {
                        // An arXiv paper on this device only: the walkthrough reads the paper numbered here.
                        if context.localContext != nil {
                            Button { expandSheet?(); explaining = true } label: {
                                Label("Explain", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Walks through this figure part by part. Uses credits.")
                            .accessibilityIdentifier("figureView.explain")
                        }
                        Button { host.finish(.askInChat(context, part: nil)) } label: {
                            Label("Ask in chat", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Opens the paper’s chat with this figure selected")
                        .accessibilityIdentifier("figureView.askInChat")
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .navigationDestination(isPresented: $explaining) {
                if let host, let context { FigureExplainView(model: host.model, context: context, finish: host.finish) }
            }
            .task(id: figureID) {
                explaining = false
                context = host.flatMap { $0.model.figureContext(paperID: $0.paperID, figureID: figureID) }
            }
    }
}

/// The walkthrough of one figure: the figure, what it shows, then part by part. Requested on opening when nothing is
/// kept on this device (Explain was chosen to get here); kept answers show at once.
struct FigureExplainView: View {
    let model: ReaderModel
    let context: FigureViewContext
    let finish: @MainActor (FigureViewOutcome) -> Void
    @State private var session: FigureExplainSession?
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0

    var body: some View {
        Group {
            if let session { content(session) } else { ProgressView() }
        }
        .navigationTitle(context.label).navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            guard session == nil else { return }
            let opened = FigureExplainSession(context: context, model: model)
            session = opened
            await opened.start()
        }
        .onDisappear { session?.stop() }
        .sheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .presentationDetents([.large])
                .macSheetKeys()
        }
    }

    private func content(_ session: FigureExplainSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                figureCard(session)
                Button { finish(.askInChat(context, part: nil)) } label: {
                    Label("Ask in chat", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens the paper’s chat with this figure selected")
                .accessibilityIdentifier("figureView.walkthrough.askInChat")
                walkthrough(session)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("figureView.walkthrough")
    }

    // MARK: The figure

    private func figureCard(_ session: FigureExplainSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = session.image {
                // Figures are drawn on white in the paper; keep that in dark mode too.
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    // Never more than twice its own size: a small figure stays sharp.
                    .frame(maxWidth: CGFloat(image.width) * 2, maxHeight: min(300, CGFloat(image.height) * 2))
                    .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(context.label)
                    .accessibilityIdentifier("figureView.figure")
            }
            ChatMessageText(source: context.caption, fontSize: bodySize * 0.82, streaming: false, speaker: "Caption", identifier: "figureView.caption")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    // MARK: The walkthrough

    @ViewBuilder private func walkthrough(_ session: FigureExplainSession) -> some View {
        let part = session.walkthrough
        VStack(alignment: .leading, spacing: 16) {
            if let walkthrough = part.walkthrough {
                if !walkthrough.summary.isEmpty {
                    ChatMessageText(source: walkthrough.summary, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                    identifier: "figureView.summary", assistant: true, onCite: cite)
                }
                ForEach(Array(walkthrough.sections.enumerated()), id: \.offset) { index, section in
                    sectionCard(section, index: index, session: session)
                }
            } else if part.state == .done, !part.text.isEmpty {
                // No usable walkthrough: the model's words are the description.
                ChatMessageText(source: part.text, fontSize: bodySize, streaming: false, speaker: "Assistant", identifier: "figureView.description",
                                assistant: true, onCite: cite)
            }
            status(part, working: "Looking at the figure…", retry: { session.retry() })
        }
    }

    private func sectionCard(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession) -> some View {
        let number = index + 1, simpler = session.simpler[index], detail = session.details[index]
        return VStack(alignment: .leading, spacing: 10) {
            // A tap on the part's heading opens its menu (owner: "tap on different parts of the response and ask to back
            // up a bit, or link back into the paper"); a long press or right-click anywhere on the part does too.
            Menu { menuItems(section, index: index, session: session) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !section.label.isEmpty {
                            Text(section.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(section.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([section.label, section.title].filter { !$0.isEmpty }.joined(separator: ": "))
            .accessibilityHint("Options for this part")
            .accessibilityIdentifier("figureView.section.\(number).menu")
            if let box = section.box, let image = session.image, let crop = Self.crop(image, box) {
                Image(decorative: crop, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: CGFloat(crop.width) * 2, maxHeight: min(260, CGFloat(crop.height) * 2))
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25)))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Detail of \(context.label): \(section.name)")
                    .accessibilityIdentifier("figureView.section.\(number).crop")
            }
            ChatMessageText(source: section.text, fontSize: bodySize, streaming: false, speaker: "Assistant",
                            identifier: "figureView.section.\(number).text", assistant: true, onCite: cite)
            if let simpler {
                VStack(alignment: .leading, spacing: 8) {
                    Label("More simply", systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if !simpler.text.isEmpty {
                        ChatMessageText(source: simpler.text, fontSize: bodySize, streaming: simpler.state == .loading, speaker: "Assistant",
                                        identifier: "figureView.section.\(number).simpler", assistant: true,
                                        onCite: simpler.state == .loading ? nil : cite)
                    }
                    status(simpler, working: "Explaining it more simply…", retry: { session.retrySimpler(index) })
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 3) }
            }
            if let detail { detailBlock(detail, number: number, index: index, session: session) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .contextMenu { menuItems(section, index: index, session: session) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("figureView.section.\(number)")
    }

    /// One part extracted (owner, TestFlight 62: "opens up a loader below, gets the info, and puts it below"): the region
    /// cropped from the image that was sent, then the closer reading; the words alone when no region could be given.
    @ViewBuilder private func detailBlock(_ detail: FigureExplainSession.Part, number: Int, index: Int, session: FigureExplainSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up close", systemImage: "viewfinder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let box = detail.detail?.box, let image = session.image, let crop = Self.crop(image, box) {
                Image(decorative: crop, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: CGFloat(crop.width) * 2, maxHeight: min(320, CGFloat(crop.height) * 2))
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25)))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("This part of \(context.label), up close")
                    .accessibilityIdentifier("figureView.section.\(number).detailCrop")
            }
            let words = detail.detail?.text ?? detail.text
            if detail.state == .done, !words.isEmpty {
                ChatMessageText(source: words, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                identifier: "figureView.section.\(number).detail", assistant: true, onCite: cite)
                if detail.detail == nil {
                    Text("Couldn’t crop this part; here is the closer reading.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("figureView.section.\(number).detailNoCrop")
                }
            }
            status(detail, working: "Extracting this part…", retry: { session.retryDetail(index) })
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 3) }
    }

    @ViewBuilder private func menuItems(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession) -> some View {
        let state = session.simpler[index]?.state, extracted = session.details[index]?.state
        Button { session.simplify(index) } label: { Label("Explain more simply", systemImage: "arrow.uturn.backward") }
            .disabled(state == .loading || state == .done)
            .accessibilityIdentifier("figureView.simpler")
        Button { session.extract(index) } label: { Label("Extract the subfigure and more context", systemImage: "viewfinder") }
            .disabled(extracted == .loading || extracted == .done)
            .accessibilityIdentifier("figureView.extract")
        Button {
            finish(section.paragraphs.first.map { .paragraph(paperID: context.paperID, marker: $0) } ?? .figure(paperID: context.paperID, figureID: context.figureID))
        } label: { Label("Show in the paper", systemImage: "doc.text.magnifyingglass") }
            .accessibilityIdentifier("figureView.showInPaper")
        Button { finish(.askInChat(context, part: section)) } label: { Label("Ask in chat about this", systemImage: "bubble.left.and.text.bubble.right") }
            .accessibilityIdentifier("figureView.askAbout")
    }

    @ViewBuilder private func status(_ part: FigureExplainSession.Part, working: String, retry: @escaping () -> Void) -> some View {
        switch part.state {
        case .loading where part.text.isEmpty:
            HStack(spacing: 10) { ProgressView(); Text(working).foregroundStyle(.secondary) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("figureView.loading")
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Text(part.notCharged ? message + " Not charged." : message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("figureView.failure")
                if retryable { Button("Try again", action: retry).accessibilityIdentifier("figureView.retry") }
            }
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to have figures explained.").foregroundStyle(.secondary)
                Button("Sign in") { finish(.signIn) }
            }
        case .needsConsent:
            Button("Continue…", action: retry)
        case .unavailable:
            Text("Explanations need this paper on this device as an arXiv paper.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private var cite: ChatCiteHandler {
        let paperID = context.paperID
        return { marker in finish(.paragraph(paperID: paperID, marker: marker)) }
    }

    /// A part of the figure, by its box in fractions of the image the request carried (the same proportions here).
    static func crop(_ image: CGImage, _ box: FigureWalkthrough.Box) -> CGImage? {
        guard let rect = box.pixels(width: image.width, height: image.height) else { return nil }
        return image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }
}
