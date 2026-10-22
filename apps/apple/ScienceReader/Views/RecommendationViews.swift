import ScienceReaderCore
import SwiftUI

// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): the menu under Find similar papers, the Library's
// catalog entry and the sheet that shows each added paper with why it was chosen, Remove and Undo.

/// "Recommend similar papers ›" with Add 1 / 3 / 5 and the price above them. Shown only for papers the server knows.
struct RecommendSimilarMenu: View {
    let model: ReaderModel
    let paper: Paper
    var body: some View {
        if model.canRecommend(paper) {
            Menu {
                RecommendCountButtons(note: model.recommendationCreditNote) { model.recommendSimilar(paper, count: $0) }
            } label: { Label { Text("Recommend similar papers") } icon: { menuIcon("sparkles") } }
            .accessibilityIdentifier("recommend.menu")
        }
    }
}

/// The Library ⋯ entry: recommendations for the papers of the catalog being viewed.
struct RecommendCatalogMenu: View {
    let model: ReaderModel
    var body: some View {
        if !model.catalogRecommendationSeeds.isEmpty {
            Menu {
                RecommendCountButtons(note: model.recommendationCreditNote) { model.recommendForCatalog(count: $0) }
            } label: { Label { Text("Recommend for this catalog") } icon: { menuIcon("sparkles") } }
            .accessibilityIdentifier("recommend.catalogMenu")
        }
    }
}

private struct RecommendCountButtons: View {
    let note: String
    let choose: (Int) -> Void
    var body: some View {
        Section(note) {
            ForEach(RecommendRequestBody.counts, id: \.self) { count in
                Button(count == 1 ? "Add 1 paper" : "Add \(count) papers") { choose(count) }
                    .accessibilityIdentifier("recommend.add.\(count)")
            }
        }
    }
}

/// The request's sheet: its status, the papers as they are added (each with its reason and a Remove button), then
/// what was added and what it cost, with Undo and Done. Closing it leaves the request running.
struct RecommendationSheet: View {
    @Bindable var model: ReaderModel
    /// Half height on a phone (the Library stays in view); the full form sheet on iPad and Mac (inside a sheet the size
    /// class is compact on iPad too, so the device decides).
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    var body: some View {
        NavigationStack {
            Group {
                if let run = model.recommendation { RecommendationRunView(model: model, run: run) }
                else { ContentUnavailableView("No recommendations", systemImage: "sparkles") }
            }
            .navigationTitle("Recommended papers")
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showRecommendations = false }.accessibilityIdentifier("recommend.done")
                }
                if let run = model.recommendation, !run.isRunning, !run.removable.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Undo") { Task { await model.undoRecommendations() } }
                            .disabled(run.undoing).accessibilityIdentifier("recommend.undo")
                    }
                }
            }
        }
        .presentationDetents(phone ? [.medium, .large] : [.large])
        .accessibilityIdentifier("recommend.sheet")
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }
}

private struct RecommendationRunView: View {
    let model: ReaderModel
    let run: RecommendationRun
    var body: some View {
        List {
            Section {
                Text(run.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if run.isRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(run.statusLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("recommend.status")
                } else if let outcome = run.outcome {
                    // Free AI that couldn't pay says why (migration 0150); the balance is read again once.
                    Text(run.failureCode == "insufficient_credits" ? model.creditsMessage(outcome) : outcome)
                        .font(.subheadline.weight(.medium)).accessibilityIdentifier("recommend.footer")
                        .task(id: run.failureCode) { if run.failureCode == "insufficient_credits" { await model.refreshCreditBalance() } }
                    if run.failureCode == "insufficient_credits" {
                        Button("Get credits") { model.openCreditsFromRecommendations() }.accessibilityIdentifier("recommend.getCredits")
                    } else if let code = run.failureCode, !["daily_limit", "unavailable", "connection"].contains(code) {
                        Button("Try again") { model.retryRecommendation() }.accessibilityIdentifier("recommend.retry")
                    }
                }
            }
            if !run.rows.isEmpty {
                Section {
                    ForEach(run.rows) { row in RecommendationRow(model: model, row: row) }
                }
            }
        }
    }
}

private struct RecommendationRow: View {
    let model: ReaderModel
    let row: RecommendationRun.Row
    private var paper: RecommendedPaper { row.paper }
    private var byline: String {
        let authors = paper.authors.prefix(2).joined(separator: ", ") + (paper.authors.count > 2 ? " et al." : "")
        return [authors.isEmpty ? nil : authors, paper.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
    private var note: String? {
        switch row.state {
        case .added, .removing: nil
        case .removed: "Removed"
        case .present: "Already in your library"
        case .failed: "Couldn’t add"
        case .removeFailed: "Couldn’t remove it yet. Try again."
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(paper.title).font(.body.weight(.medium)).lineLimit(2)
                if !byline.isEmpty { Text(byline).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !paper.reason.isEmpty { Text(paper.reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                if let note { Text(note).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            }
            .opacity(row.state == .removed ? 0.45 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row.state {
            case .added, .removeFailed:
                Button { Task { await model.removeRecommended(paper.sourceID) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(paper.title)")
                .accessibilityIdentifier("recommend.remove.\(paper.sourceID)")
            case .removing: ProgressView()
            case .removed, .present, .failed: EmptyView()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recommend.row.\(paper.sourceID)")
    }
}
