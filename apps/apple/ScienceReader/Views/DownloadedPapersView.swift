import SwiftUI
import ScienceReaderCore

/// Settings › Your assets › Downloaded papers (owner, build 59): the papers this device keeps, largest first, each
/// removable. Removing never touches the library: the paper, its chats and its place stay, and it downloads again
/// when opened.
struct DownloadedPapersView: View {
    @Bindable var model: ReaderModel
    @State private var removing: Set<String>? = nil

    var body: some View {
        let papers = model.downloadedPapers
        List {
            if !papers.isEmpty {
                Section {
                    ForEach(papers) { paper in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(paper.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text("\(paper.kinds) · \(Self.size(paper.totalBytes))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("downloads.\(paper.id)")
                        .swipeActions(allowsFullSwipe: false) {
                            Button { removing = [paper.id] } label: { Label("Remove", systemImage: "trash") }.tint(.red)
                        }
                        .contextMenu {
                            Button(role: .destructive) { removing = [paper.id] } label: { Label("Remove download", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("\(papers.count) \(papers.count == 1 ? "paper" : "papers") · \(Self.size(papers.reduce(0) { $0 + $1.totalBytes }))")
                } footer: {
                    Text("Removing a download frees space on this device only. The paper stays in your library with its chats, and downloads again when you open it.")
                }
                Section {
                    Button("Remove all downloads", role: .destructive) { removing = Set(papers.map(\.id)) }
                        .accessibilityIdentifier("downloads.removeAll")
                }
            }
        }
        .overlay {
            if papers.isEmpty {
                ContentUnavailableView("No downloaded papers", systemImage: "arrow.down.circle",
                                       description: Text("Papers you open are kept on this device so they open at once."))
            }
        }
        .navigationTitle("Downloaded papers").navigationBarTitleDisplayMode(.inline)
        .task { await model.refreshLocalRecords() }
        .alert(removing?.count == 1 ? "Remove this download?" : "Remove all downloads?",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let ids = removing { Task { await model.removeDownloads(ids) } }
                removing = nil
            }.accessibilityIdentifier("downloads.confirmRemove")
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This doesn’t remove anything from your library: the papers and their chats stay, and download again when you open them.")
        }
        .tabBarSpace(color: .chromeGroupedBackground)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
