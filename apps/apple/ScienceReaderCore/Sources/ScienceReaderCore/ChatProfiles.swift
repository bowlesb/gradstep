import Foundation

/// A chat's model, effort and length (owner request 2026-10-08: "customize the length and effort and model right there
/// in the chat"). The chat function accepts only its published, versioned table of these (`chat-profiles-v1`,
/// `GET functions/v1/chat`) and charges at the chosen model's rates; this build only sends the choice and displays
/// the server's estimates. Contract: docs/architecture/CHAT.md#models-effort-and-length.
public struct ChatProfileChoice: Codable, Equatable, Hashable, Sendable {
    /// `deepseek` (chat redesign 2026-10-16): DeepSeek V4.1 Flash, offered only when the server's table lists it.
    public enum Model: String, Codable, CaseIterable, Sendable { case haiku, sonnet, opus, deepseek, gemini }
    /// `auto` (chat redesign 2026-10-16): the server picks low, medium or high for each question. The reader no longer
    /// chooses effort; older builds' explicit efforts stay valid.
    public enum Effort: String, Codable, CaseIterable, Sendable { case low, medium, high, auto }
    public enum Length: String, Codable, CaseIterable, Sendable { case brief, standard, detailed }

    public var model: Model
    public var effort: Effort
    public var length: Length

    public init(model: Model, effort: Effort, length: Length) { self.model = model; self.effort = effort; self.length = length }

    /// Today's answers (and every request without a choice): Sonnet, low effort, standard length.
    public static let standard = ChatProfileChoice(model: .sonnet, effort: .low, length: .standard)

    /// `sonnet-low-standard`: the server's profile identifier, also saved with each answer.
    public var id: String { "\(model.rawValue)-\(effort.rawValue)-\(length.rawValue)" }

    /// A saved or reported profile identifier; nil for anything else (a repair's `diagram_fix`, a later build's value).
    public init?(id: String) {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let model = Model(rawValue: parts[0]), let effort = Effort(rawValue: parts[1]),
              let length = Length(rawValue: parts[2]) else { return nil }
        self.init(model: model, effort: effort, length: length)
    }
}

public extension ChatProfileChoice.Model {
    /// Built-in names, used until (or when) the server's table is unavailable.
    var label: String { switch self { case .haiku: "Haiku"; case .sonnet: "Sonnet"; case .opus: "Opus"; case .deepseek: "DeepSeek"; case .gemini: "Gemini Flash" } }
    var detail: String {
        switch self {
        case .haiku: "Quick, economical explanations"
        case .sonnet: "Strong answers at a moderate cost"
        case .opus: "Most capable; costs the most"
        case .deepseek: "Low cost; processed by DeepSeek"
        case .gemini: "Recommended for paper questions; lower cost"
        }
    }
    /// Who processes a question asked with this model (Settings › AI chat options).
    var processor: String { self == .gemini ? "Google through OpenRouter" : self == .deepseek ? "DeepSeek" : "Anthropic" }
}
public extension ChatProfileChoice.Effort {
    var label: String { switch self { case .low: "Low"; case .medium: "Medium"; case .high: "High"; case .auto: "Automatic" } }
    var detail: String {
        switch self {
        case .low: "Thinks only when needed; quickest"
        case .medium: "Thinks through harder questions"
        case .high: "Thinks carefully; slowest"
        case .auto: "Chosen for each question"
        }
    }
}
public extension ChatProfileChoice.Length {
    var label: String { switch self { case .brief: "Brief"; case .standard: "Standard"; case .detailed: "Detailed" } }
    var detail: String {
        switch self {
        case .brief: "A few sentences"
        case .standard: "Focused answers"
        case .detailed: "Thorough, with derivations and caveats"
        }
    }
}

/// The server's published table (`GET functions/v1/chat`), decoded tolerantly and bounded. Labels and estimates come
/// from the server so they can change without a new build; the choices themselves are the three fixed enums above.
public struct ChatProfileTable: Equatable, Sendable {
    public static let supportedVersion = "chat-profiles-v1"
    public struct Estimate: Equatable, Sendable, Codable {
        public let low: Int, high: Int, max: Int
        public init(low: Int, high: Int, max: Int) { self.low = low; self.high = high; self.max = max }
    }
    public struct Option: Equatable, Sendable { public let label: String; public let detail: String }

    public let version: String
    public let defaultChoice: ChatProfileChoice
    public let models: [ChatProfileChoice.Model: Option]
    public let efforts: [ChatProfileChoice.Effort: Option]
    public let lengths: [ChatProfileChoice.Length: Option]
    /// Offered profiles and their credit estimates. A choice the server doesn't list isn't offered.
    public let estimates: [ChatProfileChoice: Estimate]
    public let note: String?

    public init(version: String, defaultChoice: ChatProfileChoice, models: [ChatProfileChoice.Model: Option] = [:],
                efforts: [ChatProfileChoice.Effort: Option] = [:], lengths: [ChatProfileChoice.Length: Option] = [:],
                estimates: [ChatProfileChoice: Estimate], note: String? = nil) {
        self.version = version; self.defaultChoice = defaultChoice; self.models = models; self.efforts = efforts
        self.lengths = lengths; self.estimates = estimates; self.note = note
    }

    /// The table this build understands, or nil (another version, malformed, or too large).
    public static func decode(_ data: Data) -> ChatProfileTable? {
        guard data.count <= 64 * 1024 else { return nil }
        struct Wire: Decodable {
            struct Named: Decodable { let id: String; let label: String; let detail: String?; let consent_version: String?; let provider: String? }
            struct Profile: Decodable { let model: String; let effort: String; let length: String; let credits: Estimate }
            struct Choice: Decodable { let model: String; let effort: String; let length: String }
            let version: String
            let `default`: Choice
            let default_recommended: Choice?
            let models: [Named]?
            let efforts: [Named]?
            let lengths: [Named]?
            let profiles: [Profile]
            let estimate_note: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.version == supportedVersion,
              let model = ChatProfileChoice.Model(rawValue: wire.default.model), let effort = ChatProfileChoice.Effort(rawValue: wire.default.effort),
              let length = ChatProfileChoice.Length(rawValue: wire.default.length) else { return nil }
        func text(_ value: String, _ limit: Int) -> String? {
            let flat = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flat.isEmpty || flat.count > limit ? nil : flat
        }
        func options<Key: RawRepresentable & Hashable>(_ named: [Wire.Named]?, _ key: Key.Type) -> [Key: Option] where Key.RawValue == String {
            var result: [Key: Option] = [:]
            for item in named ?? [] {
                guard let id = Key(rawValue: item.id), let label = text(item.label, 24) else { continue }
                result[id] = Option(label: label, detail: item.detail.flatMap { text($0, 80) } ?? "")
            }
            return result
        }
        let geminiUsable = wire.models?.contains { $0.id == "gemini" && $0.consent_version == "cloud-ai-v5" && $0.provider == "openrouter" } == true
        var estimates: [ChatProfileChoice: Estimate] = [:]
        for profile in wire.profiles.prefix(64) {
            guard let m = ChatProfileChoice.Model(rawValue: profile.model), let e = ChatProfileChoice.Effort(rawValue: profile.effort),
                  let l = ChatProfileChoice.Length(rawValue: profile.length), profile.credits.low >= 0,
                  profile.credits.low <= profile.credits.high, profile.credits.high <= profile.credits.max, profile.credits.max < 1_000_000 else { continue }
            guard m != .gemini || geminiUsable else { continue }
            estimates[ChatProfileChoice(model: m, effort: e, length: l)] = profile.credits
        }
        var defaultChoice = ChatProfileChoice(model: model, effort: effort, length: length)
        guard estimates[defaultChoice] != nil else { return nil }
        if let recommended = wire.default_recommended, let m = ChatProfileChoice.Model(rawValue: recommended.model),
           let e = ChatProfileChoice.Effort(rawValue: recommended.effort), let l = ChatProfileChoice.Length(rawValue: recommended.length) {
            let choice = ChatProfileChoice(model: m, effort: e, length: l)
            if estimates[choice] != nil { defaultChoice = choice }
        }
        let models = options(wire.models, ChatProfileChoice.Model.self).filter { $0.key != .gemini || geminiUsable }
        return ChatProfileTable(version: wire.version, defaultChoice: defaultChoice, models: models,
            efforts: options(wire.efforts, ChatProfileChoice.Effort.self), lengths: options(wire.lengths, ChatProfileChoice.Length.self),
            estimates: estimates, note: wire.estimate_note.flatMap { text($0, 200) })
    }

    public func offers(_ choice: ChatProfileChoice) -> Bool { estimates[choice] != nil }
    public func label(_ model: ChatProfileChoice.Model) -> String { models[model]?.label ?? model.label }
    public func label(_ effort: ChatProfileChoice.Effort) -> String { efforts[effort]?.label ?? effort.label }
    public func label(_ length: ChatProfileChoice.Length) -> String { lengths[length]?.label ?? length.label }
    public func detail(_ model: ChatProfileChoice.Model) -> String { models[model]?.detail ?? model.detail }
    public func detail(_ effort: ChatProfileChoice.Effort) -> String { efforts[effort]?.detail ?? effort.detail }
    public func detail(_ length: ChatProfileChoice.Length) -> String { lengths[length]?.detail ?? length.detail }

    /// What a request asks for: the reader's model and length with the effort the server chooses (`auto`) when the
    /// table offers it; else the choice as stored, else its low-effort form, else the server's default. Effort is no
    /// longer the reader's choice (chat redesign 2026-10-16).
    public func requested(_ choice: ChatProfileChoice) -> ChatProfileChoice {
        var automatic = choice; automatic.effort = .auto
        if offers(automatic) { return automatic }
        if offers(choice) { return choice }
        var low = choice; low.effort = .low
        return offers(low) ? low : defaultChoice
    }
    /// The models the table offers (any length), in the app's order.
    public var offeredModels: [ChatProfileChoice.Model] {
        ChatProfileChoice.Model.allCases.filter { m in estimates.keys.contains { $0.model == m } }
    }
    /// The estimate shown for a model and length: the automatic effort's when offered, else low effort's.
    public func estimate(model: ChatProfileChoice.Model, length: ChatProfileChoice.Length) -> Estimate? {
        estimates[ChatProfileChoice(model: model, effort: .auto, length: length)] ?? estimates[ChatProfileChoice(model: model, effort: .low, length: length)] ?? estimates[ChatProfileChoice(model: model, effort: .medium, length: length)]
    }

    /// "Usually 4–24 credits · up to 37", "About 1 credit · up to 2"; nil when the server doesn't offer the choice.
    public func estimateText(_ choice: ChatProfileChoice) -> String? {
        guard let estimate = estimates[choice] else { return nil }
        return ChatProfileText.estimate(estimate)
    }
}

public enum ChatProfileText {
    static func credits(_ count: Int) -> String { count == 1 ? "1 credit" : "\(count) credits" }

    public static func estimate(_ estimate: ChatProfileTable.Estimate) -> String {
        let usual = estimate.low == estimate.high ? "About \(credits(estimate.low))" : "Usually \(estimate.low)–\(credits(estimate.high))"
        return "\(usual) · up to \(estimate.max)"
    }

    /// The reader's choice: "Sonnet · Standard" (effort is the server's, chat redesign 2026-10-16).
    public static func summary(_ choice: ChatProfileChoice, table: ChatProfileTable? = nil) -> String {
        [table?.label(choice.model) ?? choice.model.label, table?.label(choice.length) ?? choice.length.label].joined(separator: " · ")
    }

    /// The line under an answer: its profile ("Sonnet · Standard"), and the model when another one wrote it (a
    /// refusal fallback): "Sonnet · Standard · by Claude Sonnet 5". Nil for answers saved without either.
    public static func answeredBy(model: String?, profile: String?, table: ChatProfileTable? = nil) -> String? {
        let choice = profile.flatMap(ChatProfileChoice.init(id:))
        var parts: [String] = []
        if let choice { parts.append(summary(choice, table: table)) }
        if let model, !model.isEmpty {
            let expected = choice.map { apiModel(for: $0.model) }
            if model != expected { parts.append(choice == nil ? modelName(model) : "by \(modelName(model))") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The API model each choice asks for (chat-profiles-v1).
    public static func apiModel(for model: ChatProfileChoice.Model) -> String {
        switch model { case .haiku: "claude-haiku-5-5"; case .sonnet: "claude-sonnet-5-5"; case .opus: "claude-opus-5-5"; case .deepseek: "deepseek-flash"; case .gemini: "gemini-3.8-flash" }
    }

    /// "claude-sonnet-5" → "Claude Sonnet 5"; anything unexpected is shown bounded, as sent.
    public static func modelName(_ id: String) -> String {
        let trimmed = String(id.prefix(64))
        if trimmed.hasPrefix("local/") {
            let names = ["qwen3-06b": "Qwen3 0.6B", "qwen35-2b": "Qwen3.5 2B", "qwen35-4b": "Qwen3.5 4B", "gemma4-e2b": "Gemma 4 E2B"]
            return (trimmed.split(separator: "/").dropFirst().first.flatMap { names[String($0)] } ?? "Local AI") + " · on device"
        }
        if trimmed == "gemini-3.8-flash" { return "Gemini 3.8 Flash" }
        if trimmed.hasPrefix("deepseek-") { return trimmed == "deepseek-flash" ? "DeepSeek V4.1 Flash" : "DeepSeek" }
        guard trimmed.hasPrefix("claude-") else { return trimmed }
        let words = trimmed.dropFirst("claude-".count).split(separator: "-").map(String.init)
        guard let family = words.first, !family.isEmpty else { return trimmed }
        let version = words.dropFirst().filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return "Claude " + family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
    }
}
