import SwiftUI
import ScienceReaderCore

/// Edit tags (docs/architecture/TAGS.md): the paper's tags as chips (tap × to remove), a field to add
/// any tag, and suggestions from the tag vocabulary and the reader's own tags. A task sheet: Cancel on
/// the left, Save on the right, medium height first.
struct TagEditorView: View {
    @Bindable var model: ReaderModel
    let paper: Paper
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String]
    @State private var draft = ""
    @State private var saving = false
    @State private var issue: String?
    @FocusState private var fieldFocused: Bool
    @ScaledMetric(relativeTo: .subheadline) private var chipHeight = 32.0

    init(model: ReaderModel, paper: Paper) {
        self.model = model; self.paper = paper
        _tags = State(initialValue: LibraryTags.tags(for: paper))
    }

    private var changed: Bool { tags != LibraryTags.tags(for: paper) }
    private var preventsDismissal: Bool { saving || changed || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var ownCount: Int { tags.filter { !PaperTags.contains(paper.catalogTags, $0) }.count }
    private var typed: String? { PaperTags.normalized(draft) }

    /// While typing: the typed text first (unless already chosen), then vocabulary names and the reader's
    /// other tags that match. Otherwise: catalog tags removed here, the paper's categories' names, the
    /// reader's most used tags.
    private var suggestions: [(name: String, detail: String?)] {
        var result: [(name: String, detail: String?)] = []
        func add(_ name: String, _ detail: String?) {
            guard PaperKeywords.allowed(name), !PaperTags.contains(tags, name), !result.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return }
            result.append((name, detail))
        }
        let own = model.ownTagsInLibrary(excluding: paper.id)
        if let typed {
            let query = typed.lowercased()
            for tag in TagVocabulary.suggestions(for: typed, excluding: tags, limit: 6) { add(tag.name, tag.definition) }
            for tag in own where tag.lowercased().contains(query) { add(tag, "Your tag") }
        } else {
            for tag in paper.catalogTags { add(tag, TagVocabulary.tag(named: tag)?.definition) }
            for name in TagVocabulary.names(forCategories: paper.keywords) { add(name, TagVocabulary.tag(named: name)?.definition) }
            for tag in own.prefix(6) { add(tag, "Your tag") }
        }
        return Array(result.prefix(8))
    }

    private func add(_ raw: String) {
        guard let text = PaperTags.normalized(raw) else { return }
        guard PaperKeywords.allowed(text) else { issue = "Choose a specific method, dataset or topic instead of AI or machine learning."; return }
        draft = ""
        if PaperTags.contains(tags, text) { return }
        // Use the vocabulary's spelling when it is a vocabulary tag.
        let name = TagVocabulary.tag(named: text)?.name ?? text
        if paper.sourceMembership != nil && tags.count >= PaperTags.maximumSourceTags {
            issue = "A paper can have up to \(PaperTags.maximumSourceTags) keywords."
            return
        }
        if !PaperTags.contains(paper.catalogTags, name) && ownCount >= PaperTags.maximumOwnTags {
            issue = "A paper can have up to \(PaperTags.maximumOwnTags) tags of your own."
            return
        }
        issue = nil
        tags.append(name)
    }

    private func save() {
        saving = true; issue = nil
        Task {
            let problem = await model.saveTags(tags, for: paper)
            saving = false
            if let problem { issue = problem } else { dismiss() }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if tags.isEmpty {
                        Text("No tags").foregroundStyle(.secondary).accessibilityIdentifier("tags.empty")
                    } else {
                        TagFlow(spacing: 8) {
                            ForEach(tags, id: \.self) { tag in
                                Button { tags.removeAll { $0 == tag }; issue = nil } label: {
                                    HStack(spacing: 6) {
                                        Text(tag).font(.subheadline).lineLimit(1)
                                        Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12).frame(minHeight: chipHeight)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tag).accessibilityHint("Removes this tag")
                                .accessibilityIdentifier("tags.chip.\(tag)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("Tags") }
                Section {
                    TextField("Add a tag", text: $draft)
                        .focused($fieldFocused).submitLabel(.done).autocorrectionDisabled()
                        .onSubmit { add(draft); fieldFocused = true }
                        .accessibilityIdentifier("tags.field")
                    if let typed, !PaperTags.contains(tags, typed), TagVocabulary.tag(named: typed) == nil {
                        suggestionRow(name: typed, detail: nil, title: "Add “\(typed)”")
                    }
                    ForEach(suggestions, id: \.name) { suggestion in
                        suggestionRow(name: suggestion.name, detail: suggestion.detail, title: suggestion.name)
                    }
                    if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("tags.issue")
                    }
                } header: { Text(typed == nil ? "Suggestions" : "Add") }
                footer: {
                    Text(model.canChangeLibrary
                         ? "Suggested tags come from the paper’s title and abstract. Your tags sync to your other devices through Gradstep’s server; they aren’t end-to-end encrypted."
                         : "Tags can be changed once your library is up to date.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Edit tags").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { save() }.disabled(!changed || !model.canChangeLibrary)
                            .accessibilityIdentifier("tags.save")
                    }
                }
            }
            .interactiveDismissDisabled(preventsDismissal)
        }
        .presentationDetents([.medium, .large])
        .macSheetKeys(enabled: !preventsDismissal)
    }

    private func suggestionRow(name: String, detail: String?, title: String) -> some View {
        Button { add(name) } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle").foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(name)")
        .accessibilityIdentifier("tags.suggestion.\(name)")
    }
}

/// Lays chips out in rows, wrapping to the next row when one doesn't fit.
struct TagFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [], current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if !current.indices.isEmpty && current.width + spacing + itemWidth > width {
                rows.append(current); current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
