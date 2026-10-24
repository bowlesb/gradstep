import CoreGraphics
import Foundation

/// The provenance of a bundle the on-device PDF route made (docs/architecture/DEVICE_PDF_ROUTE.md): which PDF
/// (its digest is the manifest's source), which converter, and, when the PDF belongs to a library paper, that
/// paper's arXiv identity. The bundle's text came from the reader's own models; nothing here is an official source.
public struct DevicePDFReaderSource: Equatable, Hashable, Sendable {
    public let pdfSHA256: String
    public let paper: DevicePDFPaper?
    /// Where each figure's crop sits on its page, by figure id (port revision 10); empty for older readings, which then
    /// offer no zoom-out onto the page.
    public var figures: [String: DevicePDFFigureRegion] = [:]
}

/// A figure's crop on its PDF page (FIGURE_VIEW.md "Zoom out onto the page"): the page (from 0), the crop and the page's
/// size in points from the top left of the page as shown (its crop box, turned by its /Rotate), as the converter cut it.
public struct DevicePDFFigureRegion: Equatable, Hashable, Sendable {
    public let page: Int
    public let x0: Double, y0: Double, x1: Double, y1: Double
    public let pageWidth: Double, pageHeight: Double
    public init?(page: Int, x0: Double, y0: Double, x1: Double, y1: Double, pageWidth: Double, pageHeight: Double) {
        // A crop may reach a point past the page (whole pixels rounded outwards); nothing else is admitted.
        guard (0..<100_000).contains(page), [x0, y0, x1, y1, pageWidth, pageHeight].allSatisfy(\.isFinite),
              (1...20_000).contains(pageWidth), (1...20_000).contains(pageHeight), x1 - x0 >= 1, y1 - y0 >= 1,
              x0 >= -1, y0 >= -1, x1 <= pageWidth + 1, y1 <= pageHeight + 1 else { return nil }
        self.page = page; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.pageWidth = pageWidth; self.pageHeight = pageHeight
    }
    public var crop: CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
    public var pageSize: CGSize { CGSize(width: pageWidth, height: pageHeight) }
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
        return DevicePDFReaderSource(pdfSHA256: pdf, paper: paper, figures: figures(root["figures"]))
    }

    /// `[id, page, x0, y0, x1, y1, page width, page height]` rows; a row that is not one is left out (its figure simply
    /// has no zoom-out), never the reading.
    static func figures(_ value: Any?) -> [String: DevicePDFFigureRegion] {
        guard let rows = value as? [[Any]] else { return [:] }
        var out: [String: DevicePDFFigureRegion] = [:]
        for row in rows.prefix(256) where row.count == 8 {
            guard let id = row[0] as? String, (1...128).contains(id.utf8.count), let page = row[1] as? Int else { continue }
            let numbers = row[2...].compactMap { ($0 as? NSNumber).map(\.doubleValue) }
            guard numbers.count == 6, let region = DevicePDFFigureRegion(page: page, x0: numbers[0], y0: numbers[1], x1: numbers[2], y1: numbers[3],
                                                                       pageWidth: numbers[4], pageHeight: numbers[5]) else { continue }
            out[id] = region
        }
        return out
    }
}
