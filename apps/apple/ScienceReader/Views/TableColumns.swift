import SwiftUI

// Column choices for the app's tables (owner feedback, build 16 #3 and build 17: "choose which columns to show and also
// allow horizontal scrolling"; "Table still sucks, why are there so few options"). The Library keeps its own settings
// type (`LibraryColumnSettings`); the Feed and All chats use `ColumnChoice` and `ColumnChooserSheet`.

/// The words every column chooser uses.
enum TableColumnWording {
    /// A chosen column that doesn't fit the width beside the others.
    static let scrolls = "Scroll sideways to see it"

    static func footer(_ width: LibraryColumnSettings.WidthClass) -> String {
        width == .compact
            ? "For iPhone; iPad keeps its own columns. When the columns are wider than the screen, they scroll sideways and the title stays in place."
            : "For iPad and Mac; iPhone keeps its own columns. When the columns are wider than the window, they scroll sideways and the title stays in place."
    }
}

/// The reader's columns for one table, kept on the device separately for iPhone and for iPad/Mac (by device kind, so
/// rotating a phone never swaps sets). Unknown names (a column a later build removed) are ignored; no saved value means
/// the defaults.
struct ColumnChoice<Column: CaseIterable & RawRepresentable & Hashable & Sendable>: Equatable, Sendable where Column.RawValue == String {
    let key: String
    let compactDefault: Set<Column>
    let regularDefault: Set<Column>
    var compact: Set<Column>
    var regular: Set<Column>

    init(key: String, compactDefault: Set<Column>, regularDefault: Set<Column>) {
        self.key = key; self.compactDefault = compactDefault; self.regularDefault = regularDefault
        compact = compactDefault; regular = regularDefault
    }

    func defaults(_ width: LibraryColumnSettings.WidthClass) -> Set<Column> { width == .compact ? compactDefault : regularDefault }

    subscript(width: LibraryColumnSettings.WidthClass) -> Set<Column> {
        get { width == .compact ? compact : regular }
        set { if width == .compact { compact = newValue } else { regular = newValue } }
    }

    static func load(key: String, compactDefault: Set<Column>, regularDefault: Set<Column>, from defaults: UserDefaults) -> Self {
        var choice = Self(key: key, compactDefault: compactDefault, regularDefault: regularDefault)
        for width in LibraryColumnSettings.WidthClass.allCases {
            guard let saved = defaults.string(forKey: key + "." + width.rawValue) else { continue }
            choice[width] = Set(saved.split(separator: ",").compactMap { Column(rawValue: String($0)) })
        }
        return choice
    }

    func save(to defaults: UserDefaults) {
        for width in LibraryColumnSettings.WidthClass.allCases {
            let names = Column.allCases.filter(self[width].contains).map(\.rawValue)
            defaults.set(names.joined(separator: ","), forKey: key + "." + width.rawValue)
        }
    }
}

/// A table's options › Columns: the title row (always shown), a toggle per column with what it shows (or that it
/// scrolls sideways when it doesn't fit), the columns that always show, and Restore defaults. Changes apply at once.
struct ColumnChooserSheet: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        let explanation: String
    }

    /// "feed.columns": toggles are "<prefix>.<column>", plus "<prefix>.restore" and "<prefix>.done".
    let identifier: String
    let titleRow: (title: String, detail: String)
    let options: [Option]
    /// Columns that always show, with what they show ("Add").
    var fixed: [(title: String, detail: String)] = []
    @Binding var chosen: Set<String>
    let defaults: Set<String>
    /// Chosen columns that scroll sideways at the table's current width.
    let scrolling: Set<String>
    let footer: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    fixedRow(titleRow.title, titleRow.detail)
                    ForEach(options) { option in
                        Toggle(isOn: Binding(get: { chosen.contains(option.id) },
                                             set: { on in if on { chosen.insert(option.id) } else { chosen.remove(option.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(chosen.contains(option.id) && scrolling.contains(option.id) ? TableColumnWording.scrolls : option.explanation)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("\(identifier).\(option.id)")
                    }
                    ForEach(fixed, id: \.title) { fixedRow($0.title, $0.detail) }
                } footer: {
                    Text(footer)
                }
                Section {
                    Button("Restore defaults") { chosen = defaults }
                        .disabled(chosen == defaults)
                        .accessibilityIdentifier("\(identifier).restore")
                }
            }
            .navigationTitle("Columns").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("\(identifier).done") }
            }
        }
        .presentationDetents([.medium, .large])
        .macSheetKeys()
    }

    private func fixedRow(_ title: String, _ detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Always shown").font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
