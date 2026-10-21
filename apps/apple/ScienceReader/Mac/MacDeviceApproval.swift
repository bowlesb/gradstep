#if targetEnvironment(macCatalyst)
import CoreImage.CIFilterBuiltins
import ScienceReaderCore
import SwiftUI

/// The Mac restore screen's bounded poller. Key ownership stays in DeviceKeys; a nil result means
/// ReaderModel finished the same account's ordinary activation. Cancelling this view never deletes keys.
@MainActor @Observable
final class MacApprovalSession {
    enum Phase: Equatable {
        case preparing, waiting(DeviceApprovalPayload), approved, paused(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var running = false
    private var generation = UUID()
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private let duration: TimeInterval

    init(duration: TimeInterval = 30 * 60,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.duration = duration; self.now = now; self.sleep = sleep
    }

    func run(request: @MainActor (Bool) async throws -> DeviceApprovalPayload?) async {
        let run = UUID()
        generation = run; running = true; phase = .preparing
        defer { if generation == run { running = false } }
        let started = now()
        var checkedRequestAt = -TimeInterval.infinity
        var delay: TimeInterval = 2
        do {
            while now() - started < duration {
                try Task.checkCancellation()
                let refresh = now() - checkedRequestAt >= 60
                let payload = try await request(refresh)
                try Task.checkCancellation()
                guard generation == run else { return }
                guard let payload else { phase = .approved; return }
                phase = .waiting(payload)
                if refresh { checkedRequestAt = now() }
                try await sleep(min(delay, max(0, duration - (now() - started))))
                guard generation == run else { return }
                delay = min(10, delay * 1.5)
            }
            guard generation == run else { return }
            phase = .paused("This code has been waiting for a while. Show it again when your other device is ready.")
        } catch is CancellationError {
            // Backgrounding, switching to recovery, or signing out ends this poll; the persisted recipient stays.
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            phase = .paused(Self.message(error))
        }
    }

    func stop() { generation = UUID(); running = false }

    static func message(_ error: Error) -> String {
        switch error {
        case DeviceKeyError.operationInProgress:
            "This Mac is still preparing your private library. Try again in a moment."
        case DeviceKeyError.noKeyAuthority:
            "This account has no approved device to share its private keys yet. Use the recovery code to set up the first device."
        case BackendError.signInRequired:
            "Sign in again to finish setting up this Mac."
        case ReaderError.invalidKey, ReaderError.corruptData, ReaderError.wrongAccount, ReaderError.staleEpoch:
            "Couldn’t verify this Mac’s approval. Try again or use your recovery code."
        default:
            "Couldn’t check this Mac’s approval. Check your connection and try again."
        }
    }
}

/// Core Image draws the existing GSDA1 payload locally. Four white modules on all sides are the QR quiet zone;
/// integer pixel scaling and nearest-neighbour display keep the code scannable in either app appearance.
enum MacApprovalQRCode {
    static func image(_ payload: DeviceApprovalPayload) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.encoded.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: CIColor.white).cropped(to: extent)
        let padded = code.composited(over: background).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let rendered = CIContext().createCGImage(padded, from: padded.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}

struct MacDeviceApprovalSection: View {
    let request: @MainActor (Bool) async throws -> DeviceApprovalPayload?
    @State private var session = MacApprovalSession()
    @State private var retry = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private struct Poll: Equatable { let active: Bool; let retry: UUID }

    var body: some View {
        Section("Approve from your phone or iPad") {
            VStack(alignment: .leading, spacing: 16) {
                Text("On a device already signed in to this account, open Settings › Account › Add a device and scan this code.")
                    .fixedSize(horizontal: false, vertical: true)
                switch session.phase {
                case .preparing:
                    ProgressView("Preparing this Mac’s code…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                case .waiting(let payload):
                    if let code = MacApprovalQRCode.image(payload) {
                        Image(uiImage: code).interpolation(.none).resizable().scaledToFit().hiddenFromReports()
                            .frame(width: 240, height: 240)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Approval code for this Mac")
                            .accessibilityIdentifier("macApproval.qr")
                    } else {
                        Label("Couldn’t draw the code. Compare the number instead.", systemImage: "qrcode")
                    }
                    VStack(spacing: 6) {
                        Text(DeviceApproval.display(payload.comparisonCode))
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled).accessibilityIdentifier("macApproval.number")
                        Label("Waiting for approval", systemImage: "clock")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                    Text("Check that the same number appears on both devices. Without a camera, open the new-device banner on your approved device to compare the number.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .approved:
                    Label("This Mac is approved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).accessibilityIdentifier("macApproval.approved")
                case .paused(let message):
                    Text(message).foregroundStyle(.secondary).accessibilityIdentifier("macApproval.issue")
                    Button("Show the code again") { retry = UUID() }
                        .accessibilityIdentifier("macApproval.retry")
                }
            }.padding(.vertical, 8)
        }
        .task(id: Poll(active: scenePhase == .active, retry: retry)) {
            guard scenePhase == .active else { session.stop(); return }
            await session.run(request: request)
        }
        .onDisappear { session.stop() }
    }
}
#endif
