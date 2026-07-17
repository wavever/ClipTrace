import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openMainWindow = Self(
        "openMainWindow",
        default: .init(.v, modifiers: [.command, .shift])
    )

    static let openQuickPaste = Self(
        "openQuickPaste",
        default: .init(.v, modifiers: [.command, .option])
    )
}

enum AppShortcut: String, CaseIterable, Identifiable {
    case openMainWindow
    case openQuickPaste

    var id: String { rawValue }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .openMainWindow: return .openMainWindow
        case .openQuickPaste: return .openQuickPaste
        }
    }

    var displayName: String {
        switch self {
        case .openMainWindow: return L("settings.shortcut.openMainWindow")
        case .openQuickPaste: return L("settings.shortcut.openQuickPaste")
        }
    }

    var subtitle: String {
        switch self {
        case .openMainWindow: return L("settings.shortcut.openMainWindow.subtitle")
        case .openQuickPaste: return L("settings.shortcut.openQuickPaste.subtitle")
        }
    }
}

/// Tracks the per-command suspension state that KeyboardShortcuts 2.3 cannot
/// expose. Keeping the state here lets the release runner use its newest
/// Xcode-compatible package version without re-enabling a shortcut that the
/// settings recorder is still capturing.
@MainActor
enum AppShortcutActivation {
    private static var suspendedNames = Set<KeyboardShortcuts.Name>()

    static func isEnabled(_ name: KeyboardShortcuts.Name) -> Bool {
        KeyboardShortcuts.isEnabled && !suspendedNames.contains(name)
    }

    static func suspend(_ name: KeyboardShortcuts.Name) {
        suspendedNames.insert(name)
        KeyboardShortcuts.disable(name)
    }

    static func restore(_ name: KeyboardShortcuts.Name) {
        suspendedNames.remove(name)
        KeyboardShortcuts.enable(name)
    }

    static func setShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        for name: KeyboardShortcuts.Name
    ) {
        suspendedNames.remove(name)
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }
}
