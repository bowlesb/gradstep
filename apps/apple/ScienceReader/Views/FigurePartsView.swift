import SwiftUI
import ScienceReaderCore

/// The image of a figure in a bundle on this device, by its manifest and member path (set by RootView from the model).
struct FigureImageLookupKey: EnvironmentKey { static let defaultValue: @MainActor @Sendable (String, String) -> CGImage? = { _, _ in nil } }
extension EnvironmentValues {
    var figureImage: @MainActor @Sendable (String, String) -> CGImage? {
        get { self[FigureImageLookupKey.self] }
        set { self[FigureImageLookupKey.self] = newValue }
    }
}

/// An answer's figure parts (docs/proposals/CHAT_TOOLS.md item 4): the whole figure with its parts numbered, then each
/// part cropped from the paper's own image with the answer's note. Without the paper on this device, the notes alone.
struct FigurePartsView: View {
    let stored: StoredFigureParts
    @Environment(\.figureImage) private var figureImage

    var body: some View {
        ScrollView {
            FigurePartsContent(stored: stored, image: figureImage(stored.manifestSHA256, stored.assetPath))
                .padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    /// A part of the figure, by its box in fractions of the image.
    static func crop(_ image: CGImage, _ box: [Double]) -> CGImage? {
        guard box.count == 4 else { return nil }
        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(x: box[0] * w, y: box[1] * h, width: (box[2] - box[0]) * w, height: (box[3] - box[1]) * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return rect.width >= 2 && rect.height >= 2 ? image.cropping(to: rect) : nil
    }
}

/// The parts themselves (no scrolling), so the sheet and a rendering share one layout.
struct FigurePartsContent: View {
    let stored: StoredFigureParts
    let image: CGImage?

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .overlay { GeometryReader { proxy in
                            ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                                let rect = CGRect(x: part.box[0] * proxy.size.width, y: part.box[1] * proxy.size.height,
                                                  width: (part.box[2] - part.box[0]) * proxy.size.width, height: (part.box[3] - part.box[1]) * proxy.size.height)
                                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
                                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor))
                                    .position(x: rect.minX + 12, y: rect.minY + 10)
                            }
                        } }
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
                        if let image, let crop = FigurePartsView.crop(image, part.box) {
                            Image(decorative: crop, scale: 1).resizable().scaledToFit().frame(maxHeight: 280)
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
    let fontSize: Double
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                if let image {
                    ScrollView(.horizontal, showsIndicators: false) { FigurePartsThumbnails(stored: stored, image: image, fontSize: fontSize) }
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
    let fontSize: Double
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(stored.parts.enumerated()), id: \.offset) { index, part in
                VStack(alignment: .leading, spacing: 4) {
                    if let crop = FigurePartsView.crop(image, part.box) {
                        Image(decorative: crop, scale: 1).resizable().scaledToFit()
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
