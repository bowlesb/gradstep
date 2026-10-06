import SwiftUI

/// Google's custom-button treatment (light, or dark in dark mode), using the
/// unmodified official mark and bundled Google Sans Medium. Asset provenance and
/// the font license live beside the app's resources; this control adds no
/// authentication dependency. Its shape matches the other sign-in buttons
/// (`AuthenticationButtonStyle`).
@MainActor
struct NativeGoogleAuthenticationButton: View {
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var minimumLineHeight: CGFloat = 20
    var isEnabled = true
    let action: @MainActor () -> Void

    /// Google's published button colors: fill, 1 pt stroke, text.
    private var palette: (fill: Color, stroke: Color, text: Color) {
        colorScheme == .dark
            ? (Self.rgb(0x13, 0x13, 0x14), Self.rgb(0x8E, 0x91, 0x8F), Self.rgb(0xE3, 0xE3, 0xE3))
            : (.white, Self.rgb(0x74, 0x77, 0x75), Self.rgb(0x1F, 0x1F, 0x1F))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AuthenticationButtonStyle.cornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleSignInMark")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Continue with Google")
                    .font(.custom("GoogleSans-Medium", size: 14, relativeTo: .body))
                    .foregroundStyle(palette.text)
                    .opacity(isEnabled && environmentEnabled ? 1 : 0.38)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: minimumLineHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: AuthenticationButtonStyle.height)
            .background(palette.fill, in: shape)
            .overlay { shape.strokeBorder(palette.stroke, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Continue with Google")
        .accessibilityIdentifier("auth.google")
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }
}
