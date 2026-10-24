import SwiftUI
import ScienceReaderCore

/// The paper's Contents with Figures, Tables and Equations beside it (owner, build 59: "four tabs, content, figures,
/// tables, and equations. The default selected when you enter should be contents… minimalistic but nicely designed…
/// consistent styling in the rows and be clickable into the paper"). Each row goes to its place in the paper with Back.
struct PaperContentsSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case contents = "Contents", figures = "Figures", tables = "Tables", equations = "Equations"
        var id: String { rawValue }
    }
    /// A display equation: "Equation (4)" as printed, or "Equation · 3.2 Method" when it has no number (owner, build 62:
    /// "remove the equation text from this view and instead put Equation 1, Equation 2"); its element in the page draws
    /// it in the tiles.
    struct Equation: Identifiable, Equatable { let id: String; let label: String; let markup: String? }

    /// The tiles, pushed from the Figures list (owner, build 59: "a link to the same squares based view"); a table with
    /// its whole caption, pushed from the Tables list; the equations typeset as tiles (owner, build 62).
    enum Route: Hashable { case tiles, table(String), equationTiles }

    let headings: [PaperHeading]
    let bundle: VerifiedReaderBundle?
    /// The heading being read: its row is marked and Contents opens on it (owner, TestFlight 91: "you should see what
    /// section you are in because the part you were reading is highlighted").
    var current: String? = nil
    var baseFontSize: Double = 17
    /// Report this screen, as the last row of each list (the tabs fill the top row on a phone; there is no ⋯ there).
    var report: (() -> Void)? = nil
    /// In a Wide slot (Navigate): ✕ closes the slot rather than a sheet.
    var onClose: (() -> Void)? = nil
    let go: (PaperJumpRequest.Target, String) -> Void
    @SheetDismiss private var dismissSheet
    @Environment(\.slotPane) private var slotPane
    private func dismiss() { if let onClose { onClose() } else { dismissSheet() } }
    @State private var tab: Tab = .contents
    @State private var path = NavigationPath()
    @State private var equations: [Equation]? = nil
    /// The equations are listed by the index alone while the page is still being read for their printed numbers.
    @State private var readingNumbers = false
    @AppStorage("reader.contents.doubleTapDiscovered") private var doubleTapDiscovered = false
    @ScaledMetric(relativeTo: .body) private var indent = 18.0

    private var figures: [GalleryFigure] { bundle.map { GalleryFigure.all(in: $0.index) } ?? [] }
    /// The captioned tables the index lists (revision 16) beside those arXiv published as images, in page order.
    private var tables: [GalleryFigure] { bundle.map { GalleryFigure.tables(in: $0.index) } ?? [] }

    var body: some View {
        NavigationStack(path: $path) {
            // One glass row: the tabs (they name the tab, so no title) and an X (owner, build 62: "remove Done, use x
            // button… Liquid… tabs"; "the title Equations is duplicative").
            VStack(spacing: 0) {
                #if !targetEnvironment(macCatalyst)
                if !doubleTapDiscovered && !slotPane {
                    Text("Double tap anywhere while reading the article for this menu")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .accessibilityIdentifier("contents.doubleTapHint")
                }
                #endif
                SheetTopRow(close: { dismiss() }) {
                    GlassTabs(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab, identifier: "contents.tabs")
                }
                list
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: tab) {
                if tab == .equations, equations == nil || readingNumbers { await loadEquations() }
            }
            // A figure's own page: the figure, its whole caption, Show in paper (owner, build 59: "get to the entire title
            // without going all the way back to the paper").
            .navigationDestination(for: String.self) { id in
                if let bundle {
                    GalleryFigureDetail(bundle: bundle, figures: figures, current: id, baseFontSize: baseFontSize,
                                        onShowInPaper: { go(.figure, $0) }, close: { dismiss() })
                }
            }
            .navigationDestination(for: Route.self) { route in
                if let bundle {
                    switch route {
                    case .tiles:
                        VStack(spacing: 0) {
                            SheetTopRow(back: { path.removeLast() }, close: { dismiss() }) { SheetRowTitle(text: "Figures") }
                            FigureGrid(bundle: bundle, figures: figures)
                        }
                        .toolbar(.hidden, for: .navigationBar)
                    case .equationTiles:
                        VStack(spacing: 0) {
                            SheetTopRow(back: { path.removeLast() }, close: { dismiss() }) { SheetRowTitle(text: "Equations") }
                            // A tile goes where its row goes: the paper at that equation, with Back.
                            EquationTilesView(bundle: bundle, equations: equations ?? []) { go(.equation, $0) }
                                .accessibilityIdentifier("contents.equationTiles.page")
                        }
                        .toolbar(.hidden, for: .navigationBar)
                    // A table's own view (a table block or one published as an image), its whole caption, Show in paper:
                    // the paper goes to it as to a referenced table, with Back.
                    case .table(let id):
                        GalleryFigureDetail(bundle: bundle, figures: tables, current: id, baseFontSize: baseFontSize,
                                            onShowInPaper: { go(.referencedFigure, $0) }, close: { dismiss() }, noun: "Table")
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .contents:
            let nested = headings.contains { $0.depth > 0 }
            ScrollViewReader { proxy in
                List {
                    ForEach(headings) { heading in
                        let reading = heading.id == current
                        Button { go(.heading, heading.id) } label: {
                            ContentsEntry(title: heading.title, detail: nil, strong: nested && heading.depth == 0, reading: reading)
                        }
                        .accessibilityValue([nested ? "Level \(heading.depth + 1)" : "", reading ? "Reading" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
                        .padding(.leading, CGFloat(heading.depth) * indent)
                        .listRowBackground(reading ? Color.accentColor.opacity(0.14) : nil)
                        .id(heading.id)
                        .accessibilityIdentifier(reading ? "contents.reading" : "")
                    }
                    reportRow
                }
                .listStyle(.plain)
                // Opens on the section being read, in the middle where the list is long enough.
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
            .overlay { if headings.isEmpty { ContentUnavailableView("No sections", systemImage: "list.bullet.indent") } }
            .accessibilityIdentifier("contents.list.contents")
        case .figures, .tables:
            let wanted = tab == .tables ? tables : figures.filter { !($0.number?.hasPrefix("Table") ?? false) }
            List {
                if tab == .figures, !wanted.isEmpty {
                    NavigationLink(value: Route.tiles) { Label("View as tiles", systemImage: "square.grid.2x2") }
                        .accessibilityIdentifier("contents.figureTiles")
                }
                ForEach(Array(wanted.enumerated()), id: \.element.id) { index, figure in
                    // "Figure 1 — Subplots of …", the caption cut off; the row opens the figure (or table) with its whole
                    // caption.
                    let entry = CaptionEntry(number: figure.number ?? (tab == .tables ? "Table" : "Figure"), caption: figure.caption)
                    Group {
                        if tab == .tables { NavigationLink(value: Route.table(figure.id)) { entry } }
                        else { NavigationLink(value: figure.id) { entry } }
                    }
                    .accessibilityIdentifier("contents.\(tab == .tables ? "table" : "figure").\(index)")
                }
                reportRow
            }
            .listStyle(.plain)
            .overlay { if wanted.isEmpty { ContentUnavailableView(tab == .tables ? "No tables" : "No figures", systemImage: tab == .tables ? "tablecells" : "photo") } }
            .accessibilityIdentifier("contents.list.\(tab == .tables ? "tables" : "figures")")
        case .equations:
            if let equations {
                List {
                    if !equations.isEmpty, !readingNumbers {
                        NavigationLink(value: Route.equationTiles) { Label("View as tiles", systemImage: "square.grid.2x2") }
                            .accessibilityIdentifier("contents.equationTiles")
                    }
                    ForEach(Array(equations.enumerated()), id: \.element.id) { index, equation in
                        Button { go(.equation, equation.id) } label: { ContentsEntry(title: equation.label, detail: nil, strong: true) }
                            .accessibilityIdentifier("contents.equation.\(index)")
                    }
                    reportRow
                }
                .listStyle(.plain)
                .overlay { if equations.isEmpty { ContentUnavailableView("No equations", systemImage: "function") } }
                .accessibilityIdentifier("contents.list.equations")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("contents.equations.loading")
            }
        }
    }

    @ViewBuilder private var reportRow: some View {
        if let report {
            Button(action: report) { Label("Report this screen", systemImage: "ladybug").font(.footnote) }
                .foregroundStyle(.secondary).listRowSeparator(.hidden, edges: .bottom).padding(.top, 12)
                .accessibilityIdentifier("contents.report")
        }
    }

    /// The full list (printed numbers read from the page) when it is quick. Otherwise, within 1.5 s, the equations named
    /// from the index alone, their printed numbers filled in when the page has been read (build 68: "Hanging", a spinner
    /// that never ended on a long paper). The rows keep their places as the names fill in.
    private func loadEquations() async {
        let bundle = bundle
        let scan = Task { await Self.equations(in: bundle) }
        let early = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, equations == nil else { return }
            equations = Self.indexEquations(in: bundle); readingNumbers = true
        }
        let loaded = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel(); early.cancel() }
        early.cancel()
        guard !Task.isCancelled else { return }
        // A scan that found nothing usable keeps the index's names (it never replaces a list with an empty one).
        if !loaded.isEmpty || equations == nil { equations = loaded }
        readingNumbers = false
    }

    /// The display equations named from the index alone (a \tag{…} in the source, else the section): instant, no page scan.
    nonisolated static func indexEquations(in bundle: VerifiedReaderBundle?) -> [Equation] {
        guard let index = bundle?.index else { return [] }
        let sections = Self.sections(of: index)
        return index.equations.filter(\.display).map { equation in
            let tag = equation.latex.firstMatch(of: /\\tag\*?\{([^}]{1,12})\}/).map { "(\($0.output.1))" }
            return Equation(id: equation.id, label: label(number: tag, section: sections[equation.blockID]), markup: nil)
        }
    }

    /// The paper's display equations in order: numbered as printed, else named by their section; each with its element in
    /// the page for the tiles.
    static func equations(in bundle: VerifiedReaderBundle?) async -> [Equation] {
        guard let bundle else { return [] }
        let index = bundle.index
        let html = bundle.data(for: bundle.manifest.entrypoint).flatMap { String(data: $0, encoding: .utf8) }
        let load = Task.detached(priority: .userInitiated) {
            let sections = Self.sections(of: index)
            let displayed = index.equations.filter(\.display)
            let elements = html.map { EquationMarkup.elements(in: $0, equationIDs: displayed.map(\.id)) } ?? [:]
            return displayed.map { equation in
                let markup = elements[equation.id]
                // The printed number from the page, else a \tag{…} in the source.
                let tag = equation.latex.firstMatch(of: /\\tag\*?\{([^}]{1,12})\}/).map { "(\($0.output.1))" }
                let number = markup.flatMap(EquationMarkup.number(in:)) ?? tag
                return Equation(id: equation.id, label: label(number: number, section: sections[equation.blockID]), markup: markup)
            }
        }
        return await withTaskCancellationHandler { await load.value } onCancel: { load.cancel() }
    }

    /// "Equation (4)"; without a number, "Equation · 3.2 Method" (its section), else "Equation".
    nonisolated static func label(number: String?, section: String?) -> String {
        if number != nil { return EquationMarkup.label(number: number) }
        guard let section, !section.isEmpty else { return "Equation" }
        return "Equation · \(section)"
    }

    /// Each block's section: the heading last seen before it in reading order.
    nonisolated static func sections(of index: ReaderBundleIndex) -> [String: String] {
        let titles = Dictionary(index.headings.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var current: String?, result: [String: String] = [:]
        for block in index.blocks {
            if let title = titles[block.id] { current = title }
            if let current { result[block.id] = current }
        }
        return result
    }
}

/// A figure or table: its number in bold and its caption after a dash, on two lines at most.
private struct CaptionEntry: View {
    let number: String
    let caption: String
    var body: some View {
        (Text(number).fontWeight(.semibold) + Text(caption.isEmpty ? "" : " — \(caption)").foregroundColor(.secondary))
            .font(.body).lineLimit(2).multilineTextAlignment(.leading)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row in every tab: its name, then (for figures, tables and equations) a muted line or two.
private struct ContentsEntry: View {
    let title: String
    let detail: String?
    var strong = false
    /// The section being read: a bar at its leading edge and the title in the accent colour.
    var reading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let name = Text(title).font(strong || reading ? .body.weight(.semibold) : .body).multilineTextAlignment(.leading)
            if reading { name.foregroundStyle(Color.accentColor) } else { name }
            if let detail {
                Text(detail).font(.subheadline)
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if reading { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2).offset(x: -10) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
