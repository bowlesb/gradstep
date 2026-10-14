import Foundation

/// Study (experimental, 2026-10-14; docs/architecture/CHAT.md "Study"): an adaptive tutor for one paper. Every
/// `study` turn carries the reader's knowledge map (concepts with a state, links between them, the journey so far);
/// the server's tutor adapts to it and sends the updated map back as a `study` event. The map lives in memory with
/// the open chat and is never written to the device or the cloud. The port of `_shared/chat-study.ts`.
public struct StudyMap: Codable, Equatable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable { case unknown, learning, known, verified }
    public enum LinkKind: String, Codable, CaseIterable, Sendable { case prerequisite, deeper, related }
    public enum Next: String, Codable, CaseIterable, Sendable { case calibrate, teach, verify, deeper, tangent, revisit }
    public struct Concept: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let state: State
        public let paragraphs: [Int]
        public let note: String?
        public init(id: String, label: String, state: State, paragraphs: [Int], note: String? = nil) {
            self.id = id; self.label = label; self.state = state; self.paragraphs = paragraphs; self.note = note
        }
    }
    public struct Link: Codable, Equatable, Sendable {
        public let from: String
        public let to: String
        public let kind: LinkKind
        public init(from: String, to: String, kind: LinkKind) { self.from = from; self.to = to; self.kind = kind }
    }
    public var concepts: [Concept]
    public var links: [Link]
    public var focus: String?
    public var journey: [String]
    public var next: Next

    public init(concepts: [Concept], links: [Link], focus: String?, journey: [String], next: Next) {
        self.concepts = concepts; self.links = links; self.focus = focus; self.journey = journey; self.next = next
    }
    public static let empty = StudyMap(concepts: [], links: [], focus: nil, journey: [], next: .calibrate)

    public enum Limits {
        public static let concepts = 60, links = 120, label = 80, note = 160, paragraphs = 8, journey = 80, bytes = 16_384
    }
    /// The reader's opening turn: the tutor starts with a calibrating question (on the selected passage when there is one).
    public static func startMessage(selection: String? = nil) -> String {
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Start studying this paper, beginning with this passage: \(selection)"
        }
        return "Start studying this paper."
    }

    /// The map as the server sends it, whole or not at all: ids are slugs, labels bounded and cleaned, states and
    /// link kinds known, links between concepts on the map (no self links; duplicates collapse), the journey and the
    /// focus on the map (a focus that is not is dropped), an unknown next step calibrates.
    public static func validated(_ data: Data) -> StudyMap? {
        struct Raw: Decodable {
            struct Concept: Decodable { let id: String?; let label: String?; let state: String?; let paragraphs: [Int]?; let note: String? }
            struct Link: Decodable { let from: String?; let to: String?; let kind: String? }
            let concepts: [Concept]?; let links: [Link]?; let focus: String?; let journey: [String]?; let next: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let concepts = raw.concepts, let links = raw.links,
              concepts.count <= Limits.concepts, links.count <= Limits.links, let journey = raw.journey, journey.count <= Limits.journey else { return nil }
        var kept: [Concept] = [], ids = Set<String>()
        for concept in concepts {
            guard let id = concept.id, isID(id), !ids.contains(id), let label = concept.label.flatMap({ clean($0, limit: Limits.label) }),
                  let state = concept.state.flatMap(State.init(rawValue:)) else { return nil }
            let paragraphs = Array(Set((concept.paragraphs ?? []).filter { (1...100_000).contains($0) })).sorted()
            guard paragraphs.count <= Limits.paragraphs else { return nil }
            ids.insert(id)
            kept.append(Concept(id: id, label: label, state: state, paragraphs: paragraphs, note: concept.note.flatMap { clean($0, limit: Limits.note) }))
        }
        var keptLinks: [Link] = [], seen = Set<String>()
        for link in links {
            guard let from = link.from, let to = link.to, ids.contains(from), ids.contains(to), from != to,
                  let kind = link.kind.flatMap(LinkKind.init(rawValue:)) else { return nil }
            guard seen.insert("\(from)>\(to)").inserted else { continue }
            keptLinks.append(Link(from: from, to: to, kind: kind))
        }
        guard journey.allSatisfy({ ids.contains($0) }) else { return nil }
        let map = StudyMap(concepts: kept, links: keptLinks, focus: raw.focus.flatMap { ids.contains($0) ? $0 : nil }, journey: journey,
                           next: raw.next.flatMap(Next.init(rawValue:)) ?? .calibrate)
        guard let encoded = try? JSONEncoder().encode(map), encoded.count <= Limits.bytes else { return nil }
        return map
    }

    private static func isID(_ id: String) -> Bool {
        guard (1...40).contains(id.count), let first = id.unicodeScalars.first, first.properties.isASCIIHexDigit || ("a"..."z").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }
    private static func clean(_ value: String, limit: Int) -> String? {
        let scalars = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let text = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty || text.unicodeScalars.count > limit ? nil : text
    }

    public func concept(_ id: String?) -> Concept? { id.flatMap { id in concepts.first { $0.id == id } } }
    public var focusConcept: Concept? { concept(focus) }
    public func count(_ state: State) -> Int { concepts.filter { $0.state == state }.count }
    /// "3 concepts · 1 known · 1 learning · 1 not yet" (known counts the verified too).
    public var summary: String {
        guard !concepts.isEmpty else { return "Built from your answers as you go" }
        return "\(concepts.count) \(concepts.count == 1 ? "concept" : "concepts") · \(count(.known) + count(.verified)) known · \(count(.learning)) learning · \(count(.unknown)) not yet"
    }

    /// The map as a Mermaid flowchart, drawn by the same strict-mode renderer as the agent's diagrams. Labels are
    /// quoted and stripped of the characters Mermaid reads as syntax; ids are prefixed so none is a keyword.
    public var mermaid: String {
        func node(_ id: String) -> String { "s_" + String(id.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }) }
        func label(_ text: String) -> String {
            let stripped = String(text.map { "\"\\[]{}()<>|#;`".contains($0) ? " " : $0 })
            let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? "concept" : String(collapsed.prefix(48))
        }
        var lines = ["flowchart TD"]
        for concept in concepts { lines.append("  \(node(concept.id))[\"\(label(concept.label))\"]:::\(concept.state.rawValue)") }
        for link in links {
            let edge = switch link.kind { case .prerequisite: "-->"; case .deeper: "-.->"; case .related: "---" }
            lines.append("  \(node(link.from)) \(edge) \(node(link.to))")
        }
        lines += ["  classDef unknown fill:#fbe3e1,stroke:#c0392b,color:#1b1b1b", "  classDef learning fill:#fff1cc,stroke:#d68910,color:#1b1b1b",
                  "  classDef known fill:#dbe9fb,stroke:#2e6fd0,color:#1b1b1b", "  classDef verified fill:#dcf3e2,stroke:#1f8f4e,color:#1b1b1b"]
        if let focus { lines.append("  style \(node(focus)) stroke-width:3px") }
        return lines.joined(separator: "\n")
    }
}

public extension StudyMap.State {
    var text: String {
        switch self { case .unknown: "Not yet"; case .learning: "Learning"; case .known: "Known"; case .verified: "Verified" }
    }
}
public extension StudyMap.Next {
    var text: String {
        switch self {
        case .calibrate: "Finding your starting point"; case .teach: "Teaching"; case .verify: "Checking what you learned"
        case .deeper: "Going deeper"; case .tangent: "Moving to a related idea"; case .revisit: "Returning to an earlier gap"
        }
    }
}
public extension StudyMap.LinkKind {
    var text: String { switch self { case .prerequisite: "builds on"; case .deeper: "goes deeper into"; case .related: "relates to" } }
}
