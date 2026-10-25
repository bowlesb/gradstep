import Foundation

/// Settings as global search finds them (docs/architecture/GLOBAL_SEARCH.md "Settings"): each row's title, its section
/// and a few other words people use for it ("dark mode" → Theme). A row matches only when every word typed begins a
/// word of its title or its other words, never from explanatory text alone. Opening one shows Settings scrolled to that
/// row (its identifier in `SettingsView`), briefly tinted; a row that is a page of its own (Your AI usage, Account, About)
/// opens the page. `ScienceReaderTests/GlobalSearchAppTests` checks every identifier is in Settings.
enum GlobalSearchSettings {
    struct Row: Sendable, Equatable, Identifiable {
        /// The row's accessibility identifier in SettingsView (its scroll target).
        let id: String
        let title: String
        let section: String
        var synonyms: [String] = []
        /// A page Settings opens rather than scrolls to.
        var page: Page? = nil
        /// When it shows (signed in, chat available, Mac only…).
        var when: Condition = .always
    }
    enum Page: String, Sendable { case account, aiUsage, about }
    enum Condition: Sendable { case always, signedIn, signedOut, chat, credits, notMac, mac }

    static let rows: [Row] = [
        Row(id: "account.row", title: "Account", section: "Account",
            synonyms: ["sign out", "log out", "delete account", "sync", "email", "devices", "recovery code"], page: .account, when: .signedIn),
        Row(id: "account.signIn", title: "Sign in or create an account", section: "Account", synonyms: ["log in", "login"], when: .signedOut),
        Row(id: "settings.credits.available", title: "Available credits", section: "AI credits", synonyms: ["balance", "credits"], when: .credits),
        Row(id: "settings.plan", title: "Plan", section: "AI credits", synonyms: ["subscription", "pricing", "free AI"], when: .credits),
        Row(id: "settings.aiUsage", title: "Your AI usage", section: "AI credits", synonyms: ["tokens", "cost", "spending", "usage"], page: .aiUsage, when: .credits),
        Row(id: "settings.getCredits", title: "Get credits", section: "AI credits", synonyms: ["buy", "purchase", "top up"], when: .credits),
        Row(id: "settings.aiScenario.general", title: "General chat", section: "AI defaults by activity", synonyms: ["model", "default model"], when: .chat),
        Row(id: "settings.aiScenario.paper", title: "Paper chat", section: "AI defaults by activity", synonyms: ["model", "default model"], when: .chat),
        Row(id: "settings.aiScenario.equations", title: "Equation explanations model", section: "AI defaults by activity",
            synonyms: ["model", "default model"], when: .chat),
        Row(id: "settings.aiScenario.figures", title: "Figures and tables model", section: "AI defaults by activity",
            synonyms: ["model", "default model"], when: .chat),
        Row(id: "settings.localModels", title: "Local models", section: "AI options", synonyms: ["on-device model", "offline AI"], when: .mac),
        Row(id: "settings.visualAnswers", title: "Visual answers", section: "AI options", synonyms: ["diagrams", "visuals", "drawings"], when: .chat),
        Row(id: "settings.autoDownload", title: "Download new papers", section: "Library", synonyms: ["offline", "automatic download", "prepare"]),
        Row(id: "settings.theme", title: "Theme", section: "Reading", synonyms: ["dark mode", "light mode", "appearance", "colours", "colors"]),
        Row(id: "settings.passageMarks", title: "Underline passages with chats", section: "Reading", synonyms: ["highlights", "marks"]),
        Row(id: "settings.chats", title: "Chats", section: "Your assets", synonyms: ["all chats", "history", "conversations"]),
        Row(id: "settings.diagrams", title: "Diagrams", section: "Your assets", synonyms: ["visual answers"]),
        Row(id: "settings.notes", title: "Snippets", section: "Your assets", synonyms: ["notes", "collections"]),
        Row(id: "settings.equationExplanations", title: "Equation explanations", section: "Your assets", synonyms: ["kept explanations"]),
        Row(id: "settings.figureExplanations", title: "Figure explanations", section: "Your assets", synonyms: ["kept explanations"]),
        Row(id: "settings.paperExplanations", title: "Paper explanations", section: "Your assets", synonyms: ["AI Explainer", "kept explanations"]),
        Row(id: "settings.downloads", title: "Downloaded papers", section: "Your assets", synonyms: ["storage", "space", "delete downloads", "offline"]),
        Row(id: "settings.report", title: "Report a problem", section: "Support", synonyms: ["bug", "feedback", "support", "help"]),
        Row(id: "settings.screenshotPrompt", title: "Offer to report after a screenshot", section: "Support", synonyms: ["screenshot"], when: .notMac),
        Row(id: "settings.about", title: "About Gradstep", section: "About", synonyms: ["version", "privacy", "acknowledgements", "licenses"], page: .about),
    ]

    /// The rows Settings shows now.
    @MainActor static func visible(_ model: ReaderModel) -> [Row] {
        rows.filter { row in
            switch row.when {
            case .always: true
            case .signedIn: model.isSignedIn
            case .signedOut: !model.isSignedIn
            case .chat: model.chatTransport != nil
            case .credits: model.isSignedIn && model.chatTransport != nil
            case .notMac: !Platform.isMac
            case .mac: Platform.isMac
            }
        }
    }

    static func row(_ id: String) -> Row? { rows.first { $0.id == id } }
}

/// Settings opened from a search result: the row to show (or the page to open), once.
struct SettingsFocus: Equatable {
    let row: String
    let token = UUID()
}
