import SwiftUI
import AppKit
import Observation

/// User-facing appearance theme choice. `.system` follows macOS dark/light mode.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light:  return L("settings.theme.light")
        case .dark:   return L("settings.theme.dark")
        case .system: return L("settings.theme.system")
        }
    }

    var icon: String {
        switch self {
        case .light:  return "sun.max"
        case .dark:   return "moon"
        case .system: return "desktopcomputer"
        }
    }

    /// `nil` means "let the system decide" — required so SwiftUI doesn't lock
    /// the colour scheme when the user picks "follow system".
    var colorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }

    /// AppKit appearance used to pin the whole app via `NSApp.appearance`.
    /// `nil` follows the system. We drive this instead of relying on
    /// `.preferredColorScheme`, because on macOS SwiftUI pins the window's
    /// `NSAppearance` for `.light`/`.dark` but fails to clear it when switching
    /// back to `nil` — leaving the window stuck on the previously forced scheme
    /// after the user picks "follow system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

/// Independent presentation preference shared by the two compact clipboard
/// panels. The main window owns a separate layout key because its adaptive
/// grid has different density and navigation semantics.
enum PanelContentLayout: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .list: return L("settings.panelLayout.list")
        case .grid: return L("settings.panelLayout.grid")
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

/// User-pickable theme accent. We bypass the asset catalog `AccentColor` slot
/// because we want runtime switching (no rebuild) and a curated palette that
/// reads warmer than the macOS system blue. Each case stores its own light /
/// dark variant — values are hand-tuned to stay readable on both backgrounds.
enum AccentPalette: String, CaseIterable, Identifiable {
    case sage      // 鼠尾草 — calm, the default
    case clay      // 陶土 / 暖珊瑚
    case amber     // 琥珀 / 浅杏
    case lavender  // 柔雾紫
    case teal      // 雾青
    case blue      // 经典蓝（比系统蓝更柔）

    var id: String { rawValue }

    /// Dynamic NSColor so AppKit bridges and SwiftUI views resolve the same
    /// runtime accent in both light and dark appearances.
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? Self.darkValues[self]! : Self.lightValues[self]!
        }
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    var displayName: String {
        switch self {
        case .sage:     return L("settings.accent.sage")
        case .clay:     return L("settings.accent.clay")
        case .amber:    return L("settings.accent.amber")
        case .lavender: return L("settings.accent.lavender")
        case .teal:     return L("settings.accent.teal")
        case .blue:     return L("settings.accent.blue")
        }
    }

    private static let lightValues: [AccentPalette: NSColor] = [
        .sage:     NSColor(srgbRed: 0.47, green: 0.65, blue: 0.54, alpha: 1),
        .clay:     NSColor(srgbRed: 0.78, green: 0.51, blue: 0.43, alpha: 1),
        .amber:    NSColor(srgbRed: 0.80, green: 0.62, blue: 0.39, alpha: 1),
        .lavender: NSColor(srgbRed: 0.61, green: 0.52, blue: 0.74, alpha: 1),
        .teal:     NSColor(srgbRed: 0.42, green: 0.62, blue: 0.63, alpha: 1),
        .blue:     NSColor(srgbRed: 0.39, green: 0.55, blue: 0.78, alpha: 1),
    ]

    private static let darkValues: [AccentPalette: NSColor] = [
        .sage:     NSColor(srgbRed: 0.58, green: 0.76, blue: 0.65, alpha: 1),
        .clay:     NSColor(srgbRed: 0.88, green: 0.62, blue: 0.54, alpha: 1),
        .amber:    NSColor(srgbRed: 0.90, green: 0.73, blue: 0.51, alpha: 1),
        .lavender: NSColor(srgbRed: 0.72, green: 0.63, blue: 0.84, alpha: 1),
        .teal:     NSColor(srgbRed: 0.55, green: 0.74, blue: 0.74, alpha: 1),
        .blue:     NSColor(srgbRed: 0.55, green: 0.70, blue: 0.92, alpha: 1),
    ]
}

/// Source of truth for the runtime accent. We can't drive this through the
/// asset catalog `AccentColor` slot — that's evaluated at build time — and we
/// can't ride on `Color.accentColor`, because on macOS that resolves directly
/// to `NSColor.controlAccentColor` (the System Settings value) and ignores
/// SwiftUI's tint environment. So we own the storage ourselves and tag the
/// class `@Observable` so any view body that reads `palette` re-evaluates
/// automatically when the user picks a new swatch.
@Observable
final class AccentThemeStore {
    static let shared = AccentThemeStore()

    var palette: AccentPalette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: "accentPalette")
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "accentPalette")
            ?? AccentPalette.sage.rawValue
        self.palette = AccentPalette(rawValue: raw) ?? .sage
    }
}

extension Color {
    /// App-wide accent. Replaces every `Color.accentColor` reference so that
    /// runtime palette changes take effect — see `AccentThemeStore` for why
    /// we can't just rely on `Color.accentColor`.
    static var appAccent: Color {
        AccentThemeStore.shared.palette.color
    }
}

/// Preferred UI language. `.system` defers to the user's macOS language list.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zh        // 简体中文
    case en        // English

    var id: String { rawValue }

    /// Always shown in its *own* language so a user who accidentally flipped
    /// into English can still find their way back to 中文.
    var nativeName: String {
        switch self {
        case .system: return L("settings.language.system")
        case .zh:     return "中文"
        case .en:     return "English"
        }
    }

    /// `nil` lets SwiftUI inherit the system locale; otherwise we pin it.
    var locale: Locale? {
        switch self {
        case .system: return nil
        case .zh:     return Locale(identifier: "zh-Hans")
        case .en:     return Locale(identifier: "en")
        }
    }
}
