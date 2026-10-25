#if DEBUG && FIXTURE_HOST
import Foundation

/// Fault injection for UI journeys (docs/architecture/RESILIENCE.md "Fault injection",
/// docs/reviews/OFFLINE_AND_STORAGE_20261025.md): requests whose path starts with a given prefix fail the way a struggling
/// service or a bad connection fails, so a journey can prove the rest of the app keeps working. Compiled out of release
/// and physical-device builds; never opens a connection.
///
/// `--backend-fault=<prefix>:<kind>` (repeatable). `<prefix>`: a path (`rest/v1/rpc/v1_key_state`), a host and path
/// (`arxiv.org/html`) or `*` for every request. `<kind>`:
/// - an HTTP status (a 429 carries `Retry-After: 30`), `timeout`, `malformed` (a 200 with cut-off JSON);
/// - `offline` (no network), `dns` (the name doesn't resolve), `tls` (a secure connection can't be made), `lost` (the
///   connection drops after the response starts), `html` (a captive Wi‑Fi's sign-in page, 200 text/html, in place of
///   the answer).
/// `--network-offline[=<seconds>]` (`NetworkFaultFixture`) fails every request as offline, for that long after launch.
/// Installed on every session the app makes: the backend's (`BackendClient`), arXiv's, the PDF downloader's and search's.
final class BackendFaultProtocol: URLProtocol {
    struct Fault: Equatable { let prefix: String; let kind: Kind }
    enum Kind: Equatable { case status(Int), timeout, malformed, offline, dns, tls, lost, html }

    static let faults: [Fault] = parse(ProcessInfo.processInfo.arguments)
    static var isActive: Bool { !faults.isEmpty || NetworkFaultFixture.offlineWindow != nil }

    static func parse(_ arguments: [String]) -> [Fault] {
        arguments.compactMap { argument -> Fault? in
            guard argument.hasPrefix("--backend-fault=") else { return nil }
            let value = argument.dropFirst("--backend-fault=".count)
            guard let colon = value.lastIndex(of: ":") else { return nil }
            let prefix = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let spec = String(value[value.index(after: colon)...])
            let named: [String: Kind] = ["timeout": .timeout, "malformed": .malformed, "offline": .offline, "dns": .dns, "tls": .tls,
                                         "lost": .lost, "html": .html]
            guard !prefix.isEmpty, let kind = named[spec] ?? Int(spec).map(Kind.status) else { return nil }
            return Fault(prefix: prefix, kind: kind)
        }
    }

    static func fault(for request: URLRequest) -> Fault? {
        guard let url = request.url else { return nil }
        if NetworkFaultFixture.isOffline { return Fault(prefix: "*", kind: .offline) }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let located = (url.host ?? "") + "/" + path
        return faults.first { $0.prefix == "*" || path.hasPrefix($0.prefix) || located.hasPrefix($0.prefix) }
    }

    /// Puts the injector in front of a session's requests while a fault is configured (a no-op otherwise).
    static func install(in configuration: URLSessionConfiguration) {
        guard isActive else { return }
        configuration.protocolClasses = [BackendFaultProtocol.self] + (configuration.protocolClasses ?? [])
    }

    override class func canInit(with request: URLRequest) -> Bool { fault(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fault = Self.fault(for: request), let url = request.url else { return }
        switch fault.kind {
        case .timeout:
            // As a request that never answers ends: the timeout error, after a short wait.
            fail(.timedOut, after: 1)
        case .offline: fail(.notConnectedToInternet, after: 0.05)
        case .dns: fail(.cannotFindHost, after: 0.2)
        case .tls: fail(.secureConnectionFailed, after: 0.2)
        case .lost:
            // The answer starts, then the connection drops partway.
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/octet-stream", "Content-Length": "1048576"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x25, count: 4096))
            fail(.networkConnectionLost, after: 0.3)
        case .html:
            respond(url: url, status: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: Data("<!doctype html><html><head><title>Sign in to Wi-Fi</title></head><body><form>Accept terms</form></body></html>".utf8))
        case .malformed:
            respond(url: url, status: 200, headers: ["Content-Type": "application/json"], body: Data("{\"unexpected\":".utf8))
        case .status(let status):
            var headers = ["Content-Type": "application/json"]
            if status == 429 { headers["Retry-After"] = "30" }
            respond(url: url, status: status, headers: headers, body: Data("{\"code\":\"fault_injected\"}".utf8))
        }
    }
    override func stopLoading() {}

    private func fail(_ code: URLError.Code, after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    private func respond(url: URL, status: Int, headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
