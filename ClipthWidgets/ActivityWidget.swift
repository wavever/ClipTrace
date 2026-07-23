import WidgetKit
import SwiftUI

/// 活跃统计 — copy activity over time: today / 7d / 30d totals plus a mini
/// contribution heatmap (medium), mirroring the in-app Stats wall.
struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.activityWidgetKind, provider: SnapshotProvider()) { entry in
            ActivityWidgetView(snapshot: entry.snapshot)
                .containerBackground(WidgetPalette.paper, for: .widget)
        }
        .configurationDisplayName(wText("", zh: "活跃统计", en: "Activity"))
        .description(wText("", zh: "查看每日复制活跃度与近期热力图。", en: "Daily copy activity and a recent heatmap."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ActivityWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ClipthWidgetSnapshot

    private var accent: Color {
        WidgetPalette.accent(snapshot.accentPalette, customHex: snapshot.customAccentHex)
    }
    private var lang: String { snapshot.language }

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    // MARK: Small — today big + 7d/30d

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(wText(lang, zh: "活跃统计", en: "Activity"))
            Spacer(minLength: 4)
            Text(wText(lang, zh: "今日复制", en: "Today"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(snapshot.statsEnabled ? snapshot.today.formatted() : "—")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(snapshot.statsEnabled ? accent : .secondary)
            Spacer(minLength: 6)
            HStack(spacing: 12) {
                totalPair(wText(lang, zh: "近7天", en: "7d"), snapshot.last7)
                totalPair(wText(lang, zh: "近30天", en: "30d"), snapshot.last30)
            }
        }
        .opacity(snapshot.statsEnabled ? 1 : 0.7)
    }

    // MARK: Medium — heatmap + totals

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                header(wText(lang, zh: "活跃统计", en: "Activity"))
                Spacer()
                HStack(spacing: 3) {
                    Text(wText(lang, zh: "今日", en: "Today"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(snapshot.statsEnabled ? snapshot.today.formatted() : "—")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(snapshot.statsEnabled ? accent : .secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if snapshot.statsEnabled {
                // Fills the space between header and footer; cells size to fit.
                MiniHeatmap(dailyCounts: snapshot.dailyCounts, accent: accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(wText(lang, zh: "复制统计已关闭", en: "Copy stats are off"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            HStack(spacing: 0) {
                totalPair(wText(lang, zh: "近7天", en: "Last 7d"), snapshot.last7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                totalPair(wText(lang, zh: "近30天", en: "Last 30d"), snapshot.last30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                totalPair(wText(lang, zh: "总计", en: "Total"), snapshot.totalCopies)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(snapshot.statsEnabled ? 1 : 0.85)
    }

    // MARK: Pieces

    private func header(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func totalPair(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value.formatted())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Mini contribution heatmap

/// Compact GitHub-style contribution wall ending today. A trimmed port of
/// `ContributionWall` in StatsPanelView.swift — same colour ramp, sized to fill
/// the medium widget. Columns are weeks (oldest left), rows are weekdays.
private struct MiniHeatmap: View {
    let dailyCounts: [String: Int]
    let accent: Color

    private let gap: CGFloat = 2.5
    private let maxCell: CGFloat = 13
    private let minCell: CGFloat = 3

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        GeometryReader { geo in
            // Size square cells to fill the available HEIGHT (7 rows), then draw
            // as many week-columns as fit the WIDTH — so the wall spans edge to
            // edge regardless of how short the middle slot is. Capped at the
            // exported window so we never request more history than we have.
            let maxWeeks = max(1, Int((Double(WidgetShared.heatmapDays) / 7.0).rounded(.up)))
            let cell = max(minCell, min(maxCell, (geo.size.height - gap * 6) / 7))
            let weeks = max(1, min(maxWeeks, Int((geo.size.width + gap) / (cell + gap))))
            let grid = buildGrid(weeks: weeks)
            let maxCount = max(grid.flatMap { $0 }.map(\.count).max() ?? 0, 1)
            HStack(spacing: gap) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: week[row], max: maxCount))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }

    private struct DayCell { let isValid: Bool; let count: Int }

    /// Build `weeks` columns of 7 days ending in the week that contains today.
    /// Future days in the current week render as empty (clear) cells.
    private func buildGrid(weeks: Int) -> [[DayCell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let firstWeekday = cal.firstWeekday
        let todayWeekday = cal.component(.weekday, from: today)
        let offsetIntoWeek = (todayWeekday - firstWeekday + 7) % 7
        let startOfThisWeek = cal.date(byAdding: .day, value: -offsetIntoWeek, to: today) ?? today
        let gridStart = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: startOfThisWeek) ?? startOfThisWeek

        var grid: [[DayCell]] = []
        for w in 0..<weeks {
            var column: [DayCell] = []
            for r in 0..<7 {
                let day = cal.date(byAdding: .day, value: w * 7 + r, to: gridStart) ?? gridStart
                if day > today {
                    column.append(DayCell(isValid: false, count: 0))
                } else {
                    let count = dailyCounts[Self.dayFormatter.string(from: day)] ?? 0
                    column.append(DayCell(isValid: true, count: count))
                }
            }
            grid.append(column)
        }
        return grid
    }

    private func color(for cell: DayCell, max: Int) -> Color {
        guard cell.isValid else { return .clear }
        if cell.count == 0 { return Color.secondary.opacity(0.12) }
        let ratio = Double(cell.count) / Double(max)
        switch ratio {
        case ..<0.25: return accent.opacity(0.30)
        case ..<0.5:  return accent.opacity(0.55)
        case ..<0.75: return accent.opacity(0.80)
        default:      return accent
        }
    }
}
