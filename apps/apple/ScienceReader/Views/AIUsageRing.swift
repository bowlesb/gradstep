import Charts
import ScienceReaderCore
import SwiftUI

/// Your AI usage › All: credits by activity (owner, build 82: "The very top before the list when on All a pie chart
/// summarizing the cost types and their cost"), as the browser's UsageRing. A thin ring, largest first clockwise from the
/// top with a surface gap between segments, and a legend with each name, its credits and share; a named segment or row
/// chooses that activity's chip, Other lists what it holds. The legend carries every value, so colour never stands alone.
/// Slices and words: AIUsageFormat.slices (tests/fixtures/ai-usage.json).
struct AIUsageRing: View {
    let slices: [AIUsageSlice]
    let total: Int64
    let choose: (AIUsageActivity) -> Void
    @State private var selectedAngle: Int64?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
        layout {
            ring
            legend
        }
        .padding(.horizontal, DesignMetrics.margin).padding(.top, 4).padding(.bottom, 10)
    }

    private var ring: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Credits", slice.credits), innerRadius: .ratio(0.74), angularInset: 1)
                .foregroundStyle(Self.color(slice))
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, angle in
            guard let angle, let activity = slice(at: angle)?.activity else { return }
            selectedAngle = nil
            choose(activity)
        }
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(AIUsageFormat.grouped(total)).font(.headline).monospacedDigit()
                Text(total == 1 ? "credit" : "credits").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AIUsageFormat.slicesSummary(slices))
        .accessibilityIdentifier("usage.ring")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(slices) { slice in
                if let activity = slice.activity {
                    Button { choose(activity) } label: { row(slice) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(slice.label), \(credits(slice)), \(slice.percent)")
                        .accessibilityHint("Shows only \(slice.label)")
                        .accessibilityIdentifier("usage.legend.\(activity.rawValue)")
                } else {
                    row(slice)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(slice.label), \(credits(slice)), \(slice.percent)"
                            + (slice.members.isEmpty ? "" : ": \(slice.members.joined(separator: ", "))"))
                        .accessibilityIdentifier("usage.legend.other")
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func row(_ slice: AIUsageSlice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(Self.color(slice)).frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 0) {
                Text(slice.label).font(.subheadline)
                if !slice.members.isEmpty {
                    Text(slice.members.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            (Text(AIUsageFormat.grouped(slice.credits)) + Text(" · \(slice.percent)").foregroundStyle(.secondary))
                .font(.subheadline).monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func credits(_ slice: AIUsageSlice) -> String { "\(AIUsageFormat.grouped(slice.credits)) \(slice.credits == 1 ? "credit" : "credits")" }

    /// The segment under a tapped angle (the chart's cumulative credits, clockwise from the top).
    private func slice(at angle: Int64) -> AIUsageSlice? {
        var end: Int64 = 0
        for slice in slices {
            end += slice.credits
            if angle <= end { return slice }
        }
        return nil
    }

    /// The chart palette by size (slots 1–4, then Other's neutral), each with its own dark step; validated with the
    /// dataviz palette checker for adjacent segments on the app's light and dark surfaces (docs/DESIGN.md).
    static func color(_ slice: AIUsageSlice) -> Color {
        let pairs: [(light: UInt32, dark: UInt32)] = [(0x2A78D6, 0x3987E5), (0xEB6834, 0xD95926), (0x1BAF7A, 0x199E70), (0xEDA100, 0xC98500)]
        let pair = slice.slot.map { pairs[min($0, pairs.count - 1)] } ?? (0x8C8A85, 0x6B6A66)
        return Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
