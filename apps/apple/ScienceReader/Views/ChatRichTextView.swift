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
    /// An answer: its text is selectable with actions, and a leading "Answer:" label is not shown.
    var assistant = false
    var onQuote: ChatQuoteHandler?
    /// An answer's `[¶N]` citations open that block of the paper (nil while streaming).
    var onCite: ChatCiteHandler?

    var body: some View {
        // An answer's `[[part N]]` lines are where its figure crops go (the transcript places them); never shown as text.
        let shown = assistant ? FigurePartMarkers.stripped(ChatRichText.withoutAnswerLabel(source), streaming: streaming) : source
        let blocks = ChatRichText.parse(shown, streaming: streaming)
        if blocks.contains(where: { if case .table = $0 { true } else { false } }) {
            ChatBlocksView(blocks: blocks, fontSize: fontSize, showSources: false, speaker: speaker, selectable: assistant, onQuote: onQuote, onCite: onCite)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        } else {
            let spoken = streaming ? shown : (ChatRichText.trailingSources(shown)?.body ?? shown)
            ChatBlocksView(blocks: blocks, fontSize: fontSize, showSources: false, selectable: assistant, onQuote: onQuote, onCite: onCite)
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
    /// Answers: paragraphs, headings and list items are selectable text views (same look).
    var selectable = false
    /// Answers: actions on selected text and formulas (nil while streaming).
    var onQuote: ChatQuoteHandler?
    /// Answers: `[¶N]` citations as links into the paper.
    var onCite: ChatCiteHandler?
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
            if selectable {
                ChatSelectableText(parts: parts, size: fontSize, dark: colorScheme == .dark, onQuote: onQuote, onCite: onCite)
            } else {
                inlineText(parts, size: fontSize).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        case .heading(let level, let parts):
            if selectable {
                ChatSelectableText(parts: parts, size: fontSize * (level <= 2 ? 1.12 : 1.04), weight: .semibold, lineSpacing: 0,
                                   dark: colorScheme == .dark, onQuote: onQuote, onCite: onCite)
                    .accessibilityAddTraits(.isHeader)
            } else {
                inlineText(parts, size: fontSize * (level <= 2 ? 1.12 : 1.04)).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            }
        case .listItem(let marker, let depth, let parts):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: fontSize)).foregroundStyle(.secondary).accessibilityHidden(marker == "•")
                if selectable {
                    // A text view has no baseline for SwiftUI: its first line's is the font's ascender.
                    ChatSelectableText(parts: parts, size: fontSize, dark: colorScheme == .dark, onQuote: onQuote, onCite: onCite)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.firstTextBaseline) { _ in UIFont.systemFont(ofSize: fontSize).ascender }
                } else {
                    inlineText(parts, size: fontSize).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.padding(.leading, CGFloat(depth) * 16)
        case .displayMath(let latex):
            if let onQuote {
                displayMath(latex).contextMenu {
                    Button("Copy LaTeX", systemImage: "doc.on.doc") { ChatFormulaActions.copyLatex(latex) }
                    Button("Copy as text", systemImage: "textformat") { ChatFormulaActions.copyText(latex) }
                    ForEach(ReaderModel.ChatQuoteAction.allCases, id: \.self) { action in
                        Button(action.menuTitle, systemImage: action.symbol) { onQuote(action, "\\[\(latex)\\]") }
                    }
                }
            } else {
                displayMath(latex)
            }
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

/// Runs an action on text or a formula from an answer (Quote in Chat, Explain, Define).
typealias ChatQuoteHandler = @MainActor (ReaderModel.ChatQuoteAction, String) -> Void
/// Opens the paper block an answer cites (`[¶N]`, grounded citations, 2026-10-14).
typealias ChatCiteHandler = @MainActor (Int) -> Void

extension NSAttributedString.Key {
    /// The LaTeX of an inline formula drawn as an image attachment.
    static let chatLatex = NSAttributedString.Key("ScienceReaderChatLatex")
}

/// The actions on one formula, shared by the display-math context menu and the
/// selection menu of inline formulas.
enum ChatFormulaActions {
    @MainActor static func copyLatex(_ latex: String) { UIPasteboard.general.string = latex }
    @MainActor static func copyText(_ latex: String) { UIPasteboard.general.string = ChatMathText.plain(latex) }

    @MainActor static func menu(_ latex: String, quote: String, onQuote: @escaping ChatQuoteHandler) -> [UIMenuElement] {
        [UIAction(title: "Copy LaTeX", image: UIImage(systemName: "doc.on.doc")) { _ in copyLatex(latex) },
         UIAction(title: "Copy as text", image: UIImage(systemName: "textformat")) { _ in copyText(latex) }] + quoteActions(quote, onQuote: onQuote)
    }

    /// Quote in Chat, Explain, Define: the same words and order for text and formulas (build 16 #4).
    @MainActor static func quoteActions(_ quote: String, onQuote: @escaping ChatQuoteHandler) -> [UIMenuElement] {
        ReaderModel.ChatQuoteAction.allCases.map { action in
            UIAction(title: action.menuTitle, image: UIImage(systemName: action.symbol)) { _ in onQuote(action, quote) }
        }
    }
}

/// Answer text the reader can select and act on (owner feedback 2026-10-07): a read-only
/// text view whose selection menu adds Quote in Chat, Explain and Define to Copy, and
/// whose inline formulas (image attachments) offer Copy LaTeX and Copy as text. Copy and
/// quotes keep formulas as their LaTeX. On the Mac it is the right-click menu.
struct ChatSelectableText: UIViewRepresentable {
    let parts: [ChatInline]
    let size: Double
    var weight: UIFont.Weight = .regular
    var lineSpacing: CGFloat = 4
    let dark: Bool
    var onQuote: ChatQuoteHandler?
    var onCite: ChatCiteHandler?

    struct Key: Equatable { let parts: [ChatInline]; let size: Double; let weight: CGFloat; let dark: Bool }

    /// A citation link's address: `gradstep-cite://12` names block 12 of the paper the chat is about.
    static let citeScheme = "gradstep-cite"
    static func citedBlock(_ url: URL) -> Int? {
        guard url.scheme == citeScheme, let host = url.host, let marker = Int(host), marker >= 1 else { return nil }
        return marker
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var key: Key?
        var onQuote: ChatQuoteHandler?
        var onCite: ChatCiteHandler?

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onQuote, range.length > 0, let text = textView.attributedText else { return nil }
            let quote = ChatSelectableText.quote(text, range: range)
            guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if let latex = ChatSelectableText.soleFormula(text, range: range) {
                return UIMenu(children: ChatFormulaActions.menu(latex, quote: quote, onQuote: onQuote))
            }
            let actions = ChatFormulaActions.quoteActions(quote, onQuote: onQuote)
            // Copy (the system's edit group) stays first; the chat actions follow it, then Look Up, Share and the rest.
            let isEdit = { (element: UIMenuElement) in (element as? UIMenu)?.identifier == .standardEdit }
            return UIMenu(children: suggestedActions.filter(isEdit) + [UIMenu(options: .displayInline, children: actions)]
                          + suggestedActions.filter { !isEdit($0) })
        }

        /// A tap on a formula does nothing (its image is not a document to preview or share); a tap on a
        /// citation opens the cited block of the paper instead of following a URL.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .textAttachment = textItem.content { return nil }
            if case .link(let url) = textItem.content, let marker = ChatSelectableText.citedBlock(url) {
                guard let onCite else { return nil }
                return UIAction(title: "Go to passage") { _ in onCite(marker) }
            }
            return defaultAction
        }

        /// A citation's long-press menu offers only the jump, never a web preview of its address.
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            if case .link(let url) = textItem.content, let marker = ChatSelectableText.citedBlock(url) {
                guard let onCite else { return nil }
                return UITextItem.MenuConfiguration(menu: UIMenu(children: [UIAction(title: "Go to passage", image: UIImage(systemName: "text.quote")) { _ in onCite(marker) }]))
            }
            guard let onQuote, case .textAttachment = textItem.content, let text = textView.attributedText,
                  let latex = ChatSelectableText.soleFormula(text, range: textItem.range) else { return nil }
            return UITextItem.MenuConfiguration(menu: UIMenu(children: ChatFormulaActions.menu(latex, quote: "\\(\(latex)\\)", onQuote: onQuote)))
        }
    }

    /// Copy keeps formulas as LaTeX instead of image placeholders.
    final class TextView: UITextView {
        override func copy(_ sender: Any?) {
            guard let text = attributedText, selectedRange.length > 0 else { return super.copy(sender) }
            UIPasteboard.general.string = ChatSelectableText.quote(text, range: selectedRange)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TextView {
        let view = TextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.onQuote = onQuote
        context.coordinator.onCite = onCite
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        let key = Key(parts: parts, size: size, weight: weight.rawValue, dark: dark)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.attributedText = Self.withCitations(attributed(), size: size)
        view.invalidateIntrinsicContentSize()
    }

    /// `[¶N]` in the answer text becomes a small tinted link to that block (an image attachment never matches).
    static func withCitations(_ text: NSAttributedString, size: Double) -> NSAttributedString {
        let string = text.string
        guard string.contains("[¶"), let pattern = try? NSRegularExpression(pattern: #"\[¶(\d{1,5})\]"#) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let font = UIFont.systemFont(ofSize: size * 0.82, weight: .medium)
        let matches = pattern.matches(in: string, range: NSRange(string.startIndex..., in: string))
        // "[¶23][¶24]" read as one "¶23¶24": a thin space between citations that touch (figure view, live 2026-10-16).
        let touching = Set(matches.map(\.range.location))
        for match in matches.reversed() {
            guard let marker = Int((string as NSString).substring(with: match.range(at: 1))), marker >= 1,
                  let url = URL(string: "\(citeScheme)://\(marker)") else { continue }
            let gap = touching.contains(match.range.upperBound) ? "\u{2009}" : ""
            result.replaceCharacters(in: match.range, with: "¶\(marker)" + gap)
            let shown = NSRange(location: match.range.location, length: ("¶\(marker)" as NSString).length)
            result.addAttributes([.link: url, .font: font], range: shown)
        }
        return result
    }

    /// Wraps to any finite proposed width (so stacks can size it like Text); unproposed, one line.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite {
            let fit = uiView.sizeThatFits(CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude))
            return CGSize(width: width, height: ceil(fit.height))
        }
        let fit = uiView.sizeThatFits(CGSize(width: CGFloat(10_000), height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(fit.width), height: ceil(fit.height))
    }

    private func attributed() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        for run in ChatRichText.styledRuns(parts) {
            switch run {
            case .text(let text):
                let intent = text.inlinePresentationIntent ?? []
                var attributes: [NSAttributedString.Key: Any] = [.font: Self.font(base, intent: intent), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: String(text.characters), attributes: attributes))
            case .math(let latex, _):
                if let rendered = ChatMathCache.shared.render(latex, size: size, display: false, dark: dark) {
                    let attachment = NSTextAttachment(image: rendered.image)
                    attachment.bounds = CGRect(x: 0, y: -rendered.descent, width: rendered.image.size.width, height: rendered.image.size.height)
                    let piece = NSMutableAttributedString(attachment: attachment)
                    piece.addAttributes([.chatLatex: latex, .paragraphStyle: paragraph, .font: base], range: NSRange(location: 0, length: piece.length))
                    result.append(piece)
                } else {
                    result.append(NSAttributedString(string: "\\(\(latex)\\)", attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]))
                }
            }
        }
        return result
    }

    private static func font(_ base: UIFont, intent: InlinePresentationIntent) -> UIFont {
        if intent.contains(.code) { return UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular) }
        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// The selected text with each formula as its delimited LaTeX.
    static func quote(_ text: NSAttributedString, range: NSRange) -> String {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        var out = ""
        text.enumerateAttribute(.chatLatex, in: clamped) { value, part, _ in
            if let latex = value as? String { out += "\\(\(latex)\\)" } else { out += (text.string as NSString).substring(with: part) }
        }
        return out
    }

    /// The LaTeX when the range is a single formula (allowing surrounding spaces).
    static func soleFormula(_ text: NSAttributedString, range: NSRange) -> String? {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        var formulas: [String] = [], other = false
        text.enumerateAttribute(.chatLatex, in: clamped) { value, part, _ in
            if let latex = value as? String { formulas.append(latex) }
            else if !(text.string as NSString).substring(with: part).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { other = true }
        }
        return formulas.count == 1 && !other ? formulas[0] : nil
    }
}

/// Inline Markdown with typeset inline math, shared by paragraphs and table cells.
enum ChatInlineText {
    /// Inline Markdown whose LaTeX backslashes stay literal. Displayed text
    /// shows links rather than following them (`inertLinks`).
    static func markdown(_ text: String, inertLinks: Bool = true) -> LocalizedStringKey {
        LocalizedStringKey(ChatDisplayText.inlineMarkdownPreservingBackslashes(inertLinks ? ChatRichText.inertLinks(text) : text))
    }

    /// Emphasis is parsed across the whole line, so `**$n = 0$:**` is bold, not asterisks.
    @MainActor static func text(_ parts: [ChatInline], size: Double, dark: Bool) -> Text {
        ChatRichText.styledRuns(parts).reduce(Text(verbatim: "")) { text, run in
            switch run {
            case .text(let value):
                return text + Text(value).font(.system(size: size))
            case .math(let latex, _):
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

/// The reader's model and the add state behind every answer's paper list.
struct ChatPaperContext {
    let model: ReaderModel
    let actions: ChatPaperActions
}

/// Add-to-library state for "Papers in this answer", shared by all answers in the
/// transcript (adding a paper under one answer marks it under the others) and
/// fenced to the reader session that started each add.
@MainActor @Observable final class ChatPaperActions {
    private var notices: [String: ReaderModel.ReferenceNotice] = [:]
    /// The library source the server matched for a DOI (the library knows papers by source ID only).
    private var matched: [String: String] = [:]

    private func key(_ mention: ChatPaperMention, _ model: ReaderModel) -> String { "\(model.readerSessionID.uuidString)|\(mention.id)" }

    func notice(for mention: ChatPaperMention, model: ReaderModel) -> ReaderModel.ReferenceNotice? { notices[key(mention, model)] }

    func inLibrary(_ mention: ChatPaperMention, model: ReaderModel) -> Bool {
        let library = model.librarySourceIDs
        switch mention.identity {
        case .arxiv(let reference):
            #if DEBUG && targetEnvironment(simulator)
            // The research chat fixture shows one named paper as already in the library.
            if ChatFixtureTransport.isEnabled, reference.sourceID == "2310.12036" { return true }
            #endif
            return library.contains(reference.sourceID)
        case .doi:
            return matched[key(mention, model)].map(library.contains) ?? false
        }
    }

    /// The library's title for a paper the answer names only by ID.
    func libraryTitle(_ mention: ChatPaperMention, model: ReaderModel) -> String? {
        guard case .arxiv(let reference) = mention.identity else { return nil }
        return model.papers.first { $0.sourceID == reference.sourceID }?.title
    }

    /// Resolve current membership when tapped; a queued import opens its library status, never a stale paper.
    func openLibrary(_ mention: ChatPaperMention, model: ReaderModel) {
        let source: String?
        switch mention.identity {
        case .arxiv(let reference): source = reference.sourceID
        case .doi: source = matched[key(mention, model)]
        }
        guard let source, model.librarySourceIDs.contains(source) else { return }
        if let paper = model.papers.first(where: { $0.sourceID == source }) {
            model.select(paper)
        } else {
            model.searchExternal = false; model.libraryFilter = .all; model.libraryTagFilter = nil
            model.libraryQuery = source; model.tab = .library
        }
    }

    /// arXiv papers are queued like the Library's Add; a DOI goes to `add-reference`,
    /// with the reader's outcome wording.
    func add(_ mention: ChatPaperMention, model: ReaderModel) async {
        guard model.isSignedIn else { model.openSignIn(); return }
        let key = key(mention, model), session = model.readerSessionID
        guard notices[key]?.kind != .working else { return }
        let text: String
        switch mention.identity {
        case .arxiv(let reference): text = reference.sourceID
        case .doi(let doi): text = doi
        }
        notices[key] = ReaderModel.ReferenceNotice(kind: .working, message: "Adding to your library…", reference: text)
        var outcome: ReaderModel.ReferenceNotice?
        switch mention.identity {
        case .arxiv(let reference):
            do {
                try await model.importPaper(reference.sourceID, stayInSearch: true)
                outcome = .init(kind: .added, message: "Added. It’s being prepared to read.", reference: text, sourceID: reference.sourceID)
            } catch is CancellationError {
                outcome = nil
            } catch LibraryCommandError.targetBusy {
                outcome = .init(kind: .present, message: "This paper already has a pending change.", reference: text)
            } catch ReaderModel.LibraryAddError.alreadyInLibrary {
                outcome = .init(kind: .present, message: "Already in your library.", reference: text, sourceID: reference.sourceID)
            } catch {
                outcome = .init(kind: .unavailable, message: "Couldn’t add it right now.", reference: text)
            }
        case .doi:
            outcome = await model.referenceOutcome(text)
        }
        guard model.readerSessionID == session else { return }
        notices[key] = outcome
        if let source = outcome?.sourceID { matched[key] = source }
    }
}

/// "Papers in this answer": the arXiv IDs and DOIs an answer names, found on the
/// device (no model call), styled like Sources. Each one's identifier links to its
/// abstract page (after the reader sees the address), and it can be added to the library.
struct ChatAnswerPapersView: View {
    let mentions: [ChatPaperMention]
    let fontSize: Double
    let context: ChatPaperContext
    @Environment(\.openURL) private var openURL
    @State private var pending: ChatPaperMention?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Papers in this answer").font(.system(size: fontSize * 0.82, weight: .semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                row(mention, number: index + 1)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.papers")
        .confirmationDialog("Open this paper in Safari?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { mention in
            Button("Open in Safari") { openURL(mention.url) }
            Button("Cancel", role: .cancel) {}
        } message: { mention in Text(verbatim: mention.url.absoluteString) }
    }

    private func row(_ mention: ChatPaperMention, number: Int) -> some View {
        let actions = context.actions, model = context.model
        let inLibrary = actions.inLibrary(mention, model: model)
        let notice = actions.notice(for: mention, model: model)
        let title = mention.title ?? actions.libraryTitle(mention, model: model)
        let small = Font.system(size: fontSize * 0.74)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(verbatim: title).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: "Paper \(number): \(title), \(mention.label)"))
                        .accessibilityIdentifier("chat.paper.\(number)")
                } else {
                    // Named only by its identifier: the identifier is the line, and the link.
                    link(mention, number: number, font: .system(size: fontSize * 0.86))
                }
                // One line when everything fits untruncated, else the link and state above Add to library.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        details(mention, number: number, linked: title != nil, inLibrary: inLibrary, font: small)
                        buttons(mention, number: number, inLibrary: inLibrary, notice: notice)
                    }
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 6) {
                        details(mention, number: number, linked: title != nil, inLibrary: inLibrary, font: small)
                        buttons(mention, number: number, inLibrary: inLibrary, notice: notice)
                    }
                }
                if let notice { noticeLine(notice, mention: mention, number: number, font: small) }
            }
        }
        .font(.system(size: fontSize * 0.86))
    }

    /// The paper's arXiv ID or DOI as a link to its abstract page (owner feedback, build 16 #9: "remove Open and just
    /// put arXiv and it can link out"). It opens only after the reader sees the address, like Sources.
    private func link(_ mention: ChatPaperMention, number: Int, font: Font) -> some View {
        Button { pending = mention } label: {
            HStack(spacing: 2) {
                Text(verbatim: mention.label).lineLimit(1)
                Image(systemName: "arrow.up.right").imageScale(.small).accessibilityHidden(true)
            }
        }
        .font(font).buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: mention.label))
        .accessibilityHint("Shows the abstract page’s address before opening it in Safari")
        .accessibilityIdentifier("chat.paper.\(number).open")
    }

    @ViewBuilder private func details(_ mention: ChatPaperMention, number: Int, linked: Bool, inLibrary: Bool, font: Font) -> some View {
        if linked || inLibrary {
            HStack(spacing: 10) {
                if linked { link(mention, number: number, font: font) }
                if inLibrary {
                    Button { context.actions.openLibrary(mention, model: context.model) } label: {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .accessibilityLabel("Open in Library")
                    .accessibilityHint("Reads the saved paper, or shows its import progress")
                    .accessibilityIdentifier("chat.paper.\(number).inLibrary")
                }
            }
            .font(font)
        }
    }

    @ViewBuilder private func buttons(_ mention: ChatPaperMention, number: Int, inLibrary: Bool, notice: ReaderModel.ReferenceNotice?) -> some View {
        let font = Font.system(size: fontSize * 0.78, weight: .medium)
        if !inLibrary, notice?.kind != .working, notice?.kind != .added, notice?.kind != .present {
            Button { Task { await context.actions.add(mention, model: context.model) } } label: {
                HStack(spacing: 3) { Image(systemName: "plus.circle"); Text("Add to library") }.lineLimit(1)
            }
            .font(font).buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: "Add \(mention.label) to library"))
            .accessibilityIdentifier("chat.paper.\(number).add")
        }
    }

    private func noticeLine(_ notice: ReaderModel.ReferenceNotice, mention: ChatPaperMention, number: Int, font: Font) -> some View {
        let problem = notice.kind == .notFound || notice.kind == .unavailable || notice.kind == .closed
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if notice.kind == .working { ProgressView().controlSize(.mini) }
            else {
                Image(systemName: problem ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(problem ? Color.orange : Color.green)
                    .accessibilityHidden(true)
            }
            Text(verbatim: notice.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.paper.\(number).notice")
            if notice.kind == .unavailable {
                Button("Try again") { Task { await context.actions.add(mention, model: context.model) } }.buttonStyle(.borderless)
                    .accessibilityIdentifier("chat.paper.\(number).retry")
            }
        }
        .font(font)
    }
}
