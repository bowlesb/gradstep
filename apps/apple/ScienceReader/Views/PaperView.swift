import SwiftUI
import PDFKit
import WebKit
import ScienceReaderCore

/// Reading state for one immutable document artifact. It contains no paper text. Kept per
/// account on this device (ReadingActivityStore), never sent to the server.
struct PaperReadingLocation: Equatable {
    let blockIndex: Int?
    let blockFraction: Double
    let blockHeight: Double
    let scrollY: Double
    /// 0…1 through the document at this position, when the reader reported it.
    var progress: Double? = nil

    fileprivate func adjusted(by delta: Double) -> Self {
        Self(blockIndex: blockIndex, blockFraction: blockFraction + delta / max(1, blockHeight),
             blockHeight: blockHeight, scrollY: max(0, scrollY + delta), progress: progress)
    }
}

struct PaperJumpRequest: Equatable, Identifiable {
    enum Target: Equatable {
        /// A Contents entry: the heading goes to the top of the page.
        case heading
        /// The figure gallery's "Show in paper": the figure is centered and highlighted, with Back.
        case figure
        /// "Go to figure" from a figure reference ("Fig. 1" in the text): a figure, table or algorithm, centered and
        /// highlighted, with Back to the reference.
        case referencedFigure
        /// Contents › Equations: a display equation, centered and highlighted, with Back.
        case equation
    }
    let id = UUID()
    let locationKey: String
    /// The heading's ID, or the figure's for `.figure`.
    let headingID: String
    var target: Target = .heading
}

struct PaperHeading: Equatable, Identifiable {
    let id: String
    let title: String
    /// Steps below the shallowest heading shown in Contents (0…3), from its level or, where Mathpix flattened the
    /// levels, its section number (reader-bridge.js, CONTENTS OUTLINE).
    var depth: Int = 0
}

private struct PaperLoadIdentity: Hashable {
    let scope: ReaderDocumentScope
    let revision: UUID
}

/// A bibliography entry the reader tapped (reader-bridge.js): its text as shown, the best
/// link it names, and where it is on screen (to anchor the actions).
/// What a tapped reference's edit menu offers.
enum ReferenceAction { case openLink, discuss, add, copy }

struct ReaderReference: Identifiable, Equatable {
    struct Link: Equatable {
        let url: URL
        let title: String
    }

    let id = UUID()
    let title: String
    let text: String
    let link: Link?
    let anchor: CGRect

    /// Accepts only a well-formed message for a block of this verified bundle.
    init?(message body: [String: Any], bundle: VerifiedReaderBundle, viewport: CGSize) {
        guard body["manifest_sha256"] as? String == bundle.manifestSHA256, let block = body["block_id"] as? String,
              bundle.index.blocks.contains(where: { $0.id == block }),
              let raw = body["text"] as? String, raw.utf8.count <= 16_000 else { return nil }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if let number = body["number"] as? Int, (0...99_999).contains(number) { title = "Reference \(number)" }
        else if let label = body["label"] as? String, (1...24).contains(label.count) { title = "Reference \(label)" }
        else { title = "Reference" }
        self.text = text
        let hrefs = (body["links"] as? [String] ?? []).prefix(8)
        link = Self.link(in: text, hrefs: Array(hrefs))
        let rect = body["rect"] as? [String: Double] ?? [:]
        let values = ["x", "y", "width", "height"].map { rect[$0] ?? 0 }
        let bounds = CGRect(origin: .zero, size: viewport)
        anchor = values.allSatisfy(\.isFinite)
            ? CGRect(x: values[0], y: values[1], width: max(1, values[2]), height: max(1, values[3])).intersection(bounds) : .null
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The entry's best destination: its arXiv paper, then its DOI, then a web address.
    static func link(in text: String, hrefs: [String]) -> Link? {
        let lowered = text.lowercased()
        if lowered.contains("arxiv") || lowered.contains("corr") {
            for match in text.matches(of: #/(\d{2})(\d{2})\.(\d{4,5})(v\d{1,3})?(?!\d)/#) {
                let before = match.range.lowerBound == text.startIndex ? nil : text[text.index(before: match.range.lowerBound)]
                guard before.map({ !$0.isNumber && $0 != "." }) ?? true,
                      let year = Int(match.output.1), let month = Int(match.output.2), year >= 7, (1...12).contains(month) else { continue }
                let id = "\(match.output.1)\(match.output.2).\(match.output.3)\(match.output.4 ?? "")"
                if let url = URL(string: "https://arxiv.org/abs/" + id) { return Link(url: url, title: "Open on arXiv") }
            }
        }
        if let match = text.firstMatch(of: #/\b(10\.\d{4,9}/[^\s"<>]+)/#) {
            var doi = String(match.output.1)
            while let last = doi.last, ".,;:]".contains(last) || (last == ")" && doi.filter({ $0 == "(" }).count < doi.filter({ $0 == ")" }).count) {
                doi.removeLast()
            }
            if let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://doi.org/" + path) {
                return Link(url: url, title: "Open DOI")
            }
        }
        let candidates = hrefs + text.matches(of: #/https://[^\s<>"]+/#).map { String($0.output) }
        for candidate in candidates {
            var value = candidate
            while let last = value.last, ".,;:)]".contains(last) { value.removeLast() }
            guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil else { continue }
            return Link(url: url, title: "Open link")
        }
        return nil
    }
}

/// A figure, table or algorithm the text refers to ("Fig. 1", "Table 2"), tapped in the paper (reader-bridge.js,
/// FIGURE REFERENCES): shown with its caption and "Go to figure" (owner feedback, build 21).
struct ReaderFigureReference: Identifiable, Equatable {
    let id = UUID()
    /// The element shown: one of the bundle's figures, or one of its table or code blocks.
    let targetID: String
    /// "Figure 3", "Table 2", "Algorithm 1".
    let label: String

    /// Accepts only a well-formed message naming a figure, table or code block of this verified bundle.
    init?(message body: [String: Any], bundle: VerifiedReaderBundle) {
        guard body["manifest_sha256"] as? String == bundle.manifestSHA256, let target = body["id"] as? String,
              bundle.index.figures.contains(where: { $0.id == target })
                || bundle.index.blocks.contains(where: { $0.id == target && ($0.kind == "table" || $0.kind == "code") }),
              let label = body["label"] as? String, label.wholeMatch(of: /(?:Figure|Table|Algorithm) [A-Z0-9][A-Za-z0-9.]{0,9}/) != nil
        else { return nil }
        targetID = target
        self.label = label
    }

    /// The action that goes to it in the paper.
    var goTitle: String { label.hasPrefix("Table") ? "Go to table" : label.hasPrefix("Algorithm") ? "Go to algorithm" : "Go to figure" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct PaperView: View {
    @Bindable var model: ReaderModel
    @State private var showContents = false
    @State private var showReaderVersion = false
    @State private var selection: ReaderSelection?
    @State private var readerFailed = false
    @State private var reloadID = UUID()
    @State private var selectionClearID = UUID()
    @State private var figure: String?
    @State private var showFigures = false
    /// "Show in paper" from the gallery, applied once the gallery has closed.
    /// Where Contents goes once its sheet has closed.
    @State private var contentsJump: (PaperJumpRequest.Target, String)?
    @State private var figureToShow: String?
    @State private var loadingPaper = true
    /// After following a citation: offer "Back" to the place left.
    @State private var citationBack = false
    @State private var citationReturnID: UUID?
    /// Where Back goes (the section left), from the bridge; empty when unknown.
    @State private var citationOrigin = ""
    /// Ends the offer without going back (the X beside Back).
    @State private var citationDismissID: UUID?
    /// One silent reload after the web content process died (owner, build 44: a swipe on Back ended on "Couldn't open").
    @State private var crashReloads = 0
    @State private var reference: ReaderReference?
    @State private var authorToSearch: String?
    /// A figure reference tapped in the text, shown in a sheet; "Go to figure" is applied once the sheet has closed.
    @State private var figureReference: ReaderFigureReference?
    /// The figure reference's sheet: half height, the full height for a walkthrough.
    @State private var figureReferenceDetent: PresentationDetent = .medium
    @State private var figureReferenceToShow: String?
    /// The equation view (docs/architecture/EQUATION_VIEW.md) and what it asked for as it closed (a paragraph, the chat).
    @State private var equation: EquationViewRequest?
    @State private var equationFollowUp: EquationViewOutcome?
    /// A new value shows WebKit's find bar over the paper ("Find in paper", ⌘F).
    @State private var findRequestID: UUID?
    @State private var find = PaperFindController()
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    /// One step of a Contents entry's indent.
    @ScaledMetric(relativeTo: .body) private var contentsIndent = 18.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    /// In the wide Reader, beside the chat column (which the reader can hide).
    @Environment(\.readerChatColumn) private var besideChat
    /// iPad and Mac (the wide layout): line width and reading mode apply (READING_MODE.md).
    @Environment(\.wideReader) private var wideReader
    /// Inside reading mode: the quiet bar replaces the toolbar and the bottom controls.
    @Environment(\.readingModeActive) private var readingActive

    private var readingKey: String? {
        guard let paper = model.selectedPaper else { return nil }
        return "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")/\(paper.readerBundle?.manifestSHA256 ?? "unverified")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.selectedPaper, let bundle = paper.readerBundle, let readingKey, let readerScope = model.readerDocumentScope {
                    // Floating chrome (2026-10-07): the tab bar and the reader's controls float on a band below the
                    // page, which fades its last lines. The page itself stops above them: reading positions,
                    // heading and citation jumps are measured in the page's own viewport, which must be what shows.
                    Group {
                        readerHooks(PaperWebView(url: bundle.entryURL, bundle: bundle, locationKey: readingKey,
                                     location: model.paperLocations[readingKey],
                                     fontSize: model.paperFontSize * bodySize / 17, lineWidth: model.paperLineWidth, jump: model.paperJump,
                                     reduceMotion: reduceMotion, selectionClearID: selectionClearID, onLoading: {
                                         if model.readerDocumentScope == readerScope { loadingPaper = $0 }
                                     },
                                     onLocation: { key, location in
                                         // The section being read, for reading mode's bar and J / K (every paper).
                                         if model.readerDocumentScope == readerScope { model.noteReadingPosition(location, paperID: paper.id) }
                                         // A sign-out clears the selection and the account's transient state.
                                         guard model.readerSessionID == readerScope.sessionID, model.selectedPaper?.id == paper.id else { return }
                                         model.recordReadingLocation(location, key: key, documentID: paper.id)
                                     }, onJumpApplied: { id in
                                         if model.paperJump?.id == id { model.paperJump = nil }
                                     },
                                     onSelection: {
                                         if model.readerDocumentScope == readerScope { selection = $0 }
                                     }, onHeadings: {
                                         if model.readerDocumentScope == readerScope { model.headings = $0 }
                                     }, onFigure: {
                                         if model.readerDocumentScope == readerScope {
                                             #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                             OfflineResourceProbe.shared.begin(.figure)
                                             #endif
                                             figure = $0
                                         }
                                     }, onFailure: {
                                         if model.readerDocumentScope == readerScope {
                                             readerFailed = true; selection = nil; model.headings = []; citationBack = false; reference = nil
                                             figureReference = nil
                                         }
                                     }, onReady: {
                                         #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                         if model.readerDocumentScope == readerScope { OfflineResourceProbe.shared.finish(.readerReady) }
                                         #endif
                                     }, paperLine: paper.publicationLine, paperTags: LibraryTags.tags(for: paper), paperTagSource: paper.tagsCustomized ? "Your keywords" : "Gradstep · on this device",
                                     onTags: { if model.readerDocumentScope == readerScope { model.editTags(for: paper) } },
                                     citationReturnID: citationReturnID, onCitation: { active, origin in
                                         if model.readerDocumentScope == readerScope { citationBack = active; citationOrigin = active ? origin : "" }
                                     },                                     onReference: { value in
                                         if model.readerDocumentScope == readerScope { reference = value }
                                     }, onFigureReference: { value in
                                         if model.readerDocumentScope == readerScope { figureReference = value }
                                     }, onMenuAction: { action, chosen in
                                         // The edit menu's action on what was selected when it was chosen.
                                         guard model.readerDocumentScope == readerScope else { return }
                                         if action == .define, chosen.parts.count == 1, let id = chosen.parts.first?.equationID {
                                             equation = EquationViewRequest(paperID: paper.id, equationID: id, chats: true)
                                         } else { model.selectionAction(action, selection: chosen, scope: readerScope) }
                                         selection = nil; selectionClearID = UUID()
                                     }, hasSelection: selection != nil, onEquation: { id in
                                         guard model.readerDocumentScope == readerScope else { return }
                                         equation = EquationViewRequest(paperID: paper.id, equationID: id, explains: true)
                                         selection = nil; selectionClearID = UUID()
                                     }, findRequestID: findRequestID, marks: model.paperMarks(for: paper), onMarks: { ids in
                                         if model.readerDocumentScope == readerScope { model.openMarkedConversations(ids) }
                                     }, passage: model.passageJump(for: paper), onPassage: { id, found in
                                         if model.readerDocumentScope == readerScope { model.finishPassage(id, found: found) }
                                     }, onKey: { key in
                                         guard model.readerDocumentScope == readerScope else { return }
                                         switch key {
                                         case "next": model.stepSection(1)
                                         case "previous": model.stepSection(-1)
                                         // Esc in reading mode: the chat slide-over first, then reading mode itself.
                                         default: if model.readingChatShown { model.readingChatShown = false } else if model.readingMode { model.exitReadingMode() }
                                         }
                                     }), scope: readerScope)
                            .id(PaperLoadIdentity(scope: readerScope, revision: reloadID))
                            .overlay(alignment: .topLeading) { referenceActions }
                    }
                    .modifier(PassageChooser(model: model))
                    .overlay { if readerFailed {
                        ContentUnavailableView { Label("Couldn’t open this paper", systemImage: "doc.badge.ellipsis") }
                            description: { Text("The reading bundle couldn’t be loaded completely.") }
                            actions: { Button("Try again") { readerFailed = false; loadingPaper = true; reloadID = UUID() } }
                            .background(Color(uiColor: .systemBackground))
                    } }
                    .overlay { if loadingPaper { ProgressView("Preparing…").allowsHitTesting(false) } }
                    .background { findShortcut }
                    // Over the page, not beside it: the page's viewport never changes as they come and go (a shrinking
                    // viewport moved the reading position near the end of a paper).
                    .overlay(alignment: .bottom) { bottomControls(scope: readerScope) }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if find.isPresented { PaperFindBar(find: find) }
                        if let run = model.deviceModelRun, run.paperID == paper.id { DeviceModelProgressBar(run: run) { model.cancelDeviceModelReading() } }
                        else if let issue = model.deviceModelIssue { DeviceModelIssueBar(issue: issue) { model.deviceModelIssue = nil } }
                        else if model.isModelReading(paper), !readerFailed {
                            DeviceModelBanner(summary: model.shownDeviceModelSummary, report: { model.beginReport() }, showHTML: { model.showHTMLReading() })
                        }
                    }
                    // A− / A+ (build 16 #6), at the bottom right over the page's fade; not while a reference's
                    // outcome spans the bottom. "Back to where you were" sits at the left of the same row.
                    .overlay(alignment: .bottomTrailing) {
                        if showsTextSize {
                            HStack(spacing: 8) {
                                // Line width beside A− / A+ where the column can grow (READING_MODE.md).
                                if wideReader {
                                    LineWidthMenu(selection: $model.paperLineWidth).chromeSurface(Capsule(), interactive: true)
                                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                }
                                TextSizeControl(identifier: "paper.textSize", canShrink: model.paperFontSize > 14, canGrow: model.paperFontSize < 26,
                                                shrink: { model.paperFontSize = max(14, model.paperFontSize - 1) },
                                                grow: { model.paperFontSize = min(26, model.paperFontSize + 1) })
                            }
                            .padding(.trailing, Self.textSizeInset).padding(.bottom, 8)
                        }
                    }
                    // Reading mode's quiet bar over the top of the paper (the toolbar steps aside).
                    .overlay(alignment: .top) {
                        if readingActive {
                            ReadingTopBar(model: model, title: paper.title, forced: citationBack, contents: { showContents = true },
                                          figures: bundle.index.figures.isEmpty || readerFailed || loadingPaper ? nil : { showFigures = true })
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: citationBack)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection == nil)
                    .macPaperMenu(PaperMenuActions(
                        contents: { showContents = true },
                        back: citationBack && !readerFailed ? { citationBack = false; citationOrigin = ""; citationReturnID = UUID() } : nil,
                        backTitle: citationOrigin.isEmpty ? "Back to Where You Were" : "Back to \(citationOrigin)",
                        dismissBack: citationBack && !readerFailed ? { citationBack = false; citationOrigin = ""; citationDismissID = UUID() } : nil,
                        selection: selection == nil ? nil : { runSelectionAction($0, scope: readerScope) },
                        // Paper › Figures (audit 2026-10-15: never wired since the menu was added, so always greyed out).
                        figures: model.selectedPaper?.readerBundle?.index.figures.isEmpty == false && !readerFailed && !loadingPaper ? { showFigures = true } : nil))
                } else if let selected = model.selectedPaper {
                    if let run = model.deviceModelRun, run.paperID == selected.id {
                        VStack { DeviceModelProgressBar(run: run) { model.cancelDeviceModelReading() }.frame(maxWidth: 520); Spacer() }
                    } else if model.openingPaperID == model.selectedPaper?.id {
                        // One fraction, two words (owner, 2026-10-15): "Downloading… 37%", then "Preparing… 94%".
                        if let fraction = model.openingProgress {
                            ProgressView(value: fraction) { Text("\(ArxivHTMLReader.phase(for: fraction)) \(Int((fraction * 100).rounded(.down)))%").monospacedDigit() }
                                .frame(maxWidth: 260).padding(.horizontal, 24)
                                .accessibilityLabel("\(ArxivHTMLReader.phase(for: fraction)) \(Int((fraction * 100).rounded(.down))) percent")
                                .accessibilityIdentifier("paper.openingLocalCopy")
                        } else {
                            ProgressView("Preparing…").accessibilityIdentifier("paper.openingLocalCopy")
                        }
                    } else if let issue = model.readerOpenIssue {
                        // One screen whatever stopped the reader (owner, build 62: "there should be just one — with the pdf
                        // option and the on device option"; "remove the try again"): the paper's PDF, or the on-device model
                        // reading it. Only when arXiv was busy or unreachable is Try again the useful action.
                        let network = model.readerOpenFallback == .none
                        ContentUnavailableView {
                            Label(network ? "Couldn’t reach arXiv" : "Read this paper as its PDF", systemImage: network ? "wifi.exclamationmark" : "doc.richtext")
                        }
                            description: {
                                Text(network ? issue : model.readerOpenFallback == .pdfOnly ? "arXiv has no web version of this paper."
                                     : "Its web version couldn’t be prepared on this device.")
                            }
                            actions: {
                                if network {
                                    Button("Try again") { model.retryOpeningSelectedPaper() }.buttonStyle(.borderedProminent)
                                } else {
                                    if model.isDownloadingPDF(selected) {
                                        ProgressView("Downloading PDF…").accessibilityIdentifier("paper.downloadingPDF")
                                    } else {
                                        Button { model.openPDF(selected) } label: { Label("Open PDF", systemImage: "doc.text") }
                                            .buttonStyle(.borderedProminent).accessibilityIdentifier("paper.openPDF")
                                    }
                                    // The experiment (docs/architecture/DEVICE_PDF_ROUTE.md): fetches the PDF first when needed.
                                    if model.deviceModelAvailable {
                                        Button { model.readPDFWithDeviceModel(selected) } label: {
                                            Label("Read with the on-device model", systemImage: "cpu")
                                        }
                                        .buttonStyle(.bordered).disabled(model.deviceModelRun != nil || model.isDownloadingPDF(selected))
                                        .accessibilityIdentifier("deviceModel.tryFromIssue")
                                        Text("Experimental").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let code = model.readerOpenCode, model.readerOpenFallback != .pdfOnly {
                                    InfoButton(text: "\(issue)\n\nCode: \(code)", identifier: "paper.openIssueInfo")
                                }
                                if let issue = model.deviceModelIssue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                            }
                    } else {
                        ContentUnavailableView { Label("Reading copy needed", systemImage: "arrow.down.document") }
                            description: { Text("This paper’s reading copy isn’t on this device yet.") }
                            actions: { Button("Download") { model.retryOpeningSelectedPaper() } }
                    }
                } else {
                    ContentUnavailableView("Open a paper", image: GradstepSymbol.paper, description: Text("Choose a paper from your library to start reading."))
                }
            }
            .tabBarSpace(fade: false)
            .navigationTitle("Paper").navigationBarTitleDisplayMode(.inline)
            .toolbar(readingActive ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showContents = true } label: { Image(GradstepSymbol.contents) }.accessibilityLabel("Table of contents").disabled(model.selectedPaper == nil) }
                ToolbarItem(placement: .principal) { titleView }
                // Reading mode (READING_MODE.md): the paper alone, full screen on the Mac (its View menu has ⇧⌘R).
                if wideReader && !readingActive && model.canEnterReadingMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.enterReadingMode() } label: { Image(systemName: "book") }
                            .accessibilityLabel("Reading mode").accessibilityIdentifier("paper.readingMode")
                            .help("Reading mode (⇧⌘R)")
                            .modifier(ReadingModeShortcut())
                    }
                }
                if besideChat && model.readerChatHidden {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.readerChatHidden = false } label: { Image(GradstepSymbol.chat) }
                            .accessibilityLabel("Show chat").accessibilityIdentifier("paper.showChat")
                    }
                }
                // Screen options (docs/DESIGN.md): "…" is the rightmost item; view choices first,
                // then this screen's actions, then "Report this screen".
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // One row: smaller A, larger A.
                        ControlGroup {
                            MenuRow("Smaller text", systemImage: "textformat.size.smaller") { model.paperFontSize = max(14, model.paperFontSize - 1) }
                                .disabled(model.paperFontSize <= 14)
                            MenuRow("Larger text", systemImage: "textformat.size.larger") { model.paperFontSize = min(26, model.paperFontSize + 1) }
                                .disabled(model.paperFontSize >= 26)
                        }
                        .controlGroupStyle(.compactMenu)
                        if besideChat {
                            MenuRow(model.readerChatHidden ? "Show chat" : "Hide chat", systemImage: "sidebar.right") {
                                model.readerChatHidden.toggle()
                            }.accessibilityIdentifier("paper.chatColumn")
                        }
                        MenuRow("Find in paper", systemImage: "magnifyingglass") { showFind() }.accessibilityIdentifier("paper.find")
                            .disabled(!canFind)
                        if model.selectedPaper?.readerBundle?.index.figures.isEmpty == false {
                            MenuRow("Figures", systemImage: "photo.on.rectangle") { showFigures = true }
                                .accessibilityIdentifier("paper.figures").disabled(readerFailed || loadingPaper)
                        }
                        // The experimental on-device model (docs/architecture/DEVICE_PDF_ROUTE.md), when this paper's PDF is here.
                        if let paper = model.selectedPaper, model.deviceModelAvailable, model.hasDeviceModelPDF(paper) {
                            if model.isModelReading(paper) {
                                MenuRow("Show the HTML reading", systemImage: "doc.richtext") { model.showHTMLReading() }
                                    .accessibilityIdentifier("paper.htmlReading")
                                MenuRow("Read again with the on-device model", systemImage: "cpu") { model.readWithDeviceModel(paper, again: true) }
                                    .disabled(model.deviceModelRun != nil)
                            } else {
                                MenuRow("Read with the on-device model", systemImage: "cpu") { model.readWithDeviceModel(paper) }
                                    .disabled(model.deviceModelRun != nil).accessibilityIdentifier("paper.deviceModel")
                            }
                        }
                        MenuRow("Ask about this paper", systemImage: GradstepSymbol.chat) { model.askAboutSelectedPaper() }
                        if let paper = model.selectedPaper {
                            PodcastListenMenuRow(model: model, paper: paper)
                            PaperShareMenu(paper: paper)
                            Button("Find similar papers", systemImage: "doc.text.magnifyingglass") { model.findSimilarPapers(paper) }
                        }
                        // Its saved chats (owner request 2026-10-07: "a paper's own conversations when you open it").
                        if let paper = model.selectedPaper, let count = model.paperChatCounts[paper.id], count > 0 {
                            Button { model.openAllChats(paper: paper.id, thisPaper: true) } label: {
                                Label { Text("Chats about this paper"); Text(ChatHistoryFormat.count(shown: count, total: count)) }
                                    icon: { menuIcon(GradstepSymbol.chats) }
                            }
                            .accessibilityIdentifier("paper.chats")
                        }
                        if let paper = model.selectedPaper, !paper.isSample {
                            MenuRow("Edit tags", systemImage: "tag") { model.editTags(for: paper) }
                        }
                        // The reader's version for this paper, and Update when a newer one is here (owner, build 62).
                        if let paper = model.selectedPaper, paper.readerBundle?.manifest.source.kind == "arxiv-html" {
                            MenuRow("Reader version details", systemImage: "info.circle") { showReaderVersion = true }
                                .accessibilityIdentifier("paper.readerVersion")
                        }
                        MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Paper options")
                }
            }
            .confirmationDialog(authorToSearch ?? "Author", isPresented: Binding(get: { authorToSearch != nil }, set: { if !$0 { authorToSearch = nil } }), titleVisibility: .visible) {
            if let name = authorToSearch {
                Button("Find papers by \(name)") {
                    model.discoveryQuery = "author:" + name; model.searchExternal = true; model.tab = .library; model.runDiscovery(); authorToSearch = nil
                }
            }
        }
        .sheet(isPresented: $showContents, onDismiss: {
                // After the sheet has gone, as the gallery does, so the jump is seen.
                if case let (target, id)? = contentsJump, let readingKey { model.paperJump = PaperJumpRequest(locationKey: readingKey, headingID: id, target: target) }
                contentsJump = nil
                applyFigureOutcome()
            }) {
                PaperContentsSheet(headings: model.headings, bundle: model.selectedPaper?.readerBundle, baseFontSize: model.paperFontSize) { target, id in
                    contentsJump = (target, id)
                    showContents = false
                }
                .environment(\.figureViewHost, figureHost { showContents = false })
                .macSheetKeys()
            }
            .sheet(item: $model.presentedExplainer, onDismiss: {
                applyFigureOutcome()
                if let outcome = equationFollowUp { equationFollowUp = nil; model.applyEquationOutcome(outcome) }
            }) { presentation in
                let subject = presentation.subject
                if subject.action == "equation" {
                    EquationView(model: model, request: EquationViewRequest(paperID: subject.paperID, equationID: subject.itemID)) { outcome in
                        equationFollowUp = outcome; model.presentedExplainer = nil
                    }
                } else if let context = model.figureContext(paperID: subject.paperID, figureID: subject.itemID) {
                    NavigationStack {
                        FigureExplainView(model: model, context: context, requesting: false, finish: { outcome in
                            model.pendingFigureOutcome = outcome; model.presentedExplainer = nil
                        }, close: { model.presentedExplainer = nil })
                    }
                }
            }
            .sheet(isPresented: $showReaderVersion) {
                if let paper = model.selectedPaper { ReaderVersionSheet(model: model, paper: paper).macSheetKeys() }
            }
            .sheet(isPresented: $showFigures, onDismiss: {
                // After the gallery has gone, so the jump and its highlight are seen.
                if let id = figureToShow, let readingKey { model.paperJump = PaperJumpRequest(locationKey: readingKey, headingID: id, target: .figure) }
                figureToShow = nil
                applyFigureOutcome()
            }) {
                if let bundle = model.selectedPaper?.readerBundle {
                    FigureGalleryView(bundle: bundle, baseFontSize: model.paperFontSize) { id in
                        figureToShow = id; showFigures = false
                    }
                    .environment(\.figureViewHost, figureHost { showFigures = false })
                    .macSheetKeys()
                }
            }
            // A figure reference ("Fig. 1"): the figure, table or algorithm with its caption, half height so the paper
            // stays in view; "Go to figure" goes there with Back once the sheet has gone.
            .sheet(item: $figureReference, onDismiss: {
                if let id = figureReferenceToShow, let readingKey {
                    model.paperJump = PaperJumpRequest(locationKey: readingKey, headingID: id, target: .referencedFigure)
                }
                figureReferenceToShow = nil
                applyFigureOutcome()
            }) { value in
                NavigationStack {
                    Group {
                        if let bundle = model.selectedPaper?.readerBundle {
                            // A figure or a table gets Explain in Chat and AI Explainer (an algorithm's code block, neither).
                            FigureWebView(bundle: bundle, figureID: value.targetID, baseFontSize: model.paperFontSize)
                                .figurePageActions(figureID: value.targetID) { figureReference = nil }
                        }
                        else { Color.clear.sheetTopRow(close: { figureReference = nil }) }
                    }
                    .toolbar {
                        // Words, not a symbol (a bottom-bar Label shows only its icon on iOS 26).
                        ToolbarItem(placement: .bottomBar) {
                            Button(value.goTitle) { figureReferenceToShow = value.targetID; figureReference = nil }
                                .accessibilityIdentifier("figureReference.go")
                        }
                    }
                }
                .presentationDetents([.medium, .large], selection: $figureReferenceDetent).presentationDragIndicator(.visible)
                .onAppear { figureReferenceDetent = .medium }
                .environment(\.expandSheet) { figureReferenceDetent = .large }
                .environment(\.figureViewHost, figureHost { figureReference = nil })
                .macSheetKeys()
            }
            // The equation view: large, sized and scrolled as the reader likes, each symbol described. A symbol's
            // paragraph or Ask in chat is applied once the sheet has gone.
            .sheet(item: $equation, onDismiss: {
                if let followUp = equationFollowUp { model.applyEquationOutcome(followUp) }
                equationFollowUp = nil
            }) { request in
                EquationView(model: model, request: request) { outcome in equationFollowUp = outcome; equation = nil }
                    .macSheetKeys()
            }
            .sheet(isPresented: Binding(get: { figure != nil }, set: { if !$0 { figure = nil } }), onDismiss: applyFigureOutcome) {
                NavigationStack {
                    Group {
                        if let figure, let bundle = model.selectedPaper?.readerBundle, let scope = model.readerDocumentScope {
                            FigureWebView(bundle: bundle, figureID: figure, baseFontSize: model.paperFontSize, onReady: {
                                #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                if model.readerDocumentScope == scope, self.figure == figure { OfflineResourceProbe.shared.finish(.figure) }
                                #endif
                            })
                            .figurePageActions(figureID: figure) { self.figure = nil }
                        }
                        else { Color.clear.sheetTopRow(close: { self.figure = nil }) }
                    }
                }
                .environment(\.figureViewHost, figureHost { figure = nil })
                .macSheetKeys()
            }
        }
        .onChange(of: model.readerDocumentScope) { _, _ in
            selection = nil; figure = nil; showContents = false; readerFailed = false; showFigures = false; figureToShow = nil
            citationBack = false; reference = nil; model.referenceNotice = nil; figureReference = nil; figureReferenceToShow = nil
            loadingPaper = model.selectedPaper?.readerBundle != nil
        }
        // Settings › Your assets › an explanation: its equation or figure once its paper shows (ReaderModel.openExplanation),
        // after the reset above; the kept answer shows there without a new request.
        .task(id: "\(model.pendingExplanation?.paperID.uuidString ?? "")/\(model.pendingExplanation?.itemID ?? "")/\(model.readerDocumentScope?.manifestSHA256 ?? "")") {
            guard let subject = model.pendingExplanation, let paper = model.selectedPaper, paper.id == subject.paperID,
                  let bundle = paper.readerBundle, model.readerDocumentScope != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, model.pendingExplanation == subject else { return }
            model.pendingExplanation = nil
            let earlier = "This explanation was made for an earlier copy of this paper. Open the \(subject.action.hasPrefix("equation") ? "equation" : "figure") to explain it again."
            if subject.action.hasPrefix("equation") {
                if bundle.index.equations.contains(where: { $0.id == subject.itemID }) { equation = EquationViewRequest(paperID: paper.id, equationID: subject.itemID) }
                else { model.error = earlier }
            } else if model.figureContext(paperID: paper.id, figureID: subject.itemID) != nil { figure = subject.itemID }
            else { model.error = earlier }
        }
    }

    // MARK: - Figure view

    /// The open paper's figure pages: what they choose is kept on the model while their sheet closes.
    private func figureHost(close: @escaping @MainActor () -> Void) -> FigureViewHost? {
        guard let paperID = model.selectedPaper?.id else { return nil }
        let model = model
        return FigureViewHost(model: model, paperID: paperID, finish: { outcome in model.pendingFigureOutcome = outcome; close() }, close: close)
    }

    /// What a figure page chose, once its sheet has gone (so the jump, the chat or the sign-in is seen).
    private func applyFigureOutcome() {
        guard let outcome = model.takeFigureOutcome() else { return }
        switch outcome {
        case .figure(_, let id): if let readingKey { model.paperJump = PaperJumpRequest(locationKey: readingKey, headingID: id, target: .figure) }
        case .paragraph(let paperID, let marker): model.goToCitedBlock(marker, paperID: paperID)
        case .askInChat(let context, let part): model.askAboutFigure(context, part: part)
        case .signIn: model.openSignIn()
        case .continueChat: model.tab = .chat; model.wideMode = .reader; model.readerChatHidden = false; model.requestComposerFocus()
        }
    }

    // MARK: - Find in paper

    /// WebKit's find bar searches the open paper (docs/LEGACY_GAP_AUDIT.md #7). It only highlights and scrolls;
    /// the page's text and blocks are unchanged, so selections and reading positions keep working.
    private var canFind: Bool { model.selectedPaper?.readerBundle != nil && !readerFailed && !loadingPaper }

    private func showFind() {
        guard canFind else { return }
        selection = nil; selectionClearID = UUID()
        findRequestID = UUID()
    }

    /// ⌘F with a hardware keyboard on iPad (the Mac's Edit menu has its own Find in Paper).
    @ViewBuilder private var findShortcut: some View {
        if !Platform.isMac {
            Button("Find in paper") { showFind() }.keyboardShortcut("f").disabled(!canFind)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    /// A− / A+ shows unless the paper failed or is loading, or a reference's outcome spans the bottom.
    private var showsTextSize: Bool { !readerFailed && !loadingPaper && model.referenceNotice == nil && !readingActive }
    /// A− / A+'s distance from the trailing edge, and its width (two 44 pt buttons and a hairline; the control keeps
    /// its size at every text size). Back keeps clear of it on the same row.
    private static let textSizeInset: CGFloat = 12
    private static let textSizeWidth: CGFloat = 89

    /// The reader's floating bottom controls (a reference's outcome; Back after a jump, at the left of the A− / A+
    /// row), over the paper's fade; with none showing, the fade alone (under the tab bar). The selection actions are
    /// in the edit menu (build 16 #5).
    private func bottomControls(scope: ReaderDocumentScope) -> some View {
        let notice = readerFailed ? nil : model.referenceNotice
        let back = citationBack && !readerFailed
        let explainerBack = model.explainerReturn?.paperID == model.selectedPaper?.id && model.explainerReturn != nil
        // After a chat citation opened the paper: a way back to the conversation, unless the chat is beside the page.
        let chatBack = model.returnToChatAvailable && !readerFailed && !(besideChat && !model.readerChatHidden)
        return VStack(spacing: 8) {
            if let notice { referenceBanner(notice) }
            if back || chatBack || explainerBack {
                HStack(spacing: 8) {
                    if explainerBack, let subject = model.explainerReturn {
                        Button { model.returnToExplainer() } label: {
                            Label("Back to \(subject.label.hasPrefix("Table") ? "Table" : subject.action == "equation" ? "Equation" : "Figure") Explainer", systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                        }.modifier(ReaderControlMaterial()).accessibilityIdentifier("reader.explainer.back")
                    } else if back { citationBackButton; citationDismissButton }
                    if chatBack { chatBackButton }
                }
                .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, showsTextSize ? Self.textSizeInset + Self.textSizeWidth + (wideReader ? 52 : 0) + 12 : 12)
            }
        }
        .padding(.top, notice != nil || back || chatBack || explainerBack ? 6 : 0)
        .padding(.bottom, notice != nil || back || chatBack || explainerBack ? 8 : 0)
        .frame(maxWidth: .infinity)
        .chromeBand(.bottom)
    }

    // MARK: - Citations and references

    /// The outcome of "Add to library" on a reference. Success clears itself; a reference the
    /// server can't identify offers the chat, which searches more widely.
    private func referenceBanner(_ notice: ReaderModel.ReferenceNotice) -> some View {
        let problem = notice.kind == .notFound || notice.kind == .unavailable || notice.kind == .closed
        return StatusBanner(tone: problem ? .problem : .info,
                            systemImage: notice.kind == .working ? "arrow.down.circle" : problem ? "exclamationmark.circle" : "checkmark.circle",
                            message: notice.message, actionsBelow: notice.kind == .notFound, messageID: "reader.reference.notice") {
            if notice.kind == .notFound {
                Button("Ask in chat") { model.referenceNotice = nil; model.selectionAction(.ingest, quote: notice.reference) }
            } else if notice.kind == .unavailable {
                Button("Try again") { Task { await model.addReference(notice.reference) } }
            }
            if notice.kind != .working {
                Button { model.referenceNotice = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                    .accessibilityLabel("Dismiss").tint(.secondary)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .transition(.opacity)
        .task(id: notice.id) {
            guard notice.kind == .added || notice.kind == .present else { return }
            try? await Task.sleep(for: .seconds(6))
            if model.referenceNotice?.id == notice.id { model.referenceNotice = nil }
        }
    }

    /// Floats at the bottom left of the paper after any jump (a citation, a figure, a section of the paper's own
    /// contents, Show in paper, Go to passage) until the reader goes back, scrolls two screens away or returns by
    /// scrolling; returns to the exact place (owner feedback, build 21: "a 'return to reading location' option").
    /// Back to the conversation whose citation opened the paper (owner, 2026-10-15).
    private var chatBackButton: some View {
        Button { model.returnToChat() } label: {
            ViewThatFits(in: .horizontal) {
                Label("Back to chat", systemImage: "bubble.left.and.text.bubble.right").fixedSize()
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right").fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .modifier(ReaderControlMaterial())
        .accessibilityLabel("Back to chat")
        .accessibilityIdentifier("reader.chat.back")
        .transition(.opacity)
    }
    /// The hooks added in build 46, set after construction so the page's long initializer still type-checks.
    private func readerHooks(_ view: PaperWebView, scope: ReaderDocumentScope) -> PaperWebView {
        var hooked = view
        hooked.findController = find
        hooked.citationDismissID = citationDismissID
        hooked.paperAuthors = model.selectedPaper?.authorNames ?? []
        hooked.onAuthor = { name in if model.readerDocumentScope == scope { authorToSearch = name } }
        hooked.onCrash = handleCrash
        hooked.onReferenceAction = { value, action in handleReferenceAction(value, action, scope: scope) }
        return hooked
    }
    /// The web content process died (memory, a swipe that unloaded the page): reload once, quietly; say so the second time.
    private func handleCrash() {
        if crashReloads == 0 { crashReloads += 1; loadingPaper = true; reloadID = UUID() } else { readerFailed = true }
    }
    /// A tapped bibliography entry's chosen action, from the native edit menu beside it.
    private func handleReferenceAction(_ value: ReaderReference, _ action: ReferenceAction, scope: ReaderDocumentScope) {
        guard model.readerDocumentScope == scope else { return }
        switch action {
        case .openLink: if let link = value.link { openURL(link.url) }
        case .discuss: model.discussReference(value.text)
        case .add: Task { await model.addReference(value.text) }
        case .copy: UIPasteboard.general.string = value.text
        }
    }
    /// The X beside Back: the offer goes away without going back (owner, build 44).
    private var citationDismissButton: some View {
        Button {
            citationBack = false; citationOrigin = ""; citationDismissID = UUID()
        } label: {
            Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 40, height: 44).contentShape(Circle())
        }
        .modifier(ReaderControlMaterial())
        .accessibilityLabel("Dismiss Back")
        .accessibilityIdentifier("reader.citation.dismiss")
        .transition(.opacity)
    }
    private var citationBackButton: some View {
        Button {
            citationBack = false; citationOrigin = ""; citationReturnID = UUID()
        } label: {
            // Where it goes when the bridge knows the section left ("Back to 3 Method"); the full words when they fit
            // beside A− / A+; "Back" at large text sizes or in a narrow column.
            ViewThatFits(in: .horizontal) {
                Label(citationOrigin.isEmpty ? "Back to where you were" : "Back to \(citationOrigin)", systemImage: "arrow.uturn.backward").fixedSize()
                Label("Back", systemImage: "arrow.uturn.backward").fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .modifier(ReaderControlMaterial())
        .accessibilityLabel(citationOrigin.isEmpty ? "Back to where you were" : "Back to \(citationOrigin)")
        .accessibilityIdentifier("reader.citation.back")
        .accessibilityHint("Returns to where you were reading")
        .transition(.opacity)
    }

    /// The actions for a tapped reference, anchored to the entry (a popover on iPad). No title row: the entry is in
    /// view beside them (owner feedback, build 21: "Reference at the top of the message isn't needed").
    private var referenceActions: some View {
        GeometryReader { proxy in
            let anchor = reference?.anchor ?? .null
            let rect = anchor.isNull || anchor.isEmpty ? CGRect(x: proxy.size.width / 2, y: proxy.size.height / 2, width: 1, height: 1) : anchor
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .confirmationDialog(reference?.title ?? "Reference", isPresented: Binding(
                    get: { reference != nil }, set: { if !$0 { reference = nil } }), titleVisibility: .hidden, presenting: reference) { value in
                    if let link = value.link {
                        Button(link.title) { openURL(link.url) }
                    }
                    // The paper's chat with the entry quoted in the message box, not sent (build 21).
                    Button("Discuss in chat") { model.discussReference(value.text) }
                    Button("Add to library") { Task { await model.addReference(value.text) } }
                    Button("Copy") { UIPasteboard.general.string = value.text }
                    Button("Cancel", role: .cancel) {}
                }
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }

    /// The paper's title, with "Offline sample" as a small second line rather than a separate band.
    private var titleView: some View {
        VStack(spacing: 0) {
            Text(model.selectedPaper?.title ?? "Paper").font(.subheadline.weight(.semibold)).lineLimit(1)
            if model.selectedPaper?.isSample == true {
                Text("Offline sample").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // Both lines stay inside the bar at large text sizes, as the system's own bar titles do.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// The Mac's Paper menu (Ask About Selection) runs the same action as the edit menu.
    private func runSelectionAction(_ action: SelectionAction, scope: ReaderDocumentScope) {
        guard let selection else { return }
        model.selectionAction(action, selection: selection, scope: scope)
        self.selection = nil; selectionClearID = UUID()
    }
}

struct PaperWebView: UIViewRepresentable {
    let url: URL
    var bundle: VerifiedReaderBundle? = nil
    var figureID: String? = nil
    let locationKey: String
    let location: PaperReadingLocation?
    let fontSize: Double
    /// The text column's measure (READING_MODE.md), applied by the bridge before the first layout and live after.
    var lineWidth: ReaderLineWidth = .comfortable
    let jump: PaperJumpRequest?
    let reduceMotion: Bool
    var selectionClearID: UUID? = nil
    let onLoading: (Bool) -> Void
    let onLocation: (String, PaperReadingLocation) -> Void
    let onJumpApplied: (UUID) -> Void
    let onSelection: (ReaderSelection?) -> Void
    let onHeadings: ([PaperHeading]) -> Void
    let onFigure: (String) -> Void
    var onFailure: () -> Void = {}
    var onReady: () -> Void = {}
    /// One secondary line under the authors (year · venue · source); nil shows none.
    var paperLine: String? = nil
    /// The paper's tags as small chips under that line (docs/architecture/TAGS.md); a tap calls `onTags`.
    var paperTags: [String] = []
    var paperTagSource = "Gradstep"
    var onTags: () -> Void = {}
    var paperAuthors: [String] = []
    var onAuthor: (String) -> Void = { _ in }
    /// A new value returns from a citation jump to the reading position.
    var citationReturnID: UUID? = nil
    /// A new value ends the Back offer in the page without going back.
    var citationDismissID: UUID? = nil
    /// The web content process died: the view reloads once by itself before saying so.
    var onCrash: () -> Void = {}
    /// True while the reader can go back from a citation jump.
    var onCitation: (Bool, String) -> Void = { _, _ in }
    /// A tapped bibliography entry's chosen action (the native edit menu beside the entry).
    var onReferenceAction: ((ReaderReference, ReferenceAction) -> Void)? = nil
    var onReference: (ReaderReference) -> Void = { _ in }
    /// A figure, table or algorithm reference tapped in the text.
    var onFigureReference: (ReaderFigureReference) -> Void = { _ in }
    /// A selection action chosen in the edit menu (selected text, or a tapped equation), with what was selected then.
    var onMenuAction: ((SelectionAction, ReaderSelection) -> Void)? = nil
    /// Text or an equation is selected (the Mac's right-click menu offers the actions only then).
    var hasSelection = false
    /// "Equation" chosen in a tapped equation's menu, with its ID in the bundle (the equation view).
    var onEquation: ((String) -> Void)? = nil
    /// A new value shows the find bar (the paper only; a figure's view has none).
    var findRequestID: UUID? = nil
    var findController: PaperFindController? = nil
    /// Passages with conversations, underlined; a tap on one reports its conversations (PaperPassages.swift).
    var marks: [PaperMark] = []
    var onMarks: ([UUID]) -> Void = { _ in }
    /// Go to passage, applied once the reader is ready; reports whether the passage was found.
    var passage: PaperPassageRequest? = nil
    var onPassage: (UUID, Bool) -> Void = { _, _ in }
    /// J, K and Esc typed in the paper ("next", "previous", "escape"): sections and reading mode.
    var onKey: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    /// One ephemeral (never persisted) store for every reader page: a new store per
    /// page made WebKit start fresh support processes on each open.
    @MainActor static let dataStore = WKWebsiteDataStore.nonPersistent()
    static let bridgeScript = Bundle.main.url(forResource: "reader-bridge", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    @MainActor private static var warm: WKWebView?
    /// J / K / Esc typed in the paper go to the app (the browser's frame shim forwards its own keys; this is the
    /// native page's): sections, and leaving reading mode.
    static let keyScript = """
        addEventListener('keydown', event => {
          const t = event.target;
          if (event.metaKey || event.ctrlKey || event.altKey || (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)))) return;
          const key = {j: 'next', k: 'previous', Escape: 'escape'}[event.key];
          if (key) window.webkit.messageHandlers.reader.postMessage({type: 'key', key});
        }, true);

        """

    /// Starts WebKit's processes once, just after launch, so the first paper
    /// opened doesn't pay for them (~1–3 s measured on the first open).
    @MainActor static func prewarm() {
        guard warm == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warm = web
    }

    func makeUIView(context: Context) -> WKWebView {
        SessionTimeline.shared.record("reader", ["phase": "create"])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let bundle { configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle") }
        let script = Self.bridgeScript
        var info: [String: Any] = [:]
        if let bundle, let indexData = try? JSONEncoder().encode(bundle.index),
           let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any] {
            info = index; info["manifest_sha256"] = bundle.manifestSHA256
            if let figureID { info["figure_id"] = figureID }
        }
        let json = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
        // The line is placed before the first layout, so restoring a position never shifts.
        let line = figureID == nil ? paperLine.flatMap { try? JSONEncoder().encode($0) } : nil
        context.coordinator.appliedPaperLine = line == nil ? nil : paperLine
        let tags = figureID == nil ? try? JSONSerialization.data(withJSONObject: ["names": paperTags, "source": paperTagSource]) : nil
        context.coordinator.appliedPaperTags = tags == nil ? [] : paperTags
        context.coordinator.appliedPaperTagSource = paperTagSource
        context.coordinator.appliedLineWidth = lineWidth
        let authors = (try? JSONEncoder().encode(figureID == nil ? paperAuthors : [])) ?? Data("[]".utf8)
        let prelude = "window.__readerBundleConfig = " + (bundle == nil ? "null" : String(decoding: json, as: UTF8.self)) + ";\n"
            + "window.__readerPaperLine = " + (line.map { String(decoding: $0, as: UTF8.self) } ?? "null") + ";\n"
            + "window.__readerAuthors = " + String(decoding: authors, as: UTF8.self) + ";\n"
            + "window.__readerPaperTags = " + (tags.map { String(decoding: $0, as: UTF8.self) } ?? "null") + ";\n"
            + "window.__readerLineWidth = \"\(lineWidth.rawValue)\";\n"
            + (figureID == nil ? Self.keyScript : "")
        configuration.userContentController.addUserScript(WKUserScript(source: prelude + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "reader")
        let web = ReaderWebView(frame: .zero, configuration: configuration)
        if figureID == nil {
            ReaderWebView.paper = web
            // The edit menu's actions (selected text, a tapped equation); a figure's view has none.
            let coordinator = context.coordinator
            web.menuAction = { [weak coordinator, weak web] action in
                if let coordinator, let web { coordinator.runMenuAction(action, in: web) }
            }
            web.onOpenEquation = { [weak coordinator] id in coordinator?.parent.onEquation?(id) }
            web.onEquationMenuDismissed = { [weak web] id in
                web?.callAsyncJavaScript("window.__scienceReaderClearEquation(id);", arguments: ["id": id], in: nil, in: .defaultClient,
                                         completionHandler: nil)
            }
        }
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.isFindInteractionEnabled = false
        web.findRequested = { [weak web, weak coordinator = context.coordinator] in
            guard let web else { return }; coordinator?.parent.findController?.open(in: web)
        }
        web.findStepped = { [weak coordinator = context.coordinator] backwards in coordinator?.parent.findController?.step(backwards) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.navigationDelegate = context.coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        (web as? ReaderWebView)?.hasSelection = hasSelection
        if context.coordinator.loadedURL != url {
            context.coordinator.ready = false
            context.coordinator.loadedURL = url
            context.coordinator.invalidateLoad()
            SessionTimeline.shared.record("reader", ["phase": "request"])
            if bundle != nil { context.coordinator.navigation = web.load(URLRequest(url: url)) }
            else { context.coordinator.navigation = web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        }
        guard context.coordinator.ready else { return }
        context.coordinator.clearSelectionIfNeeded(in: web)
        context.coordinator.showFindIfNeeded(in: web)
        context.coordinator.returnFromCitationIfNeeded(in: web)
        context.coordinator.applyPaperLine(in: web)
        context.coordinator.applyPaperTags(in: web)
        // Math fit depends on the text size, so refit only when it changes
        // (compared here: WebKit rounds the size it stores).
        if context.coordinator.appliedFontSize != fontSize {
            context.coordinator.appliedFontSize = fontSize
            web.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'; window.__scienceReaderFit?.();",
                                    arguments: ["size": fontSize], in: nil, in: .defaultClient, completionHandler: nil)
        }
        if context.coordinator.appliedLineWidth != lineWidth, figureID == nil {
            context.coordinator.appliedLineWidth = lineWidth
            web.callAsyncJavaScript("window.__scienceReaderSetLineWidth?.(mode);", arguments: ["mode": lineWidth.rawValue],
                                    in: nil, in: .defaultClient, completionHandler: nil)
        }
        context.coordinator.applyJump(in: web)
        context.coordinator.applyPassageWork(in: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.saveFinalLocation(in: web)
        coordinator.parent.findController?.close()
        (web as? ReaderWebView)?.findRequested = nil
        (web as? ReaderWebView)?.findStepped = nil
        web.endEditing(true)
        coordinator.active = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
        web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: PaperWebView
        var loadedURL: URL?
        var ready = false
        var active = true
        var navigation: WKNavigation?
        var appliedFontSize: Double?
        var appliedLineWidth: ReaderLineWidth?
        private var loadingID = UUID()
        private var inFlightJumpID: UUID?
        private var lastJumpID: UUID?
        private var latestLocation: PaperReadingLocation?
        private var sampledOffsetY = 0.0
        private var lastSelectionClearID: UUID?
        private var lastCitationReturnID: UUID?
        var lastCitationDismissID: UUID?
        private var lastFindRequestID: UUID?
        /// After a citation jump the saved place stays where reading left off.
        private var citationActive = false
        var appliedPaperLine: String?
        var appliedPaperTags: [String] = []
        var appliedPaperTagSource = ""
        var passages = PaperPassageState()
        init(_ parent: PaperWebView) {
            self.parent = parent; lastSelectionClearID = parent.selectionClearID; lastCitationReturnID = parent.citationReturnID; lastCitationDismissID = parent.citationDismissID
            lastFindRequestID = parent.findRequestID
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "key":
                if ready, let key = body["key"] as? String, ["next", "previous", "escape"].contains(key) { parent.onKey(key) }
            case "selection":
                guard ready, let bundle = parent.bundle, let (selection, quote) = Self.selection(body["selection"], bundle: bundle) else {
                    parent.onSelection(nil); return
                }
                parent.onSelection(selection)
                // A tapped equation: the edit menu opens beside it (selected text gets WebKit's own).
                if let menu = body["menu"] as? [String: Any], let web = message.webView as? ReaderWebView,
                   selection.parts.count == 1, selection.parts[0].kind == "equation", let equationID = selection.parts[0].equationID,
                   let x = menu["x"] as? Double, let y = menu["y"] as? Double, let width = menu["width"] as? Double,
                   let height = menu["height"] as? Double, [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) {
                    web.presentEquationMenu(quote: quote, rect: CGRect(x: x, y: y, width: max(1, width), height: max(1, height)),
                                            equationID: equationID)
                }
            case "headings":
                if let items = body["items"] as? [[String: Any]], items.count <= 1_000 {
                    let headings = items.compactMap { item -> PaperHeading? in
                        guard let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 2_048,
                              let title = item["title"] as? String, !title.isEmpty, title.utf8.count <= 8_000,
                              let depth = item["depth"] as? Int, (0...3).contains(depth) else { return nil }
                        return PaperHeading(id: id, title: title, depth: depth)
                    }
                    guard headings.count == items.count, Set(headings.map(\.id)).count == headings.count else { return }
                    parent.onHeadings(headings)
                }
            case "figure":
                if ready, let bundle = parent.bundle, body["manifest_sha256"] as? String == bundle.manifestSHA256,
                   let id = body["id"] as? String, bundle.index.figures.contains(where: { $0.id == id }) { parent.onFigure(id) }
            case "invalid": invalidateLoad(); navigation = nil; parent.onLoading(false); parent.onFailure()
            case "position": if ready, let web = message.webView { remember(body, in: web) }
            case "citation":
                guard ready, let state = body["state"] as? String, state == "jumped" || state == "ended" else { return }
                citationActive = state == "jumped" && (body["back"] as? Bool ?? true)
                let origin = (body["from"] as? String ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                parent.onCitation(citationActive, citationActive ? String(origin.prefix(48)) : "")
            case "author":
                guard ready, parent.figureID == nil, let name = body["name"] as? String, parent.paperAuthors.contains(name) else { return }
                parent.onAuthor(name)
            case "tags":
                guard ready, parent.figureID == nil else { return }
                parent.onTags()
            case "reference":
                guard ready, let bundle = parent.bundle, let size = message.webView?.bounds.size,
                      let reference = ReaderReference(message: body, bundle: bundle, viewport: size) else { return }
                // The native edit menu beside the entry (owner, build 44: "a native style popup like Copy").
                if let web = message.webView as? ReaderWebView, let act = parent.onReferenceAction {
                    // Copy first, as in the system's menu for selected text; the link keeps its own name ("Open on arXiv").
                    var actions: [UIMenuElement] = [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in act(reference, .copy) }]
                    if let link = reference.link { actions.append(UIAction(title: link.title, image: UIImage(systemName: "safari")) { _ in act(reference, .openLink) }) }
                    actions.append(UIAction(title: "Add to library", image: UIImage(systemName: "plus.circle")) { _ in act(reference, .add) })
                    actions.append(UIAction(title: "Discuss in chat", image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { _ in act(reference, .discuss) })
                    web.presentReferenceMenu(rect: reference.anchor, actions: actions)
                } else {
                    parent.onReference(reference)
                }
            case "figureref":
                guard ready, parent.figureID == nil, let bundle = parent.bundle,
                      let reference = ReaderFigureReference(message: body, bundle: bundle) else { return }
                parent.onFigureReference(reference)
            case "marks": receiveMarks(body)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active, navigation === self.navigation else { return }
            let load = loadingID
            let location: Any
            if let saved = parent.location {
                location = ["block": saved.blockIndex ?? -1, "fraction": saved.blockFraction, "y": saved.scrollY] as [String: Any]
            } else { location = NSNull() }
            let arguments: [String: Any] = ["size": parent.fontSize, "location": location]
            webView.callAsyncJavaScript("""
                document.documentElement.style.fontSize = size + 'px';
                await window.__scienceReaderReady;
                await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                window.__scienceReaderFit?.();
                if (location) window.__scienceReaderRestore(location);
                return window.__scienceReaderLocation();
                """, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, let webView, self.active, self.loadingID == load else { return }
                    guard case .success(let value) = result, let body = value as? [String: Any] else {
                        self.parent.onLoading(false); self.parent.onFailure(); return
                    }
                    self.ready = true
                    SessionTimeline.shared.record("reader", ["phase": "ready"])
                    self.appliedFontSize = arguments["size"] as? Double
                    self.remember(body, in: webView)
                    self.parent.onLoading(false)
                    self.parent.onReady()
                    self.applyJump(in: webView)
                    self.applyPassageWork(in: webView)
                }
        }

        func applyJump(in web: WKWebView) {
            guard active, ready, inFlightJumpID == nil, let request = parent.jump,
                  request.locationKey == parent.locationKey, request.id != lastJumpID else { return }
            inFlightJumpID = request.id
            let load = loadingID
            let script = switch request.target {
            case .figure: "return window.__scienceReaderShowFigure(id,reduced);"
            case .referencedFigure: "return window.__scienceReaderShowFigure(id,reduced,true);"
            case .equation: "return window.__scienceReaderShowEquation(id,reduced);"
            case .heading: "return window.__scienceReaderJumpToHeading(id,reduced);"
            }
            web.callAsyncJavaScript(script, arguments: ["id": request.headingID, "reduced": parent.reduceMotion],
                                    in: nil, in: .defaultClient) { [weak self, weak web] result in
                    guard let self, let web, self.active, self.loadingID == load else { return }
                    self.inFlightJumpID = nil
                    if case .success(let value) = result, value as? Bool == true {
                        self.lastJumpID = request.id
                        self.parent.onJumpApplied(request.id)
                    }
                    if self.parent.jump?.id != request.id { self.applyJump(in: web) }
                }
        }

        /// A selection message's payload as a selection whose quote the bundle resolves, with that quote.
        static func selection(_ value: Any?, bundle: VerifiedReaderBundle) -> (ReaderSelection, String)? {
            guard let value = value as? [String: Any], JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 100_000,
                  let selection = try? JSONDecoder().decode(ReaderSelection.self, from: data),
                  let quote = try? selection.resolvedQuote(in: bundle), !quote.isEmpty else { return nil }
            return (selection, quote)
        }

        /// An edit-menu action: reads what is selected now (WebKit's menu can open before the debounced selection
        /// report arrives) and runs the action on it.
        func runMenuAction(_ action: SelectionAction, in web: WKWebView) {
            guard active, ready, let bundle = parent.bundle else { return }
            let load = loadingID
            web.callAsyncJavaScript("return window.__scienceReaderSelectionNow();", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.active, self.loadingID == load, case .success(let value) = result,
                      let (selection, _) = Self.selection(value, bundle: bundle) else { return }
                self.parent.onMenuAction?(action, selection)
            }
        }

        func clearSelectionIfNeeded(in web: WKWebView) {
            guard let id = parent.selectionClearID, id != lastSelectionClearID else { return }
            lastSelectionClearID = id
            (web as? ReaderWebView)?.dismissEquationMenu()
            web.callAsyncJavaScript("window.__scienceReaderClearSelection();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func showFindIfNeeded(in web: WKWebView) {
            guard let id = parent.findRequestID, id != lastFindRequestID else { return }
            lastFindRequestID = id
            // After the menu that asked has closed, so the page can take the keyboard focus.
            DispatchQueue.main.async { [weak web] in (web as? ReaderWebView)?.showFind() }
        }

        func returnFromCitationIfNeeded(in web: WKWebView) {
            if let id = parent.citationDismissID, id != lastCitationDismissID {
                lastCitationDismissID = id; citationActive = false
                web.callAsyncJavaScript("return window.__scienceReaderEndCitation();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
            }
            guard let id = parent.citationReturnID, id != lastCitationReturnID else { return }
            lastCitationReturnID = id
            citationActive = false
            web.callAsyncJavaScript("return window.__scienceReaderCitationBack();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        /// Library metadata can arrive or change while the paper is open.
        func applyPaperLine(in web: WKWebView) {
            guard parent.figureID == nil, appliedPaperLine != parent.paperLine else { return }
            appliedPaperLine = parent.paperLine
            web.callAsyncJavaScript("window.__scienceReaderSetPaperLine(line);", arguments: ["line": parent.paperLine ?? NSNull()],
                                    in: nil, in: .defaultClient, completionHandler: nil)
        }

        /// Tags can arrive or change while the paper is open (tagging, an edit on another device).
        func applyPaperTags(in web: WKWebView) {
            guard parent.figureID == nil, appliedPaperTags != parent.paperTags || appliedPaperTagSource != parent.paperTagSource else { return }
            appliedPaperTags = parent.paperTags
            appliedPaperTagSource = parent.paperTagSource
            web.callAsyncJavaScript("window.__scienceReaderSetPaperTags(tags);", arguments: ["tags": ["names": parent.paperTags, "source": parent.paperTagSource]],
                                    in: nil, in: .defaultClient, completionHandler: nil)
        }

        private func remember(_ body: [String: Any], in web: WKWebView) {
            guard let block = body["block"] as? Int, (-1...1_000_000).contains(block),
                  let fraction = body["fraction"] as? Double, fraction.isFinite, abs(fraction) < 1_000_000,
                  let height = body["height"] as? Double, height.isFinite, (1...1_000_000_000).contains(height),
                  let y = body["y"] as? Double, y.isFinite, (0...1_000_000_000).contains(y) else { return }
            let progress = (body["progress"] as? Double).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let location = PaperReadingLocation(blockIndex: block < 0 ? nil : block, blockFraction: fraction, blockHeight: height, scrollY: y,
                                                progress: progress)
            latestLocation = location
            sampledOffsetY = web.scrollView.contentOffset.y
            parent.onLocation(parent.locationKey, location)
        }

        func saveFinalLocation(in web: WKWebView) {
            guard ready, let latestLocation else { return }
            // Include the final scroll movement even if the throttled DOM report is still queued
            // (but not a citation jump: the place to come back to is where reading left off).
            let delta = citationActive ? 0 : (web.scrollView.contentOffset.y - sampledOffsetY) / max(1, web.scrollView.zoomScale)
            parent.onLocation(parent.locationKey, latestLocation.adjusted(by: delta))
        }

        func invalidateLoad() {
            loadingID = UUID(); ready = false; inFlightJumpID = nil; latestLocation = nil; appliedFontSize = nil; citationActive = false
            passages.reset()
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard active, navigation === self.navigation else { return }
            SessionTimeline.shared.record("reader", ["phase": "loading"])
            parent.onLoading(true)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation) }
        private func fail(_ navigation: WKNavigation?) {
            guard active, navigation === self.navigation else { return }
            invalidateLoad(); self.navigation = nil; parent.onLoading(false); parent.onFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard active else { return }
            invalidateLoad(); navigation = nil
            parent.onLoading(false); parent.onCrash()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = navigationAction.request.url else { return .cancel }
            if let bundle = parent.bundle {
                if bundle.permitsNavigation(to: destination), navigationAction.targetFrame?.isMainFrame == true { return .allow }
            } else if destination.isFileURL, let loadedURL,
                      destination.standardizedFileURL.path == loadedURL.standardizedFileURL.path { return .allow }
            if navigationAction.navigationType == .linkActivated, destination.scheme == "https" { await UIApplication.shared.open(destination) }
            return .cancel
        }
    }
}

/// One Contents entry (docs/LEGACY_GAP_AUDIT.md #10; the row is indented by its depth). In a nested outline the
/// top-level sections are semibold, as in the paper's own printed contents.
private struct ContentsRow: View {
    let heading: PaperHeading
    let nested: Bool

    var body: some View {
        Text(heading.title)
            .font(nested && heading.depth == 0 ? .body.weight(.semibold) : .body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct FigureWebView: View {
    let bundle: VerifiedReaderBundle
    let figureID: String
    var baseFontSize: Double = 17
    var onReady: () -> Void = {}
    @State private var failed = false
    @State private var loading = true
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    var body: some View {
        PaperWebView(url: bundle.entryURL, bundle: bundle, figureID: figureID,
                     locationKey: bundle.manifestSHA256 + "/" + figureID, location: nil,
                     fontSize: baseFontSize * bodySize / 17, jump: nil, reduceMotion: true, onLoading: { loading = $0 },
                     onLocation: { _, _ in }, onJumpApplied: { _ in }, onSelection: { _ in },
                     onHeadings: { _ in }, onFigure: { _ in }, onFailure: { failed = true }, onReady: onReady)
            .overlay { if failed { ContentUnavailableView("Couldn’t open figure", systemImage: "photo").background(Color(uiColor: .systemBackground)) }
                else if loading { ProgressView("Opening figure…").allowsHitTesting(false) } }
    }
}

/// A simple native viewer for a PDF that was deliberately kept on this
/// device. It is separate from the verified Mathpix reader: no extracted text
/// or server document is invented for a source-only paper.
struct LocalPDFReaderView: View {
    let presentation: LocalPaperPresentation
    /// The experimental on-device model, when it can read this PDF (docs/architecture/DEVICE_PDF_ROUTE.md).
    var readWithModel: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showContents = false
    @State private var jump: PDFOutlineEntry? = nil
    /// The PDF's own outline (bookmarks), when the file carries one (owner report, build 36: "Table of contents still not
    /// rendering for older PDFs"): the HTML reader's Contents never applied to a PDF kept on the device.
    private var outline: [PDFOutlineEntry] { PDFOutlineEntry.entries(in: presentation.data) }

    var body: some View {
        NavigationStack {
            LocalPDFKitView(data: presentation.data, jump: $jump)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(presentation.title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showContents = true } label: { Image(GradstepSymbol.contents) }
                            .accessibilityLabel("Table of contents").accessibilityIdentifier("pdf.contents")
                    }
                    if let readWithModel {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button(action: readWithModel) { Label("Read with the on-device model (experimental)", systemImage: "cpu") }
                            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("PDF options").accessibilityIdentifier("pdf.options")
                        }
                    }
                }
                .sheet(isPresented: $showContents) {
                    NavigationStack {
                        let entries = outline
                        Group {
                            if entries.isEmpty {
                                ContentUnavailableView("No table of contents", systemImage: "list.bullet.indent",
                                                       description: Text("This PDF has no outline of its own. The reader’s Contents come from a paper’s structured text, which this PDF doesn’t have on this device."))
                            } else {
                                let nested = entries.contains { $0.depth > 0 }
                                List(entries) { entry in
                                    Button { jump = entry; showContents = false } label: {
                                        ContentsRow(heading: PaperHeading(id: entry.id, title: entry.title, depth: entry.depth), nested: nested)
                                    }
                                    .accessibilityValue(nested ? "Level \(entry.depth + 1)" : "")
                                    .padding(.leading, CGFloat(entry.depth) * 16)
                                }
                            }
                        }
                        .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showContents = false } } }
                    }
                    .macSheetKeys()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// One entry of a PDF's outline, flattened in reading order with its depth (at most four levels, 500 entries).
struct PDFOutlineEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
    /// The outline's own index path, so the destination is found again in a fresh document.
    let path: [Int]

    static func entries(in data: Data) -> [PDFOutlineEntry] {
        guard let document = PDFDocument(data: data), let root = document.outlineRoot else { return [] }
        var out: [PDFOutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int, path: [Int]) {
            for index in 0..<node.numberOfChildren {
                guard out.count < 500, let child = node.child(at: index) else { return }
                let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let childPath = path + [index]
                if !title.isEmpty, child.destination != nil { out.append(PDFOutlineEntry(id: childPath.map(String.init).joined(separator: "."), title: String(title.prefix(200)), depth: depth, path: childPath)) }
                if depth < 3 { walk(child, depth: depth + 1, path: childPath) }
            }
        }
        walk(root, depth: 0, path: [])
        return out
    }

    func destination(in document: PDFDocument) -> PDFDestination? {
        var node = document.outlineRoot
        for index in path { node = node?.child(at: index) }
        return node?.destination
    }
}

private struct LocalPDFKitView: UIViewRepresentable {
    let data: Data
    @Binding var jump: PDFOutlineEntry?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil { view.document = PDFDocument(data: data); view.autoScales = true }
        // A Contents entry: go to its destination once, then clear the request.
        if let entry = jump, let document = view.document, let destination = entry.destination(in: document) {
            view.go(to: destination)
            DispatchQueue.main.async { jump = nil }
        }
    }
}
