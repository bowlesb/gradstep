import ImageIO
import SwiftUI
import ScienceReaderCore

/// One figure of the open paper as the gallery shows it: its number ("Figure 3") and caption from the bundle
/// index, and its first image (docs/LEGACY_GAP_AUDIT.md #6).
struct GalleryFigure: Identifiable, Equatable {
    let id: String
    /// "Figure 3", "Table 2", or nil when the caption names none.
    let number: String?
    /// The caption after its number, with escaped LaTeX characters read as text.
    let caption: String
    let imagePath: String?
    /// Images after the first (a figure can hold up to 16).
    let moreImages: Int

    static func all(in index: ReaderBundleIndex) -> [GalleryFigure] {
        index.figures.map { figure in
            let (number, caption) = label(figure.caption.isEmpty ? figure.alt : figure.caption)
            return GalleryFigure(id: figure.id, number: number, caption: caption, imagePath: figure.assetPaths.first,
                                 moreImages: max(0, figure.assetPaths.count - 1))
        }
    }

    /// Splits "Figure 4: Best of N …" into ("Figure 4", "Best of N …"). "Fig. 2", "FIGURE 2", "Figure A.1" and
    /// "Table 3" are recognized; anything else is all caption.
    static func label(_ text: String) -> (number: String?, caption: String) {
        var caption = text.replacing(/\\([{}%$&_#])/) { String($0.output.1) }
        caption = caption.replacing(/\s+/, with: " ").replacing(/\s+([.,;:])/) { String($0.output.1) }
            .trimmingCharacters(in: .whitespaces)
        guard let match = caption.firstMatch(of: /^(fig(?:ure)?\.?|table)\s*([A-Z]?\.?\s?\d{1,3}[a-z]?)\s*[:.|]?\s*/.ignoresCase()) else {
            return (nil, caption)
        }
        let kind = match.output.1.lowercased().hasPrefix("t") ? "Table" : "Figure"
        let number = String(match.output.2).replacing(/\s/, with: "")
        return ("\(kind) \(number)", String(caption[match.range.upperBound...]))
    }
}

/// The paper's figures as a grid (Paper › "…" › Figures). A figure opens the same figure view as a tap in the
/// paper, with previous/next and "Show in paper", which closes the gallery and goes to the figure with Back.
struct FigureGalleryView: View {
    let bundle: VerifiedReaderBundle
    var baseFontSize: Double = 17
    let onShowInPaper: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    private var figures: [GalleryFigure] { GalleryFigure.all(in: bundle.index) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 300), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    ForEach(Array(figures.enumerated()), id: \.element.id) { offset, figure in
                        NavigationLink(value: figure.id) {
                            GalleryCell(bundle: bundle, figure: figure)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("figures.item.\(offset)")
                    }
                }
                .padding(DesignMetrics.margin)
            }
            .overlay { if figures.isEmpty { ContentUnavailableView("No figures", systemImage: "photo", description: Text("This paper has no figures.")) } }
            .navigationTitle("Figures").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                GalleryFigureDetail(bundle: bundle, figures: figures, current: id, baseFontSize: baseFontSize,
                                    onShowInPaper: onShowInPaper, close: { dismiss() })
            }
        }
    }
}

private struct GalleryCell: View {
    let bundle: VerifiedReaderBundle
    let figure: GalleryFigure
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground))
                if let image {
                    // Figures are drawn on white in the paper; keep that background in dark mode too.
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6)).padding(6)
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if figure.moreImages > 0 {
                    Text("+\(figure.moreImages)").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule()).padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let number = figure.number { Text(number).font(.subheadline.weight(.semibold)) }
                if !figure.caption.isEmpty {
                    Text(figure.caption).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([figure.number, figure.caption.isEmpty ? nil : figure.caption].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(.isButton)
        .task(id: figure.id) { image = await GalleryThumbnails.image(bundle: bundle, path: figure.imagePath) }
    }
}

/// Small decoded copies of the bundle's images (already admitted by ReaderBundleLoader), kept while the app runs.
@MainActor enum GalleryThumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(bundle: VerifiedReaderBundle, path: String?) async -> UIImage? {
        guard let path, let data = bundle.data(for: path) else { return nil }
        let key = "\(bundle.manifestSHA256)/\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// A figure from the gallery: the same view as a tap in the paper, with previous/next and "Show in paper".
private struct GalleryFigureDetail: View {
    let bundle: VerifiedReaderBundle
    let figures: [GalleryFigure]
    @State var current: String
    let baseFontSize: Double
    let onShowInPaper: (String) -> Void
    /// Closes the gallery (Done), as from its grid.
    let close: () -> Void

    private var index: Int { figures.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        FigureWebView(bundle: bundle, figureID: current, baseFontSize: baseFontSize)
            .id(current)
            .navigationTitle(figures.indices.contains(index) ? figures[index].number ?? "Figure \(index + 1)" : "Figure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { current = figures[index - 1].id } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous figure").disabled(index == 0)
                    Spacer()
                    Button("Show in paper") { onShowInPaper(current) }.accessibilityIdentifier("figures.showInPaper")
                    Spacer()
                    Button { current = figures[index + 1].id } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next figure").disabled(index >= figures.count - 1)
                }
            }
    }
}
