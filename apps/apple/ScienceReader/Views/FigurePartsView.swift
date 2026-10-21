import SwiftUI
import ScienceReaderCore

/// The image of a figure in a bundle on this device, by its manifest and member paths (several: its panels composed),
/// set by RootView from the model.
struct FigureImageLookupKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable (String, [String]) -> CGImage? = { _, _ in nil } }
/// An answer's figure parts completed on the image as it was sent (`ReaderModel.figurePartCrops`), set by RootView.
struct FigurePartCropsLookupKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable (StoredFigureParts) -> [FigurePartCrop?]? = { _ in nil } }
extension EnvironmentValues {
    var figureImage: @MainActor @Sendable (String, [String]) -> CGImage? {
        get { self[FigureImageLookupKey.self] }
        set { self[FigureImageLookupKey.self] = newValue }
    }
    var figurePartCrops: @MainActor @Sendable (StoredFigureParts) -> [FigurePartCrop?]? {
        get { self[FigurePartCropsLookupKey.self] }
        set { self[FigurePartCropsLookupKey.self] = newValue }
    }
}

/// One part as it is shown (FIGURE_VIEW.md "Complete crops"): its crop completed over the ink its box cut, on a margin of
/// the figure's white background, or the whole figure when no crop could hold it all; `region` is where it is in the
/// figure (fractions), for the outline.
struct FigurePartCrop: @unchecked Sendable {
    let image: CGImage
    let region: CropRect
    let whole: Bool
    /// A figure image handed to the work off the main actor (CGImage is immutable).
    struct Unchecked: @unchecked Sendable { let image: CGImage }

    /// Every part of `stored`, completed together on the image as the question carried it: the paper's figure prepared
    /// again exactly as it was sent (`ChatFigureFinder.prepare`, from the asset's own bytes for one image). Pure; run it
    /// off the main actor.
    static func all(_ stored: StoredFigureParts, image: CGImage, asset: Data?) -> [FigurePartCrop?] {
        let sent = asset.flatMap { ChatFigureFinder.prepare($0) } ?? ChatFigureFinder.prepare(image)
        let shown = PresentedCrop.all(stored.parts.map(\.fractions), ink: sent.flatMap { PresentedCrop.ink(of: $0.data) }).crops
        return shown.map { crop in crop.image(from: image).map { FigurePartCrop(image: $0, region: crop.region, whole: crop.whole) } }
    }
}

/// An answer's figure parts (docs/proposals/CHAT_TOOLS.md item 4): the whole figure with its parts numbered, then each
/// part cropped from the paper's own image with the answer's note. Without the paper on this device, the notes alone.
struct FigurePartsView: View {
    let stored: StoredFigureParts
    @Environment(\.figureImage) private var figureImage
    @Environment(\.figurePartCrops) private var figurePartCrops

    var body: some View {
        ScrollView {
            FigurePartsContent(stored: stored, image: figureImage(stored.manifestSHA256, stored.paths), crops: figurePartCrops(stored))
                .padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    /// Where part `index` is outlined: its completed crop, or its box when the crop is the whole figure or not ready.
    static func outline(_ part: ChatFigureParts.Part, _ crop: FigurePartCrop??) -> CropRect {
        if let crop = crop ?? nil, !crop.whole { return crop.region }
        return part.fractions
    }
}

/// The parts themselves (no scrolling), so the sheet and a rendering share one layout.
struct FigurePartsContent: View {
    let stored: StoredFigureParts
    let image: CGImage?
    /// Each part's completed crop; nil while they are worked out (no crop shows and then changes size).
    let crops: [FigurePartCrop?]?

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .overlay { GeometryReader { proxy in
                            ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                                let r = FigurePartsView.outline(part, crops?[safeIndex: index])
                                let rect = CGRect(x: r.x0 * proxy.size.width, y: r.y0 * proxy.size.height,
                                                  width: (r.x1 - r.x0) * proxy.size.width, height: (r.y1 - r.y0) * proxy.size.height)
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
                                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor))
                                    .position(x: rect.minX + 12, y: rect.minY + 10)
                            }
                        } }
                        // The whole figure on a margin of its white background too (owner, 2026-10-21).
                        .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("The figure with its parts outlined")
                        .accessibilityIdentifier("figureParts.whole")
                } else {
                    Label("Open the paper on this device to see each part cropped from the figure.", systemImage: "photo")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                                .frame(minWidth: 22, minHeight: 22).background(Circle().fill(Color.accentColor))
                            Text(part.label).font(.headline)
                        }
                        if image != nil, let crop = crops?[safeIndex: index] ?? nil {
                            Image(decorative: crop.image, scale: 1).resizable().scaledToFit().frame(maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                                .accessibilityLabel("Part \(index + 1): \(part.label)")
                        }
                        Text(part.note).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("figureParts.part.\(index + 1)")
                }
            }
    }
}

/// Under an answer: the figure's parts as a row of crops with their numbers and labels; a tap opens them all with notes.
struct FigurePartsStrip: View {
    let stored: StoredFigureParts
    let image: CGImage?
    let crops: [FigurePartCrop?]?
    let fontSize: Double
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                if let image {
                    ScrollView(.horizontal, showsIndicators: false) { FigurePartsThumbnails(stored: stored, image: image, crops: crops, fontSize: fontSize) }
                }
                Label("Figure parts: \(stored.title)", systemImage: "square.split.2x2").font(.system(size: fontSize * 0.86))
                    .foregroundStyle(Color.accentColor).lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Figure parts: \(stored.title), \(stored.parts.count) parts")
        .accessibilityHint("Opens each part with its explanation")
    }
}

/// The row of crops under an answer (no scrolling of its own).
struct FigurePartsThumbnails: View {
    let stored: StoredFigureParts
    let image: CGImage
    let crops: [FigurePartCrop?]?
    let fontSize: Double
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                VStack(alignment: .leading, spacing: 4) {
                    if let crop = crops?[safeIndex: index] ?? nil {
                        Image(decorative: crop.image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: 180, maxHeight: 120)
                            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    }
                    Text("\(index + 1). \(part.label)").font(.system(size: fontSize * 0.78, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
        }
    }
}

/// An answer whose text marks where its figure's parts go: the text in pieces, each part's crop between them where the
/// answer discusses it, with its number and label (the prose already says what it shows, so no note is repeated).
/// Each piece of text keeps the answer's own rendering, selection actions and citations.
struct InlineFigurePartsAnswer: View {
    let source: String
    let stored: StoredFigureParts
    let image: CGImage?
    let crops: [FigurePartCrop?]?
    let fontSize: Double
    let identifier: String
    var onQuote: ChatQuoteHandler?
    var onCite: ChatCiteHandler?

    var body: some View {
        let segments = FigurePartMarkers.segments(ChatRichText.withoutAnswerLabel(source), parts: stored.parts.count)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let text):
                    ChatMessageText(source: text, fontSize: fontSize, streaming: false, speaker: "Assistant",
                                    identifier: index == 0 ? identifier : "\(identifier).\(index)", assistant: true, onQuote: onQuote, onCite: onCite)
                case .part(let number):
                    InlineFigurePart(number: number, part: stored.parts[number - 1], crop: image == nil ? nil : crops?[safeIndex: number - 1] ?? nil, fontSize: fontSize)
                }
            }
        }
    }
}

/// One part, inline in an answer: its number and label, and its crop from the paper's figure at a readable width.
struct InlineFigurePart: View {
    let number: Int
    let part: ChatFigureParts.Part
    let crop: FigurePartCrop?
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").font(.system(size: fontSize * 0.74, weight: .bold)).foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20).background(Circle().fill(Color.accentColor))
                Text(part.label).font(.system(size: fontSize * 0.86, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let crop {
                Image(decorative: crop.image, scale: 1).resizable().scaledToFit()
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Part \(number): \(part.label)")
        .accessibilityIdentifier("chat.message.figurePart.\(number)")
    }
}

/// Under an answer with inline parts: the whole figure, small, with its parts outlined and numbered; a tap opens the
/// full view with every part and note. Without the paper on this device, the title alone.
struct FigurePartsOverview: View {
    let stored: StoredFigureParts
    let image: CGImage?
    let crops: [FigurePartCrop?]?
    let fontSize: Double
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .overlay { GeometryReader { proxy in
                            ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                                let r = FigurePartsView.outline(part, crops?[safeIndex: index])
                                let rect = CGRect(x: r.x0 * proxy.size.width, y: r.y0 * proxy.size.height,
                                                  width: (r.x1 - r.x0) * proxy.size.width, height: (r.y1 - r.y0) * proxy.size.height)
                                RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                                Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Color.accentColor))
                                    .position(x: rect.minX + 9, y: rect.minY + 8)
                            }
                        } }
                        .padding(5).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        .frame(maxWidth: 240, maxHeight: 160, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("\(stored.title) · whole figure", systemImage: "square.split.2x2").font(.system(size: fontSize * 0.8))
                    .foregroundStyle(Color.accentColor).lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Whole figure: \(stored.title), \(stored.parts.count) parts outlined")
        .accessibilityHint("Opens each part with its explanation")
    }
}

extension Array {
    /// The element at `index`, or nil past the end (parts and their crops are kept in step, but a crop may be missing).
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
