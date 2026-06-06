import WidgetKit
import SwiftUI

/// 数据 — clipboard library composition: total clips, per-type breakdown,
/// favourites and today's new clips. Counts only, never contents.
struct DataWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.dataWidgetKind, provider: SnapshotProvider()) { entry in
            DataWidgetView(snapshot: entry.snapshot)
                .containerBackground(WidgetPalette.paper, for: .widget)
        }
        .configurationDisplayName(wText("", zh: "剪贴板数据", en: "Clipboard Data"))
        .description(wText("", zh: "查看剪贴板库的总量与类型分布。", en: "Library size and type breakdown at a glance."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DataWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ClipTraceWidgetSnapshot

    private var accent: Color { WidgetPalette.accent(snapshot.accentPalette) }
    private var lang: String { snapshot.language }

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    // MARK: Small — total + today + favourites

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(wText(lang, zh: "剪贴板", en: "Library"), system: "tray.full")
            Spacer(minLength: 4)
            Text(snapshot.total.formatted())
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(wText(lang, zh: "条记录", en: "items"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            HStack(spacing: 10) {
                miniStat("star.fill", snapshot.favorites, accent)
                miniStat("plus.circle.fill", snapshot.todayNew,
                         .secondary, prefix: "+")
            }
        }
    }

    // MARK: Medium — total + per-type breakdown bars

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                header(wText(lang, zh: "剪贴板数据", en: "Clipboard Data"), system: "tray.full")
                Spacer()
                HStack(spacing: 3) {
                    Text(wText(lang, zh: "共", en: "Total"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(snapshot.total.formatted())
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(topTypes, id: \.type) { row in
                    breakdownRow(row)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 0) {
                miniStat("star.fill", snapshot.favorites, accent,
                         label: wText(lang, zh: "收藏", en: "Saved"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                miniStat("plus.circle.fill", snapshot.todayNew, .secondary,
                         label: wText(lang, zh: "今日新增", en: "Today"), prefix: "+")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func header(_ title: String, system: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    /// Top clip types by count (drops zero buckets), capped so the medium
    /// layout stays readable.
    private var topTypes: [(type: ClipboardWidgetType, count: Int)] {
        ClipboardWidgetType.allCases
            .map { ($0, snapshot.byType[$0.rawValue] ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { (type: $0.0, count: $0.1) }
    }

    private func breakdownRow(_ row: (type: ClipboardWidgetType, count: Int)) -> some View {
        let maxCount = max(topTypes.first?.count ?? 1, 1)
        let fraction = max(0.06, Double(row.count) / Double(maxCount))
        return HStack(spacing: 7) {
            Image(systemName: row.type.icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 14)
            Text(row.type.label(lang))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(accent.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(accent)
                            .frame(width: geo.size.width * fraction)
                    }
            }
            .frame(height: 6)
            Text(row.count.formatted())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func miniStat(_ icon: String, _ value: Int, _ tint: Color,
                          label: String? = nil, prefix: String = "") -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(prefix)\(value.formatted())")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let label {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
