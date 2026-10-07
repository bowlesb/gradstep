import Foundation

// "Download on this device" (docs/architecture/PDF_UPLOADS.md): about 17 publishers refuse downloads from
// cloud servers, so the reader's own network fetches the PDF and it is uploaded to the same paper. The
// checks are the server's (supabase/functions/_shared/web-source.ts): https on the default port to a
// public DNS name, every redirect hop re-checked and re-resolved, private/local addresses refused, at
// most 64 MiB, `%PDF-` bytes required; a landing page is followed once to the PDF it declares. Bot
// checks are not evaded: the app's ordinary request, nothing more.

/// A PDF fetched on this device, in a temporary file, with the page title when one was seen.
struct DevicePDF: Sendable {
    let file: URL
    let title: String?
    let link: URL
}

protocol DevicePDFFetching: Sendable {
    func fetch(_ links: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> DevicePDF
}

/// Why a device download failed, most telling first (several links: the most telling one is shown).
enum DeviceFetchError: Error, Equatable, Sendable, Comparable {
    case failed, unreachable, notPDF, blocked, restricted, unsafe, tooLarge

    var message: String {
        switch self {
        case .blocked: "The paper’s website blocked this device too. Open it in Safari, download the PDF, then share it to Gradstep or upload it."
        case .restricted: "The website asks for a sign-in. Open it in Safari and sign in (for example through your library), then share the PDF to Gradstep."
        case .notPDF: "The link didn’t lead to a PDF on this device either. Open it in Safari to find the PDF."
        case .tooLarge: PDFFileProblem.tooLarge.message
        case .unreachable: "Couldn’t reach the paper’s website from this device. Check your connection and try again."
        case .unsafe: "This link points to a private or local address, so it isn’t downloaded."
        case .failed: "Couldn’t download the PDF on this device. Open it in Safari, or upload the PDF."
        }
    }
}

/// The server's URL rules, in Swift: https, default port, no credentials or fragment, a public DNS name
/// (a letter-only top-level label, never an IP literal or a local name), printable ASCII.
enum DeviceLinkPolicy {
    private static let localNames = #"(^|\.)(localhost|local|localdomain|internal|intranet|lan|home|corp|arpa|invalid|test|example)$"#

    static func publicHTTPS(_ url: URL, maxLength: Int = 4_096) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        components.fragment = nil
        guard components.scheme == "https", components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(),
              host.range(of: #"^[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})*\.[a-z]{2,63}$"#, options: .regularExpression) != nil,
              host.range(of: localNames, options: .regularExpression) == nil,
              let result = components.url, result.absoluteString.utf8.count <= maxLength,
              result.absoluteString.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return result
    }

    static func isPublicAddress(_ value: String) -> Bool {
        let address = value.lowercased()
        if let v4 = ipv4(address) { return publicIPv4(v4) }
        guard address.contains(":") else { return false }
        if let mapped = address.range(of: #"::ffff:(\d+\.\d+\.\d+\.\d+)$"#, options: .regularExpression) {
            let tail = String(address[mapped].dropFirst("::ffff:".count))
            return ipv4(tail).map(publicIPv4) ?? false
        }
        if address == "::" || address == "::1" { return false }
        guard let first = UInt32(address.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? "", radix: 16) else { return false }
        // Global unicast only (2000::/3), minus Teredo, documentation and 6to4.
        guard (0x2000...0x3fff).contains(first) else { return false }
        return !address.hasPrefix("2001:0:") && !address.hasPrefix("2001::") && !address.hasPrefix("2001:db8:") && !address.hasPrefix("2001:0db8:")
            && !address.hasPrefix("2002:")
    }

    private static func ipv4(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return nil }
        return parts.map { $0! }
    }
    private static func publicIPv4(_ p: [Int]) -> Bool {
        let (a, b, c) = (p[0], p[1], p[2])
        return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 192 && b == 0 && (c == 0 || c == 2))
            || (a == 192 && b == 88 && c == 99) || (a == 198 && (b == 18 || b == 19)) || (a == 198 && b == 51 && c == 100)
            || (a == 203 && b == 0 && c == 113))
    }

    /// Resolves a host with the system resolver (both families).
    static func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { throw DeviceFetchError.unreachable }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: buffer).split(separator: "%").first.map(String.init) ?? "")
                }
                cursor = entry.pointee.ai_next
            }
            return addresses
        }.value
    }
}

/// What a landing page declares: its PDF (`citation_pdf_url`, a PDF alternate link, a PDF iframe/embed,
/// a prompt meta refresh) and its title. Mirrors web-source.ts `landingPagePDF`.
enum LandingPage {
    static func pdfLink(_ html: String, base: URL) -> URL? {
        var ranked: [(Int, String)] = []
        for tag in matches(#"<(?:meta|link|iframe|embed)\b[^>]*>"#, in: html) {
            let kind = tag.dropFirst().prefix { $0.isLetter }.lowercased()
            switch kind {
            case "meta":
                let name = (attribute(tag, "name") ?? attribute(tag, "property") ?? "").lowercased()
                if name == "citation_pdf_url" || name == "bepress_citation_pdf_url" { ranked.append((0, attribute(tag, "content") ?? "")) }
                else if attribute(tag, "http-equiv")?.lowercased() == "refresh", let content = attribute(tag, "content"),
                        let match = content.range(of: #"^\s*\d{1,2}\s*[;,]\s*url\s*=\s*['"]?[^'"]+"#, options: [.regularExpression, .caseInsensitive]) {
                    let value = String(content[match]); if let eq = value.range(of: "=") {
                        ranked.append((3, String(value[eq.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))))
                    }
                }
            case "link":
                if (attribute(tag, "rel") ?? "").lowercased().contains("alternate"), (attribute(tag, "type") ?? "").lowercased().contains("application/pdf") {
                    ranked.append((1, attribute(tag, "href") ?? ""))
                }
            default:
                let src = attribute(tag, "src") ?? ""
                if (attribute(tag, "type") ?? "").lowercased().contains("application/pdf") || src.range(of: #"\.pdf([?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    ranked.append((2, src))
                }
            }
        }
        for (_, value) in ranked.sorted(by: { $0.0 < $1.0 }) where !value.isEmpty {
            if let url = URL(string: decode(value).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
               let checked = DeviceLinkPolicy.publicHTTPS(url, maxLength: 1_000) { return checked }
        }
        return nil
    }

    static func title(_ html: String) -> String? {
        for tag in matches(#"<meta\b[^>]*>"#, in: html) where (attribute(tag, "name") ?? attribute(tag, "property") ?? "").lowercased() == "citation_title" {
            if let value = attribute(tag, "content") { return PDFFileCheck.cleanTitle(decode(value)) }
        }
        return nil
    }

    /// A refusal page in place of the PDF: a sign-in, a bot check, or a page with no PDF.
    static func refusal(_ html: String, url: URL, status: Int) -> DeviceFetchError {
        let lower = html.lowercased()
        if status == 401 || status == 402 || lower.range(of: #"<input\b[^>]*type\s*=\s*["']?password"#, options: .regularExpression) != nil
            || url.path.range(of: #"(^|/)(login|log-in|signin|sign-in|sso|shibboleth|wayf|idp|authorize)(/|\.|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .restricted
        }
        if lower.range(of: #"cf-turnstile|challenge-platform|cf-chl-|_incapsula_resource|perfdrive|captcha|awswaf|datadome|just a moment|verify you are (a )?human|access denied"#,
                       options: .regularExpression) != nil { return .blocked }
        if status >= 400 { return [403, 405, 451].contains(status) ? .blocked : .failed }
        return .notPDF
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).prefix(2_000).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    private static func attribute(_ tag: String, _ name: String) -> String? {
        let pattern = #"[\s"'/]"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for index in 1...3 { if let range = Range(match.range(at: index), in: tag) { return String(tag[range]) } }
        return nil
    }
    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x2F;", with: "/").replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#x3A;", with: ":").replacingOccurrences(of: "&#58;", with: ":")
    }
}

/// Fetches over this device's network with the server's checks. Each fetch uses its own ephemeral session.
struct DevicePDFFetcher: DevicePDFFetching {
    static let maximumBytes: Int64 = PDFFileCheck.maximumBytes
    static let pageBytes = 1_500_000
    var resolve: @Sendable (String) async throws -> [String] = { try await DeviceLinkPolicy.resolve($0) }
    var configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return configuration
    }()

    func fetch(_ links: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> DevicePDF {
        var worst: DeviceFetchError?
        for link in links.prefix(5) {
            try Task.checkCancellation()
            do { return try await fetchOne(link, progress: progress) }
            catch let error as DeviceFetchError { worst = max(worst ?? error, error) }
        }
        throw worst ?? DeviceFetchError.failed
    }

    private func fetchOne(_ start: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> DevicePDF {
        guard var current = DeviceLinkPolicy.publicHTTPS(start) else { throw DeviceFetchError.unsafe }
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var followedPage = false, title: String?
        for _ in 0..<7 {
            let addresses: [String]
            do { addresses = try await resolve(current.host() ?? "") } catch { throw DeviceFetchError.unreachable }
            guard !addresses.isEmpty, addresses.allSatisfy(DeviceLinkPolicy.isPublicAddress) else { throw DeviceFetchError.unsafe }
            var request = URLRequest(url: current)
            request.setValue("application/pdf, text/html;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do { (bytes, response) = try await session.bytes(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw DeviceFetchError.unreachable }
            guard let http = response as? HTTPURLResponse else { throw DeviceFetchError.failed }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                bytes.task.cancel()
                guard let location = http.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      let checked = DeviceLinkPolicy.publicHTTPS(next) else { throw DeviceFetchError.unsafe }
                current = checked; continue
            }
            if http.statusCode == 429 || http.statusCode >= 500 { bytes.task.cancel(); throw DeviceFetchError.unreachable }
            if http.value(forHTTPHeaderField: "cf-mitigated") == "challenge" || http.value(forHTTPHeaderField: "x-amzn-waf-action") != nil {
                bytes.task.cancel(); throw DeviceFetchError.blocked
            }
            if http.statusCode == 404 || http.statusCode == 410 { bytes.task.cancel(); throw DeviceFetchError.failed }
            if http.expectedContentLength > Self.maximumBytes { bytes.task.cancel(); throw DeviceFetchError.tooLarge }
            let body = try await read(bytes, expected: http.expectedContentLength, progress: progress)
            switch body {
            case .pdf(let file):
                guard http.statusCode == 200 else { try? FileManager.default.removeItem(at: file); throw DeviceFetchError.failed }
                return DevicePDF(file: file, title: title, link: current)
            case .page(let html):
                if http.statusCode >= 400 { throw LandingPage.refusal(html, url: current, status: http.statusCode) }
                title = title ?? LandingPage.title(html)
                guard !followedPage, let next = LandingPage.pdfLink(html, base: current) else { throw LandingPage.refusal(html, url: current, status: 200) }
                followedPage = true; current = next
            case .other:
                let refusal: DeviceFetchError = http.statusCode >= 400 ? (http.statusCode == 401 || http.statusCode == 402 ? .restricted : .blocked) : .notPDF
                throw refusal
            }
        }
        throw DeviceFetchError.failed
    }

    private enum Body { case pdf(URL), page(String), other }

    /// A PDF streamed to a temporary file (refused past 64 MiB); a page read up to 1.5 MB; anything else not at all.
    private func read(_ bytes: URLSession.AsyncBytes, expected: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> Body {
        var head = Data(); var iterator = bytes.makeAsyncIterator()
        while head.count < 512, let byte = try await iterator.next() { head.append(byte) }
        let text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("%PDF-") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString).pdf")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            var written: Int64 = 0, buffer = head
            do {
                defer { try? handle.close() }
                while true {
                    let next = try await iterator.next()
                    if let next { buffer.append(next) }
                    if buffer.count >= 1 << 16 || (next == nil && !buffer.isEmpty) {
                        try handle.write(contentsOf: buffer); written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                        if written > Self.maximumBytes { throw DeviceFetchError.tooLarge }
                        if expected > 0 { progress(min(1, Double(written) / Double(expected))) }
                    }
                    if next == nil { break }
                }
            } catch { try? FileManager.default.removeItem(at: file); bytes.task.cancel(); throw error }
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > Self.maximumBytes { try? FileManager.default.removeItem(at: file); throw DeviceFetchError.tooLarge }
            progress(1)
            return .pdf(file)
        }
        if text.drop(while: { $0 == "\u{FEFF}" || $0.isWhitespace }).hasPrefix("<") {
            var page = head
            while page.count < Self.pageBytes, let byte = try await iterator.next() { page.append(byte) }
            bytes.task.cancel()
            return .page(String(decoding: page, as: UTF8.self))
        }
        bytes.task.cancel()
        return .other
    }
}

/// Every redirect is checked by the fetcher itself (never followed by the session).
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
