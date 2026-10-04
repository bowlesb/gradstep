import SwiftUI

/// Google's custom-button light treatment, using the unmodified official mark
/// and bundled Google Sans Medium. Asset provenance and the font license live
/// beside the app's resources; this control adds no authentication dependency.
@MainActor
struct NativeGoogleAuthenticationButton: View {
    @Environment(\.isEnabled) private var environmentEnabled
    @ScaledMetric(relativeTo: .body) private var minimumLineHeight: CGFloat = 20
    var isEnabled = true
    let action: @MainActor () -> Void

    var body: some View {
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
                    .foregroundStyle(Color(red: 31.0 / 255, green: 31.0 / 255, blue: 31.0 / 255))
                    .opacity(isEnabled && environmentEnabled ? 1 : 0.38)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: minimumLineHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(red: 116.0 / 255, green: 119.0 / 255, blue: 117.0 / 255), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Continue with Google")
        .accessibilityIdentifier("auth.google")
    }
}
