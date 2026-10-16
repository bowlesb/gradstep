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
    struct Equation: Identifiable, Equatable { let id: String; let label: String; let text: String }

    /// The tiles, pushed from the Figures list (owner, build 59: "a link to the same squares based view"); a table with
    /// its whole caption, pushed from the Tables list.
    enum Route: Hashable { case tiles, table(String) }

    let headings: [PaperHeading]
    let bundle: VerifiedReaderBundle?
    var baseFontSize: Double = 17
    let go: (PaperJumpRequest.Target, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents
    @State private var path = NavigationPath()
    @State private var equations: [Equation]? = nil
    /// Half height to start; a figure's walkthrough takes the full height (FIGURE_VIEW.md).
    @State private var detent: PresentationDetent = .medium
    @ScaledMetric(relativeTo: .body) private var indent = 18.0

    private var figures: [GalleryFigure] { bundle.map { GalleryFigure.all(in: $0.index) } ?? [] }
    /// The captioned tables the index lists (revision 16) beside those arXiv published as images, in page order.
    private var tables: [GalleryFigure] { bundle.map { GalleryFigure.tables(in: $0.index) } ?? [] }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, DesignMetrics.margin).padding(.top, 4).padding(.bottom, 8)
                .accessibilityIdentifier("contents.tabs")
                list
            }
            .navigationTitle(tab.rawValue).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: tab) { if tab == .equations, equations == nil { equations = await Self.equations(in: bundle) } }
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
                        FigureGrid(bundle: bundle, figures: figures).navigationTitle("Figures").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    // A table's own view (a table block or one published as an image), its whole caption, Show in paper:
                    // the paper goes to it as to a referenced table, with Back.
                    case .table(let id):
                        GalleryFigureDetail(bundle: bundle, figures: tables, current: id, baseFontSize: baseFontSize,
                                            onShowInPaper: { go(.referencedFigure, $0) }, close: { dismiss() }, noun: "Table")
                    }
                }
            }
        }
        .environment(\.expandSheet) { detent = .large }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .contents:
            let nested = headings.contains { $0.depth > 0 }
            List(headings) { heading in
                Button { go(.heading, heading.id) } label: { ContentsEntry(title: heading.title, detail: nil, strong: nested && heading.depth == 0) }
                    .accessibilityValue(nested ? "Level \(heading.depth + 1)" : "")
                    .padding(.leading, CGFloat(heading.depth) * indent)
            }
            .listStyle(.plain)
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
            }
            .listStyle(.plain)
            .overlay { if wanted.isEmpty { ContentUnavailableView(tab == .tables ? "No tables" : "No figures", systemImage: tab == .tables ? "tablecells" : "photo") } }
            .accessibilityIdentifier("contents.list.\(tab == .tables ? "tables" : "figures")")
        case .equations:
            if let equations {
                List(Array(equations.enumerated()), id: \.element.id) { index, equation in
                    Button { go(.equation, equation.id) } label: { ContentsEntry(title: equation.label, detail: equation.text, strong: true, mathDetail: true) }
                        .accessibilityIdentifier("contents.equation.\(index)")
                }
                .listStyle(.plain)
                .overlay { if equations.isEmpty { ContentUnavailableView("No equations", systemImage: "function") } }
                .accessibilityIdentifier("contents.list.equations")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The paper's display equations in order, numbered as printed, with their LaTeX read as text.
    static func equations(in bundle: VerifiedReaderBundle?) async -> [Equation] {
        guard let bundle else { return [] }
        let display = bundle.index.equations.filter(\.display)
        let html = bundle.data(for: bundle.manifest.entrypoint).flatMap { String(data: $0, encoding: .utf8) }
        return await Task.detached(priority: .userInitiated) {
            display.map { equation in
                // The printed number from the page, else a \tag{…} in the source; labels and number switches aren't shown.
                let tag = equation.latex.firstMatch(of: /\\tag\*?\{([^}]{1,12})\}/).map { "(\($0.output.1))" }
                let number = html.flatMap { EquationMarkup.element(in: $0, equationID: equation.id) }.flatMap(EquationMarkup.number(in:)) ?? tag
                let source = equation.latex.replacing(/\\(label|tag\*?)\{[^}]*\}|\\(nonumber|notag)\b/, with: "")
                return Equation(id: equation.id, label: EquationMarkup.label(number: number), text: String(ChatMathText.plain(source).prefix(160)))
            }
        }.value
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
    var mathDetail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(strong ? .body.weight(.semibold) : .body).multilineTextAlignment(.leading)
            if let detail {
                Text(detail).font(mathDetail ? .system(.subheadline, design: .serif).italic() : .subheadline)
                    .foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
