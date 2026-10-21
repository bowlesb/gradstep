import ScienceReaderCore
import SwiftUI
import UIKit

@MainActor
enum ScreenshotCapture {
    static func currentWindow() -> UIImage? {
        guard let window = keyWindow(), !window.bounds.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true; format.scale = min(window.screen.scale, 2)
        let hidden = CaptureRedaction.shared.regions
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.systemBackground.setFill(); context.fill(window.bounds)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            // A recovery code or other secret on screen is covered before the image exists (build 75: a feedback
            // screenshot showed the whole recovery code).
            UIColor.black.setFill()
            for region in hidden { context.fill(region.insetBy(dx: -8, dy: -8)) }
        }
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?
            .windows.first(where: \.isKeyWindow)
    }

    /// Re-render pixels to remove source metadata and flatten crop/redactions.
    /// Coordinates refer to the full displayed, orientation-correct image.
    static func prepare(_ image: UIImage, redactions: [CGRect] = [], crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> (image: UIImage, attachment: ReportImage) {
        guard image.size.width > 0, image.size.height > 0 else { throw ReaderError.corruptData }
        let region = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width > 0.01, region.height > 0.01 else { throw ReaderError.invalidEvent }
        let full = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let cropPixels = CGRect(x: region.minX * full.width, y: region.minY * full.height, width: region.width * full.width, height: region.height * full.height)
        let factor = min(1, 2560 / max(cropPixels.width, cropPixels.height))
        let output = CGSize(width: max(1, floor(cropPixels.width * factor)), height: max(1, floor(cropPixels.height * factor)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: output, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: output))
            context.cgContext.scaleBy(x: factor, y: factor)
            context.cgContext.translateBy(x: -cropPixels.minX, y: -cropPixels.minY)
            image.draw(in: CGRect(origin: .zero, size: full))
            UIColor.black.setFill()
            for rectangle in redactions {
                let rect = rectangle.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.cgContext.fill(CGRect(x: rect.minX * full.width, y: rect.minY * full.height, width: rect.width * full.width, height: rect.height * full.height))
            }
        }
        if let png = flattened.pngData(), png.count <= 5 * 1024 * 1024 { return (flattened, ReportImage(bytes: png, mediaType: "image/png")) }
        for quality in [0.9, 0.75, 0.6] {
            if let jpeg = flattened.jpegData(compressionQuality: quality), jpeg.count <= 5 * 1024 * 1024, let preview = UIImage(data: jpeg) {
                return (preview, ReportImage(bytes: jpeg, mediaType: "image/jpeg"))
            }
        }
        throw ReaderError.invalidEvent
    }
}

/// Views that must never appear in a report's screenshot (a recovery code, a code being typed): their frames in window
/// coordinates while they are on screen. `ScreenshotCapture` covers them in black.
@MainActor
final class CaptureRedaction {
    static let shared = CaptureRedaction()
    private var frames: [UUID: CGRect] = [:]
    var regions: [CGRect] { frames.values.filter { !$0.isEmpty } }
    func set(_ id: UUID, _ frame: CGRect?) { frames[id] = frame }
}

private struct HiddenFromReports: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { CaptureRedaction.shared.set(id, $0) }
            .onDisappear { CaptureRedaction.shared.set(id, nil) }
    }
}

extension View {
    /// Covered in black in every in-app report screenshot.
    func hiddenFromReports() -> some View { modifier(HiddenFromReports()) }
}

/// "Report this screen" from anywhere, a sheet included. With nothing presented it is the root's own report sheet;
/// over a sheet it is presented on top of it (a SwiftUI view presents one sheet at a time, so the root can't).
@MainActor
enum ReportPresenter {
    static func present(_ model: ReaderModel, sheet: String? = nil, afterMenu: Bool = false) {
        let scope = model.readerSessionID
        Task { @MainActor in
            if afterMenu { try? await Task.sleep(for: .milliseconds(350)) }
            guard model.readerSessionID == scope, !model.showReport else { return }
            guard let root = ScreenshotCapture.keyWindow()?.rootViewController else { model.beginReport(sheet: sheet); return }
            var top = root
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            guard top !== root else { model.beginReport(sheet: sheet); return }
            model.captureReport(sheet: sheet)
            top.present(ReportHostingController(model: model), animated: true)
        }
    }
}

private final class ReportHostingController: UIHostingController<AnyView> {
    private let model: ReaderModel
    init(model: ReaderModel) {
        self.model = model
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(ReportComposer(model: model, onClose: { [weak self] in self?.dismiss(animated: true) }))
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        model.reportScreenshot = nil; model.showReportsAfterComposer = false
    }
}

/// After the reader takes a screenshot in Gradstep: a small "Report this screen" offer at the top for a few seconds, in
/// its own window over any sheet. It never covers the system's screenshot thumbnail (bottom left) or TestFlight's
/// feedback, takes no focus, and one tap on × (or waiting) dismisses it. Settings › Offer to report after a screenshot.
@MainActor
final class ScreenshotReportPrompt {
    static let shared = ScreenshotReportPrompt()
    static let enabledKey = "report.screenshotPrompt"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private weak var model: ReaderModel?
    private var observer: NSObjectProtocol?
    private var window: UIWindow?
    private var hide: Task<Void, Never>?

    func start(_ model: ReaderModel) {
        self.model = model
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenshotReportPrompt.shared.show() }
        }
    }

    func show() {
        // Not over the recovery code or sign-in (nothing there is reported), nor while a report is being written.
        guard Self.enabled, let model, !model.showRecovery, model.signInPresentationID == nil, !model.showReport,
              let key = ScreenshotCapture.keyWindow(), let scene = key.windowScene else { return }
        let bounds = scene.coordinateSpace.bounds
        let width = min(bounds.width - 32, 360), height: CGFloat = 52
        let window = self.window ?? UIWindow(windowScene: scene)
        window.frame = CGRect(x: (bounds.width - width) / 2, y: key.safeAreaInsets.top + 6, width: width, height: height)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ScreenshotReportToast(report: { [weak self] in self?.report() }, dismiss: { [weak self] in self?.dismiss() }))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        UIAccessibility.post(notification: .announcement, argument: "Report this screen, at the top of the screen.")
        hide?.cancel()
        hide = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    func dismiss() {
        hide?.cancel(); hide = nil
        window?.isHidden = true; window?.rootViewController = nil; window = nil
    }

    private func report() {
        dismiss()
        if let model { ReportPresenter.present(model, sheet: "after a screenshot") }
    }
}

private struct ScreenshotReportToast: View {
    let report: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: report) {
                Label("Report this screen", systemImage: "ladybug").font(.subheadline.weight(.semibold))
                    .padding(.leading, 16).padding(.trailing, 8).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor).accessibilityIdentifier("screenshotPrompt.report")
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss").accessibilityIdentifier("screenshotPrompt.dismiss")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .chromeSurface(Capsule(), interactive: true)
    }
}
