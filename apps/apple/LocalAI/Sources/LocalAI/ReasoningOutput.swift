import Foundation

/// Qwen's template primes an open thinking span. Keep it out of the answer even when the lower-level
/// generation API treats those tokens as ordinary text. Retains only a possible delimiter suffix.
struct ReasoningOutput: Sendable {
    private var inside: Bool
    private var pending = ""
    init(thinking: Bool) { inside = thinking }
    mutating func append(_ text: String) -> String {
        pending += text
        var output = ""
        while !pending.isEmpty {
            let delimiter = inside ? "</think>" : "<think>"
            if let match = pending.range(of: delimiter) {
                if !inside { output += pending[..<match.lowerBound] }
                pending = String(pending[match.upperBound...]); inside.toggle()
            } else {
                let held = (1..<delimiter.count).reversed().first { pending.hasSuffix(delimiter.prefix($0)) } ?? 0
                if !inside { output += pending.dropLast(held) }
                pending = held == 0 ? "" : String(pending.suffix(held))
                break
            }
        }
        return output
    }
    mutating func finish() -> String {
        defer { pending = "" }
        return inside ? "" : pending
    }
}
