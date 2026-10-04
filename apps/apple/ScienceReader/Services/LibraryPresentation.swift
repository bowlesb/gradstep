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
                sourceID: item.sourceID, sourceRevision: item.sourceRevision),
                createdSequence: item.createdSequence, canReadStructured: item.canReadStructured))
        case .import(let value):
            return .imported(id: value.id, visible: value.visible ? value : nil)
        }
    }
}
