import ScienceReaderCore
import SwiftUI

/// Settings › AI credits › Your AI usage, also from Get credits (owner, 2026-10-22: "a table of my recent AI token spend
/// for all the different activities … rows ordered by time, each row being an activity, and the exact cost, so that a
/// user can figure out where their credits are going"). One row per request, newest first: when, the activity (and the
/// paper, from this device's library), the model, the tokens and the credits; stopped, failed and running requests say
/// so; a row opens to show its parts (answer, title, suggested questions, searches, audio). Activity chips, the period
/// in ⋯, totals for the period with what affects cost behind ⓘ, and more rows as the list scrolls. Words: AIUsage.swift.
struct AIUsageView: View {
    @Bindable var model: ReaderModel
    @State private var screen = AIUsageScreen()
    @AppStorage("gradstep.usage-period") private var days = 30
    @State private var expanded: Set<UUID> = []
    @State private var width: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Columns on a wide screen (iPad, Mac); a phone and accessibility text sizes stack each row.
    private var columns: Bool { sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize && width >= 640 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                summary
                if screen.activities.count > 1 { chips }
                // Credits by activity, in the All view only (owner, build 82).
                if screen.activity == nil, let totals = screen.totals, case let slices = AIUsageFormat.slices(screen.activities), !slices.isEmpty {
                    AIUsageRing(slices: slices, total: totals.credits) { screen.activity = $0 }
                }
                content
            }
            .frame(maxWidth: columns ? 980 : DesignMetrics.column)
            .frame(maxWidth: .infinity)
        }
        // A new period or activity starts at the top of its list.
        .id(Query(days: days, activity: screen.activity, account: model.accountID))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Your AI usage").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Screen options (DESIGN.md): the period as a submenu showing its choice, then Report this screen.
                Menu {
                    Menu {
                        ForEach(AIUsageFormat.periods, id: \.self) { choice in
                            Button { days = choice } label: {
                                if choice == days { Label(AIUsageFormat.periodLabel(choice), systemImage: "checkmark") }
                                else { Text(AIUsageFormat.periodLabel(choice)) }
                            }
                            .accessibilityIdentifier("usage.period.\(choice)")
                        }
                    } label: {
                        Label { Text("Period"); Text(AIUsageFormat.periodLabel(days)) } icon: { menuIcon("calendar") }
                    }
                    .accessibilityIdentifier("usage.period")
                    Section { MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) } }
                } label: { Image(systemName: "ellipsis").accessibilityLabel("Options") }
                .accessibilityIdentifier("usage.options")
            }
        }
        .refreshable { await screen.load(model: model, days: days, reset: true) }
        .task(id: Query(days: days, activity: screen.activity, account: model.accountID)) {
            expanded = []
            await screen.load(model: model, days: days, reset: true)
        }
        .infoBubbleDimming()
    }

    private struct Query: Hashable { let days: Int; let activity: AIUsageActivity?; let account: UUID? }

    // MARK: Totals, chips

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(AIUsageFormat.periodLabel(days) + (screen.activity.map { " · \($0.name)" } ?? "")).font(.headline)
                InfoButton(text: AIUsageFormat.info, identifier: "usage.info")
            }
            Group {
                if let totals = screen.totals { Text(AIUsageFormat.totalsText(totals)) }
                else if screen.state == .loading { Text("Loading…") }
                else { Text(" ") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("usage.totals")
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 12).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(title: "All", selected: screen.activity == nil) { screen.activity = nil }
                    .accessibilityIdentifier("usage.chip.all")
                ForEach(screen.activities, id: \.activity) { item in
                    ChipButton(title: item.activity.name, selected: screen.activity == item.activity) { screen.activity = item.activity }
                        .accessibilityIdentifier("usage.chip.\(item.activity.rawValue)")
                }
            }
            .padding(.horizontal, DesignMetrics.margin)
        }
        .padding(.bottom, 4)
    }

    // MARK: Rows

    @ViewBuilder private var content: some View {
        if screen.state == .failed && screen.rows.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t load your AI usage", systemImage: "exclamationmark.triangle")
            } description: { Text("Check your connection and try again.") } actions: {
                Button("Try again") { Task { await screen.load(model: model, days: days, reset: true) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("usage.retry")
            }
            .padding(.top, 40)
        } else if screen.state == .loading && screen.rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60).accessibilityLabel("Loading your AI usage")
        } else if screen.rows.isEmpty {
            ContentUnavailableView("No AI usage \(days == 365 ? "in the last 12 months" : "in the last \(days) days")", systemImage: "list.bullet.rectangle",
                                   description: Text("Answers, explainers, podcasts and searches you ask for appear here with what they cost."))
                .padding(.top, 40).accessibilityIdentifier("usage.empty")
        } else {
            if columns { header }
            let provenance = model.aiUsageProvenance()
            ForEach(screen.rows) { op in
                let p = provenance[op.id]
                AIUsageRow(op: op, label: AIUsageFormat.activityLabel(op.activity, provenance: p), paper: model.aiUsagePaperTitle(p),
                           columns: columns, expanded: expanded.contains(op.id)) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        if expanded.contains(op.id) { expanded.remove(op.id) } else { expanded.insert(op.id) }
                    }
                }
                .onAppear { if op.id == screen.rows.last?.id { Task { await screen.loadMore(model: model, days: days) } } }
                Divider().padding(.leading, DesignMetrics.margin)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Time").frame(width: AIUsageRow.timeWidth, alignment: .leading)
            Text("Activity").frame(maxWidth: .infinity, alignment: .leading)
            Text("Model").frame(width: AIUsageRow.modelWidth, alignment: .leading)
            Text("Tokens").frame(width: AIUsageRow.tokensWidth, alignment: .leading)
            Text("Cost").frame(width: AIUsageRow.costWidth, alignment: .trailing)
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        if screen.next != nil {
            HStack {
                Spacer()
                if screen.state == .failed {
                    Text("Couldn’t load more.").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await screen.loadMore(model: model, days: days) } }.font(.footnote)
                } else { ProgressView().accessibilityLabel("Loading more") }
                Spacer()
            }
            .padding(.vertical, 16).accessibilityIdentifier("usage.more")
        }
        Color.clear.frame(height: 24)
    }
}

/// One request: the activity and paper, when, model, tokens and cost; opened, its parts.
struct AIUsageRow: View {
    static let timeWidth: CGFloat = 100, modelWidth: CGFloat = 150, tokensWidth: CGFloat = 230, costWidth: CGFloat = 140
    let op: AIUsageOperation
    let label: String
    let paper: String?
    let columns: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { columns ? AnyView(wide) : AnyView(stacked) }
                .buttonStyle(UsageRowStyle())
                .accessibilityLabel(spoken)
                .accessibilityValue(expanded ? "Open" : "Closed")
                .accessibilityHint(expanded ? "Hides where its tokens went" : "Shows where its tokens went")
                .accessibilityIdentifier("usage.row.\(op.id.uuidString.lowercased())")
            if expanded { parts.transition(.opacity) }
        }
    }

    private var time: String { AIUsageRow.time(op.createdAt) }
    private var tokens: String { AIUsageFormat.tokensText(op, estimated: op.estimated) }
    private var spoken: String {
        [label, paper, time, AIUsageFormat.modelLabel(op.model), tokens == "—" ? nil : tokens, AIUsageFormat.creditsText(op), op.outcome.label]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private var cost: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(AIUsageFormat.creditsText(op)).font(.subheadline.weight(.semibold)).monospacedDigit()
            if let outcome = op.outcome.label {
                Text(outcome).font(.caption).foregroundStyle(op.outcome.isProblem ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.headline)
            if let paper { Text(paper).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private var stacked: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title
                Text([time, AIUsageFormat.modelLabel(op.model), tokens].filter { $0 != "—" }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            cost
        }
    }

    private var wide: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time).frame(width: Self.timeWidth, alignment: .leading).foregroundStyle(.secondary)
            title.frame(maxWidth: .infinity, alignment: .leading)
            Text(AIUsageFormat.modelLabel(op.model)).frame(width: Self.modelWidth, alignment: .leading).foregroundStyle(.secondary)
            Text(tokens).frame(width: Self.tokensWidth, alignment: .leading).foregroundStyle(.secondary).monospacedDigit()
            cost.frame(width: Self.costWidth, alignment: .trailing)
        }
        .font(.subheadline)
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(op.parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(part.part.label + (part.calls > 1 ? " ×\(part.calls)" : "")).font(.subheadline.weight(.medium))
                        Text(AIUsageFormat.modelLabel(part.model)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(AIUsageFormat.tokensText(part, estimated: part.estimated, exact: true) + (part.pending ? " · still being counted" : ""))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            if op.parts.isEmpty { Text("No model was called.").font(.footnote).foregroundStyle(.secondary) }
            Text(op.paidBy == "gradstep" ? "Paid by Gradstep, not your credits."
                 : op.parts.count > 1 ? "One charge for the whole request; the parts show where its tokens went."
                 : "Charged from the tokens the provider reported.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, columns ? DesignMetrics.margin + Self.timeWidth + 12 : DesignMetrics.margin + 12)
        .padding(.trailing, DesignMetrics.margin).padding(.bottom, 12)
        .accessibilityIdentifier("usage.parts.\(op.id.uuidString.lowercased())")
    }

    /// "9:47 PM" today, "Yesterday, 9:47 PM", "Oct 18, 9:47 PM", and the year when it isn't this one.
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(clock)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? "\(date.formatted(.dateTime.month(.abbreviated).day())), \(clock)" : date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A row's press: a quiet fill, the row's own padding (DESIGN.md "Rows": 16 pt sides, 12 pt vertical).
private struct UsageRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// The list's pages: newest first, keyset pages of 25, totals and chips from the first page; a newer request's answer
/// replaces an older one (period, activity or account changed while it was on its way).
@Observable @MainActor final class AIUsageScreen {
    enum State { case loading, ready, loadingMore, failed }
    private(set) var rows: [AIUsageOperation] = []
    private(set) var totals: AIUsageTotals?
    private(set) var activities: [AIUsageActivityCount] = []
    private(set) var next: AIUsageCursor?
    private(set) var state: State = .loading
    var activity: AIUsageActivity?
    @ObservationIgnored private var generation = 0

    func load(model: ReaderModel, days: Int, reset: Bool) async {
        guard let source = model.aiUsageSource, let account = model.accountID else { state = .failed; return }
        generation += 1
        let mine = generation, wanted = activity
        if reset { state = .loading; next = nil }
        do {
            let page = try await source.aiUsage(days: days, activity: wanted, before: nil, accountID: account)
            guard mine == generation else { return }
            rows = page.operations; totals = page.totals; next = page.next
            if wanted == nil { activities = page.activities ?? [] }
            state = .ready
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if reset { rows = []; totals = nil }
            state = .failed
        }
    }

    func loadMore(model: ReaderModel, days: Int) async {
        guard let cursor = next, state == .ready || state == .failed, let source = model.aiUsageSource, let account = model.accountID else { return }
        let mine = generation
        state = .loadingMore
        do {
            let page = try await source.aiUsage(days: days, activity: activity, before: cursor, accountID: account)
            guard mine == generation else { return }
            let seen = Set(rows.map(\.id))
            rows += page.operations.filter { !seen.contains($0.id) }
            next = page.next; state = .ready
        } catch {
            guard mine == generation else { return }
            state = .failed
        }
    }
}
