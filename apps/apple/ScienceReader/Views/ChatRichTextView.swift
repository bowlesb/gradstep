import SwiftUI
import SwiftMath
import ScienceReaderCore

/// Renders a chat message's Markdown-like blocks with native math (SwiftMath,
/// CoreText). The stored source is never changed; formulas SwiftMath cannot
/// typeset fall back to their LaTeX source. Presentation only.
struct ChatRichTextView: View {
    let source: String
    let fontSize: Double
    /// The transcript shows sources separately (outside the combined
    /// accessibility element) so each one stays individually actionable.
    var showSources = true
    /// A growing answer keeps a table at its very end as pipe text until it is complete.
    var streaming = false

    var body: some View {
        ChatBlocksView(blocks: ChatRichText.parse(source, streaming: streaming), fontSize: fontSize, showSources: showSources)
    }
}

/// One transcript message's text. Without a table it is a single accessibility
/// element labelled with its source, as before. With a table, the text around
/// each table stays combined and each table is its own element whose rows
/// VoiceOver reads one at a time.
struct ChatMessageText: View {
    let source: String
    let fontSize: Double
    let streaming: Bool
    /// "You" or "Assistant": the start of the message's spoken label.
    let speaker: String
    let identifier: String

    var body: some View {
        let blocks = ChatRichText.parse(source, streaming: streaming)
        if blocks.contains(where: { if case .table = $0 { true } else { false } }) {
            ChatBlocksView(blocks: blocks, fontSize: fontSize, showSources: false, speaker: speaker)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        } else {
            let spoken = streaming ? source : (ChatRichText.trailingSources(source)?.body ?? source)
            ChatBlocksView(blocks: blocks, fontSize: fontSize, showSources: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text("\(speaker): \(Text(ChatInlineText.markdown(spoken, inertLinks: false)))"))
        }
    }
}

/// Parsed blocks in reading order. With `speaker`, consecutive non-table blocks
/// form one combined accessibility element and each table is its own.
struct ChatBlocksView: View {
    let blocks: [ChatBlock]
    let fontSize: Double
    var showSources = true
    var speaker: String?
    @Environment(\.colorScheme) private var colorScheme

    private enum Group { case flow([ChatBlock]), table(ChatTable, number: Int) }

    var body: some View {
        if let speaker {
            let groups = Self.groups(blocks)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    switch group {
                    case .flow(let flow):
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(flow.enumerated()), id: \.offset) { _, block in blockView(block) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("\(index == 0 ? "\(speaker): " : "")\(Text(ChatInlineText.markdown(ChatRichText.spokenText(flow), inertLinks: false)))"))
                    case .table(let table, let number):
                        ChatTableView(table: table, fontSize: fontSize, number: number, speaker: index == 0 ? speaker : nil)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
            }
        }
    }

    private static func groups(_ blocks: [ChatBlock]) -> [Group] {
        var groups: [Group] = [], flow: [ChatBlock] = [], tables = 0
        for block in blocks {
            switch block {
            case .table(let table):
                if !flow.isEmpty { groups.append(.flow(flow)); flow = [] }
                tables += 1
                groups.append(.table(table, number: tables))
            case .sources: continue
            default: flow.append(block)
            }
        }
        if !flow.isEmpty { groups.append(.flow(flow)) }
        return groups
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
        case .table(let table):
            ChatTableView(table: table, fontSize: fontSize, number: tableNumber(of: table))
        case .preformatted(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text).font(.system(size: fontSize * 0.84, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Tables are numbered in order within the message (accessibility identifiers).
    private func tableNumber(of table: ChatTable) -> Int {
        var number = 0
        for block in blocks {
            guard case .table(let other) = block else { continue }
            number += 1
            if other == table { return number }
        }
        return number
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
        ChatInlineText.text(parts, size: size, dark: colorScheme == .dark)
    }
}

/// Inline Markdown with typeset inline math, shared by paragraphs and table cells.
enum ChatInlineText {
    /// Inline Markdown whose LaTeX backslashes stay literal. Displayed text
    /// shows links rather than following them (`inertLinks`).
    static func markdown(_ text: String, inertLinks: Bool = true) -> LocalizedStringKey {
        LocalizedStringKey(ChatDisplayText.inlineMarkdownPreservingBackslashes(inertLinks ? ChatRichText.inertLinks(text) : text))
    }

    @MainActor static func text(_ parts: [ChatInline], size: Double, dark: Bool) -> Text {
        parts.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case .text(let value):
                return text + Text(markdown(value)).font(.system(size: size))
            case .math(let latex):
                if let rendered = ChatMathCache.shared.render(latex, size: size, display: false, dark: dark) {
                    return text + Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
                }
                return text + Text(verbatim: "\\(\(latex)\\)").font(.system(size: size * 0.9, design: .monospaced))
            }
        }
    }
}

/// A GFM table as a compact native grid: the header emphasized, thin rules
/// between rows, cells rendered like paragraphs (inline math included). It
/// keeps its natural width when that fits, wraps long cells next, and scrolls
/// sideways only when it is still too wide. VoiceOver reads it row by row.
struct ChatTableView: View {
    let table: ChatTable
    let fontSize: Double
    /// 1-based position among the message's tables (accessibility identifiers).
    let number: Int
    var speaker: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var cellSize: Double { fontSize * 0.88 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(cap: nil)
            grid(cap: fontSize * 9)
            ScrollView(.horizontal, showsIndicators: true) { grid(cap: fontSize * 14) }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityChildren {
            VStack(alignment: .leading) {
                Text(verbatim: table.spokenHeader).accessibilityIdentifier("chat.table.\(number).header")
                ForEach(table.rows.indices, id: \.self) { row in
                    Text(verbatim: table.spokenRow(row)).accessibilityIdentifier("chat.table.\(number).row.\(row + 1)")
                }
            }
        }
        .accessibilityIdentifier("chat.table.\(number)")
    }

    private var label: String {
        let rows = table.rows.count, columns = table.header.count
        return "\(speaker.map { "\($0): " } ?? "")Table, \(rows) \(rows == 1 ? "row" : "rows"), \(columns) \(columns == 1 ? "column" : "columns")"
    }

    /// `cap`: the widest a cell may be before its text wraps (nil: never wraps).
    private func grid(cap: Double?) -> some View {
        let hairline = 1 / max(displayScale, 1)
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, header: true, cap: cap)
                }
            }
            Rectangle().fill(Color.primary.opacity(0.22)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                if row > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: hairline).gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, header: false, cap: cap)
                    }
                }
            }
        }
        // Ideal size on both axes: rows are as tall as their tallest cell, no taller.
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .padding(.vertical, 1)
    }

    private func cell(_ cell: ChatTable.Cell, column: Int, header: Bool, cap: Double?) -> some View {
        let alignment = table.alignments[column]
        let text = ChatInlineText.text(cell.parts, size: cellSize, dark: colorScheme == .dark)
            .fontWeight(header ? .semibold : .regular).monospacedDigit()
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .lineSpacing(2)
        let frameAlignment: Alignment = alignment == .center ? .top : alignment == .trailing ? .topTrailing : .topLeading
        return CappedWidth(cap: cap.map { CGFloat($0) }) { text.fixedSize(horizontal: cap == nil, vertical: true) }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background { Rectangle().fill(header ? Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045) : Color.clear) }
    }
}

/// Lays out its one child at its natural width, or at most `cap` wide (the
/// text wrapping) when that is narrower.
private struct CappedWidth: Layout {
    let cap: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: width(for: child, proposal: proposal), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func width(for child: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        let natural = child.sizeThatFits(.unspecified).width
        guard let cap else { return natural }
        return min(natural, cap, proposal.width ?? .infinity)
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
