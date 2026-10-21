import SwiftUI

@main
struct ScienceReaderApp: App {
    @State private var model = ReaderModel()
    @State private var started = false
    @State private var pendingLink: URL?
    #if targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(MacAppDelegate.self) private var macDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .macPlatformStyle()
                .onOpenURL { url in if started { model.openPaperLink(url) } else { pendingLink = url } }
                .tint(Color.accentColor)
                // System menus and alerts (UIKit) follow the window's tint (design audit F3).
                .background(WindowTint())
                .preferredColorScheme(model.appearance == "dark" ? .dark : model.appearance == "light" ? .light : nil)
                .task {
                    await model.start()
                    started = true
                    if let pendingLink { model.openPaperLink(pendingLink); self.pendingLink = nil }
                    // After the first screen: warm WebKit so the first paper opens quickly.
                    try? await Task.sleep(for: .milliseconds(500))
                    PaperWebView.prewarm()
                }
        }
        // The Mac menu bar. Not on iPad: with these commands attached, an iPad keyboard's ⌘F no longer reached the
        // paper's find (iPad journey, 2026-10-21; NATIVE_REVIEW_20261021 B1), so the iPad keeps its own shortcuts.
        #if targetEnvironment(macCatalyst)
        .commands { GradstepCommands(model: model) }
        #endif
    }
}

/// Sets the hosting window's tint to the app's accent color, once it resolves.
private struct WindowTint: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { TintingView() }
    func updateUIView(_ view: UIView, context: Context) {}
    final class TintingView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window, let accent = UIColor(named: "AccentColor") { window.tintColor = accent }
        }
    }
}
