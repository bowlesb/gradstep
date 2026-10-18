import SwiftUI
import ScienceReaderCore

enum AIUseCase: String, CaseIterable, Identifiable {
    case general, paper, equations, figures
    var id: Self { self }
    var title: String { switch self {
        case .general: "General chat"
        case .paper: "Paper chat"
        case .equations: "Equation explanations"
        case .figures: "Figures and tables"
    } }
}

struct AIScenarioDefaults: View {
    @Bindable var model: ReaderModel
    let scenario: AIUseCase
    var body: some View {
        Form {
            Section {
                #if targetEnvironment(macCatalyst)
                Picker("Default model", selection: Binding(get: { model.localDefault(for: scenario) ?? "cloud" }, set: {
                    model.setLocalDefault($0 == "cloud" ? nil : $0, for: scenario)
                })) {
                    Text("Cloud").tag("cloud")
                    ForEach(model.localAI.models.filter { (scenario != .figures || $0.vision) && (model.localAI.installed.contains($0.id) || model.localDefault(for: scenario) == $0.id) }) { option in
                        Text("\(option.name) (local)").tag(option.id)
                    }
                }.accessibilityIdentifier("settings.aiScenario.engine")
                #endif
                ChatChoiceControls(model: model, mode: .scenario(scenario))
            } footer: {
                Text("Used when starting \(scenario.title.lowercased()). Existing conversations keep their selected model. You can change it before sending.")
            }
            Section { Button("Use recommended defaults") { model.resetAIDefault(for: scenario) } }
        }.navigationTitle(scenario.title).navigationBarTitleDisplayMode(.inline)
            .task { model.refreshChatProfiles(); await model.localAI.refresh() }
    }
}
