import Foundation
import ImageIO
import ScienceReaderCore
import UniformTypeIdentifiers
import WebKit

enum ReaderBundleLoader {
    // The sample is authored fixture data. Its trusted digest is compiled into
    // the app, never read from the unverified manifest it authenticates.
    static let sampleManifestSHA256 = "4851d8173451955cc36a455dc5d5fe0992a156d186c09f6fb291e05b4935f0b4"
    private static let sampleResult: Result<VerifiedReaderBundle, Error> = Result {
        guard let resources = Bundle.main.resourceURL else { throw ReaderBundleError.invalidResource }
        return try load(directory: resources.appendingPathComponent("ReaderSamples/" + sampleManifestSHA256),
                        expectedSHA256: sampleManifestSHA256)
    }
    static func sample() throws -> VerifiedReaderBundle { try sampleResult.get() }

    static func load(directory: URL, expectedSHA256: String) throws -> VerifiedReaderBundle {
        try admitImages(in: VerifiedReaderBundle.load(directory: directory, expectedSHA256: expectedSHA256))
    }

    /// The encrypted cache can reopen an owned payload without extracting files.
    /// Apply the same integrity and image admission as the compiled/disk source.
    static func verify(manifest: Data, expectedSHA256: String, members: [String: Data]) throws -> VerifiedReaderBundle {
        try admitImages(in: VerifiedReaderBundle.verify(manifest: manifest, expectedSHA256: expectedSHA256, members: members))
    }

    private static func admitImages(in bundle: VerifiedReaderBundle) throws -> VerifiedReaderBundle {
        // Metadata/header recognition alone is insufficient. Force decoding of
        // every bounded raster while the bundle still cannot be presented.
        for member in bundle.manifest.members where member.role == "image" {
            guard let data = bundle.data(for: member.path), let width = member.width, let height = member.height else { throw ReaderBundleError.invalidResource }
            try ReaderPNGValidator.validate(data, width: width, height: height)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width == member.width, height == member.height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == member.width, image.height == member.height,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ReaderBundleError.invalidResource }
        }
        return bundle
    }
}

/// All responses are synchronous from the immutable snapshot. There is no
/// outstanding network/file callback after WebKit cancels a scheme task.
@MainActor
final class ReaderBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    let bundle: VerifiedReaderBundle
    init(bundle: VerifiedReaderBundle) { self.bundle = bundle }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET",
              let url = urlSchemeTask.request.url, let resource = bundle.resource(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        let response = URLResponse(url: url, mimeType: resource.mediaType,
                                   expectedContentLength: resource.data.count,
                                   textEncodingName: resource.mediaType.hasPrefix("text/") ? "utf-8" : nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(resource.data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
