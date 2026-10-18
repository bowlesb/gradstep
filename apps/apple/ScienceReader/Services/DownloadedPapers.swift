import Foundation
import ScienceReaderCore

/// Settings › Your assets › Downloaded papers (owner, build 59: "a downloaded papers section… that will allow you to
/// delete them… with a message saying that this will not delete the article from their library"): what this device
/// holds for each paper — its prepared reading copy and any PDF kept — and removing them, which never touches the
/// library or its chats.
struct DownloadedPaper: Identifiable, Equatable {
    /// The arXiv source id (a PDF the reader added keeps its local id).
    let id: String
    let title: String
    let readerBytes: Int64
    let pdfBytes: Int64
    var totalBytes: Int64 { readerBytes + pdfBytes }
    /// "Reading copy · PDF", "PDF", …
    var kinds: String { [readerBytes > 0 ? "Reading copy" : nil, pdfBytes > 0 ? "PDF" : nil].compactMap { $0 }.joined(separator: " · ") }
}

extension ReaderModel {
    var downloadedPapers: [DownloadedPaper] {
        var reader: [String: Int64] = [:], pdf: [String: Int64] = [:]
        for record in localReaderRecords { reader[record.identity.sourceID, default: 0] += record.byteCount }
        for record in localPaperRecords { pdf[record.identity.sourceID, default: 0] += record.byteCount }
        let titles = Dictionary(papers.compactMap { paper in paper.sourceID.map { ($0, paper.title) } }, uniquingKeysWith: { first, _ in first })
        return Set(reader.keys).union(pdf.keys).map { id in
            DownloadedPaper(id: id, title: titles[id] ?? LibrarySource.placeholderTitle(sourceID: id), readerBytes: reader[id] ?? 0, pdfBytes: pdf[id] ?? 0)
        }
        .sorted { $0.totalBytes == $1.totalBytes ? $0.title < $1.title : $0.totalBytes > $1.totalBytes }
    }

    /// Removes this device's copies of one paper (all revisions). The paper stays in the library; opening it downloads
    /// and prepares it again.
    func removeDownloads(_ ids: Set<String>) async {
        forgetIndexedPapers(Set(papers.filter { ids.contains($0.sourceID ?? "") }.map(\.id)))
        let readers = localReaderRecords.filter { ids.contains($0.identity.sourceID) }
        let pdfs = localPaperRecords.filter { ids.contains($0.identity.sourceID) }
        do {
            if !readers.isEmpty {
                let write = try acceptLocalReaderStoreWrite { store in for record in readers { try await store.remove(record.identity) } }
                _ = try await write.value
            }
            if !pdfs.isEmpty {
                let write = try acceptLocalPaperWrite { store in for record in pdfs { try await store.remove(record.identity) } }
                _ = try await write.value
            }
        } catch {
            self.error = "Couldn’t remove the download. Try again."
        }
        await refreshLocalRecords()
        // A paper shown from a copy that is gone keeps its page until it is opened again; the others let go of theirs.
        papers = papers.map { paper in
            guard let id = paper.sourceID, ids.contains(id), paper.id != selectedPaper?.id, paper.readerBundle != nil else { return paper }
            return paper.displaying(nil)
        }
    }
}
