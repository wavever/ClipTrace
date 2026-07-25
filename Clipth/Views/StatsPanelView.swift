import SwiftUI
import AppKit
import Charts
import ImageIO

struct StatsPanelView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var store = CopyStatsStore.shared
    @State private var localization = L10n.shared
    @StateObject private var dashboard = StatsDashboardModel()
    @State private var appChartRange = AppChartRange.thirtyDays

    private var loadID: DashboardLoadID {
        DashboardLoadID(
            revision: store.revision,
            isChinese: localization.effectiveLanguage == .zh
        )
    }

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
        .task(id: loadID) {
            await dashboard.load(
                snapshot: store.snapshot(),
                isChinese: loadID.isChinese
            )
        }
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
        LazyVStack(spacing: 14) {
            SettingCard(title: L("stats.summary.title"), subtitle: L("stats.summary.subtitle")) {
                HStack(spacing: 14) {
                    summaryTile(
                        label: L("stats.today"),
                        value: dashboard.summary?.today,
                        tint: .appAccent
                    )
                    summaryTile(
                        label: L("stats.last7days"),
                        value: dashboard.summary?.lastSevenDays,
                        tint: .appWarning
                    )
                    summaryTile(
                        label: L("stats.last30days"),
                        value: dashboard.summary?.lastThirtyDays,
                        tint: .appMetal
                    )
                    summaryTile(
                        label: L("stats.total"),
                        value: dashboard.summary?.total,
                        tint: .secondary
                    )
                }
            }

            SettingCard(title: L("stats.heatmap.title"), subtitle: L("stats.heatmap.subtitle")) {
                if let heatmap = dashboard.heatmap {
                    ContributionWall(data: heatmap)
                        .transition(.opacity)
                } else {
                    DashboardLoadingPlaceholder(height: 126)
                }
            }

            SettingCard(title: L("stats.apps.title"), subtitle: L("stats.apps.subtitle")) {
                AppCopyBarChart(
                    data: dashboard.appCharts[appChartRange],
                    isLoading: dashboard.isLoadingAppIcons,
                    range: $appChartRange
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: dashboard.heatmap != nil)
    }

    private func summaryTile(label: String, value: Int?, tint: Color) -> some View {
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
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appPaper.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appPaperDivider.opacity(0.7), lineWidth: 0.5)
        )
    }
}

// MARK: - Background dashboard processing

private struct DashboardLoadID: Hashable {
    let revision: Int
    let isChinese: Bool
}

private struct StatsSummary: Sendable {
    let today: Int
    let lastSevenDays: Int
    let lastThirtyDays: Int
    let total: Int
}

private struct HeatmapCellData: Sendable {
    let dateLabel: String?
    let count: Int
    let level: Int
}

private struct HeatmapMonthLabel: Identifiable, Sendable {
    let column: Int
    let text: String

    var id: Int { column }
}

private struct HeatmapData: Sendable {
    let weeks: [[HeatmapCellData]]
    let monthLabels: [HeatmapMonthLabel]
    let weekdayLabels: [String]
    let totalCount: Int
}

private struct ComputedDashboard: Sendable {
    let summary: StatsSummary
    let heatmap: HeatmapData
    let appEntries: [AppChartRange: [AppCopyCount]]
}

private struct PreparedAppIcon: @unchecked Sendable {
    let image: CGImage
}

private struct PreparedAppChartEntry: Sendable {
    let count: AppCopyCount
    let icon: PreparedAppIcon
}

private struct PreparedAppChart: Sendable {
    let entries: [PreparedAppChartEntry]
    let domainMaximum: Double
}

@MainActor
private final class StatsDashboardModel: ObservableObject {
    @Published private(set) var summary: StatsSummary?
    @Published private(set) var heatmap: HeatmapData?
    @Published private(set) var appCharts: [AppChartRange: AppChartData] = [:]
    @Published private(set) var isLoadingAppIcons = true

    func load(snapshot: CopyStatsSnapshot, isChinese: Bool) async {
        if appCharts.isEmpty {
            isLoadingAppIcons = true
        }

        // Only the copy-on-write snapshot crosses the actor boundary. Date
        // bucketing, aggregation and the full heatmap grid never block SwiftUI.
        let computed = await Task.detached(priority: .userInitiated) {
            StatsDashboardProcessor.compute(
                snapshot: snapshot,
                isChinese: isChinese
            )
        }.value

        guard !Task.isCancelled else { return }
        summary = computed.summary
        heatmap = computed.heatmap

        // Icon discovery is intentionally a second phase so the useful parts
        // of the dashboard appear without waiting for filesystem enumeration.
        let preparedCharts = await AppIconCatalog.shared.prepare(
            entriesByRange: computed.appEntries
        )
        guard !Task.isCancelled else { return }

        var renderedCharts: [AppChartRange: AppChartData] = [:]
        for (range, prepared) in preparedCharts {
            let entries = prepared.entries.map { entry in
                let image = NSImage(
                    cgImage: entry.icon.image,
                    size: NSSize(width: 32, height: 32)
                )
                return AppChartDisplayEntry(
                    id: entry.count.id,
                    name: entry.count.name,
                    count: entry.count.count,
                    icon: image
                )
            }
            renderedCharts[range] = AppChartData(
                entries: entries,
                domainMaximum: prepared.domainMaximum
            )
        }
        appCharts = renderedCharts
        isLoadingAppIcons = false
    }
}

private enum StatsDashboardProcessor {
    static func compute(
        snapshot: CopyStatsSnapshot,
        isChinese: Bool,
        now: Date = Date()
    ) -> ComputedDashboard {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        let today = calendar.startOfDay(for: now)
        let keyFormatter = dayKeyFormatter(calendar: calendar)

        let summary = StatsSummary(
            today: snapshot.dailyCounts[keyFormatter.string(from: today)] ?? 0,
            lastSevenDays: count(
                inLast: 7,
                through: today,
                calendar: calendar,
                formatter: keyFormatter,
                counts: snapshot.dailyCounts
            ),
            lastThirtyDays: count(
                inLast: 30,
                through: today,
                calendar: calendar,
                formatter: keyFormatter,
                counts: snapshot.dailyCounts
            ),
            total: snapshot.dailyCounts.values.reduce(0, +)
        )

        let heatmap = makeHeatmap(
            dailyCounts: snapshot.dailyCounts,
            today: today,
            calendar: calendar,
            keyFormatter: keyFormatter,
            isChinese: isChinese
        )

        var appEntries: [AppChartRange: [AppCopyCount]] = [:]
        for range in AppChartRange.allCases {
            appEntries[range] = aggregateApps(
                dailyAppCounts: snapshot.dailyAppCounts,
                days: range.days,
                today: today,
                calendar: calendar,
                formatter: keyFormatter
            )
        }

        return ComputedDashboard(
            summary: summary,
            heatmap: heatmap,
            appEntries: appEntries
        )
    }

    private static func count(
        inLast days: Int,
        through today: Date,
        calendar: Calendar,
        formatter: DateFormatter,
        counts: [String: Int]
    ) -> Int {
        (0..<days).reduce(into: 0) { result, offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return
            }
            result += counts[formatter.string(from: date)] ?? 0
        }
    }

    private static func aggregateApps(
        dailyAppCounts: [String: [String: StoredAppCopyCount]],
        days: Int,
        today: Date,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> [AppCopyCount] {
        let includedKeys = Set((0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { formatter.string(from: $0) }
        })
        var aggregated: [String: StoredAppCopyCount] = [:]

        for (day, appCounts) in dailyAppCounts where includedKeys.contains(day) {
            for appCount in appCounts.values {
                let normalizedName = normalized(appCount.name)
                var total = aggregated[normalizedName] ?? StoredAppCopyCount(
                    name: appCount.name,
                    count: 0
                )
                if !appCount.name.isEmpty {
                    total.name = appCount.name
                }
                if total.bundleIdentifier == nil {
                    total.bundleIdentifier = appCount.bundleIdentifier
                }
                total.count += appCount.count
                aggregated[normalizedName] = total
            }
        }

        return aggregated.map { normalizedName, appCount in
            AppCopyCount(
                id: normalizedName,
                name: appCount.name,
                bundleIdentifier: appCount.bundleIdentifier,
                count: appCount.count
            )
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func makeHeatmap(
        dailyCounts: [String: Int],
        today: Date,
        calendar: Calendar,
        keyFormatter: DateFormatter,
        isChinese: Bool
    ) -> HeatmapData {
        let periodStart = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        let startWeekday = calendar.component(.weekday, from: periodStart)
        let leadingDays = (startWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDays,
            to: periodStart
        ) ?? periodStart
        let todayWeekday = calendar.component(.weekday, from: today)
        let trailingDays = (calendar.firstWeekday + 6 - todayWeekday + 7) % 7
        let gridEnd = calendar.date(
            byAdding: .day,
            value: trailingDays,
            to: today
        ) ?? today
        let dayCount = (calendar.dateComponents(
            [.day],
            from: gridStart,
            to: gridEnd
        ).day ?? 0) + 1
        let weekCount = max(1, dayCount / 7)

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        dateFormatter.dateFormat = "yyyy-MM-dd EEEE"

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        monthFormatter.dateFormat = isChinese ? "M月" : "MMM"

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        let weekdaySymbols = weekdayFormatter.shortWeekdaySymbols ?? []
        let weekdayLabels = (0..<7).map { row -> String in
            let index = (calendar.firstWeekday - 1 + row) % 7
            guard [1, 3, 5].contains(index),
                  weekdaySymbols.indices.contains(index) else { return "" }
            return weekdaySymbols[index]
        }

        var rawWeeks: [[(label: String?, count: Int, date: Date?)]] = []
        var monthLabels: [HeatmapMonthLabel] = []
        var lastMonthKey = ""
        var totalCount = 0
        var maximumCount = 0
        var cursor = gridStart

        for column in 0..<weekCount {
            var week: [(label: String?, count: Int, date: Date?)] = []
            var firstVisibleDate: Date?

            for _ in 0..<7 {
                let isVisible = cursor >= periodStart && cursor <= today
                let count = isVisible
                    ? dailyCounts[keyFormatter.string(from: cursor)] ?? 0
                    : 0
                if isVisible && firstVisibleDate == nil {
                    firstVisibleDate = cursor
                }
                totalCount += count
                maximumCount = max(maximumCount, count)
                week.append((
                    label: isVisible ? dateFormatter.string(from: cursor) : nil,
                    count: count,
                    date: isVisible ? cursor : nil
                ))
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            }
            rawWeeks.append(week)

            if let firstVisibleDate {
                let components = calendar.dateComponents(
                    [.year, .month],
                    from: firstVisibleDate
                )
                let monthKey = "\(components.year ?? 0)-\(components.month ?? 0)"
                if monthKey != lastMonthKey {
                    monthLabels.append(
                        HeatmapMonthLabel(
                            column: column,
                            text: monthFormatter.string(from: firstVisibleDate)
                        )
                    )
                    lastMonthKey = monthKey
                }
            }
        }

        let denominator = max(maximumCount, 1)
        let weeks = rawWeeks.map { week in
            week.map { cell in
                HeatmapCellData(
                    dateLabel: cell.label,
                    count: cell.count,
                    level: heatmapLevel(
                        count: cell.count,
                        maximumCount: denominator,
                        isVisible: cell.date != nil
                    )
                )
            }
        }

        return HeatmapData(
            weeks: weeks,
            monthLabels: monthLabels,
            weekdayLabels: weekdayLabels,
            totalCount: totalCount
        )
    }

    private static func heatmapLevel(
        count: Int,
        maximumCount: Int,
        isVisible: Bool
    ) -> Int {
        guard isVisible else { return -1 }
        guard count > 0 else { return 0 }
        let ratio = Double(count) / Double(maximumCount)
        if ratio < 0.25 { return 1 }
        if ratio < 0.5 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }

    private static func dayKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "__unknown__" : trimmed.lowercased()
    }
}

// MARK: - Asynchronous app icon catalog

private actor AppIconCatalog {
    static let shared = AppIconCatalog()

    private struct AppLocation {
        let url: URL
        let iconFile: String?
    }

    private var locationsByBundleIdentifier: [String: AppLocation] = [:]
    private var locationsByName: [String: AppLocation] = [:]
    private var iconCache: [String: PreparedAppIcon] = [:]
    private var missingIconKeys: Set<String> = []
    private var isIndexed = false

    func prepare(
        entriesByRange: [AppChartRange: [AppCopyCount]]
    ) -> [AppChartRange: PreparedAppChart] {
        indexApplicationsIfNeeded()
        guard !Task.isCancelled else { return [:] }

        var iconsByEntryID: [String: PreparedAppIcon] = [:]
        var uniqueEntries: [String: AppCopyCount] = [:]
        for entries in entriesByRange.values {
            for entry in entries {
                if uniqueEntries[entry.id]?.bundleIdentifier == nil ||
                    entry.bundleIdentifier != nil {
                    uniqueEntries[entry.id] = entry
                }
            }
        }

        for entry in uniqueEntries.values {
            guard !Task.isCancelled else { return [:] }
            if let icon = icon(for: entry) {
                iconsByEntryID[entry.id] = icon
            }
        }

        var charts: [AppChartRange: PreparedAppChart] = [:]
        for range in AppChartRange.allCases {
            let entries = (entriesByRange[range] ?? []).compactMap { entry in
                iconsByEntryID[entry.id].map {
                    PreparedAppChartEntry(count: entry, icon: $0)
                }
            }
            let maximumCount = entries.map(\.count.count).max() ?? 1
            charts[range] = PreparedAppChart(
                entries: entries,
                domainMaximum: max(
                    Double(maximumCount) * 1.16,
                    Double(maximumCount + 1)
                )
            )
        }
        return charts
    }

    /// App bundles are indexed once on the actor's executor. No recursive
    /// filesystem walk, Bundle metadata read or icon file I/O reaches the UI
    /// actor, and subsequent dashboard visits reuse both indexes and bytes.
    private func indexApplicationsIfNeeded() {
        guard !isIndexed else { return }
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        for root in roots {
            guard !Task.isCancelled else { return }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard !Task.isCancelled else { return }
                guard let bundle = Bundle(url: url) else { continue }
                let info = bundle.infoDictionary
                let localizedInfo = bundle.localizedInfoDictionary
                let location = AppLocation(
                    url: url,
                    iconFile: info?["CFBundleIconFile"] as? String
                )

                if let bundleIdentifier = bundle.bundleIdentifier?.lowercased(),
                   !bundleIdentifier.isEmpty {
                    locationsByBundleIdentifier[bundleIdentifier] = location
                }

                let names = [
                    localizedInfo?["CFBundleDisplayName"] as? String,
                    localizedInfo?["CFBundleName"] as? String,
                    info?["CFBundleDisplayName"] as? String,
                    info?["CFBundleName"] as? String,
                    url.deletingPathExtension().lastPathComponent
                ].compactMap { $0 }
                for name in names where !name.isEmpty {
                    locationsByName[Self.normalized(name)] = location
                }
            }
        }
        isIndexed = true
    }

    private func icon(for entry: AppCopyCount) -> PreparedAppIcon? {
        let rawKey = entry.bundleIdentifier?.lowercased() ?? "name:\(entry.id)"
        if let cached = iconCache[rawKey] {
            return cached
        }
        if missingIconKeys.contains(rawKey) {
            return nil
        }

        let location: AppLocation? = {
            if let bundleIdentifier = entry.bundleIdentifier?.lowercased(),
               let exact = locationsByBundleIdentifier[bundleIdentifier] {
                return exact
            }
            return locationsByName[Self.normalized(entry.name)]
        }()
        guard let location,
              let iconURL = iconURL(for: location),
              let data = try? Data(contentsOf: iconURL, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            missingIconKeys.insert(rawKey)
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            missingIconKeys.insert(rawKey)
            return nil
        }

        let icon = PreparedAppIcon(image: image)
        iconCache[rawKey] = icon
        return icon
    }

    private func iconURL(for location: AppLocation) -> URL? {
        let fileManager = FileManager.default
        let resourcesURL = location.url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        if var iconFile = location.iconFile, !iconFile.isEmpty {
            if URL(fileURLWithPath: iconFile).pathExtension.isEmpty {
                iconFile += ".icns"
            }
            let declaredIcon = resourcesURL.appendingPathComponent(iconFile)
            if fileManager.fileExists(atPath: declaredIcon.path) {
                return declaredIcon
            }
        }

        // A few bundles omit CFBundleIconFile but still ship an icns resource.
        // This fallback examines only the already-matched app bundle.
        let candidates = (try? fileManager.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter { $0.pathExtension.lowercased() == "icns" }
            .sorted {
                let lhsPreferred = $0.lastPathComponent.localizedCaseInsensitiveContains("app")
                let rhsPreferred = $1.lastPathComponent.localizedCaseInsensitiveContains("app")
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                return $0.lastPathComponent < $1.lastPathComponent
            }
            .first
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - App distribution

private enum AppChartRange: String, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case oneYear

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .oneYear: return 365
        }
    }

    var title: String {
        switch self {
        case .sevenDays: return L("stats.apps.range.7days")
        case .thirtyDays: return L("stats.apps.range.30days")
        case .oneYear: return L("stats.apps.range.year")
        }
    }
}

private struct AppChartDisplayEntry: Identifiable {
    let id: String
    let name: String
    let count: Int
    let icon: NSImage
}

private struct AppChartData {
    let entries: [AppChartDisplayEntry]
    let domainMaximum: Double
    let entriesByID: [String: AppChartDisplayEntry]

    init(entries: [AppChartDisplayEntry], domainMaximum: Double) {
        self.entries = entries
        self.domainMaximum = domainMaximum
        self.entriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
    }
}

private struct AppCopyBarChart: View {
    let data: AppChartData?
    let isLoading: Bool
    @Binding var range: AppChartRange

    private let columnWidth: CGFloat = 52
    private let chartHeight: CGFloat = 236

    private var entries: [AppChartDisplayEntry] {
        data?.entries ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                SettingsSegmented(
                    selection: $range,
                    options: AppChartRange.allCases.map {
                        SettingsSegmented<AppChartRange>.Option(
                            value: $0,
                            title: $0.title,
                            icon: nil
                        )
                    }
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(L("stats.apps.range.label"))
            }

            if data == nil && isLoading {
                DashboardLoadingPlaceholder(height: 180)
            } else if entries.isEmpty {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                scrollableChart
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))

                if entries.count > 8 {
                    Label(L("stats.apps.scrollHint"), systemImage: "arrow.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.82),
            value: range
        )
    }

    private var scrollableChart: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: entries.count > 8) {
                chart(width: max(proxy.size.width, CGFloat(entries.count) * columnWidth))
                    .padding(.horizontal, 2)
            }
        }
        .frame(height: chartHeight)
    }

    private func chart(width: CGFloat) -> some View {
        let entriesByID = data?.entriesByID ?? [:]

        return Chart(entries) { entry in
            BarMark(
                x: .value(L("stats.apps.axis.application"), entry.id),
                y: .value(L("stats.apps.axis.copies"), entry.count),
                width: .fixed(18)
            )
            .foregroundStyle(Color.appAccent.gradient)
            .cornerRadius(5)
            .annotation(position: .top, alignment: .center, spacing: 5) {
                Text("\(entry.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.appMetal)
            }
        }
        .chartYScale(domain: 0...(data?.domainMaximum ?? 1))
        .chartXAxis {
            AxisMarks(position: .bottom, values: entries.map(\.id)) { value in
                AxisValueLabel(centered: true) {
                    if let identifier = value.as(String.self),
                       let entry = entriesByID[identifier] {
                        AppChartIconLabel(entry: entry)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.appPaperDivider.opacity(0.7))
                AxisTick()
                    .foregroundStyle(Color.appPaperDivider)
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: chartHeight)
        .accessibilityLabel(L("stats.apps.accessibility"))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.appAccent.opacity(0.78))
            Text(L("stats.apps.empty.title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMetal)
            Text(L("stats.apps.empty.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appPaper.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appPaperDivider.opacity(0.7), lineWidth: 0.5)
        )
    }
}

private struct AppChartIconLabel: View {
    let entry: AppChartDisplayEntry

    private var displayName: String {
        entry.name.isEmpty ? L("common.unknown") : entry.name
    }

    var body: some View {
        Image(nsImage: entry.icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 24, height: 24)
            .help(displayName)
            .accessibilityLabel(displayName)
    }
}

// MARK: - Contribution wall (GitHub-style heatmap)

private struct ContributionWall: View {
    let data: HeatmapData

    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("stats.totalCountFormat", data.totalCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                legend
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    weekdayLabels
                    VStack(alignment: .leading, spacing: 2) {
                        monthLabels
                        weekColumns
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var weekdayLabels: some View {
        let labelWidth: CGFloat = 28
        return VStack(alignment: .trailing, spacing: gap) {
            Color.clear.frame(width: labelWidth, height: 12)
            ForEach(Array(data.weekdayLabels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(
                width: CGFloat(data.weeks.count) * (cellSize + gap),
                height: 12
            )
            ForEach(data.monthLabels) { item in
                Text(item.text)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(item.column) * (cellSize + gap))
            }
        }
    }

    private var weekColumns: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(data.weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForLevel(cell.level))
                            .frame(width: cellSize, height: cellSize)
                            .help(tooltip(for: cell))
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text(L("stats.legend.less"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForLevel(level))
                    .frame(width: cellSize, height: cellSize)
            }
            Text(L("stats.legend.more"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case -1: return .clear
        case 0: return Color.secondary.opacity(0.12)
        case 1: return Color.appAccent.opacity(0.30)
        case 2: return Color.appAccent.opacity(0.55)
        case 3: return Color.appAccent.opacity(0.80)
        default: return Color.appAccent
        }
    }

    private func tooltip(for cell: HeatmapCellData) -> String {
        guard let dateLabel = cell.dateLabel else { return "" }
        return L("stats.tooltipFormat", dateLabel, cell.count)
    }
}

private struct DashboardLoadingPlaceholder: View {
    let height: CGFloat

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.appAccent)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appPaper.opacity(0.32))
            )
    }
}
