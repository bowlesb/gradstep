import SwiftUI
import ScienceReaderCore

/// Settings › Your assets › Equation explanations / Figure explanations (owner, build 62) / Paper explanations (the paper's
/// AI Explainer, 2026-10-22): the explanations kept on this device, newest first, each equation, figure or paper once, with
/// its paper. A row opens the paper at that equation or figure, or with its explainer, where the kept explanation shows
/// without a new request.
struct KeptExplanationsView: View {
    enum Kind { case equations, figures, papers }
    @Bindable var model: ReaderModel
    let kind: Kind
    @State private var missing: ExplanationSubject?

    private var subjects: [ExplanationSubject] {
        switch kind { case .equations: model.keptEquationExplanations; case .figures: model.keptFigureExplanations; case .papers: model.keptPaperExplanations }
    }
    private var title: String { switch kind { case .equations: "Equation explanations"; case .figures: "Figure explanations"; case .papers: "Paper explanations" } }
    private var noun: String { switch kind { case .equations: "equation"; case .figures: "figure"; case .papers: "paper" } }

    var body: some View {
        List {
            ForEach(subjects, id: \.rowID) { subject in
                Button {
                    if !model.openExplanation(subject) { missing = subject }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if kind == .papers {
                            Text(subject.paperTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        } else {
                            Text(subject.label.isEmpty ? (kind == .equations ? "Equation" : "Figure") : subject.label)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(subject.paperTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(subject.savedAt, format: .relative(presentation: .named)).font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(kind == .papers ? "explanations.paper.\(subject.paperID.wire)" : "explanations.\(noun).\(subject.itemID)")
            }
        }
        .overlay {
            if subjects.isEmpty {
                ContentUnavailableView("No \(noun) explanations", systemImage: kind == .equations ? "function" : kind == .figures ? "photo" : "doc.text",
                                       description: Text(kind == .papers ? "Papers you open the AI Explainer for are kept on this device."
                                                         : "\(noun.capitalized)s you ask the AI Explainer about are kept on this device."))
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshKeptExplanations() }
        .alert("This paper isn’t on this device", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })) {
            Button("OK", role: .cancel) { missing = nil }
        } message: {
            Text(kind == .papers ? "“\(missing?.paperTitle ?? "")” isn’t in your library here, so its explanation can’t be opened."
                 : "“\(missing?.paperTitle ?? "")” isn’t in your library here, so its \(noun) can’t be opened.")
        }
        .tabBarSpace(color: .chromeGroupedBackground)
    }
}

private extension ExplanationSubject {
    var rowID: String { "\(paperID.uuidString)/\(itemID)" }
}
