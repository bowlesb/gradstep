import Foundation

/// Study mode (reworked 2026-10-22; docs/proposals/LEARNING_GUIDE.md "Study mode, reworked"): a paper chat whose turns
/// carry `action: "study"` is a tutor that asks one focused question at a time and backs off to a short explanation when
/// the reader is shaky. The tutor keeps light notes on the reader (concepts covered, how sure the reader is, its plan)
/// that the server strips from the reply and sends once as a `study_state` event; the device keeps them with the open
/// chat (memory only, never stored) and sends them back as `study_state` with the next study turn. The 2026-10-14
/// knowledge map (a map, journey and concepts the reader saw) is retired. The port of `_shared/chat-study.ts`.
public struct StudyNotes: Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable { case intro, core, deep }
    public enum Status: String, Codable, CaseIterable, Sendable { case new, shaky, ok, solid }
    public struct Concept: Codable, Equatable, Sendable {
        public let name: String
        public let status: Status
        public let asked: [Int]
        public let paras: [Int]
        public init(name: String, status: Status, asked: [Int] = [], paras: [Int] = []) {
            self.name = name; self.status = status; self.asked = asked; self.paras = paras
        }
    }
    public let turn: Int
    public let level: Level
    public let concepts: [Concept]
    public let next: String

    public init(turn: Int, level: Level, concepts: [Concept], next: String) {
        self.turn = turn; self.level = level; self.concepts = concepts; self.next = next
    }

    public enum Limits {
        public static let concepts = 12, name = 60, asked = 8, paras = 6, next = 200, bytes = 4_096, turn = 500
    }

    /// The notes from the server (untrusted), repaired rather than refused as the server repairs them: an unknown level
    /// is `core`, an unknown status `new`, a concept without a name is dropped, a repeated name keeps the newest, lists are
    /// bounded, unique and sorted. Nil only when the shape is unusable (not an object) or the result is over 4 KB.
    public static func validated(_ data: Data, paragraphs: Int = 100_000) -> StudyNotes? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return validated(object, paragraphs: paragraphs)
    }

    public static func validated(_ v: [String: Any], paragraphs: Int = 100_000) -> StudyNotes? {
        let turn = whole(v["turn"]).flatMap { $0 >= 1 ? min($0, Limits.turn) : nil } ?? 1
        let level = (v["level"] as? String).flatMap(Level.init(rawValue:)) ?? .core
        var order: [String] = [], byName: [String: Concept] = [:]
        for raw in ((v["concepts"] as? [Any]) ?? []).prefix(64) {
            guard let c = raw as? [String: Any], let name = line(c["name"], limit: Limits.name) else { continue }
            let status = (c["status"] as? String).flatMap(Status.init(rawValue:)) ?? .new
            let key = name.lowercased()
            order.removeAll { $0 == key }; order.append(key)
            byName[key] = Concept(name: name, status: status, asked: numbers(c["asked"], max: Limits.turn, limit: Limits.asked),
                                  paras: numbers(c["paras"], max: paragraphs, limit: Limits.paras))
        }
        let concepts = order.suffix(Limits.concepts).compactMap { byName[$0] }
        let notes = StudyNotes(turn: turn, level: level, concepts: concepts, next: line(v["next"], limit: Limits.next) ?? "")
        guard let encoded = try? JSONEncoder().encode(notes), encoded.count <= Limits.bytes else { return nil }
        return notes
    }

    /// A whole number from JSON (an integral double counts, as in JavaScript).
    static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }
    private static func numbers(_ value: Any?, max: Int, limit: Int) -> [Int] {
        let kept = ((value as? [Any]) ?? []).compactMap(whole).filter { $0 >= 1 && $0 <= max }
        return Array(Array(Set(kept)).sorted().suffix(limit))
    }
    /// One line: control characters and angle brackets out, white space collapsed, cut at the limit with "…".
    private static func line(_ value: Any?, limit: Int) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar -> Unicode.Scalar in
            (scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) || scalar == "<" || scalar == ">") ? " " : scalar
        }))
        let text = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit else { return text }
        let cut = String(String.UnicodeScalarView(scalars.prefix(limit - 1)))
        return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
    }
}

/// What Study mode says and sends (LEARNING_GUIDE.md): the entry the suggestions offer, the opening turn it sends, and the
/// two quick replies the study row sends.
public enum StudyMode {
    public static let entry = "Enter Study Mode – Quiz me and help me learn"
    public static let opening = "Quiz me and help me learn this paper."
    public static let hint = "Give me a hint."
    public static let explainInstead = "Explain it to me instead."
}

/// Follow-up suggestions that ask for a picture (a diagram or a visual explanation; the server keeps at most one): the
/// app then leaves out its own generic "Draw a diagram" and "Create a visual explanation" rows. The server's pattern
/// (chat-follow-ups.ts `VISUAL_FOLLOW_UP_PATTERN`).
public enum VisualFollowUp {
    static let pattern = #"^(?:please\s+)?(?:(?:draw|sketch|diagram|visuali[sz]e|illustrate)\b|(?:create|make|show|give me|build)\b.*\b(?:diagram|visual|flow ?chart|chart|mind ?map|concept map|picture|illustration)s?\b)"#
    public static func isVisual(_ question: String) -> Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
