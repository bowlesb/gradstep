import SwiftUI
import UIKit

#if DEBUG && FIXTURE_HOST
/// Visual checks without UI automation (docs/VISUAL_CHECK.md). On the Mac, XCUITest needs an interactive automation
/// permission, so `scripts/visual-check.mjs` launches the fixture app itself: `--visual-capture=<name>` renders the
/// key window to `<temporary directory>/visual-capture/<name>.png` once the scenario has settled
/// (`--visual-capture-delay=<seconds>`, default 5) and quits. The scenario's state comes from the fixture arguments
/// (`--workflow-fixture`, `--chat-fixture`, `--start-tab`, `--wide-mode`, …) and the few steps below that a UI test
/// would otherwise perform. Debug fixture hosts only; never in a shipped build.
@MainActor enum VisualCapture {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static func argument(_ prefix: String) -> String? {
        arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var requested: String? { argument("--visual-capture=").flatMap { $0.isEmpty ? nil : $0 } }
    static var delay: Double { argument("--visual-capture-delay=").flatMap(Double.init) ?? 5 }
    /// Where captures land (inside the app's container on the Mac, which the sandbox allows).
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("visual-capture", isDirectory: true) }

    /// Steps a UI test would take, for scenarios that need more than launch state.
    static func stage(_ model: ReaderModel) async {
        if let question = argument("--visual-ask="), !question.isEmpty {
            // General chat, as the UI test's `ask`; the fixture transport answers.
            model.showWideMode(.chat)
            model.chatInput = question
            for _ in 0..<20 {
                await model.sendMessage()
                if model.chatInput.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if arguments.contains("--visual-study") {
            // Study (2026-10-14): the fixture's numbered paper, the opening turn, the reader's answer, the map bar.
            // The numbered fixture paper's chat (the Reader split on the Mac and iPad, the Chat tab on the phone).
            if let numbered = model.papers.first(where: { $0.sourceID == "2601.01234" }) { model.select(numbered) }
            model.askAboutSelectedPaper()
            await model.startStudy()
            for _ in 0..<40 where model.isAnswering { try? await Task.sleep(for: .milliseconds(250)) }
            model.chatInput = "A weighted sum of the values."
            await model.sendMessage()
            for _ in 0..<40 where model.isAnswering { try? await Task.sleep(for: .milliseconds(250)) }
        }
        if arguments.contains("--visual-show-all-chats") { model.showAllChats = true }
        if arguments.contains("--visual-show-store") { model.showStore = true }
        if arguments.contains("--visual-show-signin") { model.openSignIn() }
    }

    /// Runs from the root view once; exits the process with 0 after writing the image, 2 without a window, 3 when
    /// the file could not be written.
    static func runIfRequested(_ model: ReaderModel) async {
        guard let name = requested else { return }
        let scenes = { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene } }
        // The appearance as UIKit sees it (SwiftUI's preferred scheme alone does not reach a Catalyst window).
        if let scheme = Platform.fixtureAppearance {
            for window in scenes().flatMap(\.windows) { window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light }
        }
        try? await Task.sleep(for: .seconds(1))
        await stage(model)
        try? await Task.sleep(for: .seconds(delay))
        let windows = scenes().flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { exit(2) }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.screen.scale
        // Every window of the scene, lowest level first: on the Mac a sheet (sign-in, store, All chats) is its own
        // window over the main one, so the capture composites them at their frames.
        let layered = windows.filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { ($0.windowLevel.rawValue, $0 === window ? 0 : 1) < ($1.windowLevel.rawValue, $1 === window ? 0 : 1) }
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            for layer in layered {
                let frame = CGRect(origin: CGPoint(x: layer.frame.minX - window.frame.minX, y: layer.frame.minY - window.frame.minY), size: layer.bounds.size)
                layer.drawHierarchy(in: frame, afterScreenUpdates: true)
                // A presented sheet: on the Mac its view lives in its own AppKit sheet window, outside the window's own
                // drawing, so it is drawn where a Mac sheet hangs (top, centred) at its own size.
                var presented = layer.rootViewController?.presentedViewController
                while let controller = presented {
                    let view = controller.view!, size = view.bounds.size
                    let converted = view.convert(view.bounds, to: layer)
                    let origin = converted.origin == .zero && converted.size != layer.bounds.size
                        ? CGPoint(x: (layer.bounds.width - size.width) / 2, y: 0) : converted.origin
                    let target = CGRect(origin: CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY), size: size)
                    // The sheet window's own backdrop is not part of the view: paint it so the sheet reads as one.
                    UIColor.systemBackground.setFill(); UIBezierPath(roundedRect: target, cornerRadius: 10).fill()
                    view.drawHierarchy(in: target, afterScreenUpdates: true)
                    presented = controller.presentedViewController
                }
            }
        }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = image.pngData() else { exit(3) }
            try data.write(to: directory.appendingPathComponent("\(safe).png"), options: .atomic)
            // What was composited, for the capture tool's diagnostics (scenes, windows, presented controllers).
            let report = scenes().map { scene in
                ["activation": "\(scene.activationState.rawValue)", "windows": scene.windows.map { w in
                    ["frame": "\(w.frame)", "level": "\(w.windowLevel.rawValue)", "key": "\(w.isKeyWindow)", "hidden": "\(w.isHidden)",
                     "root": String(describing: type(of: w.rootViewController!)), "presented": w.rootViewController?.presentedViewController.map { String(describing: type(of: $0)) } ?? "none"] }]
            }
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
            try json.write(to: directory.appendingPathComponent("\(safe).json"), options: .atomic)
            exit(0)
        } catch { exit(3) }
    }
}
#endif
