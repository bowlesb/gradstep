import LocalAI
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
                        Label { VStack(alignment: .leading, spacing: 3) {
                            Text("Use default")
                            Text(defaultLocal.map { "\(local.name($0)) (local)" } ?? (model.chatProfileTable?.label(defaultProfile.model) ?? defaultProfile.model.label)).font(.caption).foregroundStyle(.secondary)
                            if let reason = defaultUnavailableReason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        } } icon: { Image(systemName: "checkmark.circle") }
                    }
                    .disabled(!defaultAvailable).accessibilityIdentifier("ai.chooseDefault")
                    NavigationLink {
                        List {
                            ChatChoiceControls(model: model, mode: chat ? .chat : .choice(useCase))
                            Button("Use \(model.chatProfileTable?.label(cloudChoice.model) ?? cloudChoice.model.label)") {
                                if !chat { model.pendingAIChoice = cloudChoice }
                                select(nil)
                            }.disabled(model.chatProfileTable == nil || model.chatProfilesRefreshing)
                                .accessibilityIdentifier("ai.chooseCloud")
                        }.navigationTitle("Cloud models").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("Cloud", systemImage: "cloud") }
                    .accessibilityIdentifier("ai.cloudOptions")
                    NavigationLink {
                        List {
                            let installed = local.models.filter { local.installed.contains($0.id) && (!needsVision || $0.vision) }
                            if installed.isEmpty {
                                Text(needsVision ? "Download a model that reads figures in Settings → Local models." : "Download a model in Settings → Local models.")
                                    .foregroundStyle(.secondary).accessibilityIdentifier("ai.noLocalModels")
                            }
                            ForEach(installed) { option in
                                let available = option.admitsCurrentMemory(hasImage: needsVision)
                                Button { select(option.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(option.name) (local)")
                                        if !available { Text(option.memoryExplanation).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.disabled(!available).accessibilityIdentifier("ai.chooseLocal.\(option.id)")
                            }
                            NavigationLink("Manage downloads in Settings") { LocalAISettingsView(model: model) }
                                .accessibilityIdentifier("ai.manageModels")
                        }.navigationTitle("Local models").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("Local", systemImage: "iphone") }
                    .accessibilityIdentifier("ai.localOptions")
                } footer: { Text("Cloud models use AI credits. Downloaded local models work offline without AI credits.") }
            }
            .navigationTitle("Choose model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            if !initialized { initialized = true; if !chat { model.pendingAIChoice = nil } }
            model.refreshChatProfiles(force: true); await local.refresh()
        }
        .onDisappear { if !chat, !selectionMade { model.pendingAIChoice = nil; model.pendingLocalAIChoice = nil } }
        .frame(minWidth: Platform.isMac ? 480 : nil, minHeight: Platform.isMac ? 500 : nil)
    }

    private func select(_ id: String?) {
        selectionMade = true
        if !chat { model.pendingLocalAIChoice = .some(id) }
        choose(id); dismiss()
    }

    private var defaultAvailable: Bool { defaultUnavailableReason == nil }
    private var defaultUnavailableReason: String? {
        if let id = defaultLocal {
            guard let option = local.models.first(where: { $0.id == id }) else { return "This model is no longer available. Choose another model." }
            if needsVision && !option.vision { return "This default reads text only. Choose a model that reads figures." }
            if !local.installed.contains(id) { return "Download this model in Settings → Local models, or choose another model." }
            if !option.admitsCurrentMemory(hasImage: needsVision) { return option.memoryExplanation }
            return nil
        }
        if model.chatProfilesRefreshing { return "Loading cloud models…" }
        return model.chatProfileTable == nil ? "Cloud models couldn’t load. Open Cloud to retry." : nil
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

/// Public model files are managed here independently of a question or the phone's transient free-memory state.
struct LocalAISettingsView: View {
    @Bindable var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var memoryRevision = 0
    private var local: LocalAIController { model.localAI }

    var body: some View {
        List {
            Section {
                Text("Download ahead of time, then choose a local model when asking a question. Your paper, question and images stay on this device during inference.")
                Text("Experimental: these small models made mistakes on equations and numerical plots. Check their answers against the paper.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let bytes = LocalModel.availableAppMemory {
                    LabeledContent("Available to this app now", value: Self.size(bytes))
                    Button("Check memory again") { memoryRevision += 1 }
                }
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
            Section("Device testing") {
                LabeledContent("iPhone 17 Pro", value: "Controls tested in Simulator")
                Text("Local inference has not been measured on a physical iPhone, including iPhone 17 Pro. No iPhone model is certified yet. Available app memory, rather than the phone’s total RAM, decides which model can run.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("M1 Max Mac · 32 GB", value: "All four models ran")
                Text("The performance notes above come from this Mac. They are not iPhone speed or battery estimates. Qwen 3.5 4B gave the most useful explanations in this small test, but none passed every scientific question.")
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
            return admitsCurrentMemory(hasImage: vision) ? "Enough app memory available now. Phone performance is unverified."
                : "Cannot run now: \(required) free app memory required; \(free) available. A download can be kept for later."
        }
        return "Mac inference measured; iPhone inference unverified."
    }
    var measuredPerformance: String {
        switch id {
        case "qwen35-4b": "Mac: first text in 5.6–6.8 seconds; answers in 14.5–16.9 seconds. Peak process memory about 6.7 GB. Useful mechanism explanations, but some plot values were wrong."
        case "gemma4-e2b": "Mac: first text in 7.4–8.2 seconds; answers in 10.1–11.6 seconds. Peak process memory about 6.7 GB. Missed numerical figure details and some equation meanings."
        case "qwen35-2b": "Mac: about 3.85 GB peak process memory. More practical memory use, but it misread plot values and an equation parameter. Phone speed has not been measured."
        default: "Text-only baseline. It ran quickly on Mac but failed the tested equation explanation and overstated an unsupported compute claim. Not suitable for reading figures."
        }
    }
}
