import SwiftUI

// Floating chrome (owner request 2026-10-07, after Gemini: "things can kind of flow past it, it provides an
// illusion of less wasted space"). The tab bar, the screens' header controls and the chat message box float
// over content, which scrolls behind them and fades softly at the screen's edges (docs/DESIGN.md, Chrome).
//
// - Surfaces: Liquid Glass on iOS 26, a material before it, and a solid surface with Reduce Transparency.
// - Fades: the screen's background color, nearly opaque behind controls, then fading out over a short tail.
//   Taps inside the controls' band stay with the band; the tail lets them through to the content.
// - Screens with their own bottom controls (Paper, Chat) draw the bottom fade themselves, under those
//   controls; the root draws it for the others (`RootView`).

enum ChromeMetrics {
    /// The floating tab bar's height: a 50 pt item inside 4 pt of glass.
    static let tabBarHeight: CGFloat = 58
    /// The widest the tab bar gets (iPad): five tabs don't need more.
    static let tabBarMaxWidth: CGFloat = 520
    /// Room kept between the end of the content and the bar above it.
    static let contentGap: CGFloat = 8
    /// How far a fade reaches past the controls it is behind.
    static let fadeTail: CGFloat = 22

    /// Distance from the screen's bottom edge to the tab bar: it sits in the home indicator's area,
    /// as the system's floating tab bar does.
    static func tabBarBottom(safeBottom: CGFloat) -> CGFloat { safeBottom > 0 ? max(10, safeBottom - 14) : 10 }

    /// What the tab bar adds to the bottom safe area, so the last row can scroll clear of it.
    static func tabBarReserve(safeBottom: CGFloat) -> CGFloat {
        max(0, tabBarBottom(safeBottom: safeBottom) + tabBarHeight + contentGap - safeBottom)
    }
}

extension Color {
    /// The logo's amber point (#F2B544), a little deeper in light mode so it holds on white.
    static let gradstepAmber = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.949, green: 0.710, blue: 0.267, alpha: 1)
            : UIColor(red: 0.914, green: 0.643, blue: 0.149, alpha: 1)
    })
    /// The logo's ink (#1E1C52), paper-white (#F7F6F1) in dark mode, as on the dark app icon.
    static let gradstepInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.969, green: 0.965, blue: 0.945, alpha: 1)
            : UIColor(red: 0.118, green: 0.110, blue: 0.322, alpha: 1)
    })
    /// The screen background that chrome fades into.
    static let chromeBackground = Color(uiColor: .systemBackground)
    static let chromeGroupedBackground = Color(uiColor: .systemGroupedBackground)
}

/// A floating control's surface: glass (iOS 26) or a material, solid with Reduce Transparency.
struct ChromeSurface<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    /// A hairline edge, for a field that must read as one on a light band (the message box).
    var outlined = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay(shape.stroke(Color(uiColor: .separator), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay { if outlined { shape.stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.75) } }
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.10), radius: 10, y: 3)
        }
    }
}

/// The band behind floating controls at a screen edge: content passing behind fades into the
/// background. With Reduce Transparency (or `solid`) it is the plain background.
struct ChromeFade: View {
    let edge: VerticalEdge
    var color: Color = .chromeBackground
    var solid = false
    var tail: CGFloat = ChromeMetrics.fadeTail
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let opaque = solid || reduceTransparency
        // Behind the controls: nearly opaque (text passing behind them is a faint ghost), fully so at the
        // screen's edge (status bar, home indicator); past them it fades out over the tail.
        LinearGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(opaque ? 1 : 0.94), location: 1)],
                       startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .ignoresSafeArea(.container, edges: edge == .top ? .top : .bottom)
            .overlay(alignment: edge == .top ? .bottom : .top) {
                if !opaque {
                    LinearGradient(stops: [.init(color: color.opacity(0.94), location: 0), .init(color: color.opacity(0.62), location: 0.3),
                                           .init(color: color.opacity(0.24), location: 0.65), .init(color: color.opacity(0), location: 1)],
                                   startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
                        .frame(height: tail).offset(y: edge == .top ? tail : -tail)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct TabBarReserveKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Room the floating tab bar takes above the screen's bottom safe area (0 where there is no tab bar:
    /// the iPad's wide layout, or while a software keyboard covers it). Set by `RootView`.
    var tabBarReserve: CGFloat {
        get { self[TabBarReserveKey.self] }
        set { self[TabBarReserveKey.self] = newValue }
    }
}

/// Room for the floating tab bar under a screen's content. Applied inside each screen's NavigationStack,
/// which doesn't take safe-area insets from outside it.
struct TabBarSpace: ViewModifier {
    var fade: Bool
    var color: Color
    @Environment(\.tabBarReserve) private var reserve
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if reserve > 0 {
                Color.clear.frame(height: reserve)
                    .background { if fade { ChromeFade(edge: .bottom, color: color) } }
            }
        }
    }
}

extension View {
    /// A screen's room for the floating tab bar. `fade`: content fades out behind the bar here; screens with
    /// their own bottom controls (Paper, Chat) draw the fade under those controls instead.
    func tabBarSpace(fade: Bool = true, color: Color = .chromeBackground) -> some View {
        modifier(TabBarSpace(fade: fade, color: color))
    }

    /// Floating controls at a screen edge: content scrolls under them and fades out behind them.
    func chromeBand(_ edge: VerticalEdge, color: Color = .chromeBackground, solid: Bool = false) -> some View {
        background { ChromeFade(edge: edge, color: color, solid: solid) }
    }

    func chromeSurface<S: Shape>(_ shape: S, interactive: Bool = false, outlined: Bool = false) -> some View {
        modifier(ChromeSurface(shape: shape, interactive: interactive, outlined: outlined))
    }
}

/// Glass for the reader's floating controls (selection actions, Back, Latest).
struct ReaderControlMaterial: ViewModifier {
    func body(content: Content) -> some View { content.chromeSurface(RoundedRectangle(cornerRadius: 28)) }
}

/// Send / Stop inside the message pill: an accent circle (gray while it can't act), 44 pt to tap.
struct ComposerActionLabel: View {
    let systemImage: String
    let enabled: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
            // The accent is light in dark mode, so the symbol turns dark with it (as `ProminentLabel`).
            .foregroundStyle(enabled ? (colorScheme == .dark ? Color.black : Color.white) : Color(uiColor: .tertiaryLabel))
            .frame(width: 36, height: 36)
            .background(enabled ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
            .frame(width: 44, height: 44).contentShape(Circle())
    }
}

// MARK: - Icons

/// The app's own symbols (Assets.xcassets/Symbols, drawn by tools/icons): rounded lines like the logo, each
/// with one amber point. Two layers, so palette rendering colors the point separately.
enum GradstepSymbol {
    static let feed = "gradstep.feed"
    static let library = "gradstep.library"
    static let paper = "gradstep.paper"
    static let chat = "gradstep.chat"
    static let settings = "gradstep.settings"
    static let newChat = "gradstep.chat.new"
    /// All chats: a list (owner feedback, build 14: not a clock-arrow, which reads as refresh).
    static let chats = "gradstep.chats"
    static let contents = "gradstep.contents"
    static let mark = "gradstep.mark"
}

/// A symbol in the app's style: the line in `style`, the point in amber when `accent` is on.
struct BrandSymbol: View {
    let name: String
    var accent = true
    var body: some View {
        Image(name)
            .symbolRenderingMode(accent ? .palette : .monochrome)
            .foregroundStyle(.tint, Color.gradstepAmber)
    }
}

extension ReaderTab {
    var icon: String {
        switch self {
        case .feed: GradstepSymbol.feed
        case .library: GradstepSymbol.library
        case .paper: GradstepSymbol.paper
        case .chat: GradstepSymbol.chat
        case .settings: GradstepSymbol.settings
        }
    }
}

/// One tab of the floating tab bar: the selected tab's symbol in accent with its amber point, on a
/// light accent capsule; the others in the label color, as on the system's glass tab bar.
struct TabBarItem: View {
    let tab: ReaderTab
    let selected: Bool
    var body: some View {
        VStack(spacing: 2) {
            icon.frame(height: 27)
            Text(tab.rawValue).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .frame(maxWidth: .infinity).frame(height: 50)
        .background { if selected { Capsule().fill(Color.accentColor.opacity(0.14)) } }
        .contentShape(Capsule())
    }

    // Icon study 2026-10-07 (docs/DECISIONS.md): chosen over tuned system symbols and an app-icon tile.
    private var icon: some View {
        Image(tab.icon)
            .symbolRenderingMode(selected ? .palette : .monochrome)
            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary), Color.gradstepAmber)
            .font(.system(size: 22, weight: .medium))
    }
}
