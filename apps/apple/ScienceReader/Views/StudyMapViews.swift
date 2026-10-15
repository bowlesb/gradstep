import SwiftUI
import ScienceReaderCore

/// Study (experimental, 2026-10-14): the knowledge map a study builds, above the message box. One line (what the
/// tutor is doing, how much is mapped) with the map itself in a sheet: a flowchart, the journey, the concepts.
struct StudyMapBar: View {
    @Bindable var model: ReaderModel
    let map: StudyMap
    @State private var showMap = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap").foregroundStyle(.tint).accessibilityHidden(true)
            // Three short lines: the phone has no room for the summary beside the title.
            VStack(alignment: .leading, spacing: 1) {
                Text("Knowledge map").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(map.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("chat.study.summary")
                Text(nowText).font(.caption).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("chat.study.now")
            }
            Spacer(minLength: 4)
            Button("View") { showMap = true }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                .disabled(map.concepts.isEmpty).accessibilityIdentifier("chat.study.view")
            Menu {
                Button("End study", systemImage: "xmark.circle") { model.endStudy() }
            } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Study options") }
            .menuStyle(.button).buttonStyle(.plain).disabled(model.isAnswering).accessibilityIdentifier("chat.study.options")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .chromeSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), outlined: true)
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat.study.bar")
        .sheet(isPresented: $showMap) { StudyMapSheet(model: model, map: map).macSheetKeys() }
    }

    private var nowText: String {
        if let focus = map.focusConcept { return "Now: \(focus.label) · \(map.next.text)" }
        return map.next.text
    }
}

/// The map in full: Map (a Mermaid flowchart drawn on device), Journey (the order explored), Concepts (each with its
/// state, the tutor's note and the paper's paragraphs).
struct StudyMapSheet: View {
    @Bindable var model: ReaderModel
    let map: StudyMap
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var view: Section = .map
    @State private var drawingFailed = false
    enum Section: String, CaseIterable { case map = "Map", journey = "Journey", concepts = "Concepts" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $view) { ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8).accessibilityIdentifier("chat.study.sections")
                Text(nowText).font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
                switch view {
                case .map:
                    if drawingFailed {
                        ContentUnavailableView("Couldn’t draw the map", systemImage: "exclamationmark.triangle", description: Text("The journey and concepts are still here."))
                    } else {
                        MermaidWebView(source: map.mermaid, dark: colorScheme == .dark) { drawingFailed = true }
                            .id("\(map.mermaid)\(colorScheme)").accessibilityIdentifier("chat.study.canvas")
                    }
                case .journey: journey
                case .concepts: concepts
                }
                legend
            }
            .navigationTitle("Knowledge map").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("End study") { model.endStudy(); dismiss() }.disabled(model.isAnswering) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var nowText: String {
        if let focus = map.focusConcept { return "Now: \(focus.label) · \(map.next.text)" }
        return map.next.text
    }

    private var journey: some View {
        ScrollView {
            FlowLayout(spacing: 6) {
                ForEach(Array(map.journey.enumerated()), id: \.offset) { index, id in
                    if let concept = map.concept(id) {
                        HStack(spacing: 4) {
                            if index > 0 { Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
                            StudyChip(text: concept.label, state: concept.state)
                        }
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("chat.study.journey")
    }

    private var concepts: some View {
        List(map.concepts, id: \.id) { concept in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StudyChip(text: concept.state.text, state: concept.state)
                    Text(concept.label).font(.body.weight(.semibold))
                    if concept.id == map.focus { Text("now").font(.caption).foregroundStyle(.tint) }
                }
                if let note = concept.note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
                ForEach(map.links.filter { $0.from == concept.id }, id: \.to) { link in
                    if let other = map.concept(link.to) { Text("\(link.kind.text) \(other.label)").font(.caption).foregroundStyle(.secondary) }
                }
                if !concept.paragraphs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(concept.paragraphs, id: \.self) { paragraph in
                            Button("¶\(paragraph)") { model.goToCitedBlock(paragraph); dismiss() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.mini)
                                .accessibilityLabel("Go to paragraph \(paragraph)")
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain).accessibilityIdentifier("chat.study.concepts")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(StudyMap.State.allCases, id: \.self) { state in
                    HStack(spacing: 4) { Circle().fill(state.fill).stroke(state.stroke).frame(width: 9, height: 9); Text("\(state.text) · \(map.count(state))") }
                }
            }
            if view == .map { Text("solid: builds on · dotted: goes deeper · line: related · thick border: now") }
        }
        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
    }
}

private struct StudyChip: View {
    let text: String
    let state: StudyMap.State
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color(white: 0.1)).padding(.horizontal, 9).padding(.vertical, 3)
            .background(state.fill, in: Capsule()).overlay(Capsule().stroke(state.stroke, lineWidth: 1)).lineLimit(1)
    }
}

extension StudyMap.State {
    var fill: Color {
        switch self { case .unknown: Color(red: 0.98, green: 0.89, blue: 0.88); case .learning: Color(red: 1, green: 0.95, blue: 0.8)
        case .known: Color(red: 0.86, green: 0.91, blue: 0.98); case .verified: Color(red: 0.86, green: 0.95, blue: 0.89) }
    }
    var stroke: Color {
        switch self { case .unknown: Color(red: 0.75, green: 0.22, blue: 0.17); case .learning: Color(red: 0.84, green: 0.54, blue: 0.06)
        case .known: Color(red: 0.18, green: 0.44, blue: 0.82); case .verified: Color(red: 0.12, green: 0.56, blue: 0.31) }
    }
}

/// Wraps its children into rows (the journey's chips).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
