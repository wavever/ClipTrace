import AppKit
import SwiftUI
import SwiftData
import KeyboardShortcuts

/// Shared SwiftData container used by the SwiftUI scenes and by the floating
/// QuickPaste panel. Centralising the container guarantees the popup reads
/// from the same store the main window writes to.
@MainActor
enum AppContainer {
    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: ClipboardItem.self)
        } catch {
            fatalError("Failed to open ModelContainer: \(error)")
        }
    }()
}

/// The keystrokes that drive the QuickPaste panel's keyboard flow: `↑`/`↓`
/// move the highlight, `toggleSelectShortcut` adds/removes the highlighted
/// clip from the multi-selection, and `commitShortcut` pastes.
///
/// Deliberately *not* `KeyboardShortcuts.Name`s: that library installs a
/// system-wide Carbon hotkey for every recorded shortcut, which would hijack
/// the key everywhere (e.g. making Return unusable). We only ever match these
/// against `NSEvent`s while the panel itself is key, so they stay panel-local.
@MainActor
final class QuickPasteKeyStore: ObservableObject {
    static let shared = QuickPasteKeyStore()

    static let defaultCommit = KeyboardShortcuts.Shortcut(.return)
    static let defaultToggleSelect = KeyboardShortcuts.Shortcut(.space)

    private static let commitStorageKey = "quickPasteCommitShortcut"
    private static let toggleSelectStorageKey = "quickPasteToggleSelectShortcut"

    @Published var commitShortcut: KeyboardShortcuts.Shortcut {
        didSet { Self.persist(commitShortcut, forKey: Self.commitStorageKey) }
    }
    @Published var toggleSelectShortcut: KeyboardShortcuts.Shortcut {
        didSet { Self.persist(toggleSelectShortcut, forKey: Self.toggleSelectStorageKey) }
    }

    private init() {
        commitShortcut = Self.load(Self.commitStorageKey) ?? Self.defaultCommit
        toggleSelectShortcut = Self.load(Self.toggleSelectStorageKey) ?? Self.defaultToggleSelect
    }

    func resetCommit() { commitShortcut = Self.defaultCommit }
    func resetToggleSelect() { toggleSelectShortcut = Self.defaultToggleSelect }

    private static func load(_ key: String) -> KeyboardShortcuts.Shortcut? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
    }

    private static func persist(_ shortcut: KeyboardShortcuts.Shortcut, forKey key: String) {
        guard let encoded = try? JSONEncoder().encode(shortcut),
              let string = String(data: encoded, encoding: .utf8) else { return }
        UserDefaults.standard.set(string, forKey: key)
    }
}

@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate {
    static let shared = QuickPasteController()

    private var panel: NSPanel?
    /// App that was frontmost when we opened the panel. We re-activate it
    /// before posting the synthetic ⌘V so the keystroke lands in the right
    /// place even if focus drifted while the user picked clips.
    private var previousApp: NSRunningApplication?

    private override init() { super.init() }

    func toggle() {
        if panel != nil {
            close()
        } else {
            show()
        }
    }

    /// Show the panel hanging from a fixed anchor point (used by the Dynamic
    /// Island so the list drops straight down from the notch).
    func show(anchor: NSPoint) {
        if panel != nil { close() }
        show(topCenterAnchor: anchor)
    }

    // MARK: - Show

    private func show(topCenterAnchor: NSPoint? = nil) {
        previousApp = NSWorkspace.shared.frontmostApplication

        let items = fetchRecentItems()
        guard !items.isEmpty else {
            ToastCenter.shared.show(
                L("quickpaste.emptyClipboard"),
                systemImage: "tray",
                tint: .secondary
            )
            return
        }

        let view = QuickPasteView(
            items: items,
            onCommit: { [weak self] selected in self?.commit(selected) },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true

        let size = NSSize(width: 360, height: 440)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hosting
        panel.delegate = self

        if let topCenterAnchor {
            positionPanelTopCenter(panel, size: size, at: topCenterAnchor)
        } else {
            positionPanelAtCursor(panel, size: size)
        }
        panel.orderFrontRegardless()
        panel.makeKey()

        self.panel = panel
    }

    private func positionPanelAtCursor(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        // Anchor top-left of the panel just below-right of the cursor; flip
        // when running out of room so the panel never spills off screen.
        var origin = NSPoint(x: mouse.x + 4, y: mouse.y - size.height - 4)
        if origin.x + size.width > visible.maxX {
            origin.x = mouse.x - size.width - 4
        }
        if origin.y < visible.minY {
            origin.y = mouse.y + 4
        }
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    /// Anchor so the panel's top-center sits at `point` (used by the Dynamic
    /// Island so the list drops straight down from the notch).
    private func positionPanelTopCenter(_ panel: NSPanel, size: NSSize, at point: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height)
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func fetchRecentItems() -> [ClipboardItem] {
        let context = ModelContext(AppContainer.shared)
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 60
        let items = (try? context.fetch(descriptor)) ?? []
        // Float pinned items to the top while preserving recency within each
        // group — Bool isn't Comparable so we can't express this in SortDescriptor.
        return items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - Close

    private func close() {
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
    }

    // MARK: - Commit

    private func commit(_ items: [ClipboardItem]) {
        guard !items.isEmpty else {
            close()
            return
        }

        writePasteboard(for: items)
        close()

        let target = previousApp
        // Tiny delay so the panel really has resigned key and the prior app
        // is back in focus before the synthetic ⌘V arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            target?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !AutoPasteService.paste() {
                    // First-time users get the system prompt; everyone else
                    // gets nudged toward the Accessibility pane directly,
                    // since the common failure mode is a stale TCC entry that
                    // can only be repaired from System Settings.
                    AutoPasteService.requestTrust()
                    ToastCenter.shared.show(
                        L("quickpaste.manualPasteHint"),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        duration: 4.5
                    )
                    // Bring the Accessibility pane up a moment later so the
                    // toast has time to read; user can ignore if they already
                    // know what to do. Debounced to once per app launch so
                    // repeated Quick Paste attempts don't keep stealing focus
                    // back to System Settings.
                    if !AutoPasteService.didOfferAccessibilityRecovery {
                        AutoPasteService.didOfferAccessibilityRecovery = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            AutoPasteService.openAccessibilityPane()
                        }
                    }
                }
            }
        }
    }

    private func writePasteboard(for items: [ClipboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Tell the monitor to ignore the upcoming change tick so re-pasted
        // history items don't get bumped to the top of the list. We mark
        // **after** writing below, since we need the post-write change-count.
        defer { ClipboardMonitor.markInternalWrite() }

        if items.count == 1, let item = items.first {
            // Single-select: preserve the item's native type (image, file URL,
            // text, etc.) so paste behaves like a normal re-copy.
            switch item.itemType {
            case .text, .url, .rtf:
                pasteboard.setString(item.content, forType: .string)
            case .image:
                if let data = item.imageData {
                    pasteboard.setData(data, forType: .tiff)
                } else if let url = item.resolvedFileURL {
                    pasteboard.writeObjects([url as NSURL])
                }
            case .file, .video:
                if let url = item.resolvedFileURL {
                    pasteboard.writeObjects([url as NSURL])
                } else {
                    pasteboard.setString(item.content, forType: .string)
                }
            }
            return
        }

        // Multi-select: text-join in user's selection order. Images degrade
        // to their preview tag since they can't be concatenated as plain text.
        let joined = items.map { item -> String in
            switch item.itemType {
            case .text, .url, .rtf:
                return item.content
            case .file, .video:
                return item.resolvedFileURL?.path ?? item.content
            case .image:
                return item.resolvedFileURL?.path ?? ""
            }
        }.joined(separator: "\n")
        pasteboard.setString(joined, forType: .string)
    }

    // MARK: - NSWindowDelegate

    /// Click-outside / focus-loss dismissal.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
