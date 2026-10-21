import AVFoundation
import ScienceReaderCore
import SwiftUI

// Settings › Account › Add a device (scan the new device's QR code), and the "A new device is waiting" banner for a
// device without a camera. Both end in the same confirmation: the new device's kind and its six-digit number.
// docs/architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr

/// Whether Add a device is on screen, so the banner doesn't repeat it.
@MainActor @Observable final class DeviceApprovalPresence {
    static let shared = DeviceApprovalPresence()
    var addingDevice = false
}

/// Add a device: the camera until a code is scanned, then the confirmation.
struct AddDeviceView: View {
    let model: ReaderModel
    @State private var approver: DeviceApprover?
    @State private var width: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Group {
                if let approver, approver.canApprove {
                    DeviceApprovalPanel(approver: approver, scanner: true) { dismiss() }
                } else {
                    ApprovalMessage(systemImage: "key.slash", title: "Can’t add devices yet",
                                    message: DeviceApprover.message(DeviceApprover.Refusal.noKeys))
                }
            }
            .padding(DesignMetrics.margin)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Add a device").navigationBarTitleDisplayMode(.inline)
        .onAppear { if approver == nil { approver = model.makeDeviceApprover() }; DeviceApprovalPresence.shared.addingDevice = true }
        .onDisappear { DeviceApprovalPresence.shared.addingDevice = false }
        .onChange(of: model.isSignedIn) { _, signedIn in if !signedIn { dismiss() } }
    }
}

/// The approval steps, shared by Add a device (with the camera) and the banner's review (without).
struct DeviceApprovalPanel: View {
    @Bindable var approver: DeviceApprover
    let scanner: Bool
    let done: () -> Void
    @State private var cameraIssue: String?
    @State private var comparing = false

    var body: some View {
        switch approver.phase {
        case .scanning:
            if scanner && !comparing { scanning } else { WaitingDevices(approver: approver) }
        case .checking:
            ProgressView("Checking the code…").frame(maxWidth: .infinity, minHeight: 240)
        case .confirm(let candidate):
            confirmation(candidate)
        case .approving(let candidate):
            ProgressView("Adding \(candidate.name.lowercased())…").frame(maxWidth: .infinity, minHeight: 240)
        case .approved(let candidate):
            VStack(spacing: 20) {
                ApprovalMessage(systemImage: "checkmark.circle.fill", tint: .green, title: "\(candidate.name) added",
                                message: "It opens your private library in a few seconds.")
                Button("Done", action: done).buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("addDevice.done")
            }
        case .failed(let message):
            VStack(spacing: 20) {
                ApprovalMessage(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: "Not added", message: message)
                Button(scanner ? "Scan again" : "Back") { approver.restart() }.buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("addDevice.retry")
            }
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On the new device, sign in to Gradstep at app.gradstep.ai. Then scan the code it shows.")
                .fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
                if let cameraIssue {
                    Label(cameraIssue, systemImage: "camera.fill").foregroundStyle(.white).padding().multilineTextAlignment(.center)
                } else {
                    QRScanner { text in Task { await approver.scanned(text) } } unavailable: { cameraIssue = $0 }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Camera viewfinder for the new device’s code")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 360).frame(maxWidth: .infinity)
            .accessibilityIdentifier("addDevice.scanner")
            #if FIXTURE_HOST
            if DeviceApprovalFixture.isEnabled {
                Button("Use test code") { Task { await approver.scanned(DeviceApprovalFixture.scannedText) } }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity).accessibilityIdentifier("addDevice.fixtureScan")
            }
            #endif
            Button("No camera? Compare a number instead") { comparing = true }
                .frame(maxWidth: .infinity).accessibilityIdentifier("addDevice.compareInstead")
        }
    }

    private func confirmation(_ candidate: DeviceApprover.Candidate) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon(candidate.kind)).font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(candidate.kind == nil ? "Add this device?" : "Add this \(candidate.name.lowercased())?")
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Text("It should show this number").foregroundStyle(.secondary)
                Text(DeviceApproval.display(candidate.code))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .accessibilityLabel(candidate.code.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("addDevice.code")
            }
            .padding(.vertical, 16).frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(candidate.kind == nil
                 ? "Compare all six digits with the new device. Approving gives it the keys to your private chats and snippets, so only approve a device you’re using right now."
                 : "Approving gives it the keys to your private chats and notes. Only approve a device you’re using right now.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button { Task { await approver.approve() } } label: { Text("Approve").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("addDevice.approve")
                Button(role: .cancel) { approver.restart() } label: { Text(candidate.kind == nil ? "Not mine" : "Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("addDevice.cancel")
            }
        }
    }

    private func icon(_ kind: DeviceKind?) -> String {
        switch kind {
        case .browser: "globe"
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case nil: "laptopcomputer.and.iphone"
        }
    }
}

/// Requests waiting for approval, each to review by its number (no camera needed).
struct WaitingDevices: View {
    let approver: DeviceApprover
    @State private var waiting: [DeviceApprover.Candidate]?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Devices waiting to be added").font(.headline)
            if let issue {
                Text(issue).foregroundStyle(.secondary)
            } else if let waiting {
                if waiting.isEmpty {
                    Text("No device is waiting. On the new device, sign in to Gradstep and choose to approve it from your phone.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(waiting) { candidate in
                    Button { approver.review(candidate) } label: {
                        HStack {
                            Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.tint).accessibilityHidden(true)
                            Text("Shows \(DeviceApproval.display(candidate.code))").monospacedDigit()
                            Spacer()
                            Text("Review").foregroundStyle(.tint)
                        }
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("addDevice.waiting")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            do { waiting = try await approver.waiting() } catch { issue = DeviceApprover.message(error) }
        }
    }
}

struct ApprovalMessage: View {
    let systemImage: String
    var tint: Color = .secondary
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("addDevice.message")
        }
        .frame(maxWidth: .infinity).padding(.top, 24)
    }
}

/// "A new device is waiting · Review", while this device can approve and a request is waiting. Checked when the app
/// becomes active and then every minute while it stays active. It floats above the tab bar so no toolbar is covered.
struct DeviceApprovalBanner: ViewModifier {
    let model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var waiting: [DeviceApprover.Candidate] = []
    @State private var later: Set<UUID> = []
    @State private var review: DeviceApprover?

    private struct Poll: Equatable { let account: UUID?; let active: Bool }

    func body(content: Content) -> some View {
        let visible = review == nil && !DeviceApprovalPresence.shared.addingDevice ? waiting.filter { !later.contains($0.id) } : []
        content
            // Above the floating tab bar (or the window's bottom edge in the wide layout), clear of every toolbar.
            .overlay(alignment: .bottom) {
                if !visible.isEmpty {
                    GeometryReader { proxy in
                        let tabs = !(proxy.size.width >= 850 || Platform.isMac)
                        banner.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, tabs ? ChromeMetrics.tabBarReserve(safeBottom: proxy.safeAreaInsets.bottom) : 12)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: visible.map(\.id))
            .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }), onDismiss: { Task { await refresh() } }) {
                if let review {
                    NavigationStack {
                        ScrollView {
                            DeviceApprovalPanel(approver: review, scanner: false) { self.review = nil }
                                .padding(DesignMetrics.margin).frame(maxWidth: 560).frame(maxWidth: .infinity)
                        }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .navigationTitle("New device").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { self.review = nil } } }
                    }
                    .macSheetKeys()
                }
            }
            .task(id: Poll(account: model.deviceApprovalAccount, active: scenePhase == .active)) {
                guard scenePhase == .active, model.deviceApprovalAccount != nil else { waiting = []; return }
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.tint).accessibilityHidden(true)
            Text("A new device is waiting").font(.subheadline.weight(.medium)).lineLimit(2)
            Spacer(minLength: 8)
            Button("Review") {
                guard let approver = model.makeDeviceApprover() else { return }
                if waiting.count == 1, let only = waiting.first { approver.review(only) }
                review = approver
            }
            .buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("approvalBanner.review")
            Button { later.formUnion(waiting.map(\.id)) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Later").accessibilityIdentifier("approvalBanner.later")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, DesignMetrics.margin)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain).accessibilityIdentifier("approvalBanner")
    }

    private func refresh() async {
        guard let approver = model.makeDeviceApprover() else { waiting = []; return }
        // A failed check keeps the last answer; the next minute tries again.
        if let found = try? await approver.waiting() { waiting = found }
    }
}

/// A QR code scanner on the device's camera (iPhone, iPad, and a Mac with a camera). Reports the first code once.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let unavailable: (String) -> Void

    init(found: @escaping (String) -> Void, unavailable: @escaping (String) -> Void) { self.found = found; self.unavailable = unavailable }

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.found = found; controller.unavailable = unavailable
        return controller
    }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    /// AVCaptureSession is thread-safe for start/stop, which must run off the main thread.
    private final class Session: @unchecked Sendable { let capture = AVCaptureSession() }
    var found: ((String) -> Void)?
    var unavailable: ((String) -> Void)?
    private let session = Session()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // No camera (a Mac without one, the Simulator): say so without asking for permission.
        guard AVCaptureDevice.default(for: .video) != nil else { report(Self.noCamera); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in granted ? self?.configure() : self?.report(Self.denied) }
            }
        default: report(Self.denied)
        }
    }

    /// Reported after the current SwiftUI update (this can run inside `makeUIViewController`).
    private func report(_ issue: String) { DispatchQueue.main.async { [weak self] in self?.unavailable?(issue) } }

    private static let denied = "Camera access is off. Turn it on for Gradstep in Settings, or compare a number instead."
    private static let noCamera = "This device has no camera available. Compare a number instead."

    private func configure() {
        let capture = session.capture
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
              capture.canAddInput(input) else { report(Self.noCamera); return }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { report("The camera can’t scan codes right now."); return }
        capture.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { report("The camera can’t scan codes on this device."); return }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        let box = session
        DispatchQueue.global(qos: .userInitiated).async { box.capture.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let box = session
        DispatchQueue.global(qos: .userInitiated).async { box.capture.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let text = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            guard let text, !delivered else { return }
            delivered = true
            let box = session
            DispatchQueue.global(qos: .userInitiated).async { box.capture.stopRunning() }
            found?(text)
        }
    }
}
