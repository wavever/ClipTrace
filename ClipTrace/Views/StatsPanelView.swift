import SwiftUI
import AppKit

struct StatsPanelView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var store = CopyStatsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.appAccent.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
            // Extend through the title-bar safe area so the gradient blends
            // seamlessly with the traffic-light strip instead of cutting off
            // along the safe-area edge.
            .ignoresSafeArea(edges: .top)
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: { nav.showList() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("common.back"))
            .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 2) {
                Text(L("stats.title"))
                    .font(.system(size: 28, weight: .bold))
                Text(L("stats.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            SettingCard(title: L("stats.summary.title"), subtitle: L("stats.summary.subtitle")) {
                HStack(spacing: 14) {
                    summaryTile(label: L("stats.today"), value: store.todayCount(), tint: .appAccent)
                    summaryTile(label: L("stats.last7days"), value: store.countLast(days: 7), tint: .purple)
                    summaryTile(label: L("stats.last30days"), value: store.countLast(days: 30), tint: .blue)
                    summaryTile(label: L("stats.total"), value: store.totalAllTime, tint: .secondary)
                }
            }

            SettingCard(title: L("stats.heatmap.title"), subtitle: L("stats.heatmap.subtitle")) {
                ContributionWall(store: store)
            }
        }
    }

    private func summaryTile(label: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            Text("\(value)")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

}

// MARK: - Contribution wall (GitHub-style heatmap)

private struct ContributionWall: View {
    @ObservedObject var store: CopyStatsStore

    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 3

    private static var monthFormatter: DateFormatter {
        let f = DateFormatter()
        if L10n.shared.effectiveLanguage == .zh {
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月"
        } else {
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMM"
        }
        return f
    }

    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        if L10n.shared.effectiveLanguage == .zh {
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy-MM-dd EEEE"
        } else {
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "yyyy-MM-dd EEEE"
        }
        return f
    }

    private static var shortWeekdaySymbols: [String] {
        let f = DateFormatter()
        if L10n.shared.effectiveLanguage == .zh {
            f.locale = Locale(identifier: "zh_CN")
        } else {
            f.locale = Locale(identifier: "en_US")
        }
        return f.shortWeekdaySymbols ?? []
    }

    private struct DayCell {
        let date: Date?
        let count: Int
    }

    var body: some View {
        let grid = buildGrid()
        let maxCount = max(grid.flatMap { $0 }.map(\.count).max() ?? 0, 1)
        let totalCount = grid.flatMap { $0 }.map(\.count).reduce(0, +)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("stats.totalCountFormat", totalCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                legend
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    weekdayLabels
                    VStack(alignment: .leading, spacing: 2) {
                        monthLabels(for: grid)
                        weekColumns(grid: grid, maxCount: maxCount)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var weekdayLabels: some View {
        let firstWeekday = Calendar.current.firstWeekday
        let symbols = Self.shortWeekdaySymbols
        let labelWidth: CGFloat = 28
        return VStack(alignment: .trailing, spacing: gap) {
            Color.clear.frame(width: labelWidth, height: 12)
            ForEach(0..<7, id: \.self) { row in
                let weekdayIndex = (firstWeekday - 1 + row) % 7
                let label: String = {
                    switch weekdayIndex {
                    case 1, 3, 5: return symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""
                    default: return ""
                    }
                }()
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, height: cellSize, alignment: .trailing)
            }
        }
    }

    private func monthLabels(for grid: [[DayCell]]) -> some View {
        let calendar = Calendar.current
        var labels: [(col: Int, text: String)] = []
        var lastMonth: Int = -1
        for (i, week) in grid.enumerated() {
            guard let firstDate = week.compactMap(\.date).first else { continue }
            let month = calendar.component(.month, from: firstDate)
            if month != lastMonth {
                labels.append((col: i, text: Self.monthFormatter.string(from: firstDate)))
                lastMonth = month
            }
        }

        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: CGFloat(grid.count) * (cellSize + gap), height: 12)
            ForEach(Array(labels.enumerated()), id: \.offset) { _, item in
                Text(item.text)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(item.col) * (cellSize + gap))
            }
        }
    }

    private func weekColumns(grid: [[DayCell]], maxCount: Int) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        let cell = week[row]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: cell, max: maxCount))
                            .frame(width: cellSize, height: cellSize)
                            .help(tooltip(for: cell))
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text(L("stats.legend.less")).font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForLevel(level))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(L("stats.legend.more")).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func buildGrid() -> [[DayCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let year = calendar.component(.year, from: today)

        let firstWeekday = calendar.firstWeekday
        let jan1 = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
        let dec31 = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? today

        let jan1Weekday = calendar.component(.weekday, from: jan1)
        let daysBeforeJan1 = (jan1Weekday - firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -daysBeforeJan1, to: jan1) ?? jan1

        let dec31Weekday = calendar.component(.weekday, from: dec31)
        let daysAfterDec31 = (firstWeekday + 6 - dec31Weekday + 7) % 7
        let gridEnd = calendar.date(byAdding: .day, value: daysAfterDec31, to: dec31) ?? dec31

        let totalDays = (calendar.dateComponents([.day], from: gridStart, to: gridEnd).day ?? 0) + 1
        let weekCount = totalDays / 7

        var grid: [[DayCell]] = []
        var cursor = gridStart
        for _ in 0..<weekCount {
            var column: [DayCell] = []
            for _ in 0..<7 {
                let inYear = calendar.component(.year, from: cursor) == year
                let isFuture = cursor > today
                let date: Date? = inYear ? cursor : nil
                let count = (inYear && !isFuture) ? store.count(on: cursor) : 0
                column.append(DayCell(date: date, count: count))
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            grid.append(column)
        }
        return grid
    }

    private func color(for cell: DayCell, max: Int) -> Color {
        guard let _ = cell.date else { return Color.clear }
        if cell.count == 0 { return Color.secondary.opacity(0.12) }
        let ratio = Double(cell.count) / Double(max)
        let level: Int
        if ratio < 0.25      { level = 1 }
        else if ratio < 0.5  { level = 2 }
        else if ratio < 0.75 { level = 3 }
        else                 { level = 4 }
        return colorForLevel(level)
    }

    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 0: return Color.secondary.opacity(0.12)
        case 1: return Color.appAccent.opacity(0.30)
        case 2: return Color.appAccent.opacity(0.55)
        case 3: return Color.appAccent.opacity(0.80)
        default: return Color.appAccent
        }
    }

    private func tooltip(for cell: DayCell) -> String {
        guard let date = cell.date else { return "" }
        return L("stats.tooltipFormat", Self.dayFormatter.string(from: date), cell.count)
    }
}
