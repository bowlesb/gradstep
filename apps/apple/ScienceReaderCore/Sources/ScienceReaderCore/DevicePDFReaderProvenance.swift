import Foundation

/// The provenance of a bundle the on-device PDF route made (docs/architecture/DEVICE_PDF_ROUTE.md): which PDF
/// (its digest is the manifest's source), which converter, and, when the PDF belongs to a library paper, that
/// paper's arXiv identity. The bundle's text came from the reader's own models; nothing here is an official source.
public struct DevicePDFReaderSource: Equatable, Hashable, Sendable {
    public let pdfSHA256: String
    public let paper: DevicePDFPaper?
}

/// The library paper a PDF belongs to: an arXiv paper (its id and revision) or a PDF the reader added themselves
/// (`local:<uuid>`, revision 1; `LocalPDFMembership`).
public struct DevicePDFPaper: Equatable, Hashable, Sendable {
    public let sourceID: String
    public let revision: Int
    public init(sourceID: String, revision: Int) throws {
        guard (1...2_147_483_647).contains(revision), (try? ArxivReaderSource(sourceID: sourceID, revision: revision)) != nil || Self.isLocal(sourceID) else {
            throw ReaderBundleError.invalidResource
        }
        self.sourceID = sourceID; self.revision = revision
    }
    static func isLocal(_ value: String) -> Bool {
        value.hasPrefix("local:") && UUID(uuidString: String(value.dropFirst(6))) != nil && value == value.lowercased()
    }
}

enum DevicePDFReaderProvenance {
    static let format = "device-pdf-reader-provenance-v1"

    static func validate(_ data: Data, manifest: ReaderBundleManifest) throws -> DevicePDFReaderSource {
        guard (1...2_097_152).contains(data.count),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == format,
              let source = root["source"] as? [String: Any], source["kind"] as? String == "device-pdf",
              let pdf = source["pdf_sha256"] as? String, pdf == manifest.source.sha256,
              let adapter = root["adapter"] as? [String: Any], adapter["id"] as? String == manifest.renderer.id,
              adapter["build_sha256"] as? String == manifest.renderer.buildSHA256 else { throw ReaderBundleError.invalidResource }
        var paper: DevicePDFPaper?
        if let value = source["paper"] {
            guard let row = value as? [String: Any], let id = row["source_id"] as? String, let revision = row["revision"] as? Int else {
                throw ReaderBundleError.invalidResource
            }
            paper = try DevicePDFPaper(sourceID: id, revision: revision)
        }
        return DevicePDFReaderSource(pdfSHA256: pdf, paper: paper)
    }
}
