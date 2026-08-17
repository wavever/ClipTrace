import AppKit
import Carbon.HIToolbox
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

enum GlobalShortcutConflict {
    case otherCommand(AppShortcut)
    case system
    case menuItem(title: String)

    var message: String {
        switch self {
        case .otherCommand(let shortcut):
            return L("settings.shortcut.conflictFormat", shortcut.displayName)
        case .system:
            return L("settings.shortcut.conflictSystem")
        case .menuItem(let title):
            return L("settings.shortcut.conflictMenuFormat", title)
        }
    }

    @MainActor
    static func detect(
        _ recorded: KeyboardShortcuts.Shortcut,
        event: NSEvent,
        assigningTo name: KeyboardShortcuts.Name
    ) -> Self? {
        if let taken = AppShortcut.allCases.first(where: {
            $0.name != name && KeyboardShortcuts.getShortcut(for: $0.name) == recorded
        }) {
            return .otherCommand(taken)
        }
        if systemShortcuts.contains(recorded) { return .system }
        if let item = mainMenuItem(matching: event) { return .menuItem(title: item.title) }
        return nil
    }

    private static var systemShortcuts: [KeyboardShortcuts.Shortcut] {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let entries = raw?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let keyCode = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            return KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: modifiers)
        }
    }

    @MainActor
    private static func mainMenuItem(matching event: NSEvent) -> NSMenuItem? {
        guard let menu = NSApp.mainMenu,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty else { return nil }
        return search(menu, key: key, modifiers: event.modifierFlags.intersection(comparedModifiers))
    }

    private static let comparedModifiers: NSEvent.ModifierFlags =
        [.command, .option, .control, .shift]

    @MainActor
    private static func search(
        _ menu: NSMenu,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem? {
        for item in menu.items {
            var equivalent = item.keyEquivalent
            var mask = item.keyEquivalentModifierMask.intersection(comparedModifiers)
            if let first = equivalent.first, equivalent.count == 1, first.isUppercase {
                equivalent = equivalent.lowercased()
                mask.insert(.shift)
            }
            if !equivalent.isEmpty, equivalent == key, mask == modifiers { return item }
            if let submenu = item.submenu,
               let match = search(submenu, key: key, modifiers: modifiers) { return match }
        }
        return nil
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
