import SwiftUI

// The app's shared look (owner principles and design audit, 2026-10-06; docs/DESIGN.md).
// One way to do each thing:
// - Screen options: one "…" menu (SF Symbol `ellipsis`, never `ellipsis.circle`), the rightmost
//   top-bar item. Left side: where to go (contents, history). Right side: create (+, compose), then "…".
// - Top-bar buttons: 44 pt circles, 17 pt semibold symbols in the accent color (system bars draw
//   their own; custom headers use `HeaderButtonLabel`).
// - Margins 16 pt; vertical rhythm 4/8/12/16/24; iPad scrolling columns at most 720 pt, centered.
// - Text: `.headline` titles, `.subheadline` secondary, `.footnote` tertiary (secondary color);
//   accent color only for things that can be tapped.
// - Status: one `StatusBanner`, shown only when the reader can act on it.

enum DesignMetrics {
    static let margin: CGFloat = 16
    /// Readable column for scrolling content on iPad (the reader's text column is its own).
    static let column: CGFloat = 720

    /// Side insets that center a `column`-wide region in `width`, never below the margin.
    static func columnInset(for width: CGFloat) -> CGFloat { max(margin, (width - column) / 2) }
}

/// A top-bar button drawn by the app, matching the system's glass bar buttons.
struct HeaderButtonLabel: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
            .frame(width: 44, height: 44).modifier(GlassCircle())
            .contentShape(Circle())
    }
}

struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular.interactive(), in: Circle()) }
        else { content.background(.regularMaterial, in: Circle()) }
    }
}

/// The one status message style: an inset rounded card, a symbol, one line of text, and a
/// chevron or at most two text buttons. Information uses a light accent fill; problems orange.
enum BannerTone { case info, problem }

struct StatusBanner<Actions: View>: View {
    let tone: BannerTone
    let systemImage: String
    let message: String
    /// Long messages put their buttons on a line of their own, inside the card.
    var actionsBelow = false
    /// Accessibility identifier of the message text (tests and VoiceOver find it as text).
    var messageID: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 17))
                    .foregroundStyle(tone == .info ? Color.accentColor : Color.orange).accessibilityHidden(true)
                Text(message).font(.subheadline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(messageID ?? "")
                if !actionsBelow { actions.font(.subheadline.weight(.semibold)) }
            }
            if actionsBelow {
                HStack(spacing: 20) { actions }.font(.subheadline.weight(.semibold)).padding(.leading, 29)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(tone == .info ? Color.accentColor.opacity(0.08) : Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension StatusBanner where Actions == EmptyView {
    init(tone: BannerTone, systemImage: String, message: String) {
        self.init(tone: tone, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// A whole banner that is one tap target (e.g. "Sign in to sync ›").
struct StatusBannerLink: View {
    let tone: BannerTone
    let systemImage: String
    let message: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            StatusBanner(tone: tone, systemImage: systemImage, message: message) {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }.buttonStyle(.plain)
    }
}
