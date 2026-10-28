import SwiftUI

/// More (owner, 2026-10-25: Slack's "a [fourth] icon with the words More, and then if you click you get a screen with the
/// other three options"; docs/proposals/GLOBAL_SEARCH_AND_MORE.md A.4): one inset-grouped list of Feed, Snippets and
/// Settings, each the place's glyph in accent, its one word and a chevron; no descriptions and no badges. Feed and Snippets
/// become the place (no Back: the bar is the way out, and More again returns here); Settings opens over this list.
/// Rows keep the places' `tab.*` identifiers; the list is `more.list`.
struct MoreView: View {
    @Bindable var model: ReaderModel
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 52

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ReaderTab.morePlaces) { place in
                        Button { model.showMorePlace(place) } label: { row(place) }
                            .accessibilityIdentifier("tab.\(String(describing: place))")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 52 pt rows, growing with the text size.
            .environment(\.defaultMinListRowHeight, rowHeight)
            .accessibilityIdentifier("more.list")
            .navigationTitle(ReaderTab.more.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .tabBarSpace(color: .chromeGroupedBackground)
        }
    }

    private func row(_ place: ReaderTab) -> some View {
        HStack(spacing: 14) {
            place.image
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.accentColor, Color.gradstepAmber)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(place.rawValue).foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
