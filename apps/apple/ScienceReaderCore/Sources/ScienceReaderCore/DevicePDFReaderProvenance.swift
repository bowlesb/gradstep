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
    /// Where each block's text was read from, by block id, in reading order (port revision 11; Show in PDF): one region per
    /// layout region the block was read from. Empty for older readings, which search the whole PDF instead.
    public var blocks: [String: [DevicePDFTextRegion]] = [:]
    /// Where each equation was read from, by equation id (every revision records it).
    public var equations: [String: DevicePDFTextRegion] = [:]
}

/// A rectangle of a PDF page the on-device route read something from (Show in PDF): the page (from 0) and the box in points
/// from the top left of the page as shown, as the text layer measures it.
public struct DevicePDFTextRegion: Equatable, Hashable, Sendable {
    public let page: Int
    public let x0: Double, y0: Double, x1: Double, y1: Double
    public init?(page: Int, x0: Double, y0: Double, x1: Double, y1: Double) {
        guard (0..<100_000).contains(page), [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) <= 20_000 }), x1 > x0, y1 > y0 else { return nil }
        self.page = page; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var rect: CGRect { CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
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
        return DevicePDFReaderSource(pdfSHA256: pdf, paper: paper, figures: figures(root["figures"]), blocks: blocks(root["blocks"]),
                                     equations: equations(root["equations"]))
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

    /// `[block id, page, x0, y0, x1, y1]` rows (port revision 11), several per block in reading order; a row that is not one
    /// is left out, never the reading.
    static func blocks(_ value: Any?) -> [String: [DevicePDFTextRegion]] {
        guard let rows = value as? [[Any]] else { return [:] }
        var out: [String: [DevicePDFTextRegion]] = [:]
        for row in rows.prefix(100_000) where row.count == 6 {
            guard let id = row[0] as? String, (1...128).contains(id.utf8.count), let region = region(row, page: 1) else { continue }
            out[id, default: []].append(region)
        }
        return out
    }

    /// `[equation id, confidence, rendered, page, x0, y0, x1, y1, baseline]` rows: each equation's source region.
    static func equations(_ value: Any?) -> [String: DevicePDFTextRegion] {
        guard let rows = value as? [[Any]] else { return [:] }
        var out: [String: DevicePDFTextRegion] = [:]
        for row in rows.prefix(100_000) where row.count == 9 {
            guard let id = row[0] as? String, (1...128).contains(id.utf8.count), let region = region(row, page: 3) else { continue }
            out[id] = region
        }
        return out
    }

    /// The page (a whole number) at `page` and the box in the four numbers after it.
    private static func region(_ row: [Any], page index: Int) -> DevicePDFTextRegion? {
        guard let page = row[index] as? Int else { return nil }
        let box = row[(index + 1)...(index + 4)].compactMap { ($0 as? NSNumber).map(\.doubleValue) }
        guard box.count == 4 else { return nil }
        return DevicePDFTextRegion(page: page, x0: box[0], y0: box[1], x1: box[2], y1: box[3])
    }
}
