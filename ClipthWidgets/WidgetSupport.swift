import WidgetKit
import SwiftUI
import AppKit

// MARK: - Timeline plumbing

/// One timeline entry = one decoded snapshot. Both widgets share this; the only
/// difference between them is how they render `snapshot`.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ClipthWidgetSnapshot
}

/// Loads the latest snapshot the app wrote into the App Group container. The
/// app pushes `WidgetCenter.reloadAllTimelines()` on every change, so the
/// hourly refresh here is just a safety net (e.g. the "today" bucket rolling
/// over at midnight while the app is asleep).
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetShared.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let entry = SnapshotEntry(date: now, snapshot: WidgetShared.load() ?? .placeholder)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Localisation

/// Tiny bilingual picker. The snapshot carries the app's effective language so
/// the widget matches the in-app override instead of guessing from the system
/// locale. Falls back to the system language only before the first snapshot.
func wText(_ lang: String, zh: String, en: String) -> String {
    let resolved = lang.isEmpty
        ? ((Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh" : "en")
        : lang
    return resolved == "zh" ? zh : en
}

// MARK: - Palette

/// Replicates the app's `AccentPalette` (see AppearancePreferences.swift) so the
/// widget tints itself with the user's chosen accent. Kept in sync by value, not
/// shared code, because Theme.swift is heavily app-coupled.
enum WidgetPalette {
    private static let light: [String: NSColor] = [
        "sage":     NSColor(srgbRed: 0.47, green: 0.65, blue: 0.54, alpha: 1),
        "clay":     NSColor(srgbRed: 0.78, green: 0.51, blue: 0.43, alpha: 1),
        "amber":    NSColor(srgbRed: 0.80, green: 0.62, blue: 0.39, alpha: 1),
        "lavender": NSColor(srgbRed: 0.61, green: 0.52, blue: 0.74, alpha: 1),
        "teal":     NSColor(srgbRed: 0.42, green: 0.62, blue: 0.63, alpha: 1),
        "blue":     NSColor(srgbRed: 0.39, green: 0.55, blue: 0.78, alpha: 1),
    ]
    private static let dark: [String: NSColor] = [
        "sage":     NSColor(srgbRed: 0.58, green: 0.76, blue: 0.65, alpha: 1),
        "clay":     NSColor(srgbRed: 0.88, green: 0.62, blue: 0.54, alpha: 1),
        "amber":    NSColor(srgbRed: 0.90, green: 0.73, blue: 0.51, alpha: 1),
        "lavender": NSColor(srgbRed: 0.72, green: 0.63, blue: 0.84, alpha: 1),
        "teal":     NSColor(srgbRed: 0.55, green: 0.74, blue: 0.74, alpha: 1),
        "blue":     NSColor(srgbRed: 0.55, green: 0.70, blue: 0.92, alpha: 1),
    ]

    /// Dynamic accent for the given `AccentPalette.rawValue`, adapting to the
    /// widget's light/dark rendering. Unknown values fall back to sage.
    static func accent(_ raw: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let table = isDark ? dark : light
            return table[raw] ?? table["sage"]!
        })
    }

    /// Warm paper background matching the app's surface (Theme.swift paper
    /// tokens). Used as the widget container background.
    static var paper: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(srgbRed: 0.135, green: 0.126, blue: 0.112, alpha: 1)
                : NSColor(srgbRed: 0.985, green: 0.974, blue: 0.945, alpha: 1)
        })
    }
}

// MARK: - Shared bits

extension ClipboardWidgetType {
    /// SF Symbol + bilingual label for each clip type, mirroring the app's
    /// `ClipboardItemType`.
    var icon: String {
        switch self {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .video: return "video"
        case .file:  return "folder"
        case .url:   return "link"
        case .rtf:   return "doc.richtext"
        }
    }

    func label(_ lang: String) -> String {
        switch self {
        case .text:  return wText(lang, zh: "文本", en: "Text")
        case .image: return wText(lang, zh: "图片", en: "Image")
        case .video: return wText(lang, zh: "视频", en: "Video")
        case .file:  return wText(lang, zh: "文件", en: "File")
        case .url:   return wText(lang, zh: "链接", en: "Link")
        case .rtf:   return wText(lang, zh: "富文本", en: "Rich Text")
        }
    }
}

/// Local mirror of `ClipboardItemType` (the SwiftData model isn't compiled into
/// the widget target). Raw values match so we can read `snapshot.byType`.
enum ClipboardWidgetType: String, CaseIterable {
    case text, image, video, file, url, rtf
}
