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
                .onOpenURL { url in
                    // A Google sign-in return goes to its open sign-in page, never to paper links.
                    if NativeAuthenticationPresenter.handleOpenedURL(url) { return }
                    if started { model.openPaperLink(url) } else { pendingLink = url }
                }
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
        // The Mac menu bar. Not on iPad yet: tried there, the iPad journey's ⌘F didn't open Find (NATIVE_REVIEW_20261021
        // B1; unproven, as main failed that step on the same Simulator), so the iPad keeps its own shortcuts for now.
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
