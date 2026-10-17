import LocalAI
import SwiftUI

/// The same explicit choice before chat, equations and figures. Downloading never submits a question.
struct AIChoiceView: View {
    @Bindable var local: LocalAIController
    let needsVision: Bool
    let choose: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "qwen35-4b"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { choose(nil); dismiss() } label: {
                        Label { VStack(alignment: .leading) { Text("Cloud AI"); Text("Requires credits and an internet connection").font(.caption).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "cloud") }
                    }.accessibilityIdentifier("ai.chooseCloud")
                }
                Section("Local AI · Experimental") {
                    Text("Runs on this device without AI credits after a model download. Small models can misread plots and equations. Uses selected excerpts, not the entire paper.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("Model", selection: $selected) {
                        ForEach(local.models.filter { !needsVision || $0.vision }) { model in
                            Text("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))\(model.vision ? "" : " · text only")").tag(model.id)
                        }
                    }.accessibilityIdentifier("ai.localModel")
                    if let model = local.models.first(where: { $0.id == selected }) {
                        let enoughMemory = model.admitsCurrentMemory(hasImage: needsVision)
                        Text("Requires sufficient free app memory. Phone performance has not been verified; downloads may be too large for some devices.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !enoughMemory {
                            Text("This model needs more app memory than is available now. Choose a smaller model.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link("Model details and license", destination: URL(string: "https://huggingface.co/\(model.repository)")!)
                            .font(.caption)
                        if local.installed.contains(model.id) {
                            Button("Use Local AI") { choose(model.id); dismiss() }.accessibilityIdentifier("ai.chooseLocal")
                                .disabled(!enoughMemory)
                            Button("Remove download", role: .destructive) { Task { await local.remove(model) } }
                                .disabled(local.downloading != nil).accessibilityIdentifier("ai.removeModel")
                        } else if local.downloading == model.id {
                            ProgressView(value: local.fraction) { Text("Downloading \(model.name)") }
                                .accessibilityIdentifier("ai.downloadProgress")
                            Button("Cancel download") { local.cancelDownload() }
                        } else {
                            Button("Download \(model.name)") { local.download(model) }.disabled(local.downloading != nil || !enoughMemory)
                                .accessibilityIdentifier("ai.downloadModel")
                        }
                    }
                    if let issue = local.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("ai.downloadError") }
                    Text("Model files download from Hugging Face. Local inference sends no paper, question or image to an AI provider. Your account’s existing encrypted chat sync is separate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Choose AI").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await local.refresh() }
        .frame(minWidth: Platform.isMac ? 480 : nil, minHeight: Platform.isMac ? 500 : nil)
    }
}

struct AISelectionButton: View {
    let model: ReaderModel
    @State private var choosing = false
    var body: some View {
        Button { choosing = true } label: {
            Label(model.localAIModelID == nil ? "Cloud AI · credits" : "Local AI · \(model.localAI.name(model.localAIModelID))", systemImage: "chevron.down")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ai.selection")
        .sheet(isPresented: $choosing) {
            AIChoiceView(local: model.localAI, needsVision: false) { model.localAIModelID = $0 }
        }
    }
}
