#if targetEnvironment(macCatalyst)
import Foundation
import LocalAI
import Observation
import ScienceReaderCore

@MainActor @Observable final class LocalAIController {
    let models = LocalModel.all
    let store: LocalModelStore
    let engine = LocalEngine()
    @ObservationIgnored private let jobs = LocalAIJobs()
    private(set) var installed: Set<String> = []
    private(set) var downloading: String?
    private(set) var fraction = 0.0
    private(set) var issue: String?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Test injection is confined to the fixture host, never a distributed binary.
    #if DEBUG && FIXTURE_HOST
    @ObservationIgnored var fixtureStream: (@Sendable (ChatGenerationRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>)?
    #endif

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = LocalModelStore(root: base.appendingPathComponent("LocalAIModels", isDirectory: true))
        #if DEBUG && FIXTURE_HOST
        if ProcessInfo.processInfo.arguments.contains("--local-ai-fixture") {
            fixtureStream = { _ in AsyncThrowingStream { continuation in
                continuation.yield(.delta("This answer was generated on this device from the selected evidence [¶2]."))
                continuation.yield(.done(stopReason: "end_turn", credits: 0, model: "local/qwen35-4b/fixture"))
                continuation.finish()
            } }
        }
        #endif
    }
    func refresh() async {
        #if DEBUG && FIXTURE_HOST
        if fixtureStream != nil { installed = Set(models.map(\.id)); return }
        #endif
        var found = Set<String>()
        for model in models where await store.isInstalled(model) { found.insert(model.id) }
        installed = found
    }
    func download(_ model: LocalModel) {
        guard downloading == nil else { return }
        downloading = model.id; fraction = 0; issue = nil
        downloadTask = Task { [weak self, store] in
            do {
                try await store.download(model) { [weak self] current, total in
                    Task { @MainActor [weak self] in
                        guard self?.downloading == model.id else { return }
                        self?.fraction = Double(current) / Double(max(1, total))
                    }
                }
            } catch { if !Task.isCancelled { self?.issue = error.localizedDescription } }
            guard let self else { return }
            self.downloading = nil; self.downloadTask = nil
            await self.refresh()
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func cancelInference() { jobs.cancelAll() }
    func remove(_ model: LocalModel) async {
        guard jobs.isEmpty else { issue = "Stop the local answer before removing a model."; return }
        do { try await store.remove(model); await refresh() } catch { issue = error.localizedDescription }
    }
    func name(_ id: String?) -> String { id.flatMap { id in models.first { $0.id == id }?.name } ?? "Cloud AI" }
    func identity(_ id: String?) -> String? { id.flatMap { id in models.first { $0.id == id }?.identity } }
    func transport(_ id: String) -> any ChatTransport {
        #if DEBUG && FIXTURE_HOST
        if let fixtureStream { return LocalFixtureTransport(makeStream: fixtureStream) }
        #endif
        return LocalChatTransport(model: models.first { $0.id == id }, store: store, engine: engine, jobs: jobs)
    }
}

private struct LocalChatTransport: ChatTransport {
    let model: LocalModel?
    let store: LocalModelStore
    let engine: LocalEngine
    let jobs: LocalAIJobs
    func creditBalance(accountID: UUID) async throws -> CreditBalance { throw LocalAIError.unsupportedAction }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { throw LocalAIError.unsupportedAction }
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        guard let model else { throw ChatTransportError.rejected("local_model_missing") }
        guard request.figures.count <= 1 else { throw ChatTransportError.rejected("local_context_large") }
        if !request.figures.isEmpty, !model.vision { throw ChatTransportError.rejected("local_image_unsupported") }
        return AsyncThrowingStream { continuation in
            let id = UUID()
            let epoch = jobs.epoch
            let task = Task {
                defer { jobs.remove(id) }
                do {
                    let directory = try await store.verifiedDirectory(model)
                    let image = request.figures.first.flatMap { Data(base64Encoded: $0.data) }
                    if !request.figures.isEmpty, image == nil { throw LocalAIError.imageInvalid }
                    let result = try await engine.answer(model: model, directory: directory,
                        input: .init(question: request.turns.last?.text ?? "", selection: request.selection,
                                     paper: request.onDevicePaperText ?? request.localContext?.text, history: Array(request.turns.dropLast()),
                                     focus: request.onDeviceFocus ?? request.figures.first?.paragraph, action: request.action), image: image) {
                        continuation.yield(.delta($0))
                    }
                    if result.stoppedAtLimit { continuation.yield(.failure(code: "local_length", credits: 0)) }
                    else { continuation.yield(.done(stopReason: "end_turn", credits: 0, model: result.model, profile: nil)) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.yield(.failure(code: "local_interrupted", credits: 0)); continuation.finish(); return
                    }
                    let code: String
                    switch error {
                    case LocalAIError.needsDownload: code = "local_model_missing"
                    case LocalAIError.imageUnsupported: code = "local_image_unsupported"
                    case LocalAIError.imageInvalid: code = "local_image_invalid"
                    case LocalAIError.memory: code = "local_memory"
                    case LocalAIError.contextTooLarge: code = "local_context_large"
                    case LocalAIError.unsupportedAction: code = "local_action_unsupported"
                    case LocalAIError.busy: code = "local_busy"
                    case LocalAIError.integrity: code = "local_model_invalid"
                    case LocalAIError.unavailable: code = "local_unavailable"
                    default: code = "local_failed"
                    }
                    continuation.yield(.failure(code: code, credits: 0)); continuation.finish()
                }
            }
            jobs.insert(task, id: id, epoch: epoch)
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                guard !Task.isCancelled else { return }
                continuation.yield(.failure(code: "local_timeout", credits: 0))
                continuation.finish()
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); timeout.cancel() }
        }
    }
}

/// Cancellation can arrive while Metal is preparing its first token, before a stream has emitted anything.
final class LocalAIJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var completed: Set<UUID> = []
    private var generation = 0
    var epoch: Int { lock.withLock { generation } }
    var isEmpty: Bool { lock.withLock { tasks.isEmpty } }
    func insert(_ task: Task<Void, Never>, id: UUID, epoch: Int) {
        let stale = lock.withLock {
            let finished = completed.remove(id) != nil
            if !finished { tasks[id] = task }
            return epoch != generation
        }
        if stale { task.cancel() }
    }
    func remove(_ id: UUID) { lock.withLock { if tasks.removeValue(forKey: id) == nil { completed.insert(id) } } }
    func cancelAll() {
        let pending = lock.withLock { generation += 1; return Array(tasks.values) }
        for task in pending { task.cancel() }
    }
}

#if DEBUG && FIXTURE_HOST
private struct LocalFixtureTransport: ChatTransport {
    let makeStream: @Sendable (ChatGenerationRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> { makeStream(request) }
    func creditBalance(accountID: UUID) async throws -> CreditBalance { throw LocalAIError.unsupportedAction }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { throw LocalAIError.unsupportedAction }
}
#endif

#else
import Foundation
import Observation
import ScienceReaderCore

/// iOS keeps old encrypted local answers readable, but contains no model runtime or downloader.
/// An explicitly retained local turn is rejected; it must never silently become a paid cloud call.
@MainActor @Observable final class LocalAIController {
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAIModels", isDirectory: true)
        // Retire only the app-owned public weight cache. Chats and explanation stores live elsewhere.
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: root) }
    }
    func refresh() async {}
    func cancelInference() {}
    func name(_ id: String?) -> String { id == nil ? "Cloud AI" : "Mac model" }
    func identity(_ id: String?) -> String? {
        let revisions = ["qwen3-06b": "73e3e38d9813", "qwen35-2b": "674aaa7240b9",
                         "qwen35-4b": "0e7ffd5c629e", "gemma4-e2b": "238767527555"]
        return id.flatMap { id in revisions[id].map { "local/\(id)/\($0)" } }
    }
    func transport(_ id: String) -> any ChatTransport { MacOnlyLocalTransport() }
}
private struct MacOnlyLocalTransport: ChatTransport {
    func creditBalance(accountID: UUID) async throws -> CreditBalance { throw ChatTransportError.rejected("local_mac_only") }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { throw ChatTransportError.rejected("local_mac_only") }
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        throw ChatTransportError.rejected("local_mac_only")
    }
}
#endif
