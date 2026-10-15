#if DEBUG && FIXTURE_HOST
import Foundation

/// Fault injection for UI journeys (docs/architecture/RESILIENCE.md "Fault injection"): requests to our backend whose
/// path starts with a given prefix fail the way a struggling service fails, so a journey can prove the rest of the app
/// keeps working. Compiled out of release and physical-device builds; never opens a connection.
///
/// `--backend-fault=<path-prefix>:<status>|timeout|malformed` (repeatable), e.g.
/// `--backend-fault=rest/v1/rpc/v1_key_state:503`, `--backend-fault=auth/v1/otp:429`. A 429 carries `Retry-After: 30`.
final class BackendFaultProtocol: URLProtocol {
    struct Fault: Equatable { let prefix: String; let kind: Kind }
    enum Kind: Equatable { case status(Int), timeout, malformed }

    static let faults: [Fault] = parse(ProcessInfo.processInfo.arguments)
    static var isActive: Bool { !faults.isEmpty }

    static func parse(_ arguments: [String]) -> [Fault] {
        arguments.compactMap { argument -> Fault? in
            guard argument.hasPrefix("--backend-fault=") else { return nil }
            let value = argument.dropFirst("--backend-fault=".count)
            guard let colon = value.lastIndex(of: ":") else { return nil }
            let prefix = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let spec = value[value.index(after: colon)...]
            let kind: Kind? = spec == "timeout" ? .timeout : spec == "malformed" ? .malformed : Int(spec).map(Kind.status)
            guard !prefix.isEmpty, let kind else { return nil }
            return Fault(prefix: prefix, kind: kind)
        }
    }

    static func fault(for request: URLRequest) -> Fault? {
        guard let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return nil }
        return faults.first { path.hasPrefix($0.prefix) }
    }

    override class func canInit(with request: URLRequest) -> Bool { fault(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fault = Self.fault(for: request), let url = request.url else { return }
        switch fault.kind {
        case .timeout:
            // As a request that never answers ends: the timeout error, after a short wait.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        case .malformed:
            respond(url: url, status: 200, headers: ["Content-Type": "application/json"], body: Data("{\"unexpected\":".utf8))
        case .status(let status):
            var headers = ["Content-Type": "application/json"]
            if status == 429 { headers["Retry-After"] = "30" }
            respond(url: url, status: status, headers: headers, body: Data("{\"code\":\"fault_injected\"}".utf8))
        }
    }
    override func stopLoading() {}

    private func respond(url: URL, status: Int, headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
