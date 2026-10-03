import SwiftUI

@main
struct ScienceReaderApp: App {
    @State private var model = ReaderModel()
    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(Color(red: 99/255, green: 102/255, blue: 241/255))
                .preferredColorScheme(model.appearance == "dark" ? .dark : model.appearance == "light" ? .light : nil)
                .task { await model.start() }
        }
    }
}
