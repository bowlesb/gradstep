import ScienceReaderCore
import SwiftUI

/// Settings › AI credits › Your AI usage, also from Get credits (owner, 2026-10-22: "a table of my recent AI token spend
/// for all the different activities … rows ordered by time, each row being an activity, and the exact cost, so that a
/// user can figure out where their credits are going"). One row per request, newest first in days: when, the activity (and
/// the paper, from this device's library), the model, the tokens and the credits; stopped, failed and running requests say
/// so; a row opens to show its parts (answer, title, suggested questions, searches, audio), and "Open chat", "Open figure"…
/// under it goes back to what it was for (owner, TestFlight 92). Day · Week · Month · Year at the top drives the totals, the
/// ring and the list (TestFlight 92: "a view last day, last week, last month"); activity chips, what affects cost behind ⓘ,
/// and more rows as the list scrolls. Words: AIUsage.swift, AIUsageRange.swift.
struct AIUsageView: View {
    @Bindable var model: ReaderModel
    @State private var screen = AIUsageScreen()
    @AppStorage("gradstep.usage-range") private var range: AIUsageRange = .month
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
                if screen.activities.count > 1 || screen.activity != nil { chips }
                // Credits by activity, in the All view only (owner, build 82).
                if screen.activity == nil, let totals = screen.totals, case let slices = AIUsageFormat.slices(screen.activities), !slices.isEmpty {
                    AIUsageRing(slices: slices, total: totals.credits) { screen.activity = $0 }
                }
                content
            }
            .frame(maxWidth: columns ? 980 : DesignMetrics.column)
            .frame(maxWidth: .infinity)
        }
        // A new range or activity starts at the top of its list.
        .id(Query(range: range, activity: screen.activity, account: model.accountID))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Your AI usage").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Screen options (DESIGN.md): Report this screen (the range is the control at the top).
                Menu {
                    Section { MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) } }
                } label: { Image(systemName: "ellipsis").accessibilityLabel("Options") }
                .accessibilityIdentifier("usage.options")
            }
        }
        .refreshable { await screen.load(model: model, range: range, reset: true, lookup: true) }
        .task(id: Query(range: range, activity: screen.activity, account: model.accountID)) {
            expanded = []
            await screen.load(model: model, range: range, reset: true)
        }
        .infoBubbleDimming()
    }

    private struct Query: Hashable { let range: AIUsageRange; let activity: AIUsageActivity?; let account: UUID? }

    // MARK: Range, totals, chips

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(AIUsageRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("usage.range")
            HStack(spacing: 2) {
                Group {
                    if let totals = screen.totals { Text(AIUsageFormat.totalsText(totals)) }
                    else if screen.state == .loading { Text("Loading…") }
                    else { Text(" ") }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("usage.totals")
                InfoButton(text: range.label + (screen.activity.map { ", \($0.name)" } ?? "") + ". " + AIUsageFormat.info, identifier: "usage.info")
            }
            .padding(.top, -4).padding(.bottom, -4)
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 12).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(title: "All", selected: screen.activity == nil) { screen.activity = nil }
                    .accessibilityIdentifier("usage.chip.all")
                // The chosen activity stays offered when another range has none of it.
                let shown = screen.activities.map(\.activity) + (screen.activity.map { chosen in screen.activities.contains { $0.activity == chosen } ? [] : [chosen] } ?? [])
                ForEach(shown, id: \.self) { activity in
                    ChipButton(title: activity.name, selected: screen.activity == activity) { screen.activity = activity }
                        .accessibilityIdentifier("usage.chip.\(activity.rawValue)")
                }
            }
            .padding(.horizontal, DesignMetrics.margin)
        }
        .padding(.bottom, 4)
    }

    // MARK: Rows, by day

    @ViewBuilder private var content: some View {
        if screen.state == .failed && screen.rows.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t load your AI usage", systemImage: "exclamationmark.triangle")
            } description: { Text("Check your connection and try again.") } actions: {
                Button("Try again") { Task { await screen.load(model: model, range: range, reset: true) } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("usage.retry")
            }
            .padding(.top, 40)
        } else if screen.state == .loading && screen.rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60).accessibilityLabel("Loading your AI usage")
        } else if screen.rows.isEmpty {
            ContentUnavailableView("No AI usage in the \(range.label.lowercased())", systemImage: "list.bullet.rectangle",
                                   description: Text("Answers, explainers, podcasts and searches you ask for appear here with what they cost."))
                .padding(.top, 40).accessibilityIdentifier("usage.empty")
        } else {
            if columns { header }
            ForEach(AIUsageFormat.sections(screen.rows)) { section in
                Section {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, op in
                        AIUsageRow(op: op, context: screen.contexts[op.id] ?? AIUsageRowContext(label: op.activity.name, subtitle: nil, link: nil),
                                   columns: columns, expanded: expanded.contains(op.id), toggle: {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                if expanded.contains(op.id) { expanded.remove(op.id) } else { expanded.insert(op.id) }
                            }
                        }, open: { model.openAIUsageTarget($0, operation: op) })
                        .onAppear { if op.id == screen.rows.last?.id { Task { await screen.loadMore(model: model, range: range) } } }
                        if index < section.rows.count - 1 { Divider().padding(.leading, DesignMetrics.margin) }
                    }
                } header: { sectionHeader(section) }
            }
            footer
        }
    }

    /// A day's heading (not held at the top: under the bar's glass the rows would show above it).
    private func sectionHeader(_ section: AIUsageSection) -> some View {
        Text(section.title)
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignMetrics.margin).padding(.top, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("usage.section.\(section.id)")
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
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var footer: some View {
        if screen.next != nil {
            HStack {
                Spacer()
                if screen.state == .failed {
                    Text("Couldn’t load more.").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await screen.loadMore(model: model, range: range) } }.font(.footnote)
                } else { ProgressView().accessibilityLabel("Loading more") }
                Spacer()
            }
            .padding(.vertical, 16).accessibilityIdentifier("usage.more")
        }
        Color.clear.frame(height: 24)
    }
}

/// One request: the activity and paper, when, model, tokens and cost; opened, its parts; under it, the way back to what it
/// was for ("Open chat", "Open figure", …), when that is still here.
struct AIUsageRow: View {
    static let timeWidth: CGFloat = 100, modelWidth: CGFloat = 150, tokensWidth: CGFloat = 230, costWidth: CGFloat = 140
    let op: AIUsageOperation
    let context: AIUsageRowContext
    let columns: Bool
    let expanded: Bool
    let toggle: () -> Void
    let open: (AIUsageTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { columns ? AnyView(wide) : AnyView(stacked) }
                .buttonStyle(UsageRowStyle(bottom: context.link == nil ? 12 : 4))
                .accessibilityLabel(spoken)
                .accessibilityValue(expanded ? "Open" : "Closed")
                .accessibilityHint(expanded ? "Hides where its tokens went" : "Shows where its tokens went")
                .accessibilityIdentifier("usage.row.\(op.id.uuidString.lowercased())")
            if let link = context.link { linkButton(link) }
            if expanded { parts.transition(.opacity) }
        }
    }

    /// The clock time: the day is the section's.
    private var time: String { op.createdAt.formatted(date: .omitted, time: .shortened) }
    /// What the provider reported; nothing for a request without a final count (`AIUsageOutcome.reportsTokens`).
    private var tokens: String { op.outcome.reportsTokens ? AIUsageFormat.tokensText(op, estimated: op.estimated) : "—" }
    private var spoken: String {
        [context.label, context.subtitle, time, AIUsageFormat.modelLabel(op.model), tokens == "—" ? nil : tokens, AIUsageFormat.creditsText(op), op.outcome.label]
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
            Text(context.label).font(.headline)
            if let subtitle = context.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
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

    /// "Open chat ›" under the row, where its title is (a wide row: under the activity column).
    private func linkButton(_ link: AIUsageLink) -> some View {
        Button { open(link.target) } label: {
            HStack(spacing: 3) {
                Text(link.title)
                Image(systemName: "chevron.forward").font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.leading, columns ? DesignMetrics.margin + Self.timeWidth + 12 : DesignMetrics.margin)
        .padding(.bottom, 6)
        .accessibilityLabel(link.title + (context.subtitle.map { ": " + $0 } ?? ""))
        .accessibilityIdentifier("usage.link.\(op.id.uuidString.lowercased())")
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(op.parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(part.part.label + (part.calls > 1 ? " ×\(part.calls)" : "")).font(.subheadline.weight(.medium))
                        Text(AIUsageFormat.modelLabel(part.model)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if op.outcome.reportsTokens {
                        Text(AIUsageFormat.tokensText(part, estimated: part.estimated, exact: true) + (part.pending ? " · still being counted" : ""))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if op.parts.isEmpty { Text("No model was called.").font(.footnote).foregroundStyle(.secondary) }
            Text(op.outcome.unreportedTokens ?? (op.paidBy == "gradstep" ? "Paid by Gradstep, not your credits."
                 : op.parts.count > 1 ? "One charge for the whole request; the parts show where its tokens went."
                 : "Charged from the tokens the provider reported."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, columns ? DesignMetrics.margin + Self.timeWidth + 12 : DesignMetrics.margin + 12)
        .padding(.trailing, DesignMetrics.margin).padding(.bottom, 12)
        .accessibilityIdentifier("usage.parts.\(op.id.uuidString.lowercased())")
    }
}

/// A row's press: a quiet fill, the row's own padding (DESIGN.md "Rows": 16 pt sides, 12 pt vertical; less below when its
/// link follows).
private struct UsageRowStyle: ButtonStyle {
    var bottom: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .padding(.horizontal, DesignMetrics.margin).padding(.top, 12).padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// The list's pages: newest first, keyset pages of 25, totals and chips from the first page (the last 24 hours: every row of
/// the server's two-day window, kept to the last 24 hours here); a newer request's answer replaces an older one (range,
/// activity or account changed while it was on its way). Each row's words and link are worked out with its page, so nothing
/// changes under the reader once shown.
@Observable @MainActor final class AIUsageScreen {
    enum State { case loading, ready, loadingMore, failed }
    private(set) var rows: [AIUsageOperation] = []
    private(set) var totals: AIUsageTotals?
    private(set) var activities: [AIUsageActivityCount] = []
    private(set) var next: AIUsageCursor?
    private(set) var state: State = .loading
    private(set) var contexts: [UUID: AIUsageRowContext] = [:]
    var activity: AIUsageActivity?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lookup: AIUsageLookup?
    /// The day's window reads the server's pages until they pass 24 hours (at most this many).
    static let dayPages = 20

    func load(model: ReaderModel, range: AIUsageRange, reset: Bool, lookup refresh: Bool = false) async {
        guard let source = model.aiUsageSource, let account = model.accountID else { state = .failed; return }
        generation += 1
        let mine = generation, wanted = activity
        if reset { state = .loading; next = nil }
        do {
            let found: (rows: [AIUsageOperation], totals: AIUsageTotals?, activities: [AIUsageActivityCount]?, next: AIUsageCursor?)
            if let since = range.since(now: Date()) {
                var all: [AIUsageOperation] = [], cursor: AIUsageCursor?
                for _ in 0..<Self.dayPages {
                    let page = try await source.aiUsage(days: range.serverDays, activity: nil, before: cursor, accountID: account)
                    guard mine == generation else { return }
                    all += page.operations; cursor = page.next
                    if cursor == nil || (page.operations.last.map { $0.createdAt < since } ?? true) { break }
                }
                let window = AIUsageWindow.make(all, since: since, activity: wanted)
                found = (window.rows, window.totals, window.activities, nil)
            } else {
                let page = try await source.aiUsage(days: range.serverDays, activity: wanted, before: nil, accountID: account)
                found = (page.operations, page.totals, page.activities, page.next)
            }
            guard mine == generation else { return }
            if lookup == nil || refresh {
                let read = await model.aiUsageLookup()
                guard mine == generation else { return }
                lookup = read
            }
            contexts = Dictionary(found.rows.map { ($0.id, model.aiUsageRow($0, lookup: lookup ?? AIUsageLookup())) }, uniquingKeysWith: { first, _ in first })
            rows = found.rows; totals = found.totals; next = found.next
            if let counts = found.activities { activities = counts }
            state = .ready
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if reset { rows = []; totals = nil }
            state = .failed
        }
    }

    func loadMore(model: ReaderModel, range: AIUsageRange) async {
        guard let cursor = next, state == .ready || state == .failed, let source = model.aiUsageSource, let account = model.accountID else { return }
        let mine = generation
        state = .loadingMore
        do {
            let page = try await source.aiUsage(days: range.serverDays, activity: activity, before: cursor, accountID: account)
            guard mine == generation else { return }
            let seen = Set(rows.map(\.id))
            let more = page.operations.filter { !seen.contains($0.id) }
            for op in more { contexts[op.id] = model.aiUsageRow(op, lookup: lookup ?? AIUsageLookup()) }
            rows += more
            next = page.next; state = .ready
        } catch {
            guard mine == generation else { return }
            state = .failed
        }
    }
}
