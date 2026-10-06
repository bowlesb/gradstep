import SwiftUI

@main
struct ScienceReaderApp: App {
    @State private var model = ReaderModel()
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(Color.accentColor)
                .preferredColorScheme(model.appearance == "dark" ? .dark : model.appearance == "light" ? .light : nil)
                .task {
                    await model.start()
                    // After the first screen: warm WebKit so the first paper opens quickly.
                    try? await Task.sleep(for: .milliseconds(500))
                    PaperWebView.prewarm()
                }
        }
    }
}
