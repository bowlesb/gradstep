import SwiftUI
import ScienceReaderCore

enum AIUseCase: String, CaseIterable, Identifiable {
    case general, paper, equations, figures
    var id: Self { self }
    var title: String { switch self {
        case .general: "General chat"
        case .paper: "Paper chat"
        case .equations: "Equation explanations"
        case .figures: "Figures and tables"
    } }
}

/// What to weigh when choosing each activity's default (owner, 2026-10-21: "There should be an explainer saying some
/// considerations when choosing the default for each category and why you might consider changing them"). Behind ⓘ
/// buttons (owner, build 57), word for word the same as the browser's `AI_DEFAULTS_GUIDE` (apps/web/src/lib/chat-session.ts).
enum AIDefaultsGuide {
    static let overview = "Stronger models give deeper, more careful answers but use more credits and take longer. Faster models cost less and answer sooner. Each model is processed by its own provider, named in About AI chat options and on the episode sheet."
    static let whenToChange = "Change a default if answers feel too shallow (choose a stronger model), if credits run low (a cheaper one), or if answers are slow (a faster one)."
    static let general = "General chat answers questions that aren’t about a paper. Speed usually matters most, so a fast, low-cost model fits."
    static let paper = "Paper chat reads the whole paper with each question. A balanced model handles most questions; a stronger one helps with long derivations and critique."
    static let equations = "Equation explanations walk through symbols and derivations, which reward careful reasoning, so a stronger model is often worth the extra credits."
    static let figures = "Figures and tables: the model looks at the figure’s image as well as its caption, so it must read images (every cloud model listed does). Gemini Flash is the default: it reads plots closely at a low cost, and its walkthrough starts appearing within seconds. Sonnet is a little quicker to start and also careful, at about three times the cost. Speed differs by model: DeepSeek writes more slowly, and much more slowly at a higher effort."
    static let podcasts = "Podcasts: the writer drafts and checks a whole episode script, a long output, so its cost adds up and longer episodes cost more. The voices are the same whichever writer you choose."

    /// Settings › AI defaults by activity ⓘ.
    static var section: String { overview + "\n\n" + whenToChange }
    /// One activity's ⓘ: what it does, then the general considerations.
    static func text(for scenario: AIUseCase) -> String {
        let about = switch scenario { case .general: general; case .paper: paper; case .equations: equations; case .figures: figures }
        return compose(about)
    }
    static var podcastText: String { compose(podcasts) }
    private static func compose(_ about: String) -> String { about + "\n\n" + overview + "\n\n" + whenToChange }
}

struct AIScenarioDefaults: View {
    @Bindable var model: ReaderModel
    let scenario: AIUseCase
    var body: some View {
        Form {
            Section {
                #if targetEnvironment(macCatalyst)
                Picker("Default model", selection: Binding(get: { model.localDefault(for: scenario) ?? "cloud" }, set: {
                    model.setLocalDefault($0 == "cloud" ? nil : $0, for: scenario)
                })) {
                    Text("Cloud").tag("cloud")
                    ForEach(model.localAI.models.filter { (scenario != .figures || $0.vision) && (model.localAI.installed.contains($0.id) || model.localDefault(for: scenario) == $0.id) }) { option in
                        Text("\(option.name) (local)").tag(option.id)
                    }
                }.accessibilityIdentifier("settings.aiScenario.engine")
                #endif
                ChatChoiceControls(model: model, mode: .scenario(scenario))
            } header: {
                AIDefaultsHeader(title: "Default model", info: AIDefaultsGuide.text(for: scenario))
            } footer: {
                Text("Used when starting \(scenario.title.lowercased()). Existing conversations keep their selected model. You can change it before sending.")
            }
            Section { Button("Use recommended defaults") { model.resetAIDefault(for: scenario) } }
        }.navigationTitle(scenario.title).navigationBarTitleDisplayMode(.inline)
            .task { model.refreshChatProfiles(); await model.localAI.refresh() }
    }
}

/// A Settings section title with its ⓘ just right of the words (owner, build 57).
struct AIDefaultsHeader: View {
    let title: String
    let info: String
    var identifier = "settings.aiScenario.guide"
    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            InfoButton(text: info, identifier: identifier).textCase(nil)
        }
    }
}

/// Settings › AI defaults by activity › Podcasts (owner, 2026-10-21: "Podcasts is missing from defaults in model
/// settings"): who writes new episodes' scripts. Only the writers the server lists for podcasts are offered; the choice
/// is preselected in Make an episode whenever the chosen length offers it, and is sent as the quote's `writer`
/// (docs/architecture/PAPER_PODCASTS.md, "Writer choice"). Stored on this device, like the chat activities' defaults.
struct PodcastWriterDefaults: View {
    @Bindable var model: ReaderModel
    var body: some View {
        let podcasts = model.podcasts
        let writers = podcasts.offeredWriters
        let chosen = podcasts.effectiveDefaultWriter?.writer
        Form {
            Section {
                if writers.isEmpty {
                    Text(podcasts.capabilities?.generation == true ? "Gradstep chooses the writer for each episode."
                         : podcasts.catalogState == .loading || podcasts.capabilities == nil && podcasts.catalogState == .idle
                         ? "Loading the writers…" : "Episodes can’t be made right now.")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("settings.podcastWriter.unavailable")
                } else {
                    ForEach(writers) { writer in
                        Button { podcasts.defaultWriter = writer.writer } label: {
                            HStack {
                                Text(writer.label).foregroundStyle(Color.primary)
                                Spacer(minLength: 8)
                                if writer.writer == chosen {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(writer.writer == chosen ? .isSelected : [])
                        .accessibilityIdentifier("settings.podcastWriter.\(writer.writer)")
                    }
                }
            } header: {
                AIDefaultsHeader(title: "Written by", info: AIDefaultsGuide.podcastText)
            } footer: {
                Text("Used when you make an episode. You can choose another writer there before asking.")
            }
            Section {
                Button("Use recommended default") { podcasts.defaultWriter = nil }
                    .disabled(podcasts.defaultWriter == nil).accessibilityIdentifier("settings.podcastWriter.reset")
            }
        }
        .navigationTitle("Podcasts").navigationBarTitleDisplayMode(.inline)
        .task { podcasts.prepareListen() }
    }
}
