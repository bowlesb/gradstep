import SwiftUI
import ScienceReaderCore

extension Paper {
    var publicLink: PublicPaperLink? {
        if let sourceReference, let link = PublicPaperLink(arxiv: sourceReference) { return link }
        if let url = sourceURL.flatMap(URL.init(string:)), url.host?.lowercased() == "doi.org" { return PublicPaperLink(doi: String(url.path.dropFirst())) }
        return nil
    }
    var publicSourceURL: URL? {
        publicLink?.sourceURL ?? sourceURL.flatMap { raw in
            guard let url = URL(string: raw), ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil else { return nil }
            return url
        }
    }
}

struct PaperShareMenu: View {
    let paper: Paper
    var body: some View {
        if let source = paper.publicSourceURL {
            Menu {
                ShareLink("Source URL", item: source)
                if let link = paper.publicLink { ShareLink("Gradstep link", item: link.url) }
            } label: { Label("Share paper", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("paper.share")
        }
    }
}

extension ReaderModel {
    func openPaperLink(_ url: URL) {
        guard let link = PublicPaperLink(url: url) else { return }
        let arxiv = link.kind == "arxiv" ? try? ArxivReference(link.identity) : nil
        if let paper = papers.first(where: { $0.publicLink == link || (arxiv?.revision == nil && arxiv != nil && $0.sourceID == arxiv?.sourceID) }) {
            select(paper)
        } else {
            searchPapers(link.identity)
        }
    }
}
