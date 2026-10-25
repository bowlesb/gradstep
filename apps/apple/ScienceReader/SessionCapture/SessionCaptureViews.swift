#if INTERNAL
import SwiftUI
import UIKit

/// The recorder's on-screen controls: elapsed time, Mark and Stop, draggable.
/// Its frame is logged so the reviewer never mistakes it for app UI.
struct SessionCaptureOverlay: View {
    @Bindable var capture: SessionCapture = .shared
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        // A slim strip on the trailing edge, a third of the way down: the
        // status bar doesn't pass taps to the app, and the top and bottom bars
        // hold controls. Draggable; its frame is logged.
        GeometryReader { geometry in
            if capture.state == .recording || capture.state == .finishing {
                pill.offset(offset)
                    .position(x: geometry.size.width - 24, y: geometry.size.height * 0.36)
            }
        }
        // Sync marker: a magenta band across the top edge of the screen.
        .overlay(alignment: .top) {
            if capture.showSyncBand {
                Color(red: 1, green: 0, blue: 1).frame(height: 24).frame(maxWidth: .infinity)
                    .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var pill: some View {
        VStack(spacing: 0) {
            if capture.videoStopped {
                // The screen video stopped (it couldn't restart after the background); the event log goes on.
                Image(systemName: "video.slash.fill").font(.caption2).foregroundStyle(.orange).padding(.top, 8).padding(.bottom, 1)
                    .accessibilityLabel("Screen video stopped").accessibilityIdentifier("session.videoStopped")
            } else {
                Circle().fill(.red).frame(width: 8, height: 8).padding(.top, 9).padding(.bottom, 3).accessibilityHidden(true)
            }
            Button { capture.mark() } label: {
                Image(systemName: "flag.fill").font(.callout).frame(width: 36, height: 38).contentShape(Rectangle())
            }
            .accessibilityLabel("Mark this moment").accessibilityIdentifier("session.mark")
            Button { Task { await capture.stop() } } label: {
                Image(systemName: capture.state == .finishing ? "hourglass" : "stop.fill").font(.callout)
                    .frame(width: 36, height: 38).contentShape(Rectangle())
            }
            .disabled(capture.state != .recording).accessibilityLabel("Stop recording").accessibilityIdentifier("session.stop")
        }
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.red.opacity(0.5)))
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                SessionTimeline.shared.record("chrome", ["x": String(Int(frame.minX)), "y": String(Int(frame.minY)),
                                                         "width": String(Int(frame.width)), "height": String(Int(frame.height))])
            }
        })
        .gesture(DragGesture().onChanged { value in
            offset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
        }.onEnded { _ in dragStart = offset })
        .accessibilityElement(children: .contain).accessibilityLabel("Test session recording")
    }
}

/// Everything a test session adds to the root view: the controls, the touch
/// observer, the share sheet, and state/scene changes into the timeline.
struct SessionCaptureHooks: ViewModifier {
    let model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay { SessionCaptureOverlay() }
            .background { SessionTouchInstaller().frame(width: 0, height: 0) }
            .sheet(item: Bindable(SessionCapture.shared).share) { SessionShareSheet(url: $0.url) }
            .onChange(of: model.sessionState) { old, new in
                var changed: [String: String] = [:]
                for key in Set(old.keys).union(new.keys) where old[key] != new[key] { changed[key] = new[key] ?? "" }
                if !changed.isEmpty { SessionTimeline.shared.record("state", changed) }
            }
            // The full state once recording starts; changes after that.
            .onChange(of: SessionCapture.shared.state) { _, state in
                if state == .recording { SessionTimeline.shared.record("state", model.sessionState) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                SessionTimeline.shared.record("scene", ["phase": phase == .active ? "active" : phase == .inactive ? "inactive" : "background"])
            }
    }
}

/// Settings › Testing rows: start a session, voice option, past sessions.
struct SessionCaptureSettings: View {
    @Bindable var capture: SessionCapture = .shared

    var body: some View {
        Group {
            if capture.state == .idle {
                Button("Record a test session", systemImage: "record.circle") { Task { await capture.start() } }
                    .accessibilityIdentifier("session.start")
            } else {
                Label("Recording a test session", systemImage: "record.circle.fill").foregroundStyle(.red)
            }
            Toggle("Include my voice", isOn: $capture.includeVoice).disabled(capture.state != .idle)
                .accessibilityIdentifier("session.voice")
            if let issue = capture.issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            if !capture.sessions.isEmpty {
                NavigationLink("Recorded sessions (\(capture.sessions.count))") { SessionList(capture: capture) }
            }
        }
    }
}

private struct SessionList: View {
    @Bindable var capture: SessionCapture
    var body: some View {
        List {
            Section {
                ForEach(capture.sessions, id: \.self) { url in
                    ShareLink(item: url) { Label(url.deletingPathExtension().lastPathComponent, systemImage: "square.and.arrow.up") }
                        .swipeActions { Button("Delete", role: .destructive) { capture.delete(url) } }
                }
            } footer: {
                Text("AirDrop a session to the Mac; the review reads it from Downloads. Sessions stay on this device until deleted (the newest five are kept).")
            }
        }.navigationTitle("Recorded sessions").navigationBarTitleDisplayMode(.inline)
    }
}

/// Presents the share sheet for a finished session.
struct SessionShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Logs every touch (position only) while a session records. Never recognizes,
/// cancels or delays anything.
final class SessionTouchObserver: UIGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { log(touches, "began") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        log(touches, "ended")
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { log(touches, "cancelled"); state = .failed }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func log(_ touches: Set<UITouch>, _ phase: String) {
        guard SessionTimeline.shared.isRecording, let window = view else { return }
        for touch in touches {
            let point = touch.location(in: window)
            SessionTimeline.shared.record("touch", ["phase": phase, "x": String(Int(point.x)), "y": String(Int(point.y)),
                                                    "touch": String(UInt(bitPattern: ObjectIdentifier(touch).hashValue) % 10_000)])
        }
    }
}

/// Installs the touch observer on the app's window once.
struct SessionTouchInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ view: InstallerView, context: Context) {}
    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is SessionTouchObserver }) else { return }
            window.addGestureRecognizer(SessionTouchObserver(target: nil, action: nil))
        }
    }
}
#endif
