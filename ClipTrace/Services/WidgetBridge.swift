import Foundation
import SwiftData
import WidgetKit

/// Bridges the app's live state into the shared App Group container the widgets
/// read from. Computes a `ClipTraceWidgetSnapshot` (library counts from
/// SwiftData + activity from `CopyStatsStore`), writes it as JSON, and pokes
/// `WidgetCenter` to reload the timelines.
///
/// `requestRefresh(context:)` is debounced so a burst of captures (or a
/// retention sweep deleting many rows) collapses into a single write instead of
/// hammering the disk and the widget reload path.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    /// Coalescing window — long enough to swallow a paste storm, short enough
    /// that the widget still feels live after a copy.
    private let debounceInterval: TimeInterval = 1.5
    private var pendingTask: Task<Void, Never>?

    private init() {}

    /// Schedule a snapshot refresh. Safe to call on every mutation; repeated
    /// calls within the debounce window collapse into one write.
    func requestRefresh(context: ModelContext) {
        pendingTask?.cancel()
        let interval = debounceInterval
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot(context: context)
        }
    }

    /// Write immediately, bypassing the debounce. Used at launch so the file
    /// exists before the user installs a widget.
    func refreshNow(context: ModelContext) {
        pendingTask?.cancel()
        writeSnapshot(context: context)
    }

    // MARK: - Snapshot construction

    private func writeSnapshot(context: ModelContext) {
        let snapshot = buildSnapshot(context: context)
        let dir = WidgetShared.appWriteDirectory
        let url = WidgetShared.appWriteURL
        // The widget's sandbox container is created the first time the extension
        // runs; create the Application Support subtree if it's not there yet so
        // the very first write (e.g. right after install) still lands.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.snapshot.encode(snapshot) else { return }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func buildSnapshot(context: ModelContext) -> ClipTraceWidgetSnapshot {
        // MARK: Library composition — count-only fetches, no blobs faulted.
        let total = count(context, FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))

        var byType: [String: Int] = [:]
        for type in ClipboardItemType.allCases {
            let raw = type.rawValue
            byType[raw] = count(context, FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.type == raw }
            ))
        }

        let favorites = count(context, FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isFavorite }
        ))

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayNew = count(context, FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= startOfDay }
        ))

        // MARK: Activity — straight from the copy-stats store.
        let stats = CopyStatsStore.shared
        let dailyCounts = recentDailyCounts(from: stats)

        let language = (L10n.shared.effectiveLanguage == .zh) ? "zh" : "en"
        let palette = UserDefaults.standard.string(forKey: "accentPalette") ?? "sage"

        return ClipTraceWidgetSnapshot(
            total: total,
            byType: byType,
            favorites: favorites,
            todayNew: todayNew,
            today: stats.todayCount(),
            last7: stats.countLast(days: 7),
            last30: stats.countLast(days: 30),
            totalCopies: stats.totalAllTime,
            dailyCounts: dailyCounts,
            statsEnabled: stats.enabled,
            generatedAt: Date(),
            language: language,
            accentPalette: palette
        )
    }

    /// `fetchCount` never materialises the rows, so each tally stays cheap even
    /// on a large history with embedded image data.
    private func count(_ context: ModelContext, _ descriptor: FetchDescriptor<ClipboardItem>) -> Int {
        (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Build the recent-window daily-count dict the heatmap draws from. Keyed
    /// `yyyy-MM-dd`, covering the last `WidgetShared.heatmapDays` days; zero
    /// days are omitted (the widget treats missing keys as zero).
    private func recentDailyCounts(from stats: CopyStatsStore) -> [String: Int] {
        let days = stats.lastDays(WidgetShared.heatmapDays)
        var dict: [String: Int] = [:]
        for entry in days where entry.count > 0 {
            dict[Self.dayKey(entry.date)] = entry.count
        }
        return dict
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
