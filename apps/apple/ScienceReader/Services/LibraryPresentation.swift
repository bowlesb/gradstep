import Foundation
import ScienceReaderCore

/// Final native metadata only. An item never retains its complete wire DTO or
/// any decoded reading bytes; those remain owned by the live protocol/store and
/// the selected reader respectively. Import IDs survive even when hidden so a
/// restored mapping can suppress duplicate queued rows without settling them.
enum LibraryPresentationRow: Sendable {
    struct Item: Sendable {
        let paper: Paper
        let createdSequence: Int64
        let canReadStructured: Bool
    }

    case item(Item)
    case imported(id: UUID, visible: LibraryImportRecord?)

    /// Pure, synchronous mapping shared by live and authenticated cache input.
    /// Full author joining is done here, including during the measured restore.
    static func project(_ entry: LibraryEntry) -> Self? {
        switch entry {
        case .item(let item):
            guard item.visible else { return nil }
            return .item(.init(paper: Paper(id: item.documentID,
                title: item.metadata?.title ?? "Untitled paper",
                authors: item.metadata?.authors.joined(separator: ", ") ?? "",
                year: item.metadata?.publishedAt.flatMap { Int($0.prefix(4)) },
                abstract: item.metadata?.abstract ?? "", keywords: item.metadata?.categories ?? [],
                fileURL: nil, artifactID: item.artifactID,
                sourceID: item.sourceID, sourceRevision: item.sourceRevision,
                authorNames: item.metadata?.authors ?? [], addedAt: item.addedAt.date, pageCount: item.pageCount,
                canReadStructured: item.canReadStructured, archived: item.isArchived, venue: item.metadata?.venue),
                createdSequence: item.createdSequence, canReadStructured: item.canReadStructured))
        case .import(let value):
            return .imported(id: value.id, visible: value.visible ? value : nil)
        }
    }
}

extension Paper {
    /// The secondary line the reader shows under the authors: "2017 · NeurIPS · arXiv 1706.03762v7",
    /// or "2015 · Nature · Open access" for a web paper. Unknown parts are left out; nil when nothing
    /// is known. The bundled sample prints its own year, so it has none.
    var publicationLine: String? {
        guard !isSample else { return nil }
        var parts: [String] = []
        if let year, (1000...9999).contains(year) { parts.append(String(year)) }
        if let venue = venue?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !venue.isEmpty {
            parts.append(venue.count > 80 ? String(venue.prefix(79)) + "…" : venue)
        }
        if let sourceID, let badge = LibrarySource.badge(sourceID: sourceID, revision: sourceRevision) {
            // arXiv papers show their identifier (readers cite it); web papers the badge alone.
            parts.append(LibrarySource.isWebSourceID(sourceID) ? badge : "arXiv " + (sourceReference ?? sourceID))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
