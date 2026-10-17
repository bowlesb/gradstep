import CryptoKit
import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import os
#endif

public struct LocalModel: Codable, Equatable, Identifiable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }
    public let id: String
    public let name: String
    public let repository: String
    public let revision: String
    public let vision: Bool
    public let files: [File]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    public var identity: String { "local/\(id)/\(revision.prefix(12))" }
    /// Conservative admission for this prototype, including space for the reader and transient tensors.
    /// Use measured process footprint as well as MLX allocations. Phone evidence is still pending.
    public func requiredHeadroom(hasImage: Bool) -> Int {
        let measured: Int = switch id {
        case "qwen3-06b": 1_800_000_000
        case "qwen35-2b": 4_800_000_000
        case "qwen35-4b": 8_000_000_000
        case "gemma4-e2b": 8_500_000_000
        default: Int(bytes) * 2 + 1_000_000_000
        }
        return measured
    }
    public func admitsCurrentMemory(hasImage: Bool) -> Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        os_proc_available_memory() >= requiredHeadroom(hasImage: hasImage)
        #else
        true // Simulator tests controls; Mac process admission differs from iOS jetsam limits.
        #endif
    }
    public static let all: [LocalModel] = {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url), let models = try? JSONDecoder().decode([LocalModel].self, from: data) else { return [] }
        return models
    }()
}

public enum LocalAIError: LocalizedError, Sendable {
    case busy, needsDownload, integrity, diskSpace, imageUnsupported, imageInvalid, contextTooLarge, unsupportedAction, unavailable, emptyAnswer, memory
    public var errorDescription: String? {
        switch self {
        case .busy: "Another local AI task is running. Stop it or wait for it to finish."
        case .needsDownload: "Download this model before using Local AI."
        case .integrity: "The model download did not pass verification. Download it again."
        case .diskSpace: "There is not enough free space for this model. Free some space and try again."
        case .imageUnsupported: "This model reads text only. Choose a vision model to explain a figure."
        case .imageInvalid: "This figure could not be prepared for Local AI."
        case .contextTooLarge: "The question, selection or image is too large for this local model. Select a smaller passage or one figure."
        case .unsupportedAction: "This action needs cloud search or tools. Choose Cloud AI explicitly to use it."
        case .unavailable: "Local inference needs an Apple Silicon device with Metal. The Simulator can test the controls only."
        case .emptyAnswer: "The local model produced no answer. Try a shorter question."
        case .memory: "This device does not currently have enough app memory for this model. Choose a smaller local model."
        }
    }
}

/// Only this type has networking. It downloads public, pinned model files; it never receives a prompt or paper.
public actor LocalModelStore {
    public let root: URL
    private var downloading = false
    public init(root: URL) { self.root = root }
    public nonisolated func directory(for model: LocalModel) -> URL { root.appendingPathComponent(model.id + "-" + model.revision.prefix(12), isDirectory: true) }
    public func isInstalled(_ model: LocalModel) -> Bool {
        let folder = directory(for: model)
        return (try? String(contentsOf: folder.appendingPathComponent("verified"), encoding: .utf8)) == model.revision
            && model.files.allSatisfy { file in
                let values = try? folder.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                return values?.isSymbolicLink == false && values?.fileSize == Int(file.bytes)
            }
    }
    public func remove(_ model: LocalModel) throws {
        guard !downloading else { throw LocalAIError.busy }
        let folder = directory(for: model)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    public func verifiedDirectory(_ model: LocalModel) throws -> URL {
        guard isInstalled(model) else { throw LocalAIError.needsDownload }
        let folder = directory(for: model)
        for file in model.files {
            try Task.checkCancellation()
            guard try Self.digest(folder.appendingPathComponent(file.name)) == file.sha256 else { throw LocalAIError.integrity }
        }
        return folder
    }
    public func download(_ model: LocalModel, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard !downloading else { throw LocalAIError.busy }
        downloading = true
        defer { downloading = false }
        let folder = directory(for: model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = root; try excluded.setResourceValues(values)
        let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let remaining = model.files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard free > remaining + 512 * 1_024 * 1_024 else { throw LocalAIError.diskSpace }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3_600
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            guard !file.name.contains("/"), file.name != ".", file.name != ".." else { throw LocalAIError.integrity }
            let destination = folder.appendingPathComponent(file.name)
            if (try? Self.digest(destination)) == file.sha256 { completed += file.bytes; progress(completed, model.bytes); continue }
            let prior = completed
            let observer = DownloadObserver { bytes in progress(prior + min(bytes, file.bytes), model.bytes) }
            let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(file.name)")!
            let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: observer)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(file.bytes),
                  try Self.digest(temporary) == file.sha256 else { throw LocalAIError.integrity }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            completed += file.bytes; progress(completed, model.bytes)
        }
        try Task.checkCancellation()
        try Data(model.revision.utf8).write(to: folder.appendingPathComponent("verified"), options: .atomic)
    }
    private static func digest(_ url: URL) throws -> String {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw LocalAIError.integrity }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
}
