import Foundation

/// A shareable public identity. No account, conversation, or encrypted object identifiers.
public struct PublicPaperLink: Equatable, Sendable {
    public let kind: String
    public let identity: String
    public init?(arxiv: String) {
        guard let value = try? ArxivReference(arxiv) else { return nil }
        kind = "arxiv"; identity = value.identifier
    }
    public init?(doi: String) {
        let value = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 300, value.range(of: #"^10\.\d{4,9}/[^\s?#]+$"#, options: .regularExpression) != nil else { return nil }
        kind = "doi"; identity = value
    }
    public init?(url: URL) {
        guard url.scheme == "https", url.host == "app.gradstep.ai", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.absoluteString.count <= 1000 else { return nil }
        let parts = url.path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "p" else { return nil }
        if parts[1] == "arxiv", let parsed = Self(arxiv: parts[2]) { self = parsed }
        else if parts[1] == "doi", let parsed = Self(doi: parts[2]) { self = parsed }
        else { return nil }
    }
    public var url: URL {
        let encoded = identity.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-")))!
        return URL(string: "https://app.gradstep.ai/p/\(kind)/\(encoded)")!
    }
    public var sourceURL: URL { URL(string: kind == "arxiv" ? "https://arxiv.org/abs/\(identity)" : "https://doi.org/\(identity)")! }
}
