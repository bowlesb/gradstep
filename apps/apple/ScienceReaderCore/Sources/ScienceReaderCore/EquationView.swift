import CryptoKit
import Foundation

// The equation view (docs/architecture/EQUATION_VIEW.md): a tapped equation shown large with each symbol described, from
// the paper where the paper describes it and from general usage where it does not, and optional background. Both
// requests are chat actions on the chat's own profile and paper, so they read and write the chat's cached prefix.

/// The server's `equation` event (format `equation-symbols-v1`): a summary and the symbols in order of appearance.
public struct EquationSymbols: Codable, Equatable, Sendable {
    public static let format = "equation-symbols-v1"
    public static let maximumSymbols = 24

    public enum Source: String, Codable, Equatable, Sendable { case paper, general }
    public struct Symbol: Codable, Equatable, Sendable {
        /// Plain Unicode as the model wrote it (`π_θ(y|x)`).
        public let symbol: String
        public let latex: String?
        public let meaning: String
        public let source: Source
        /// The paper's `[¶N]` block that defines it; only with `paper`.
        public let paragraph: Int?
        public init(symbol: String, latex: String? = nil, meaning: String, source: Source, paragraph: Int? = nil) {
            self.symbol = symbol; self.latex = latex; self.meaning = meaning; self.source = source; self.paragraph = paragraph
        }
    }

    public let format: String
    public let summary: String
    public let symbols: [Symbol]

    public init(summary: String, symbols: [Symbol]) { format = Self.format; self.summary = summary; self.symbols = symbols }

    /// The event's JSON, checked and bounded as the server bounds it: control characters removed, long text cut, a
    /// `paper` symbol without a usable paragraph counted as general. Nil when nothing usable is left.
    public static func validated(_ data: Data) -> EquationSymbols? {
        struct Raw: Decodable {
            struct Row: Decodable { let symbol: String?; let latex: String?; let meaning: String?; let source: String?; let paragraph: Int? }
            let format: String; let summary: String?; let symbols: [Row]
        }
        guard data.count <= 64 * 1024, let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.format == format else { return nil }
        let rows = raw.symbols.prefix(maximumSymbols).compactMap { row -> Symbol? in
            let symbol = clean(row.symbol, 80), meaning = clean(row.meaning, 500), latex = clean(row.latex, 200)
            guard !symbol.isEmpty, !meaning.isEmpty else { return nil }
            let paragraph = row.source == Source.paper.rawValue ? row.paragraph.flatMap { $0 >= 1 && $0 <= 100_000 ? $0 : nil } : nil
            return Symbol(symbol: symbol, latex: latex.isEmpty ? nil : latex, meaning: meaning, source: paragraph == nil ? .general : .paper, paragraph: paragraph)
        }
        let summary = clean(raw.summary, 600)
        guard !summary.isEmpty || !rows.isEmpty else { return nil }
        return EquationSymbols(summary: summary, symbols: Array(rows))
    }

    static func clean(_ value: String?, _ limit: Int) -> String {
        guard let value else { return "" }
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == " " }))
        return String(kept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

/// An equation's own markup in the bundle's page, found by its id: the element carrying `data-reader-equation`, with
/// its MathML or formula image and its number. Shown alone in the equation view with the bundle's stylesheet.
public enum EquationMarkup {
    public static let maximumBytes = 512 * 1024

    /// The element whose `id` is `equationID` (an equation's span), complete with its closing tag; nil when the page has
    /// no such equation.
    public static func element(in html: String, equationID: String) -> String? {
        guard !equationID.isEmpty, equationID.utf8.count <= 128,
              equationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }),
              let attribute = html.range(of: " id=\"\(equationID)\"") else { return nil }
        // The tag the attribute belongs to.
        guard let open = html[..<attribute.lowerBound].lastIndex(of: "<") else { return nil }
        let nameEnd = html[html.index(after: open)...].firstIndex { !($0.isLetter || $0.isNumber) } ?? html.endIndex
        let name = String(html[html.index(after: open)..<nameEnd]).lowercased()
        // The opening tag itself names the equation (an id elsewhere, such as a link's target, is not one).
        guard !name.isEmpty, let tagEnd = html[attribute.upperBound...].firstIndex(of: ">"),
              html[open...tagEnd].contains("data-reader-equation=\"\(equationID)\"") else { return nil }
        // Balanced `<name …>` / `</name>` from the opening tag on.
        var depth = 0, index = open
        while index < html.endIndex {
            guard let next = html[index...].firstIndex(of: "<") else { return nil }
            let rest = html[html.index(after: next)...]
            if rest.hasPrefix("/" + name), Self.ends(rest.dropFirst(name.count + 1)) {
                depth -= 1
                guard let close = rest.firstIndex(of: ">") else { return nil }
                index = html.index(after: close)
                if depth == 0 {
                    let markup = String(html[open..<index])
                    return markup.utf8.count <= maximumBytes ? markup : nil
                }
            } else if rest.lowercased().hasPrefix(name), Self.ends(rest.dropFirst(name.count)) {
                guard let close = rest.firstIndex(of: ">") else { return nil }
                if html[html.index(before: close)] != "/" { depth += 1 }
                index = html.index(after: close)
            } else { index = html.index(after: next) }
        }
        return nil
    }

    /// The equation's printed number (`(4)`) from its tag, if it has one.
    public static func number(in markup: String) -> String? {
        guard let tag = markup.range(of: "class=\"reader-tag\""), let start = markup[tag.upperBound...].firstIndex(of: ">"),
              let end = markup[start...].range(of: "</span>") else { return nil }
        var text = String(markup[markup.index(after: start)..<end.lowerBound])
        while let tagOpen = text.firstIndex(of: "<"), let tagClose = text[tagOpen...].firstIndex(of: ">") { text.removeSubrange(tagOpen...tagClose) }
        let number = text.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty || number.count > 16 ? nil : number
    }

    /// "Equation (4)", or "Equation" without a number.
    public static func label(number: String?) -> String { number.map { "Equation \($0)" } ?? "Equation" }

    private static func ends(_ rest: Substring) -> Bool { rest.first.map { $0 == ">" || $0 == "/" || $0.isWhitespace } ?? false }
}

extension ChatGenerationRequest {
    /// An equation view request: one turn naming the equation (`Equation (4)`), its LaTeX as the selection, the paper
    /// numbered on this device, and the chat's profile and visual-answers setting, so the tools, instructions and paper
    /// match the reader's chat about this paper byte for byte (the server's cache is shared).
    public static func equation(_ action: ChatAction, operationID: UUID, label: String, latex: String, profile: ChatProfileChoice,
                                localContext: LocalPaperChatContext, visualAnswers: Bool) throws -> ChatGenerationRequest {
        guard action.isEquation, !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatRequestError.emptyContext }
        return try make(operationID: operationID, documentID: nil, transcript: [ChatTurnInput(role: .user, text: label)], selection: latex,
                        action: action, profile: profile, topicTitle: false, localContext: localContext, visualAnswers: visualAnswers)
    }
}

/// What the device keeps of one equation view request (not synced, not chat history): the symbols or the background.
public struct EquationAnswer: Codable, Equatable, Sendable {
    /// The symbols (action `equation`); nil when the server sent words instead, or for background.
    public var symbols: EquationSymbols?
    /// The background, or the words sent instead of symbols.
    public var text: String
    public var credits: Int?
    public var model: String?
    public init(symbols: EquationSymbols? = nil, text: String = "", credits: Int? = nil, model: String? = nil) {
        self.symbols = symbols; self.text = text; self.credits = credits; self.model = model
    }
}

/// One cached answer's identity: the paper revision (bundle manifest), the equation, the action and the chat profile.
public struct EquationResultKey: Hashable, Sendable {
    public let manifestSHA256: String
    public let equationID: String
    public let action: ChatAction
    public let profile: ChatProfileChoice
    public init(manifestSHA256: String, equationID: String, action: ChatAction, profile: ChatProfileChoice) {
        self.manifestSHA256 = manifestSHA256; self.equationID = equationID; self.action = action; self.profile = profile
    }
    /// A file name that names nothing about the paper (a digest of the identity).
    public var fileName: String {
        let identity = "equation-answer-v1\n\(manifestSHA256)\n\(equationID)\n\(action.rawValue)\n\(profile.id)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".sealed"
    }
}

/// Equation answers on this device, sealed with the account's local key like its reader bundles (AES-GCM, the file's
/// identity bound as associated data), in a folder with complete file protection and excluded from backup. Bounded:
/// past `maximumAnswers` the oldest are removed.
public final class EquationResultStore: @unchecked Sendable {
    public static let maximumAnswers = 400
    private static let aadPrefix = "science-reader/equation-answers/v1/"
    private let directory: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private let lock = NSLock()

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        self.directory = directory.standardizedFileURL; self.accountID = accountID; key = SymmetricKey(data: localKey)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: self.directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = self.directory
        try? excluded.setResourceValues(values)
    }

    public func read(_ answerKey: EquationResultKey) -> EquationAnswer? {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent(answerKey.fileName)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let sealed = try? Data(contentsOf: url), sealed.count <= 1_048_576,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key, authenticating: aad(answerKey)) else { return nil }
        return try? JSONDecoder().decode(EquationAnswer.self, from: data)
    }

    public func write(_ answer: EquationAnswer, for answerKey: EquationResultKey) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(answer)
        guard data.count <= 1_000_000, let sealed = try AES.GCM.seal(data, using: key, authenticating: aad(answerKey)).combined else {
            throw ReaderError.invalidEvent
        }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try sealed.write(to: directory.appendingPathComponent(answerKey.fileName), options: options)
        prune()
    }

    private func aad(_ answerKey: EquationResultKey) -> Data { Data((Self.aadPrefix + accountID.wire + "/" + answerKey.fileName).utf8) }

    private func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.maximumAnswers else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.maximumAnswers) { try? manager.removeItem(at: url) }
    }
}
