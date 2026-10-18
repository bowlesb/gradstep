#if targetEnvironment(macCatalyst)
import LocalAI
#endif
import ScienceReaderCore
import SwiftUI

/// Choosing an answer never starts a download. Downloads and compatibility live in Settings.
struct AIChoiceView: View {
    @Bindable var model: ReaderModel
    var chat = false
    var scenario: AIUseCase? = nil
    let needsVision: Bool
    let choose: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectionMade = false
    @State private var initialized = false
    @State private var expanded = false
    private var useCase: AIUseCase { scenario ?? model.currentAIUseCase }
    private var defaultProfile: ChatProfileChoice { model.profileDefault(for: useCase) }
    private var defaultLocal: String? { model.localDefault(for: useCase) }
    private var cloudChoice: ChatProfileChoice { chat ? model.chatProfile : model.pendingAIChoice ?? defaultProfile }
    private var local: LocalAIController { model.localAI }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if chat { model.setChatProfile(defaultProfile) } else { model.pendingAIChoice = defaultProfile }
                        select(defaultLocal)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default (\(defaultName))")
                            if let reason = defaultUnavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(!defaultAvailable).accessibilityIdentifier("ai.chooseDefault")
                    NavigationLink {
                        modelChoices.onAppear { expanded = true }.onDisappear { expanded = false }
                    } label: { Label("Choose model", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("ai.chooseModel")
                }
            }
            .navigationTitle("AI model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            if !initialized { initialized = true; if !chat { model.pendingAIChoice = nil } }
            model.refreshChatProfiles(); await local.refresh()
        }
        .onDisappear { if !chat, !selectionMade { model.pendingAIChoice = nil; model.pendingLocalAIChoice = nil } }
        .presentationDetents(expanded ? [.large] : [.height(220)])
        .frame(minWidth: Platform.isMac ? 480 : nil, minHeight: Platform.isMac ? (expanded ? 500 : 220) : nil)
    }

    private var defaultName: String {
        defaultLocal.map { "\(local.name($0)) (local)" } ?? (model.chatProfileTable?.label(defaultProfile.model) ?? defaultProfile.model.label)
    }

    private var modelChoices: some View {
        List {
            ChatChoiceControls(model: model, mode: chat ? .chat : .choice(useCase))
            Button("Use \(model.chatProfileTable?.label(cloudChoice.model) ?? cloudChoice.model.label)") {
                if !chat { model.pendingAIChoice = cloudChoice }
                select(nil)
            }.disabled(model.chatProfileTable == nil || model.chatProfilesRefreshing)
                .accessibilityIdentifier("ai.chooseCloud")
            #if targetEnvironment(macCatalyst)
            Section("On this Mac") {
                let installed = local.models.filter { local.installed.contains($0.id) && (!needsVision || $0.vision) }
                ForEach(installed) { option in
                    Button { select(option.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(option.name) (local)")
                            if !option.admitsCurrentMemory(hasImage: needsVision) {
                                Text(option.memoryExplanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(!option.admitsCurrentMemory(hasImage: needsVision))
                        .accessibilityIdentifier("ai.chooseLocal.\(option.id)")
                }
                NavigationLink("Manage Mac model downloads") { LocalAISettingsView(model: model) }
                    .accessibilityIdentifier("ai.manageModels")
            }
            #endif
        }.navigationTitle("Choose model").navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ id: String?) {
        selectionMade = true
        if !chat { model.pendingLocalAIChoice = .some(id) }
        choose(id); dismiss()
    }

    private var defaultAvailable: Bool { defaultUnavailableReason == nil }
    private var defaultUnavailableReason: String? {
        #if targetEnvironment(macCatalyst)
        if let id = defaultLocal {
            guard let option = local.models.first(where: { $0.id == id }) else { return "This model is no longer available. Choose another model." }
            if needsVision && !option.vision { return "This default reads text only. Choose a model that reads figures." }
            if !local.installed.contains(id) { return "Download this model in Settings → Local models, or choose another model." }
            if !option.admitsCurrentMemory(hasImage: needsVision) { return option.memoryExplanation }
            return nil
        }
        #endif
        if model.chatProfilesRefreshing { return "Loading cloud models…" }
        return model.chatProfileTable == nil ? "Cloud models couldn’t load. Choose a model to retry." : nil
    }
}

struct AISelectionButton: View {
    let model: ReaderModel
    @State private var choosing = false
    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 4) {
                Text(model.currentAIName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ai.selection").accessibilityLabel("Model: \(model.currentAIName)")
        .sheet(isPresented: $choosing) {
            AIChoiceView(model: model, chat: true, needsVision: false) { model.localAIModelID = $0 }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac model installation is separate from questions and current memory admission.
struct LocalAISettingsView: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var memoryRevision = 0
    private var local: LocalAIController { model.localAI }

    var body: some View {
        List {
            Section {
                Text("Download ahead of time, then choose a local model when asking a question. Your paper, question and images stay on this device during inference.")
                Text("Only models that pass our scientific-question and memory checks are offered here.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let bytes = LocalModel.availableAppMemory {
                    LabeledContent("Available to this app now", value: Self.size(bytes))
                    Button("Check memory again") { memoryRevision += 1 }
                }
            }
            if local.models.isEmpty {
                Section("Models under evaluation") {
                    Text("The earlier prototype models have been retired. Replacements are being tested for equation accuracy, figure reading and memory use before downloads become available.")
                    Text("Your saved local answers remain available. Choose a cloud model explicitly to ask a new question.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.accessibilityIdentifier("ai.modelsUnderEvaluation")
            }
            ForEach(local.models) { option in
                Section(option.name) {
                    LabeledContent("Reads", value: option.vision ? "Text and figures" : "Text only")
                    LabeledContent("Download", value: Self.size(Int(option.bytes)))
                    LabeledContent("Free app memory needed", value: Self.size(option.requiredHeadroom(hasImage: option.vision)))
                    Text(option.memoryExplanation).font(.footnote).foregroundStyle(.secondary)
                    if local.installed.contains(option.id) {
                        Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        Menu("Use as default") {
                            ForEach(AIUseCase.allCases.filter { $0 != .figures || option.vision }) { scenario in
                                Button(scenario.title) { model.setLocalDefault(option.id, for: scenario) }
                            }
                        }
                            .disabled(!option.admitsCurrentMemory(hasImage: option.vision))
                            .accessibilityIdentifier("ai.default.\(option.id)")
                        Button("Remove download", role: .destructive) {
                            Task {
                                await local.remove(option)
                                if !local.installed.contains(option.id) {
                                    if model.localAIDefaultModelID == option.id { model.localAIDefaultModelID = nil }
                                    for scenario in AIUseCase.allCases where model.localDefault(for: scenario) == option.id { model.setLocalDefault(nil, for: scenario) }
                                    if model.localAIModelID == option.id { model.localAIModelID = nil }
                                }
                            }
                        }.disabled(local.downloading != nil).accessibilityIdentifier("ai.removeModel.\(option.id)")
                    } else if local.downloading == option.id {
                        ProgressView(value: local.fraction) { Text("Downloading… \(Int(local.fraction * 100))%") }
                            .accessibilityIdentifier("ai.downloadProgress")
                        Button("Cancel download") { local.cancelDownload() }
                    } else {
                        Button("Download") { local.download(option) }.disabled(local.downloading != nil)
                            .accessibilityIdentifier("ai.downloadModel.\(option.id)")
                    }
                    DisclosureGroup("Measured performance and license") {
                        Text(option.measuredPerformance).font(.footnote)
                        Link("Model license", destination: URL(string: "https://huggingface.co/\(option.repository)")!)
                    }
                }
            }
            if let issue = local.issue { Section { Text(issue).foregroundStyle(.red).accessibilityIdentifier("ai.downloadError") } }
            Section("Mac memory") {
                Text("Local answers run on Apple Silicon Macs. Model size, figure resolution and other open apps affect memory use. Availability is checked again before each answer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .id(memoryRevision)
        .navigationTitle("Local models").navigationBarTitleDisplayMode(.inline)
        .task { await local.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { memoryRevision += 1 } }
    }
    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

extension LocalModel {
    var memoryExplanation: String {
        if let available = Self.availableAppMemory {
            let free = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            let required = ByteCountFormatter.string(fromByteCount: Int64(requiredHeadroom(hasImage: vision)), countStyle: .file)
            return admitsCurrentMemory(hasImage: vision) ? "Enough app memory is available now."
                : "Cannot run now: \(required) free app memory required; \(free) available. A download can be kept for later."
        }
        return "Memory availability could not be checked. Try again before starting an answer."
    }
    var measuredPerformance: String {
        "This model must pass the Mac scientific-question and memory evaluation before it is available for download."
    }
}

#endif
