import Foundation
import SwiftUI

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

    private let countsKey = "copyStats.daily.v1"
    private let enabledKey = "copyStatsEnabled"
    private let retentionDays = 365
    private var loading = true

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
        loading = false
    }

    // MARK: - Recording

    func recordCopy(at date: Date = Date()) {
        guard enabled else { return }
        let key = dayFormatter.string(from: date)
        dailyCounts[key, default: 0] += 1
        trimIfNeeded()
        persist()
    }

    func resetAll() {
        dailyCounts.removeAll()
        persist()
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
        guard let data = try? JSONEncoder().encode(dailyCounts) else { return }
        UserDefaults.standard.set(data, forKey: countsKey)
    }

    private func trimIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: today) else { return }
        let cutoffKey = dayFormatter.string(from: cutoff)
        dailyCounts = dailyCounts.filter { $0.key >= cutoffKey }
    }
}
