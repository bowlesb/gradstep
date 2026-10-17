import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ScienceReaderCore

public struct LocalInferenceResult: Codable, Sendable {
    public let text: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let seconds: Double
    public let firstTextSeconds: Double?
    public let peakMemoryBytes: Int
    public let paragraphs: [Int]
    public let omittedParagraphs: Int
    public let stoppedAtLimit: Bool
    public let modelLoadSeconds: Double
    public let contextSeconds: Double
    public let prepareSeconds: Double
}

/// No URLSession, server dependency or downloader here. The caller supplies an already verified directory.
/// One generation at a time, fresh prompt/KV cache per request. No account state or retained paper/model context.
public actor LocalEngine {
    private var busy = false
    public init() {}
    public func answer(model: LocalModel, directory: URL, input: LocalAIContext.Input, image: Data? = nil,
                       onText: @escaping @Sendable (String) -> Void) async throws -> LocalInferenceResult {
        guard !busy else { throw LocalAIError.busy }
        guard image == nil || model.vision else { throw LocalAIError.imageUnsupported }
        #if targetEnvironment(simulator) || !arch(arm64)
        throw LocalAIError.unavailable
        #else
        // A snapshot admission check, not a promise that iOS cannot reclaim memory later.
        guard model.admitsCurrentMemory(hasImage: image != nil) else { throw LocalAIError.memory }
        busy = true
        defer { busy = false; Memory.clearCache() }
        Memory.cacheLimit = 128 * 1_024 * 1_024
        Memory.peakMemory = 0
        let began = Date()
        let container: ModelContainer
        if model.vision {
            container = try await VLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        try Task.checkCancellation()
        let loaded = Date()
        let tokenizer = await container.tokenizer
        let template: [String: any Sendable] = ["enable_thinking": false]
        let prompt: LocalAIContext.Prompt
        do {
            // Reserve image tokens separately; the processor's final count below is authoritative.
            prompt = try LocalAIContext.build(input, budget: LocalAIContext.maximumInputTokens - (image == nil ? 0 : 1_100)) { system, user in
                try tokenizer.applyChatTemplate(messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                                                tools: nil, additionalContext: template).count
            }
        } catch LocalAIContext.Failure.cloudOnlyAction { throw LocalAIError.unsupportedAction }
        catch LocalAIContext.Failure.mandatoryInputTooLarge { throw LocalAIError.contextTooLarge }
        let selected = Date()
        var images: [UserInput.Image] = []
        if let image {
            guard let decoded = CIImage(data: image), decoded.extent.width > 0, decoded.extent.height > 0,
                  decoded.extent.width * decoded.extent.height <= 4_000_000 else { throw LocalAIError.imageInvalid }
            images = [.ciImage(decoded)]
        }
        let userInput = UserInput(chat: [.system(prompt.system), .user(prompt.user, images: images)],
                                  processing: .init(resize: CGSize(width: 1_600, height: 1_600), maxPixels: LocalAIContext.maximumImagePixels),
                                  additionalContext: template)
        let prepared = try await container.prepare(input: userInput)
        let count = prepared.text.tokens.size
        guard count <= LocalAIContext.maximumInputTokens else { throw LocalAIError.contextTooLarge }
        let ready = Date()
        var text = "", first: Double?, info: GenerateCompletionInfo?
        let stream = try await container.generate(input: prepared, parameters: GenerateParameters(
            maxTokens: LocalAIContext.maximumOutputTokens, temperature: 0.7, topP: 0.8, topK: 20,
            repetitionPenalty: 1.05, prefill: .init(stepSize: 256), seed: 42))
        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let piece):
                if first == nil { first = Date().timeIntervalSince(began) }
                text += piece; onText(piece)
            case .info(let value): info = value
            default: break
            }
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalAIError.emptyAnswer }
        return LocalInferenceResult(text: text, model: model.identity, inputTokens: count,
            outputTokens: info?.generationTokenCount ?? 0, seconds: Date().timeIntervalSince(began), firstTextSeconds: first,
            peakMemoryBytes: Memory.peakMemory, paragraphs: prompt.paragraphs, omittedParagraphs: prompt.omittedParagraphs,
            stoppedAtLimit: info?.stopReason == .length, modelLoadSeconds: loaded.timeIntervalSince(began),
            contextSeconds: selected.timeIntervalSince(loaded), prepareSeconds: ready.timeIntervalSince(selected))
        #endif
    }
}
