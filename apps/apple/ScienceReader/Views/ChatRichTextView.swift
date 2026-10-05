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
                return text + Text(LocalizedStringKey(ChatDisplayText.inlineMarkdownPreservingBackslashes(value))).font(.system(size: size))
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

    func render(_ latex: String, size: Double, display: Bool, dark: Bool) -> Rendered? {
        guard latex.utf8.count <= 4_000 else { return nil }
        let key = "\(display ? "d" : "i")|\(Int(size * 10))|\(dark ? 1 : 0)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let color: UIColor = dark ? .white : .black
        var image = MathImage(latex: latex, fontSize: CGFloat(size), textColor: color, labelMode: display ? .display : .text)
        let (error, rendered, layout) = image.asImage()
        let value: Rendered? = (error == nil && rendered != nil && (rendered!.size.width) > 0)
            ? Rendered(image: rendered!, descent: layout?.descent ?? 0) : nil
        cache.setObject(Box(value), forKey: key)
        return value
    }
}
