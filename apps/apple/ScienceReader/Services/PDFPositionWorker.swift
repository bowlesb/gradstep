import Foundation
import PDFKit
import JavaScriptCore
import ScienceReaderCore

/// Primitive, bounded snapshot from the app-owned isolated reader bridge. Never persisted or logged.
struct PDFReadingSnapshot: Equatable, Sendable {
    let text: String
    let nearby: Bool

    init?(message: [String: Any], bundle: VerifiedReaderBundle) {
        guard message["manifest_sha256"] as? String == bundle.manifestSHA256,
              let block = message["block_id"] as? String, bundle.index.blocks.contains(where: { $0.id == block }),
              let text = message["text"] as? String, !text.isEmpty, text.utf16.count <= 2000,
              let kind = message["kind"] as? String, ["visible", "selection", "nearby"].contains(kind) else { return nil }
        self.text = text; nearby = kind == "nearby"
    }
}

struct PDFPositionMatch: Decodable, Sendable {
    struct TextRange: Decodable, Sendable {
        let page: Int
        let location: Int
        let length: Int
    }
    let status: String
    let reason: String?
    let ranges: [TextRange]
}

enum PDFPeekError: Error {
    case unavailable, missing, unreadable, limits, matcherUnavailable, wrongRevision
}

/// Each actor owns its PDFKit extraction document and JS VM. Nothing from either crosses to the UI.
/// One index, keyed by authenticated PDF identity; ReaderModel replaces it on account/document/background change.
actor PDFPositionWorker {
    private var identity: LocalPaperIdentity?
    private var context: JSContext?
    private var index: JSValue?

    /// Validate before publishing a new local original, off the UI thread. This has no upload side effects.
    func validate(file: URL) throws {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else { throw PDFPeekError.unreadable }
        try Task.checkCancellation()
    }

    func match(data: Data, identity: LocalPaperIdentity, text: String) throws -> PDFPositionMatch {
        try Task.checkCancellation()
        if self.identity != identity || index == nil {
            self.identity = nil; index = nil; context = nil
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw PDFPeekError.unreadable }
            guard document.pageCount <= 512 else { throw PDFPeekError.limits }
            var pages: [String] = [], characters = 0
            for number in 0..<document.pageCount {
                try Task.checkCancellation()
                let text: String = autoreleasepool { document.page(at: number)?.string ?? "" }
                characters += text.utf16.count
                guard text.utf16.count <= 200_000, characters <= 8_000_000 else { throw PDFPeekError.limits }
                pages.append(text)
            }
            guard let url = Bundle.main.url(forResource: "pdf-position-matcher", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { throw PDFPeekError.matcherUnavailable }
            context.evaluateScript(script)
            guard context.exception == nil,
                  let model = context.objectForKeyedSubscript("PDFPositionMatcher"),
                  let index = model.invokeMethod("create", withArguments: [pages]), context.exception == nil,
                  !index.isUndefined else { throw PDFPeekError.limits }
            try Task.checkCancellation()
            self.context = context; self.index = index; self.identity = identity
        }
        context?.exception = nil
        guard let result = index?.invokeMethod("match", withArguments: [text]), context?.exception == nil,
              let object = result.toDictionary(), JSONSerialization.isValidJSONObject(object) else { throw PDFPeekError.matcherUnavailable }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let match = try JSONDecoder().decode(PDFPositionMatch.self, from: bytes)
        try Task.checkCancellation()
        return match
    }
}
