import SwiftUI

// Settings, reorganized (owner feedback, build 14 #8/#9: "The account option tells me nothing, sync? Sign out and
// delete feel like they should be hidden away? What does appearance mean to the user?" and, of Acknowledgements as a
// Settings row, "This doesn't look like it should be there"). Settings starts with one Account row that opens the
// Account page (email, how you sign in, sync in plain words, Sign out, Delete account); the theme is a visible
// Light / Dark / Match device choice; version, privacy and acknowledgements sit behind About Gradstep at the bottom.

/// Sync in plain words, from the model's sync state (`ReaderModel.syncStatus`, `syncIssue` and the count of encrypted
/// changes not yet sent). Pure, so the wording is tested without the UI.
struct SyncSummary: Equatable {
    enum Tone: Equatable { case synced, working, paused }
    let tone: Tone
    /// The Account page's line: "Your chats and notes are synced", "Waiting to sync 3 changes".
    let title: String
    let detail: String?
    /// The Settings row's short form: "Synced", "3 changes waiting to sync", "Sync paused".
    let short: String

    var systemImage: String {
        switch tone {
        case .synced: "checkmark.icloud"
        case .working: "arrow.triangle.2.circlepath.icloud"
        case .paused: "exclamationmark.icloud"
        }
    }

    static func changes(_ count: Int) -> String { count == 1 ? "1 change" : "\(count.formatted()) changes" }

    static func from(status: String, issue: String?, pending: Int) -> SyncSummary {
        if issue != nil || status.hasSuffix("Sync paused") {
            return SyncSummary(tone: .paused, title: "Sync is paused",
                               detail: issue ?? "Your changes are saved on this device and sync when it can reach Gradstep.",
                               short: "Sync paused")
        }
        if status == "Syncing…" {
            return SyncSummary(tone: .working, title: "Syncing…", detail: pending > 0 ? "Sending \(changes(pending))." : nil, short: "Syncing…")
        }
        if pending > 0 {
            return SyncSummary(tone: .working, title: "Waiting to sync \(changes(pending))",
                               detail: "They’re saved on this device and sync automatically.",
                               short: "\(changes(pending)) waiting to sync")
        }
        // "Synced", or a local save that has since been sent; "On this device" means no sync has finished yet.
        if status == "Synced" || status == "Saved on this device" {
            return SyncSummary(tone: .synced, title: "Your chats and notes are synced",
                               detail: "They’re encrypted with keys held on your devices.", short: "Synced")
        }
        return SyncSummary(tone: .working, title: "Not synced yet",
                           detail: "Your chats and notes are saved on this device and sync automatically.", short: "Not synced yet")
    }
}

/// How the account is named and signed into, for the Account row and page.
enum AccountFormat {
    /// "Apple", "Google", "Email code"; unknown providers are left out.
    static func methods(_ providers: [String]) -> String? {
        let names = providers.compactMap { provider -> String? in
            switch provider {
            case "apple": "Apple"
            case "google": "Google"
            case "email": "Email code"
            default: nil
            }
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : ListFormatter.localizedString(byJoining: unique)
    }

    /// The email, or "Signed in with Apple" when the account has none (Apple can withhold it).
    static func name(email: String?, providers: [String]) -> String {
        if let email, !email.isEmpty { return email }
        return "Signed in with \(methods(providers) ?? "Apple")"
    }
}

/// Settings' first row while signed in: who you are, how you sign in and whether everything is synced.
struct AccountRow: View {
    let name: String
    let detail: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        // At accessibility sizes the words wrap instead of truncating, and the picture gives up its width.
        let large = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: 12) {
            if !large {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(large ? 4 : 1).truncationMode(.middle)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(large ? nil : 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows sync, sign out and account deletion")
    }
}

/// The Account page: email, how you sign in, sync in plain words, then Sign out and Delete account.
struct AccountView: View {
    @Bindable var model: ReaderModel
    /// Opens the Delete account sheet, which Settings presents (it stays up if this page closes underneath it).
    let deleteAccount: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var width: CGFloat = 0

    var body: some View {
        let sync = SyncSummary.from(status: model.syncStatus, issue: model.syncIssue, pending: model.publishedPendingCount)
        Form {
            Section {
                if let email = model.email, !email.isEmpty {
                    LabeledContent("Email") { Text(email).textSelection(.enabled) }.accessibilityIdentifier("account.email")
                }
                if let methods = AccountFormat.methods(model.signInProviders) {
                    LabeledContent("Signed in with", value: methods).accessibilityIdentifier("account.methods")
                } else if model.email?.isEmpty ?? true {
                    Text(AccountFormat.name(email: model.email, providers: model.signInProviders))
                }
            }
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: sync.systemImage).foregroundStyle(sync.tone == .paused ? Color.orange : Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.title)
                        if let detail = sync.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("account.sync")
                Button("Sync now") { Task { await model.synchronize(reportErrors: true) } }
                    .disabled(model.syncStatus == "Syncing…")
                    .accessibilityIdentifier("account.syncNow")
            } header: { Text("Sync") } footer: {
                Text("Sync keeps your library, chats and notes the same on every device where you sign in.")
            }
            // QR device approval (DeviceApprovalViews.swift): add a browser or another device without the recovery code.
            Section {
                NavigationLink("Add a device") { AddDeviceView(model: model) }.accessibilityIdentifier("account.addDevice")
            } footer: { Text("Approve a browser or another device by scanning the code it shows, instead of typing your recovery code.") }
            Section {
                Button("Sign out") { Task { await model.signOut() } }.accessibilityIdentifier("account.signOut")
            } footer: { Text("Encrypted pending work stays on this device for your next sign-in.") }
            Section {
                Button("Delete account…", role: .destructive, action: deleteAccount).accessibilityIdentifier("account.delete")
            }
        }
        .readableScrollColumn(width: width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
        // Signing out (or deleting the account) leaves nothing to show here.
        .onChange(of: model.isSignedIn) { _, signedIn in if !signedIn { dismiss() } }
    }
}

/// Light, Dark or Match device, visible at a glance (it was "Appearance: System"). Same stored setting
/// (`ReaderModel.appearance`: "light", "dark", "system"). At accessibility text sizes a menu, which has room for the
/// words.
struct ThemePicker: View {
    @Binding var selection: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Theme", selection: $selection) { options }.accessibilityIdentifier("settings.theme")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                Picker("Theme", selection: $selection) { options }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("settings.theme")
            }
        }
    }

    @ViewBuilder private var options: some View {
        Text("Light").tag("light")
        Text("Dark").tag("dark")
        Text("Match device").tag("system")
    }
}

/// About Gradstep: version and edition, then privacy and acknowledgements.
struct AboutView: View {
    let version: String
    @State private var width: CGFloat = 0

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    if let icon = Self.appIcon {
                        Image(uiImage: icon).resizable().frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).accessibilityHidden(true)
                    }
                    Text("Gradstep").font(.title2.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            Section {
                LabeledContent("Version", value: version).accessibilityIdentifier("about.version")
                LabeledContent("Edition", value: "Private beta · staging")
            }
            Section {
                NavigationLink("How Gradstep works") { GradstepInfoView() }.accessibilityIdentifier("about.howGradstepWorks")
                NavigationLink("Privacy & data") { PrivacyView() }.accessibilityIdentifier("about.privacy")
                NavigationLink("Acknowledgements") { AcknowledgementsView() }.accessibilityIdentifier("about.acknowledgements")
            }
        }
        .readableScrollColumn(width: width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }

    /// The app's own icon, when the bundle names one.
    private static var appIcon: UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let name = files.last else { return nil }
        return UIImage(named: name)
    }
}

/// A compact, user-facing explanation of the data paths and cost controls. Keep this separate from the legal privacy
/// page: it explains why a response can cost credits and which model/provider paths are involved without promising
/// provider-specific retention or pretending that encryption at rest hides text during a requested computation.
struct GradstepInfoView: View {
    @State private var width: CGFloat = 0

    var body: some View {
        Form {
            Section {
                Text("Gradstep keeps your research useful across devices while sending only the material needed for the action you ask for. Local paper storage, encrypted sync and AI processing are separate paths.")
            } header: { Text("The short version") }

            Section {
                Text("Library metadata, tags and encrypted chat events can sync through Gradstep. Reading progress stays on this device. Chat and note content is encrypted before sync; the keys stay with your approved devices and recovery code.")
                Text("New PDFs are downloaded, opened and processed only on your device. The structured reader prepares the exact official arXiv HTML version locally. Earlier server copies and conversions were deleted on 16 October 2026.")
                Text("An AI answer sends the relevant question, selected passage, conversation context and paper text to the selected model provider. Encryption protects stored copies; it does not hide content from a provider during a computation you requested.")
                Text("Optional web search sends search queries to the configured search provider. Provider retention and handling follow that provider's terms; Gradstep does not promise zero provider retention.")
            } header: { Text("What leaves your device") }

            Section {
                Text("A credit is a Gradstep usage unit, not cash. Before an AI action, the server estimates the work and reserves a bounded maximum. When it finishes, the actual measured usage is settled. Retries use the same operation identity so a lost response does not charge twice.")
                Text("Local HTML preparation uses no OCR credits. Chat, search and podcasts have separate limits and accounting. Ready-made podcast episodes avoid repeating provider work. Account and platform budgets stop one user or a provider outage from creating an unlimited bill.")
                Text("Tokens are the text units providers use for billing; they are not the same as words. The cost of an answer depends on the paper and conversation size, cached context, model, effort, answer length, tools and searches, and the tokens actually used. The chat controls show an estimate and maximum before work starts.")
            } header: { Text("How we keep costs bounded") }

            Section {
                Text("These are planning guides, not a promise of a fixed number of answers. All paid actions use the same balance, and a longer paper or a more detailed profile can cost more.")
                Text("Paper preparation: official arXiv HTML is prepared on your device without an OCR charge. Chat: a typical Sonnet answer is usually about 4–24 credits, with the exact estimate shown before sending. Search: about 1–2 credits per search.")
                Text("Podcasts: browsing and playing a shared episode uses no generation credits. Recent five-minute private episodes used about 55–60 credits; the safety maximum is 150 and the actual charge is settled afterward.")
                Text("The current Standard and Pro plans include 800 and 1,800 credits. A light mix of new papers and chats leaves room for occasional audio; repeated long papers, deep answers and private episodes use the allowance faster.")
            } header: { Text("What a normal month can cover") }

            Section {
                Text("Current chat answers use Anthropic's Claude models: Haiku is the fast, lower-cost choice for simpler work, Sonnet is the default balance of quality and cost, and Opus is reserved for harder reasoning. An experimental on-device model can read a PDF on this device (Settings › Experimental); nothing leaves the device for it. There is no Mathpix fallback; search and speech use separate providers when enabled. The server enforces the available profiles and records the model that actually answered, including an approved fallback.")
                Text("Chat answers come from Anthropic’s Claude models, or from DeepSeek when you choose it in Answer options (Claude still writes the chat’s title and suggested questions); podcast scripts can also be written by DeepSeek when you choose it for an episode. A lower-priced model is not automatically a safe replacement for scientific reading: before using one anywhere, we compare equation handling, citations, long-paper quality, privacy terms, latency, structured tools and real measured cost. We will not trade away reliability for a price number alone.")
            } header: { Text("Models and providers") }

            Section {
                Text("Your device downloads each paper's official HTML version from arXiv and prepares it here; paper links go to the exact version on arXiv, and each paper keeps its authors' license.")
                Text(ArxivAcknowledgement.statement)
            } header: { Text("arXiv") }

            Section {
                Text("You choose the chat profile and answer length, and you can leave web search off. Each request is bounded before it runs, and the app shows what was charged afterward. If a paper or answer behaves unexpectedly, Report this screen so we can inspect the workflow and its accounting record.")
            } header: { Text("Your controls") }
        }
        .font(.subheadline)
        .readableScrollColumn(width: width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("How Gradstep works").navigationBarTitleDisplayMode(.inline)
    }
}

/// arXiv's required acknowledgement for products that use its API or data (API Access page and brand guidelines,
/// docs/architecture/ARXIV_DEVICE_ONLY.md §7), shown in How Gradstep works and Acknowledgements.
enum ArxivAcknowledgement {
    static let statement = "Thank you to arXiv for use of its open access interoperability. This product was not reviewed or approved by, nor does it necessarily express or reflect the policies or opinions of, arXiv."
}
