import AuthenticationServices
import SwiftUI
import UIKit

/// Apple's own localized control. The action may prepare the nonce before the
/// retained presenter constructs its request; no async work enters a synchronous
/// SignInWithAppleButton request-configuration closure.
@MainActor
struct NativeAppleAuthenticationButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var environmentEnabled
    var isEnabled = true
    let action: @MainActor () -> Void

    var body: some View {
        AppleButtonRepresentable(style: colorScheme == .dark ? .white : .black,
            isEnabled: isEnabled && environmentEnabled, action: action)
            .id(colorScheme)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private struct AppleButtonRepresentable: UIViewRepresentable {
        let style: ASAuthorizationAppleIDButton.Style
        let isEnabled: Bool
        let action: @MainActor () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(action: action) }

        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: style)
            button.cornerRadius = AuthenticationButtonStyle.cornerRadius
            button.isEnabled = isEnabled
            button.accessibilityIdentifier = "auth.apple"
            button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
            return button
        }

        func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
            context.coordinator.action = action
            button.isEnabled = isEnabled
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: ASAuthorizationAppleIDButton, context: Context) -> CGSize? {
            let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(200, uiView.intrinsicContentSize.width)
            let height = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 50
            return CGSize(width: width, height: max(44, height))
        }

        @MainActor final class Coordinator: NSObject {
            var action: @MainActor () -> Void
            init(action: @escaping @MainActor () -> Void) { self.action = action }
            @objc func activate() { action() }
        }
    }
}

/// Attach inside the account sheet. Reports its own UIKit window, without
/// searching application scenes. Delivery is deferred out of SwiftUI updates
/// and coalesced to the latest attachment; dismantling fences late delivery.
@MainActor
struct AuthenticationWindowReader: UIViewRepresentable {
    let onChange: @MainActor (UIWindow?) -> Void

    func makeUIView(context: Context) -> WindowView {
        let view = WindowView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: WindowView, context: Context) {
        view.onChange = onChange
        view.scheduleDelivery()
    }

    static func dismantleUIView(_ view: WindowView, coordinator: ()) {
        view.invalidate()
    }

    final class WindowView: UIView {
        var onChange: (@MainActor (UIWindow?) -> Void)?
        private var delivery: Task<Void, Never>?
        private var invalidated = false
        private var hasDelivered = false
        private weak var deliveredWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleDelivery()
        }

        func scheduleDelivery() {
            guard !invalidated, delivery == nil else { return }
            delivery = Task { @MainActor [weak self] in
                guard let self, !self.invalidated, !Task.isCancelled else { return }
                self.delivery = nil
                let current = self.window
                guard !self.hasDelivered || self.deliveredWindow !== current else { return }
                self.hasDelivered = true
                self.deliveredWindow = current
                self.onChange?(current)
            }
        }

        func invalidate() {
            invalidated = true
            delivery?.cancel(); delivery = nil
            onChange = nil
        }
    }
}
