import SwiftUI

// An information sheet's one top row (docs/DESIGN.md "Sheet top row"; owner, build 62: "the top horizontal space is
// poorly used… remove Done, use an X, use Liquid Glass tabs"): its controls on the left, a round glass X on the right,
// a pushed page's round glass Back first. No centred title where the controls already say where you are.

struct SheetTopRow<Leading: View>: View {
    /// A pushed page's way back (nil on the sheet's first page).
    var back: (() -> Void)? = nil
    let close: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) { HeaderButtonLabel(systemImage: "chevron.backward") }
                    .buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("sheet.back")
            }
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { HeaderButtonLabel(systemImage: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("sheet.close")
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 14).padding(.bottom, 8)
    }
}

/// A pushed page's name in its top row, where nothing else says where you are (the tiles).
struct SheetRowTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
    }
}

/// Tabs in one glass capsule, as the reader's glass buttons (Chrome.swift): the chosen one on a quiet fill. Each tab is
/// a button named `<identifier>.<title, lowercased>`, selected when chosen.
struct GlassTabs<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let identifier: String
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = selection == option.value
                Button {
                    if reduceMotion { selection = option.value } else { withAnimation(.snappy(duration: 0.22)) { selection = option.value } }
                } label: {
                    // Each as wide as its name (equal widths squeezed "Equations" on a phone).
                    Text(option.title)
                        // One weight: a bolder chosen tab would widen and shift the others.
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: DesignMetrics.headerControl - 8)
                        .background {
                            if chosen { Capsule().fill(Color.primary.opacity(0.11)).matchedGeometryEffect(id: "chosen", in: space) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                .accessibilityIdentifier("\(identifier).\(option.title.lowercased())")
            }
        }
        .padding(4)
        .frame(height: DesignMetrics.headerControl)
        .chromeSurface(Capsule(), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
