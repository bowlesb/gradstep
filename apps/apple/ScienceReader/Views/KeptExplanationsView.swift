import SwiftUI
import ScienceReaderCore

/// Settings › Your assets › Equation explanations / Figure explanations (owner, build 62): the explanations kept on this
/// device, newest first, each equation or figure once, with its paper. A row opens the paper at that equation or figure,
/// where the kept explanation shows without a new request.
struct KeptExplanationsView: View {
    enum Kind { case equations, figures }
    @Bindable var model: ReaderModel
    let kind: Kind
    @State private var missing: ExplanationSubject?

    private var subjects: [ExplanationSubject] { kind == .equations ? model.keptEquationExplanations : model.keptFigureExplanations }
    private var title: String { kind == .equations ? "Equation explanations" : "Figure explanations" }

    var body: some View {
        List {
            ForEach(subjects, id: \.rowID) { subject in
                Button {
                    if !model.openExplanation(subject) { missing = subject }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(subject.label.isEmpty ? (kind == .equations ? "Equation" : "Figure") : subject.label)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(subject.paperTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        Text(subject.savedAt, format: .relative(presentation: .named)).font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("explanations.\(kind == .equations ? "equation" : "figure").\(subject.itemID)")
            }
        }
        .overlay {
            if subjects.isEmpty {
                ContentUnavailableView(kind == .equations ? "No equation explanations" : "No figure explanations",
                                       systemImage: kind == .equations ? "function" : "photo",
                                       description: Text(kind == .equations ? "Equations you ask the AI Explainer about are kept on this device."
                                                                            : "Figures you ask the AI Explainer about are kept on this device."))
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshKeptExplanations() }
        .alert("This paper isn’t on this device", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })) {
            Button("OK", role: .cancel) { missing = nil }
        } message: {
            Text("“\(missing?.paperTitle ?? "")” isn’t in your library here, so its \(kind == .equations ? "equation" : "figure") can’t be opened.")
        }
        .tabBarSpace(color: .chromeGroupedBackground)
    }
}

private extension ExplanationSubject {
    var rowID: String { "\(paperID.uuidString)/\(itemID)" }
}
