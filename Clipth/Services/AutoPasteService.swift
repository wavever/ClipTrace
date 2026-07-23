import AppKit
import ApplicationServices

/// Synthesises a ⌘V keystroke targeted at whatever app is currently frontmost.
/// Requires Accessibility permission; otherwise calls fall through silently and
/// callers should surface a toast.
@MainActor
enum AutoPasteService {
    /// `true` when the app already has Accessibility permission.
    nonisolated static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// One-shot per app launch: tracks whether we've already auto-opened the
    /// Accessibility pane after a Quick Paste failure. Re-opening it on every
    /// retry within the same session is intrusive, so callers should consult
    /// (and set) this before nudging the user to System Settings.
    static var didOfferAccessibilityRecovery: Bool = false

    /// Show the system Accessibility prompt if we're not trusted yet.
    /// Does nothing when already trusted.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open the Accessibility pane in System Settings directly. Useful when
    /// recovering from a stale TCC entry: the user usually needs to *remove*
    /// the existing Clipth row and re-add the currently running binary,
    /// which is impossible from the AX permission prompt alone.
    static func openAccessibilityPane() {
        // Trigger an AX trust check first so TCC at least knows about the
        // currently running binary — without this, opening the pane may not
        // surface Clipth in the list if it was never granted before.
        _ = AXIsProcessTrusted()

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Post ⌘V to the system. Returns `false` if Accessibility is missing.
    @discardableResult
    static func paste() -> Bool {
        guard isTrusted else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }
}
