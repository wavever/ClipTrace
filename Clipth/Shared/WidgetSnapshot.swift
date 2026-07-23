import Foundation

/// Snapshot of all the numbers the widgets render, written by the app into the
/// shared App Group container and read back by the widget extension.
///
/// A macOS widget runs in its own sandboxed process, so it can't touch the
/// app's `UserDefaults.standard` or its SwiftData store. Instead the app
/// computes this tiny value type and drops it as JSON into the group container;
/// the widget just decodes it. We deliberately carry *only aggregate counts* —
/// never clip contents — so nothing sensitive leaves the app.
struct ClipthWidgetSnapshot: Codable, Hashable {
    // MARK: Library composition (数据)
    /// Total live (non-trashed) clips in history.
    var total: Int
    /// Live clip count keyed by `ClipboardItemType.rawValue`
    /// (text/image/video/file/url/rtf). Missing keys mean zero.
    var byType: [String: Int]
    /// Live clips flagged favourite.
    var favorites: Int
    /// Live clips created since local-time start of today.
    var todayNew: Int

    // MARK: Copy activity (活跃统计)
    /// Copies recorded today.
    var today: Int
    /// Copies in the last 7 calendar days (inclusive of today).
    var last7: Int
    /// Copies in the last 30 calendar days (inclusive of today).
    var last30: Int
    /// All-time copy total still inside the stats retention window.
    var totalCopies: Int
    /// `yyyy-MM-dd` → count for the recent window the heatmap draws (~105 days).
    var dailyCounts: [String: Int]
    /// Mirrors `CopyStatsStore.enabled`. When false the activity widget shows a
    /// muted "stats off" state instead of zeros.
    var statsEnabled: Bool

    // MARK: Meta
    var generatedAt: Date
    /// Effective UI language ("zh" / "en") so the widget matches the in-app
    /// language override rather than guessing from system locale.
    var language: String
    /// `AccentPalette.rawValue` so the widget tints itself with the user's
    /// chosen accent (sage/clay/amber/…) instead of a hard-coded colour.
    var accentPalette: String
    /// Present when `accentPalette == "custom"`. Stored as `#RRGGBB` so the
    /// widget extension can reproduce the user's custom tint without reaching
    /// into the app's UserDefaults.
    var customAccentHex: String?

    /// Neutral zero-state used before the app has ever written a snapshot.
    static let placeholder = ClipthWidgetSnapshot(
        total: 0, byType: [:], favorites: 0, todayNew: 0,
        today: 0, last7: 0, last30: 0, totalCopies: 0,
        dailyCounts: [:], statsEnabled: true,
        generatedAt: .distantPast, language: "zh", accentPalette: "sage",
        customAccentHex: nil
    )
}

/// Constants + file plumbing for the shared snapshot, used by both targets.
///
/// macOS requires WidgetKit extensions to be sandboxed (`com.apple.security.app-
/// sandbox`), or `chronod` won't load them. A sandboxed widget can only read its
/// own container. We deliberately do NOT use an App Group to bridge the data:
/// the `com.apple.security.application-groups` entitlement needs a provisioning
/// profile, which collides with Clipth's self-signed / no-team signing (kept
/// that way on purpose so the TCC grant stays stable — see the project signing
/// notes).
///
/// So the channel is the widget's OWN sandbox container:
/// - The widget (sandboxed) reads from `.applicationSupportDirectory`, which the
///   sandbox redirects into its container.
/// - The app (non-sandboxed) writes the same file by addressing the widget's
///   container path explicitly — its own `.applicationSupportDirectory` points
///   at the real `~/Library/Application Support`, which the widget can't see.
enum WidgetShared {
    /// Widget extension bundle id — the directory name of its sandbox container.
    static let widgetBundleID = "com.wavever.clipth.widgets"

    /// Widget kinds — must match the `kind:` strings the widgets register and
    /// the identifiers `WidgetCenter` reloads.
    static let dataWidgetKind = "ClipthDataWidget"
    static let activityWidgetKind = "ClipthActivityWidget"

    /// Recent-day window the app exports for the heatmap. A full year (matches
    /// CopyStatsStore's retention) so the widget can draw as many week-columns
    /// as fit its width — the medium widget's short middle forces small cells,
    /// which need ~34 columns to span the full width. Zero days are omitted from
    /// the JSON, so the long window barely changes the payload size.
    static let heatmapDays = 364

    private static let folderName = "Clipth"
    private static let snapshotFileName = "widget-snapshot.json"

    // MARK: Widget read side (sandbox-redirected)

    /// URL the WIDGET reads from. Inside the sandbox this resolves to
    /// `…/Containers/<widget>/Data/Library/Application Support/Clipth/…`.
    static var snapshotURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    /// Decode the latest snapshot the app wrote. Returns nil when nothing has
    /// been written yet.
    static func load() -> ClipthWidgetSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.snapshot.decode(ClipthWidgetSnapshot.self, from: data)
    }

    // MARK: App write side (explicit container path)

    /// Directory the APP writes into — the widget's sandbox container, addressed
    /// from the real home directory. Equals the widget's sandbox-redirected
    /// Application Support folder on disk.
    static var appWriteDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// File the APP writes the snapshot to.
    static var appWriteURL: URL {
        appWriteDirectory.appendingPathComponent(snapshotFileName)
    }
}

extension JSONDecoder {
    /// Shared decoder so the app's encoder and the widget's decoder agree on
    /// the date strategy.
    static let snapshot: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let snapshot: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
