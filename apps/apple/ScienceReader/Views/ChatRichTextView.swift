import SwiftUI
import SwiftMath
import ScienceReaderCore

/// Renders a chat message's Markdown-like blocks with native math (SwiftMath,
/// CoreText). The stored source is never changed; formulas SwiftMath cannot
/// typeset fall back to their LaTeX source. Presentation only.
struct ChatRichTextView: View {
    let source: String
    let fontSize: Double
    @Environment(\.colorScheme) private var colorScheme
    /// The transcript shows sources separately (outside the combined
    /// accessibility element) so each one stays individually actionable.
    var showSources = true

    var body: some View {
        let blocks = ChatRichText.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }
    }

    @ViewBuilder private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case .paragraph(let parts):
            inlineText(parts, size: fontSize).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .heading(let level, let parts):
            inlineText(parts, size: fontSize * (level <= 2 ? 1.12 : 1.04)).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth, let parts):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: fontSize)).foregroundStyle(.secondary).accessibilityHidden(marker == "•")
                inlineText(parts, size: fontSize).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(.leading, CGFloat(depth) * 16)
        case .displayMath(let latex):
            displayMath(latex)
        case .sources(let sources):
            if showSources { ChatSourcesView(sources: sources, fontSize: fontSize) }
        case .preformatted(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text).font(.system(size: fontSize * 0.84, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private func displayMath(_ latex: String) -> some View {
        if let rendered = ChatMathCache.shared.render(latex, size: fontSize * 1.05, display: true, dark: colorScheme == .dark) {
            let width = rendered.image.size.width
            // Natural size when it fits; otherwise scale down to as little as
            // 62% before falling back to horizontal scrolling.
            ViewThatFits(in: .horizontal) {
                Image(uiImage: rendered.image)
                Image(uiImage: rendered.image).resizable().interpolation(.high).scaledToFit()
                    .frame(minWidth: width * 0.62, idealWidth: width * 0.62, maxWidth: width)
                ScrollView(.horizontal, showsIndicators: true) { Image(uiImage: rendered.image) }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement().accessibilityLabel(Text(verbatim: latex)).accessibilityHint("Equation")
        } else {
            Text(verbatim: "\\[\(latex)\\]").font(.system(size: fontSize * 0.86, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func inlineText(_ parts: [ChatInline], size: Double) -> Text {
        parts.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case .text(let value):
                return text + Text(LocalizedStringKey(ChatDisplayText.inlineMarkdownPreservingBackslashes(ChatRichText.inertLinks(value)))).font(.system(size: size))
            case .math(let latex):
                if let rendered = ChatMathCache.shared.render(latex, size: size, display: false, dark: colorScheme == .dark) {
                    return text + Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
                }
                return text + Text(verbatim: "\\(\(latex)\\)").font(.system(size: size * 0.9, design: .monospaced))
            }
        }
    }
}

/// Typeset formulas keyed by source, size, style and appearance.
@MainActor final class ChatMathCache {
    static let shared = ChatMathCache()
    struct Rendered { let image: UIImage; let descent: CGFloat }
    private final class Box { let value: Rendered?; init(_ value: Rendered?) { self.value = value } }
    private let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 600; return cache }()

    /// Commands SwiftMath lacks, defined once from the shared table (it skips
    /// raw non-ASCII characters, so they cannot be written as Unicode text).
    private static let customSymbols: Void = {
        for symbol in ChatMathTypesetting.customSymbols {
            let atom: MTMathAtom? = switch symbol.kind {
            // MTMathAtom's initializer is internal: copy a symbol of the same type.
            case .relation: MTMathAtomFactory.atom(forLatexSymbol: "leq")?.copy()
            case .ordinary: MTMathAtomFactory.atom(forLatexSymbol: "infty")?.copy()
            case .largeOperator: MTMathAtomFactory.operatorWithName(symbol.character, limits: false)
            }
            guard let atom else { continue }
            atom.nucleus = symbol.character
            MTMathAtomFactory.add(latexSymbol: symbol.name, value: atom)
        }
    }()

    func render(_ latex: String, size: Double, display: Bool, dark: Bool) -> Rendered? {
        guard latex.utf8.count <= 4_000 else { return nil }
        _ = Self.customSymbols
        let key = "\(display ? "d" : "i")|\(Int(size * 10))|\(dark ? 1 : 0)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let color: UIColor = dark ? .white : .black
        var image = MathImage(latex: ChatMathTypesetting.prepare(latex), fontSize: CGFloat(size), textColor: color,
                              labelMode: display ? .display : .text)
        let (error, rendered, layout) = image.asImage()
        let value: Rendered? = (error == nil && rendered != nil && (rendered!.size.width) > 0)
            ? Rendered(image: rendered!, descent: layout?.descent ?? 0) : nil
        cache.setObject(Box(value), forKey: key)
        return value
    }
}

/// Web sources appended to an answer. Answer text is untrusted, so a source
/// opens only after the reader sees its full address and confirms.
struct ChatSourcesView: View {
    let sources: [ChatSource]
    let fontSize: Double
    @Environment(\.openURL) private var openURL
    @State private var pending: ChatSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.system(size: fontSize * 0.82, weight: .semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                Button { pending = source } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: source.title ?? source.url.host ?? source.url.absoluteString).multilineTextAlignment(.leading)
                            Text(verbatim: source.url.host ?? "").font(.system(size: fontSize * 0.72)).foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.up.right.square").font(.system(size: fontSize * 0.72)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: fontSize * 0.86)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Source \(index + 1): \(source.title ?? source.url.host ?? "")"))
                .accessibilityHint("Shows the address before opening it in Safari")
                .accessibilityIdentifier("chat.source.\(index + 1)")
            }
        }
        .padding(.top, 4)
        .confirmationDialog("Open this source in Safari?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { source in
            Button("Open in Safari") { openURL(source.url) }
            Button("Cancel", role: .cancel) {}
        } message: { source in Text(verbatim: source.url.absoluteString) }
    }
}
