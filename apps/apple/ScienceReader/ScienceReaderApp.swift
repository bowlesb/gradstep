import SwiftUI

@main
struct ScienceReaderApp: App {
    @State private var model = ReaderModel()
    #if targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(MacAppDelegate.self) private var macDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .macPlatformStyle()
                .tint(Color.accentColor)
                // System menus and alerts (UIKit) follow the window's tint (design audit F3).
                .background(WindowTint())
                .preferredColorScheme(model.appearance == "dark" ? .dark : model.appearance == "light" ? .light : nil)
                .task {
                    await model.start()
                    // After the first screen: warm WebKit so the first paper opens quickly.
                    try? await Task.sleep(for: .milliseconds(500))
                    PaperWebView.prewarm()
                }
        }
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
