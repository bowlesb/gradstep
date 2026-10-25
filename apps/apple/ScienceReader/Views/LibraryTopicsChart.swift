import Charts
import ScienceReaderCore
import SwiftUI

/// Library › All: the reader's topics (interest index step 3; owner decision 4, 2026-10-24: "the chart goes at the top of
/// Library › All, collapsible, slices filter"). Under the filter chips, so switching a chip never moves them. One header
/// row ("Topics", the count, the chosen topic, ⓘ, the chevron) and, opened, a thin ring with a legend like Credits by
/// activity: up to eight largest topics coloured by size from the chart palette (or the reader's colour), the rest and the
/// papers outside every topic in a neutral Other whose row opens the smaller topics. A slice or row shows only that
/// topic's papers; again shows everything. Touch and hold a row to rename, recolour or hide its topic. Collapsed or open
/// is remembered (`library.topics.collapsed`).
struct LibraryTopicsSection: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if model.libraryFilter == .all, model.libraryQuery.isEmpty, !model.searchExternal,
           let topics = model.interest.topics, !topics.topics.isEmpty || model.libraryTopicFilter != nil {
            LibraryTopicsChart(model: model, topics: topics)
                .listRowInsets(EdgeInsets(top: 4, leading: DesignMetrics.margin, bottom: 6, trailing: DesignMetrics.margin))
                .listRowSeparator(.hidden)
        }
    }
}

struct LibraryTopicsChart: View {
    @Bindable var model: ReaderModel
    let topics: InterestLibraryTopics
    @State private var selectedAngle: Double?
    @State private var showSmaller = false
    @State private var renaming: InterestTopicSlice?
    @State private var newName = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    static let maximumColoured = 8

    /// The ring's slices: the largest topics, then Other holding the rest (smaller topics and papers outside topics).
    private var rings: (named: [InterestTopicSlice], smaller: [InterestTopicSlice], other: Double) {
        let named = Array(topics.topics.prefix(Self.maximumColoured))
        let smaller = Array(topics.topics.dropFirst(Self.maximumColoured))
        return (named, smaller, smaller.reduce(0) { $0 + $1.share } + (topics.other?.share ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !model.interest.collapsed {
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                layout {
                    ring
                    legend
                }
                .transition(.opacity)
            }
        }
        .alert("Rename topic", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("library.topics.renameField")
            Button("Save") {
                if let slice = renaming { Task { await model.renameTopic(slice.id, to: newName) } }
                renaming = nil
            }
            if renaming?.renamed == true {
                Button("Use “\(renaming?.computedLabel ?? "")”") {
                    if let slice = renaming { Task { await model.renameTopic(slice.id, to: "") } }
                    renaming = nil
                }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Your name shows on your devices instead of the topic’s words.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.topics")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.interest.collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.interest.collapsed ? 0 : 90))
                    Text("Topics").font(.subheadline.weight(.semibold))
                    Text("\(topics.topics.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Topics, \(topics.topics.count)")
            .accessibilityValue(model.interest.collapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(model.interest.collapsed ? "Shows your library’s topics" : "Hides the chart")
            .accessibilityIdentifier("library.topics.toggle")
            if let filter = model.libraryTopicFilter {
                Button { model.libraryTopicFilter = nil } label: {
                    ChipLabel(title: filter.label, selected: true, systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Topic: \(filter.label)")
                .accessibilityHint("Shows all papers")
                .accessibilityIdentifier("library.topics.clear")
            }
            Spacer(minLength: 4)
            InfoButton(text: info, identifier: "library.topics.info")
        }
    }

    private var info: String {
        var lines = ["Your library’s topics, worked out on this device from its arXiv papers and a public map of recent research. "
            + "Each is named by its most distinctive words. Tap a topic to show its papers; touch and hold to rename, recolour or hide it. "
            + "Names, colours and hidden topics reach your other devices the way your notes do."]
        if topics.uploads > 0 { lines.append(topics.uploads == 1 ? "Your uploaded PDF isn’t in topics yet." : "Your \(topics.uploads) uploaded PDFs aren’t in topics yet.") }
        if topics.pending > 0 { lines.append(topics.pending == 1 ? "1 paper you just added joins once it’s ready." : "\(topics.pending) papers you just added join once they’re ready.") }
        if !topics.emerging.isEmpty {
            lines.append("Emerging: " + topics.emerging.map { "\($0.label) (\($0.count))" }.joined(separator: ", ") + ". A third paper makes it a topic.")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Ring

    private struct Wedge: Identifiable {
        let id: Int
        let share: Double
        let colour: Color
    }

    private var wedges: [Wedge] {
        let r = rings
        var out = r.named.map { Wedge(id: $0.id, share: $0.share, colour: Self.color($0.colour)) }
        if r.other > 0 { out.append(Wedge(id: InterestTopicSlice.otherID, share: r.other, colour: Self.color(nil))) }
        return out
    }

    private var ring: some View {
        let selected = model.libraryTopicFilter?.id
        return Chart(wedges) { wedge in
            SectorMark(angle: .value("Share", wedge.share), innerRadius: .ratio(0.72), angularInset: 1)
                .foregroundStyle(wedge.colour)
                .opacity(selected == nil || selected == wedge.id || (selected.map(isSmaller) ?? false) && wedge.id == InterestTopicSlice.otherID ? 1 : 0.3)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, angle in
            guard let angle else { return }
            selectedAngle = nil
            guard let wedge = wedge(at: angle) else { return }
            if wedge.id == InterestTopicSlice.otherID { withAnimation { showSmaller.toggle() } }
            else if let slice = topics.slice(wedge.id) { model.toggleTopicFilter(slice) }
        }
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text("\(topics.indexed)").font(.headline).monospacedDigit()
                Text(topics.indexed == 1 ? "paper" : "papers").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("library.topics.ring")
    }

    private func isSmaller(_ id: Int) -> Bool { rings.smaller.contains { $0.id == id } || id == InterestTopicSlice.otherID }

    private var summary: String {
        let r = rings
        var parts = r.named.map { "\($0.label), \(Self.percent($0.share))" }
        if r.other > 0 { parts.append("Other, \(Self.percent(r.other))") }
        return "Topics: " + parts.joined(separator: "; ")
    }

    private func wedge(at angle: Double) -> Wedge? {
        var end = 0.0
        for wedge in wedges {
            end += wedge.share
            if angle <= end + 1e-9 { return wedge }
        }
        return wedges.last
    }

    // MARK: Legend

    private var legend: some View {
        let r = rings
        let columns = sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize && r.named.count > 4
        return VStack(alignment: .leading, spacing: 0) {
            if columns {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 0) {
                    ForEach(r.named) { topicRow($0) }
                }
            } else {
                ForEach(r.named) { topicRow($0) }
            }
            if r.other > 0 { otherRow(r) }
            if showSmaller {
                ForEach(r.smaller) { topicRow($0, neutral: true) }
                if let other = topics.other, !other.papers.isEmpty { outsideRow(other) }
                ForEach(topics.hidden) { hiddenRow($0) }
            }
        }
        .frame(maxWidth: columns ? 620 : 380, alignment: .leading)
    }

    private func topicRow(_ slice: InterestTopicSlice, neutral: Bool = false) -> some View {
        let selected = model.libraryTopicFilter?.id == slice.id
        return Button { model.toggleTopicFilter(slice) } label: {
            row(swatch: neutral ? Self.color(nil) : Self.color(slice.colour), label: slice.label, count: slice.count,
                share: slice.share, selected: selected, indent: neutral)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(slice) }
        .accessibilityLabel("\(slice.label), \(slice.count) \(slice.count == 1 ? "paper" : "papers"), \(Self.percent(slice.share))")
        .accessibilityValue(selected ? "Shown" : "")
        .accessibilityHint(selected ? "Shows all papers" : "Shows only this topic’s papers")
        .accessibilityIdentifier("library.topics.row.\(slice.id)")
    }

    private func otherRow(_ r: (named: [InterestTopicSlice], smaller: [InterestTopicSlice], other: Double)) -> some View {
        let parts = (r.smaller.isEmpty ? [] : [r.smaller.count == 1 ? "1 smaller topic" : "\(r.smaller.count) smaller topics"])
            + ((topics.other?.count ?? 0) > 0 ? ["\(topics.other!.count) outside topics"] : [])
        let count = r.smaller.reduce(0) { $0 + $1.count } + (topics.other?.count ?? 0)
        return Button { withAnimation(.easeInOut(duration: 0.2)) { showSmaller.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Self.color(nil)).frame(width: 10, height: 10)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("Other").font(.subheadline)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showSmaller ? 180 : 0))
                    }
                    if !parts.isEmpty { Text(parts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                trailing(count: count, share: r.other)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Other, \(parts.joined(separator: ", ")), \(Self.percent(r.other))")
        .accessibilityValue(showSmaller ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("library.topics.other")
    }

    private func outsideRow(_ other: InterestTopicSlice) -> some View {
        let selected = model.libraryTopicFilter?.id == other.id
        let detail = topics.otherGroups.prefix(3).map { "\($0.label) (\($0.count))" }.joined(separator: ", ")
        return Button { model.toggleTopicFilter(InterestTopicSlice(id: other.id, label: "Outside topics", computedLabel: "Outside topics",
                                                                   renamed: false, papers: other.papers, share: other.share, colour: nil,
                                                                   hidden: false, terms: [])) } label: {
            row(swatch: .clear, label: "Outside topics", detail: detail.isEmpty ? nil : detail, count: other.count, share: nil, selected: selected, indent: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.topics.outside")
    }

    private func hiddenRow(_ slice: InterestTopicSlice) -> some View {
        row(swatch: .clear, label: slice.label, detail: "Hidden", count: slice.count, share: nil, selected: false, indent: true)
            .contextMenu {
                Button("Show topic", systemImage: "eye") { Task { await model.setTopicHidden(slice.id, false) } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Show topic") { Task { await model.setTopicHidden(slice.id, false) } }
            .accessibilityIdentifier("library.topics.hidden.\(slice.id)")
    }

    private func row(swatch: Color, label: String, detail: String? = nil, count: Int, share: Double?, selected: Bool, indent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(swatch).frame(width: 10, height: 10)
                .overlay { if swatch == .clear { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5), lineWidth: 1) } }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing(count: count, share: share)
        }
        .padding(.vertical, 3).padding(.leading, indent ? 12 : 0)
        .padding(.horizontal, selected ? 6 : 0)
        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.14)) } }
        .contentShape(Rectangle())
    }

    private func trailing(count: Int, share: Double?) -> some View {
        (Text("\(count)") + Text(share.map { " · \(Self.percent($0))" } ?? "").foregroundStyle(.secondary))
            .font(.subheadline).monospacedDigit()
    }

    @ViewBuilder private func menu(_ slice: InterestTopicSlice) -> some View {
        Button("Rename…", systemImage: "pencil") { newName = slice.renamed ? slice.label : ""; renaming = slice }
        Menu {
            Button("By size") { Task { await model.setTopicColour(slice.id, nil) } }
            ForEach(0 ..< Self.names.count, id: \.self) { slot in
                Button { Task { await model.setTopicColour(slice.id, slot) } } label: {
                    Label { Text(Self.names[slot]) } icon: { Image(systemName: "circle.fill").foregroundStyle(Self.color(slot)) }
                }
            }
        } label: { Label("Colour", systemImage: "paintpalette") }
        Button("Hide topic", systemImage: "eye.slash") { Task { await model.setTopicHidden(slice.id, true) } }
    }

    // MARK: Palette

    static let names = ["Blue", "Orange", "Aqua", "Yellow", "Magenta", "Green", "Violet", "Red"]

    /// The chart palette's eight slots (Credits by activity uses the first four), each with its own dark step; validated
    /// with the dataviz checker for adjacent segments on white and black (docs/DESIGN.md). nil: Other's neutral.
    static func color(_ slot: Int?) -> Color {
        let pairs: [(light: UInt32, dark: UInt32)] = [(0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500),
                                                       (0xE87BA4, 0xD55181), (0x008300, 0x008300), (0x6250D6, 0x9085E9), (0xE34948, 0xE66767)]
        let pair = slot.map { pairs[max(0, min($0, pairs.count - 1))] } ?? (0x8C8A85, 0x6B6A66)
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    /// Whole percent, "<1%" for a sliver.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }
}
