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
// - Floating chrome and the app's own icons: Chrome.swift.

enum DesignMetrics {
    static let margin: CGFloat = 16
    /// Readable column for scrolling content on iPad (the reader's text column is its own).
    static let column: CGFloat = 720
    /// App-drawn header controls (search field, circle buttons): 44 pt touch targets; on the Mac, pointer-sized
    /// like the window's toolbar buttons.
    static let headerControl: CGFloat = Platform.isMac ? 34 : 44
    static let headerSymbol: CGFloat = Platform.isMac ? 15 : 17

    /// Side insets that center a `column`-wide region in `width`, never below the margin.
    static func columnInset(for width: CGFloat) -> CGFloat { max(margin, (width - column) / 2) }
}

/// A top-bar button drawn by the app, matching the system's glass bar buttons. `image` names one of the
/// app's own symbols (`GradstepSymbol`), drawn with its amber point.
struct HeaderButtonLabel: View {
    var systemImage: String? = nil
    var image: String? = nil
    var body: some View {
        Group {
            if let image { BrandSymbol(name: image) } else { Image(systemName: systemImage ?? "questionmark") }
        }
        .font(.system(size: DesignMetrics.headerSymbol, weight: .semibold)).foregroundStyle(.tint)
        .frame(width: DesignMetrics.headerControl, height: DesignMetrics.headerControl).modifier(GlassCircle())
        .contentShape(Circle())
    }
}

/// Floating chrome's glass (Chrome.swift), as a circle; solid with Reduce Transparency.
struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View { content.chromeSurface(Circle(), interactive: true) }
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

/// The label of a `.borderedProminent` button. The accent is light in dark mode, so the label
/// turns dark with it (white on the light indigo is hard to read).
struct ProminentLabel: View {
    let title: String
    var fullWidth = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Text(title).foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 44 : nil)
    }
}

/// An SF Symbol, or one of the app's own symbols (`GradstepSymbol`), drawn in the app's accent color
/// inside system menus, which ignore the window tint.
func menuIcon(_ name: String) -> Image {
    if let accent = UIColor(named: "AccentColor"),
       let image = (UIImage(systemName: name) ?? UIImage(named: name))?.withTintColor(accent, renderingMode: .alwaysOriginal) {
        return Image(uiImage: image)
    }
    return UIImage(systemName: name) != nil ? Image(systemName: name) : Image(name)
}

extension View {
    /// The one readable column on iPad: 16 pt margins inside at most 720 pt, centered. On iPhone it
    /// is just the side margins.
    func readableColumn() -> some View {
        padding(.horizontal, DesignMetrics.margin).frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
    }

    /// Side insets for a scroll view's content so its rows sit in the readable column (iPad only;
    /// iPhone keeps the system's own insets).
    @ViewBuilder func readableScrollColumn(width: CGFloat) -> some View {
        if Platform.isLargeScreen {
            contentMargins(.horizontal, max(0, (width - DesignMetrics.column) / 2), for: .scrollContent)
        } else { self }
    }
}

/// A menu row with an accent-colored icon (`menuIcon`); same title for VoiceOver and tests.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }
    var body: some View {
        Button(action: action) { Label { Text(title) } icon: { menuIcon(systemImage) } }
    }
}

/// A filter chip (Feed topics): the selected one looks like the selected tab — accent text on a
/// light accent capsule; others are body text on a quiet fill. 36 pt tall, 44 pt to tap.
struct ChipButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 36)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
