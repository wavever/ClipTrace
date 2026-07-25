import Foundation
import SwiftUI

struct AppCopyCount: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let count: Int
}

struct AppCopySeed: Sendable {
    let sourceApp: String
    let createdAt: Date
}

struct StoredAppCopyCount: Codable, Sendable {
    var name: String
    var count: Int
    var bundleIdentifier: String? = nil
}

struct CopyStatsSnapshot: Sendable {
    let dailyCounts: [String: Int]
    let dailyAppCounts: [String: [String: StoredAppCopyCount]]
}

private struct CopyStatsBackfillResult: Sendable {
    let dailyCounts: [String: Int]
    let dailyAppCounts: [String: [String: StoredAppCopyCount]]
}

private enum CopyStatsBackfillProcessor {
    static func process(
        seeds: [AppCopySeed],
        dailyCounts: [String: Int],
        dailyAppCounts: [String: [String: StoredAppCopyCount]],
        needsDailyBackfill: Bool,
        needsAppBackfill: Bool,
        retentionDays: Int,
        now: Date = Date()
    ) -> CopyStatsBackfillResult {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var historicalCounts: [String: [String: StoredAppCopyCount]] = [:]
        for seed in seeds {
            let day = dayFormatter.string(from: seed.createdAt)
            let name = seed.sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = normalizedAppName(name)
            var dayCounts = historicalCounts[day, default: [:]]
            var count = dayCounts[normalizedName] ?? StoredAppCopyCount(
                name: name,
                count: 0
            )
            if !name.isEmpty {
                count.name = name
            }
            count.count += 1
            dayCounts[normalizedName] = count
            historicalCounts[day] = dayCounts
        }

        var mergedDailyCounts = dailyCounts
        if needsDailyBackfill {
            for (day, historyForDay) in historicalCounts {
                let historicalTotal = historyForDay.values.reduce(0) { $0 + $1.count }
                mergedDailyCounts[day] = max(
                    mergedDailyCounts[day] ?? 0,
                    historicalTotal
                )
            }
        }

        var mergedAppCounts = dailyAppCounts
        if needsAppBackfill {
            for (day, historyForDay) in historicalCounts {
                var storedForDay = mergedAppCounts[day, default: [:]]
                for (normalizedName, historical) in historyForDay {
                    let alreadyRecorded = storedForDay.values
                        .filter { normalizedAppName($0.name) == normalizedName }
                        .reduce(0) { $0 + $1.count }
                    let missingCount = max(0, historical.count - alreadyRecorded)
                    guard missingCount > 0 else { continue }

                    let identifier = "history:\(normalizedName)"
                    var baseline = storedForDay[identifier] ?? StoredAppCopyCount(
                        name: historical.name,
                        count: 0
                    )
                    baseline.count += missingCount
                    storedForDay[identifier] = baseline
                }
                mergedAppCounts[day] = storedForDay
            }
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(
            byAdding: .day,
            value: -retentionDays,
            to: today
        ) ?? today
        let cutoffKey = dayFormatter.string(from: cutoff)
        return CopyStatsBackfillResult(
            dailyCounts: mergedDailyCounts.filter { $0.key >= cutoffKey },
            dailyAppCounts: mergedAppCounts.filter { $0.key >= cutoffKey }
        )
    }

    private static func normalizedAppName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "__unknown__" : trimmed.lowercased()
    }
}

private actor CopyStatsPersistence {
    private var latestRevision = -1

    func persist(
        revision: Int,
        dailyCounts: [String: Int],
        dailyAppCounts: [String: [String: StoredAppCopyCount]],
        countsKey: String,
        appCountsKey: String
    ) {
        // Detached callers may reach the actor out of order. A monotonic
        // revision prevents an older snapshot from replacing a newer write.
        guard revision >= latestRevision else { return }
        latestRevision = revision

        if let data = try? JSONEncoder().encode(dailyCounts) {
            UserDefaults.standard.set(data, forKey: countsKey)
        }
        if let data = try? JSONEncoder().encode(dailyAppCounts) {
            UserDefaults.standard.set(data, forKey: appCountsKey)
        }
    }
}

@MainActor
final class CopyStatsStore: ObservableObject {
    static let shared = CopyStatsStore()

    /// Master switch — when off, recordCopy() is a no-op and the UI hides
    /// stats surfaces. The toggle is mirrored to UserDefaults so it survives
    /// relaunches and stays in sync with the @AppStorage flag in settings.
    @Published var enabled: Bool {
        didSet {
            guard !loading else { return }
            UserDefaults.standard.set(enabled, forKey: enabledKey)
        }
    }

    /// ISO yyyy-MM-dd → count for that day.
    @Published private(set) var dailyCounts: [String: Int] = [:]
    /// A small monotonic token lets views request a fresh background snapshot
    /// without comparing the full statistics dictionaries on the main actor.
    @Published private(set) var revision = 0
    /// ISO yyyy-MM-dd → stable app identifier → display metadata and count.
    /// Keeping this separate preserves compatibility with existing daily totals
    /// while allowing app-level statistics to start recording immediately.
    @Published private var dailyAppCounts: [String: [String: StoredAppCopyCount]] = [:]

    private let countsKey = "copyStats.daily.v1"
    private let appCountsKey = "copyStats.apps.daily.v1"
    private let appHistoryBackfillKey = "copyStats.apps.historyBackfill.v1"
    private let dailyHistoryBackfillKey = "copyStats.daily.historyBackfill.v1"
    private let enabledKey = "copyStatsEnabled"
    private let retentionDays = 365
    private let persistenceWorker = CopyStatsPersistence()
    private var loading = true
    private var persistenceRevision = 0
    private var backfillTask: Task<Void, Never>?

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        // Default to ON so users see counts working out of the box; the
        // toggle in settings remains the single source of truth.
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }
        self.enabled = UserDefaults.standard.bool(forKey: enabledKey)

        if let data = UserDefaults.standard.data(forKey: countsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.dailyCounts = decoded
        }
        if let data = UserDefaults.standard.data(forKey: appCountsKey),
           let decoded = try? JSONDecoder().decode(
               [String: [String: StoredAppCopyCount]].self,
               from: data
           ) {
            self.dailyAppCounts = decoded
        }
        loading = false
        restoreDailyHistoryFromAppCountsIfNeeded()
    }

    // MARK: - Recording

    func recordCopy(
        sourceApp: String = "",
        bundleIdentifier: String = "",
        at date: Date = Date()
    ) {
        guard enabled else { return }
        let key = dayFormatter.string(from: date)
        dailyCounts[key, default: 0] += 1

        let name = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bundle ids distinguish apps reliably. Name-based fallback still lets
        // system and remote clipboard sources participate when no id exists.
        let identifier = bundleID.isEmpty
            ? "name:\(name.lowercased())"
            : "bundle:\(bundleID.lowercased())"
        var appCounts = dailyAppCounts[key, default: [:]]
        var appCount = appCounts[identifier] ?? StoredAppCopyCount(
            name: name,
            count: 0,
            bundleIdentifier: bundleID.isEmpty ? nil : bundleID
        )
        if !name.isEmpty {
            appCount.name = name
        }
        if !bundleID.isEmpty {
            appCount.bundleIdentifier = bundleID
        }
        appCount.count += 1
        appCounts[identifier] = appCount
        dailyAppCounts[key] = appCounts

        trimIfNeeded()
        persist()
        revision &+= 1
    }

    func resetAll() {
        dailyCounts.removeAll()
        dailyAppCounts.removeAll()
        // Clearing statistics is an explicit user choice. Marking the migration
        // complete prevents retained clipboard history from silently restoring
        // daily or app counts on the next launch.
        UserDefaults.standard.set(true, forKey: appHistoryBackfillKey)
        UserDefaults.standard.set(true, forKey: dailyHistoryBackfillKey)
        persist()
        revision &+= 1
    }

    var needsHistoryBackfill: Bool {
        !UserDefaults.standard.bool(forKey: appHistoryBackfillKey) ||
            !UserDefaults.standard.bool(forKey: dailyHistoryBackfillKey)
    }

    /// Seeds daily and app dimensions from retained clipboard history. Some
    /// clips may already have live counts, so each baseline only fills the gap
    /// instead of blindly adding records.
    func backfillHistory(_ seeds: [AppCopySeed]) {
        let defaults = UserDefaults.standard
        let needsAppBackfill = !defaults.bool(forKey: appHistoryBackfillKey)
        let needsDailyBackfill = !defaults.bool(forKey: dailyHistoryBackfillKey)
        guard needsAppBackfill || needsDailyBackfill,
              backfillTask == nil else { return }

        let startingRevision = revision
        let currentDailyCounts = dailyCounts
        let currentDailyAppCounts = dailyAppCounts
        let retentionDays = retentionDays
        backfillTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                CopyStatsBackfillProcessor.process(
                    seeds: seeds,
                    dailyCounts: currentDailyCounts,
                    dailyAppCounts: currentDailyAppCounts,
                    needsDailyBackfill: needsDailyBackfill,
                    needsAppBackfill: needsAppBackfill,
                    retentionDays: retentionDays
                )
            }.value

            guard let self else { return }
            self.backfillTask = nil
            guard !Task.isCancelled else { return }

            // A copy or reset that landed while aggregation was running owns
            // the newer state. Recompute from that snapshot instead of
            // overwriting it with stale background output.
            guard self.revision == startingRevision else {
                self.backfillHistory(seeds)
                return
            }

            self.dailyCounts = result.dailyCounts
            self.dailyAppCounts = result.dailyAppCounts
            if needsAppBackfill {
                defaults.set(true, forKey: self.appHistoryBackfillKey)
            }
            if needsDailyBackfill {
                defaults.set(true, forKey: self.dailyHistoryBackfillKey)
            }
            self.revision &+= 1
            self.persist()
        }
    }

    // MARK: - Queries

    func count(on date: Date) -> Int {
        dailyCounts[dayFormatter.string(from: date)] ?? 0
    }

    func todayCount() -> Int { count(on: Date()) }

    /// Total within the last `days` calendar days (inclusive of today).
    func countLast(days: Int) -> Int {
        guard days > 0 else { return 0 }
        return lastDays(days).reduce(0) { $0 + $1.count }
    }

    var totalAllTime: Int { dailyCounts.values.reduce(0, +) }

    /// Dictionary copies are copy-on-write, so handing this immutable snapshot
    /// to a background task is O(1) until that task begins its own processing.
    func snapshot() -> CopyStatsSnapshot {
        CopyStatsSnapshot(
            dailyCounts: dailyCounts,
            dailyAppCounts: dailyAppCounts
        )
    }

    /// Aggregates app counts within a recent calendar-day window. App data has
    /// the same 365-day retention as daily totals; callers can pass nil for the
    /// full retained range.
    func appCopyCounts(lastDays days: Int? = nil) -> [AppCopyCount] {
        let includedKeys: Set<String>
        if let days {
            guard days > 0 else { return [] }
            includedKeys = Set(lastDays(days).map { dayFormatter.string(from: $0.date) })
        } else {
            includedKeys = Set(dailyAppCounts.keys)
        }

        // Historical rows only know the app's display name while new events
        // also have a bundle id. Grouping by normalized name keeps both sources
        // on one bar instead of splitting (for example) Safari into two rows.
        var aggregated: [String: StoredAppCopyCount] = [:]
        for (day, appCounts) in dailyAppCounts where includedKeys.contains(day) {
            for appCount in appCounts.values {
                let normalizedName = Self.normalizedAppName(appCount.name)
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

    /// Returns recent days oldest→newest. Missing days are filled with 0
    /// so chart UI gets a stable x-axis.
    func lastDays(_ days: Int) -> [(date: Date, count: Int)] {
        guard days > 0 else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().map { offset -> (Date, Int) in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return (day, dailyCounts[dayFormatter.string(from: day)] ?? 0)
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard !loading else { return }
        persistenceRevision &+= 1
        let writeRevision = persistenceRevision
        let currentDailyCounts = dailyCounts
        let currentDailyAppCounts = dailyAppCounts
        let persistenceWorker = persistenceWorker
        let countsKey = countsKey
        let appCountsKey = appCountsKey
        Task.detached(priority: .utility) {
            await persistenceWorker.persist(
                revision: writeRevision,
                dailyCounts: currentDailyCounts,
                dailyAppCounts: currentDailyAppCounts,
                countsKey: countsKey,
                appCountsKey: appCountsKey
            )
        }
    }

    /// App history is already stored per day, so existing installations can
    /// repair the heatmap immediately without waiting for a SwiftData fetch.
    /// The history fetch remains a fallback for installations with no app data.
    private func restoreDailyHistoryFromAppCountsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: dailyHistoryBackfillKey),
              !dailyAppCounts.isEmpty else { return }

        var restoredCounts = dailyCounts
        for (day, appCounts) in dailyAppCounts {
            let appTotal = appCounts.values.reduce(0) { $0 + $1.count }
            restoredCounts[day] = max(restoredCounts[day] ?? 0, appTotal)
        }
        dailyCounts = restoredCounts
        trimIfNeeded()
        persist()
        defaults.set(true, forKey: dailyHistoryBackfillKey)
        revision &+= 1
    }

    private func trimIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: today) else { return }
        let cutoffKey = dayFormatter.string(from: cutoff)
        dailyCounts = dailyCounts.filter { $0.key >= cutoffKey }
        dailyAppCounts = dailyAppCounts.filter { $0.key >= cutoffKey }
    }

    private static func normalizedAppName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "__unknown__" : trimmed.lowercased()
    }
}
