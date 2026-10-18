import SwiftUI

struct AdvancedPaperSearch: View {
    @Bindable var model: ReaderModel
    struct Criterion: Identifiable { let id = UUID(); var field = "title"; var value = "" }
    @State private var expanded = false
    @State private var criteria = [Criterion()]
    var body: some View {
        DisclosureGroup("Search by fields", isExpanded: $expanded) {
            VStack(spacing: 8) {
                ForEach($criteria) { $criterion in
                    HStack {
                        Picker("Field", selection: $criterion.field) {
                            Text("Title").tag("title"); Text("Author").tag("author")
                            Text("Abstract").tag("abstract"); Text("Year").tag("year")
                        }.labelsHidden().pickerStyle(.menu)
                        TextField(criterion.field == "year" ? "2024 or 2020-2026" : "Contains…", text: $criterion.value)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("\(criterion.field) criterion")
                            .onChange(of: criterion.value) { _, value in criterion.value = String(value.prefix(60)).replacingOccurrences(of: "\"", with: "") }
                        if criteria.count > 1 { Button { criteria.removeAll { $0.id == criterion.id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove criterion") }
                    }
                }
                HStack {
                    Button("Add criterion") { criteria.append(Criterion()) }.disabled(criteria.count >= 4)
                    Spacer()
                    Button("Search") {
                        model.discoveryQuery = criteria.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                            .map { "\($0.field):\"\($0.value)\"" }.joined(separator: " ")
                        model.runDiscovery()
                    }.disabled(criteria.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                Text("Results must match all criteria.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.accessibilityIdentifier("library.advancedSearch")
    }
}
