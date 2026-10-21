import SwiftUI
import UIKit

/// Presentation-only state. The model/coordinator retain attempt ownership
/// while the sheet is dismissed or a system authentication panel is visible.
@MainActor
struct AuthenticationView: View {
    @Bindable var model: ReaderModel
    let presentationID: UUID
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator = model.authentication {
                    AuthenticationForm(coordinator: coordinator, presentationID: presentationID,
                        isCurrent: {
                            model.showSignIn && model.signInPresentationID == presentationID
                        })
                } else {
                    ScrollView {
                        Text("Sign-in isn’t available in this build.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 440, alignment: .leading)
                            .frame(maxWidth: .infinity).padding(16)
                            .accessibilityIdentifier("auth.unavailable")
                    }
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A task sheet: Cancel on the left (docs/DESIGN.md). While the email steps show
                // their back button there, Cancel moves to the right.
                if model.authentication?.phase.offersOtherMethods == true {
                    ToolbarItem(placement: .topBarTrailing) { cancelButton }
                } else {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                }
            }
        }
        // Short sheet: medium height, unless large text needs the whole screen.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private var cancelButton: some View {
        Button("Cancel") { model.closeSignIn(presentationID: presentationID) }
            .accessibilityIdentifier("auth.close").macBarButton()
    }
}

/// The email method and code buttons share one shape with the Apple and Google buttons:
/// 50 pt tall (growing with large text), 12 pt corners.
struct AuthenticationButtonStyle: ButtonStyle {
    static let height: CGFloat = 50
    static let cornerRadius: CGFloat = 12
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: AuthenticationButtonStyle.cornerRadius, style: .continuous)
            configuration.label
                .font(.body.weight(.semibold)).multilineTextAlignment(.center)
                .foregroundStyle(foreground)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: AuthenticationButtonStyle.height)
                .background(background, in: shape)
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }

        private var foreground: Color {
            guard isEnabled else { return Color(uiColor: .tertiaryLabel) }
            // The accent is light in dark mode, so prominent text inverts with it.
            return prominent ? (colorScheme == .dark ? .black : .white) : .accentColor
        }

        private var background: Color {
            guard isEnabled else { return Color(uiColor: .tertiarySystemFill) }
            return prominent ? .accentColor : Color.accentColor.opacity(0.15)
        }
    }
}

private extension AuthenticationCoordinator.Phase {
    /// The email steps offer a way back to the other sign-in methods.
    var offersOtherMethods: Bool {
        switch self {
        case .emailEntry, .codeEntry: true
        default: false
        }
    }
}

@MainActor
private struct AuthenticationForm: View {
    let coordinator: AuthenticationCoordinator
    let presentationID: UUID
    let isCurrent: @MainActor () -> Bool
    @State private var email = ""
    @State private var code = ""
    @State private var challengeID: UUID?
    @State private var anchor: UIWindow?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, code }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                phaseContent
            }
            .frame(maxWidth: 440, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(16).padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            AuthenticationWindowReader { anchor = $0 }.frame(width: 0, height: 0)
        }
        .toolbar {
            if showsMethodBackButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        perform { coordinator.showChoices() }
                    } label: { Label("Back", systemImage: "chevron.left") }
                    .accessibilityLabel("Other sign-in methods")
                    .accessibilityIdentifier("auth.methods")
                }
            }
        }
        .onChange(of: coordinator.phase, initial: true) { _, phase in updateLocalFields(for: phase) }
    }

    @ViewBuilder private var phaseContent: some View {
        switch coordinator.phase {
        case .choices(let issue):
            Text("Keep your library and conversations in sync.").foregroundStyle(.secondary)
            VStack(spacing: 12) {
                NativeAppleAuthenticationButton(isEnabled: anchor != nil) {
                    guard let anchor else { return }
                    perform { coordinator.startApple(presenter: authenticationPresenter(anchor: anchor)) }
                }
                .frame(height: AuthenticationButtonStyle.height)
                NativeGoogleAuthenticationButton(isEnabled: anchor != nil) {
                    guard let anchor else { return }
                    perform { coordinator.startGoogle(presenter: authenticationPresenter(anchor: anchor)) }
                }
                secondaryButton("Continue with email", identifier: "auth.emailMethod") {
                    perform { coordinator.showEmail() }
                }
            }
            if let issue { issueText(issue) }

        case .emailEntry(_, let issue):
            Text("We’ll email you a sign-in code.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).font(.body)
                    .focused($focusedField, equals: .email).submitLabel(.send)
                    .onSubmit { sendCode() }
                    .privacySensitive().accessibilityIdentifier("auth.email")
                primaryButton("Send code", identifier: "auth.sendCode", action: sendCode)
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let issue { issueText(issue) }

        case .codeEntry(let challenge):
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter your code").font(.title2.weight(.semibold))
                Text(challenge.email).foregroundStyle(.secondary).privacySensitive()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("auth.codeEmail")
                if challenge.delivery == .unconfirmed {
                    Text("Couldn’t confirm delivery. You can still enter a code.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("auth.deliveryUnconfirmed")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Six-digit code", text: $code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).font(.body.monospacedDigit())
                    .focused($focusedField, equals: .code).submitLabel(.continue)
                    .onSubmit { verifyCode() }
                    .privacySensitive().hiddenFromReports().accessibilityIdentifier("auth.code")
                if let issue = challenge.issue { issueText(issue) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let verifyWait = coordinator.verifySecondsRemaining()
                    let resendWait = coordinator.resendSecondsRemaining()
                    VStack(alignment: .leading, spacing: 12) {
                        primaryButton("Continue", identifier: "auth.verify", action: verifyCode)
                            .disabled(!hasCompleteCode || verifyWait > 0)
                        if verifyWait > 0 {
                            Text("Try again in \(verifyWait) seconds.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("auth.verifyCooldown")
                        }
                        secondaryButton(resendWait > 0 ? "Resend code in \(resendWait)s" : "Resend code",
                            identifier: "auth.resend") {
                                perform { coordinator.resendCode() }
                            }
                            .disabled(resendWait > 0)
                            .accessibilityLabel("Resend code")
                            .accessibilityValue(resendWait > 0 ? "Available in \(resendWait) seconds" : "Available")
                    }
                }
                plainButton("Use another email", identifier: "auth.changeEmail") {
                    perform { coordinator.useAnotherEmail() }
                }
            }
        case .preparing:
            progress("Preparing sign-in…", canChangeMethod: true)
        case .external(let method):
            progress(method == .apple ? "Continue with Apple to sign in." : "Continue with Google to sign in.",
                     canChangeMethod: true)
        case .sendingCode:
            progress("Sending code…", canChangeMethod: true)
        case .exchanging:
            progress("Signing in…", canChangeMethod: true)
        case .cancelling:
            progress("Finishing…", canChangeMethod: false)
        case .accepted:
            progress("Signed in", canChangeMethod: false)
        case .closed:
            EmptyView()
        }
    }

    private var showsMethodBackButton: Bool { coordinator.phase.offersOtherMethods }

    private var hasCompleteCode: Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func sendCode() {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform { coordinator.sendCode(email: email) }
    }

    private func verifyCode() {
        guard hasCompleteCode, coordinator.verifySecondsRemaining() == 0 else { return }
        perform { coordinator.verifyCode(code) }
    }

    private func perform(_ action: () -> Void) {
        guard isCurrent(), coordinator.presentation?.id == presentationID else { return }
        focusedField = nil
        action()
    }

    private func authenticationPresenter(anchor: UIWindow) -> any AuthenticationPresenting {
        #if DEBUG && FIXTURE_HOST && !OFFLINE_RESOURCE_MEASUREMENTS
        if AuthenticationWorkflowFixture.isEnabled {
            return AuthenticationWorkflowFixture.presenter(anchor: anchor)
        }
        #endif
        return NativeAuthenticationPresenter(anchor: anchor)
    }

    private func updateLocalFields(for phase: AuthenticationCoordinator.Phase) {
        switch phase {
        case .emailEntry(let value, _):
            email = value; code = ""; challengeID = nil
        case .codeEntry(let challenge):
            if challengeID != challenge.attemptID { code = "" }
            challengeID = challenge.attemptID; email = challenge.email
        case .sendingCode(let value):
            email = value; code = ""; challengeID = nil
        case .preparing(.email):
            code = ""; challengeID = nil
        case .exchanging(.email):
            break // An explicit correction may reuse this same owned challenge.
        default:
            email = ""; code = ""; challengeID = nil
        }
    }

    private func primaryButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fixedSize(horizontal: false, vertical: true) }
            .buttonStyle(AuthenticationButtonStyle(prominent: true)).accessibilityIdentifier(identifier)
    }

    private func secondaryButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fixedSize(horizontal: false, vertical: true) }
            .buttonStyle(AuthenticationButtonStyle(prominent: false)).accessibilityIdentifier(identifier)
    }

    private func plainButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { buttonLabel(title) }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor).accessibilityIdentifier(identifier)
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title).font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
    }

    private func issueText(_ issue: AuthenticationCoordinator.Issue) -> some View {
        Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("auth.issue")
    }

    private func progress(_ title: String, canChangeMethod: Bool) -> some View {
        VStack(spacing: 12) {
            ProgressView(title).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("auth.progress")
            if canChangeMethod {
                plainButton("Other sign-in methods", identifier: "auth.methods") {
                    perform { coordinator.showChoices() }
                }
            }
        }
    }
}
