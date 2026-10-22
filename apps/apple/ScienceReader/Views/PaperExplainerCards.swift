import CryptoKit
import ScienceReaderCore
import SwiftUI

// The paper's AI Explainer as cards: "In short", Key concepts and How it fits together. One view for the explainer's own
// page and for the chat it is opened in (build 82: "I expected all above content to follow me" and "it looks like the
// cards were removed"), so Open in Chat carries the same cards, with working ¶ links and the drawn diagram. Background and
// the paper's own ideas are one card (build 82: "Key ideas and concepts seems like two versions of the same thing"): the
// background first, each entry marked quietly with the diagram's colour for its kind.

struct PaperExplainerCards: View {
    let explainer: PaperExplainer
    /// While it streams the diagram waits for the whole explainer.
    var loading = false
    var bodySize: CGFloat = 17
    /// "paperExplainer" on its page; another prefix where it is shown again (the chat), so identifiers stay unique.
    var identifier = "paperExplainer"
    /// The cards' surface: raised on the explainer's grouped background; the chat (a plain background) passes its own.
    var surface = Color(uiColor: .secondarySystemGroupedBackground)
    let onCite: ChatCiteHandler
    @State private var showDiagram = false
    @State private var diagramImage: UIImage?
    @State private var diagramFailed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !explainer.summary.isEmpty {
                PaperExplainerCard(title: "In short", surface: surface) {
                    Text(explainer.summary).font(.system(size: bodySize)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled).accessibilityIdentifier("\(identifier).summary")
                }
            }
            if !explainer.background.isEmpty || !explainer.ideas.isEmpty {
                PaperExplainerCard(title: "Key concepts", surface: surface) {
                    ForEach(Array(explainer.background.enumerated()), id: \.offset) { index, item in
                        itemRow(item, kind: .background, identifier: "\(identifier).background.\(index + 1)")
                    }
                    ForEach(Array(explainer.ideas.enumerated()), id: \.offset) { index, item in
                        itemRow(item, kind: .idea, identifier: "\(identifier).idea.\(index + 1)")
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("\(identifier).concepts")
            }
            if !loading, !explainer.links.isEmpty { diagram }
        }
        .sheet(isPresented: $showDiagram) {
            if let diagram = ChatDiagram(title: "How it fits together", source: explainer.mermaid, messageID: nil) {
                DiagramSheet(diagram: diagram).macSheetKeys()
            }
        }
    }

    /// One concept: a quiet marker for its kind (the diagram's colour), its name, one line, and the paragraphs that rely on it.
    private func itemRow(_ item: PaperExplainer.Item, kind: PaperExplainer.Kind, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(kind)).frame(width: 7, height: 7)
                Text(kind == .background ? "Background" : "This paper").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Text(item.name).font(.system(size: bodySize, weight: .semibold))
                .accessibilityLabel(kind == .background ? "\(item.name), background" : "\(item.name), from this paper")
            if !item.line.isEmpty {
                Text(item.line).font(.system(size: bodySize * 0.92)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !item.paragraphs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.paragraphs, id: \.self) { n in
                        Button("¶\(n)") { onCite(n) }
                            .font(.footnote.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(Platform.isMac ? .small : .mini)
                            .accessibilityLabel("Go to paragraph \(n)").accessibilityIdentifier("\(identifier).cite.\(n)")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// The diagram's node borders (PaperExplainer.mermaid's classDefs): background blue-grey, the paper's ideas amber.
    static func color(_ kind: PaperExplainer.Kind) -> Color {
        kind == .background ? Color(red: 0x7a / 255, green: 0x86 / 255, blue: 0xa8 / 255) : Color(red: 0xc9 / 255, green: 0x8a / 255, blue: 0x12 / 255)
    }

    /// The diagram, drawn as an image in the card; a tap opens it full size (two fingers zoom there).
    private var diagram: some View {
        let source = explainer.mermaid, dark = colorScheme == .dark
        let id = Self.diagramID(source)
        return PaperExplainerCard(title: "How it fits together", surface: surface) {
            Button { showDiagram = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if let image = diagramImage ?? DiagramPreview.cached(id, dark: dark) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420)
                        } else if diagramFailed {
                            Label("Couldn’t draw it here", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    Label("Open full size", systemImage: "arrow.up.left.and.arrow.down.right").font(.footnote).foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Diagram: how the paper’s ideas fit together")
            .accessibilityValue(diagramImage != nil || DiagramPreview.cached(id, dark: dark) != nil ? "drawn" : diagramFailed ? "not drawn" : "drawing")
            .accessibilityHint("Opens it full size")
            .accessibilityIdentifier("\(identifier).diagram")
            .task(id: "\(id)-\(dark)") {
                diagramImage = nil; diagramFailed = false
                diagramImage = await DiagramPreview.render(id, source: source, dark: dark)
                diagramFailed = diagramImage == nil
            }
        }
    }

    /// A stable identity for the drawing's cached image: a digest of its source.
    static func diagramID(_ source: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(source.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// One of the explainer's cards: a headline over its content on the grouped background's raised surface.
struct PaperExplainerCard<Content: View>: View {
    let title: String
    var surface = Color(uiColor: .secondarySystemGroupedBackground)
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(surface))
    }
}
