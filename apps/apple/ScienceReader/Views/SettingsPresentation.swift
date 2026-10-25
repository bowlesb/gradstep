import SwiftUI

// Settings over the current screen (owner, 2026-10-20; docs/architecture/NOTES_AND_SNIPPETS.md "Navigation"): it opens
// the existing Settings over the screen; Done returns to exactly where the reader was. On iPhone it is More's third row
// (owner, 2026-10-25; JUDGMENT_LOG 15), on iPad a place (the full bar's sixth, the places menu's last row, More in a
// narrow window); only the Mac's ⋯ menus still end with it, under Report this screen.

/// The last section of every screen's ⋯ menu on the Mac. Not on iPhone or iPad, where Settings is under More or a place
/// (owner, 2026-10-24, of the iPad's ⋯: "we're going to move that so we don't see it there"; 2026-10-25 for the iPhone).
struct SettingsMenuSection: View {
    let model: ReaderModel
    /// Run before Settings opens (a screen that must first let go of the keyboard).
    var before: () -> Void = {}
    var body: some View {
        if Platform.isMac {
            Section {
                Button { before(); model.openSettings(afterMenu: true) } label: {
                    Label { Text("Settings") } icon: { menuIcon(GradstepSymbol.settings) }
                }
                .accessibilityIdentifier("menu.settings")
            }
        }
    }
}

/// The presentations Settings can open (sign-in, recovery, chats, diagrams, credits, reports, errors) are attached
/// twice: to the root, and inside the Settings sheet. Exactly one host is live at a time, so a row in Settings opens its
/// sheet over Settings (closing it returns to Settings) and nothing competes to present from the same view.
struct SharedPresentations: ViewModifier {
    enum Host { case root, settings }
    @Bindable var model: ReaderModel
    let host: Host

    private var live: Bool { model.settingsPresented == (host == .settings) }
    private func routed(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { live && flag.wrappedValue }, set: { flag.wrappedValue = $0 })
    }
    private func routed<Item>(_ item: Binding<Item?>) -> Binding<Item?> {
        Binding(get: { live ? item.wrappedValue : nil }, set: { item.wrappedValue = $0 })
    }
    private var signInPresentation: Binding<Bool> {
        // SwiftUI may deliver the dismissal after this body has changed. Keep the ID that this binding actually
        // presented, rather than cancelling whichever attempt happens to be current when the callback arrives.
        let presentationID = model.signInPresentationID
        return Binding(get: { live && model.showSignIn }, set: { presented in
            if !presented, let presentationID { model.closeSignIn(presentationID: presentationID) }
        })
    }

    func body(content: Content) -> some View {
        content
            .appSheet(isPresented: signInPresentation, onDismiss: { model.authenticationSheetDismissed() }) {
                if let presentationID = model.signInPresentationID {
                    AuthenticationView(model: model, presentationID: presentationID).id(presentationID).macSheetKeys()
                }
            }
            .appSheet(isPresented: routed($model.showRecovery)) { RecoveryView(model: model).interactiveDismissDisabled().macSheetKeys(enabled: false) }
            .appSheet(isPresented: routed($model.showAllChats)) {
                ChatHistoryView(model: model, paperID: model.allChatsPaperID, startsOnPaper: model.allChatsStartsOnPaper).macSheetKeys()
            }
            .appSheet(isPresented: routed($model.showDiagrams)) { HistoryView(model: model, diagrams: true).macSheetKeys() }
            .appSheet(isPresented: routed($model.showStore)) { CreditsStoreView(model: model).macSheetKeys() }
            .appSheet(isPresented: routed($model.showRecommendations)) { RecommendationSheet(model: model).macSheetKeys() }
            .appSheet(item: routed($model.presentedDiagram)) { presented in
                if let diagram = model.diagram(presented.id) {
                    DiagramSheet(diagram: diagram).macSheetKeys()
                        .environment(\.figureImage) { manifest, paths in model.figureImage(manifest: manifest, paths: paths) }
                        .environment(\.figurePartCrops) { stored in model.figurePartCrops(stored) }
                }
            }
            .appSheet(isPresented: routed($model.showReport), onDismiss: {
                model.reportScreenshot = nil
                if model.showReportsAfterComposer { model.showReportsAfterComposer = false; model.showReports = true }
            }) { ReportComposer(model: model) }
            .appSheet(isPresented: routed($model.showReports)) { if let service = model.support { ReportsView(service: service).macSheetKeys() } }
            .alert("Gradstep", isPresented: Binding(get: { live && model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

extension View {
    func sharedPresentations(_ model: ReaderModel, host: SharedPresentations.Host) -> some View {
        modifier(SharedPresentations(model: model, host: host))
    }
}
