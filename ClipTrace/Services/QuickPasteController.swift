import AppKit
import SwiftUI
import SwiftData
import KeyboardShortcuts

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

/// A borderless `NSPanel` reports `canBecomeKey == false` by default, which
/// makes `makeKey()` a silent no-op — the panel never becomes the key window
/// and never receives `keyDown`, so the QuickPaste arrow-key flow is dead.
/// Overriding restores keyboard handling.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class QuickPastePanelState: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var groups: [ClipboardGroup] = []
    @Published var selectedGroupFilter: ClipboardGroupFilter = .all

    var onCommit: (_ items: [ClipboardItem], _ plainText: Bool) -> Void = { _, _ in }
    var onTogglePin: (_ item: ClipboardItem) -> Void = { _ in }
    var onSelectGroup: (_ filter: ClipboardGroupFilter) -> [ClipboardItem] = { _ in [] }
    var onCancel: () -> Void = {}

    func configure(
        items: [ClipboardItem],
        groups: [ClipboardGroup],
        onCommit: @escaping (_ items: [ClipboardItem], _ plainText: Bool) -> Void,
        onTogglePin: @escaping (_ item: ClipboardItem) -> Void,
        onSelectGroup: @escaping (_ filter: ClipboardGroupFilter) -> [ClipboardItem],
        onCancel: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onTogglePin = onTogglePin
        self.onSelectGroup = onSelectGroup
        self.onCancel = onCancel
        self.selectedGroupFilter = .all
        self.groups = groups
        self.items = items
    }

    func selectGroup(_ filter: ClipboardGroupFilter) {
        guard selectedGroupFilter != filter else { return }
        selectedGroupFilter = filter
        items = onSelectGroup(filter)
    }
}

@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate {
    static let shared = QuickPasteController()

    private var panel: NSPanel?
    private let panelState = QuickPastePanelState()
    private let context = ModelContext(AppContainer.shared)
    /// App that was frontmost when we opened the panel. We re-activate it
    /// before posting the synthetic ⌘V so the keystroke lands in the right
    /// place even if focus drifted while the user picked clips.
    private var previousApp: NSRunningApplication?

    private override init() { super.init() }

    func prewarm() {
        _ = preparePanel(size: NSSize(width: 360, height: 440))
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    /// Show the panel hanging from a fixed anchor point (used by the Dynamic
    /// Island so the list drops straight down from the notch).
    func show(anchor: NSPoint) {
        if panel?.isVisible == true { close() }
        show(topCenterAnchor: anchor)
    }

    // MARK: - Show

    private func show(topCenterAnchor: NSPoint? = nil) {
        previousApp = NSWorkspace.shared.frontmostApplication

        let groups = fetchGroups()
        let items = fetchRecentItems(groupFilter: .all)
        guard !items.isEmpty else {
            ToastCenter.shared.show(
                L("quickpaste.emptyClipboard"),
                systemImage: "tray",
                tint: .secondary
            )
            return
        }

        panelState.configure(
            items: items,
            groups: groups,
            onCommit: { [weak self] selected, plainText in
                self?.commit(selected, plainText: plainText)
            },
            onTogglePin: { [weak self] item in
                self?.togglePin(item)
            },
            onSelectGroup: { [weak self] filter in
                self?.fetchRecentItems(groupFilter: filter) ?? []
            },
            onCancel: { [weak self] in self?.cancel() }
        )

        let size = NSSize(width: 360, height: 440)
        let panel = preparePanel(size: size)

        if let topCenterAnchor {
            positionPanelTopCenter(panel, size: size, at: topCenterAnchor)
        } else {
            positionPanelAtCursor(panel, size: size)
        }
        panel.orderFrontRegardless()
        // A `.nonactivatingPanel` orders front without making our app active,
        // which leaves keyboard focus with the previously-frontmost app — so
        // arrow keys never reach the panel. Activate explicitly so the panel
        // becomes the key window; `commit`/`cancel` hand focus back after.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
    }

    /// Lazily build the floating window once and reuse it. Creating a fresh
    /// NSPanel + SwiftUI hosting tree on every global-hotkey press made the
    /// popup feel sluggish, especially on the first invocation after launch.
    /// Reuse keeps the expensive view graph warm; each show only refreshes the
    /// lightweight state array and repositions the already-built window.
    private func preparePanel(size: NSSize) -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingController(rootView: QuickPasteView(state: panelState))
        hosting.view.wantsLayer = true

        let panel = KeyablePanel(
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
        self.panel = panel
        return panel
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

    private func fetchRecentItems(groupFilter: ClipboardGroupFilter) -> [ClipboardItem] {
         switch groupFilter {
         case .all:
             var pinnedDescriptor = FetchDescriptor<ClipboardItem>(
                 predicate: #Predicate { $0.deletedAt == nil && $0.isPinned },
                 sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
             )
             Self.keepPayloadFaulted(in: &pinnedDescriptor)
             let pinned = (try? context.fetch(pinnedDescriptor)) ?? []

             var recentDescriptor = FetchDescriptor<ClipboardItem>(
                 predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false },
                 sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
             )
             recentDescriptor.fetchLimit = 60
             Self.keepPayloadFaulted(in: &recentDescriptor)
             let recent = (try? context.fetch(recentDescriptor)) ?? []

            return pinned + recent

        case .ungrouped:
            var descriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
             )
             descriptor.fetchLimit = 60
             Self.keepPayloadFaulted(in: &descriptor)
             return (try? context.fetch(descriptor)) ?? []

        case .group(let groupID):
             var descriptor = FetchDescriptor<ClipboardItem>(
                 predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw != nil },
                 sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
             )
             Self.keepPayloadFaulted(in: &descriptor)
             let candidates = (try? context.fetch(descriptor)) ?? []
             return Array(candidates.lazy.filter { $0.isInGroup(groupID) }.prefix(60))
         }
     }

     private static func keepPayloadFaulted(in descriptor: inout FetchDescriptor<ClipboardItem>) {
         descriptor.propertiesToFetch = [
             \.id,
             \.type,
             \.content,
             \.fileURL,
             \.imageUTI,
             \.imageByteCount,
             \.imagePixelWidth,
             \.imagePixelHeight,
             \.imageStorageVersion,
             \.sourceApp,
             \.createdAt,
             \.isFavorite,
             \.isPinned,
             \.preview,
             \.deletedAt,
             \.tagsRaw,
             \.customTitle,
             \.groupIDsRaw,
             \.ocrText
         ]
     }

    private func fetchGroups() -> [ClipboardGroup] {
        let descriptor = FetchDescriptor<ClipboardGroup>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt)
            ]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func togglePin(_ item: ClipboardItem) {
        ClipboardRuntime.shared.viewModel.togglePin(item)
        panelState.items = fetchRecentItems(groupFilter: panelState.selectedGroupFilter)
    }

    // MARK: - Close

    private func close() {
        panel?.orderOut(nil)
    }

    /// Dismiss without pasting and hand keyboard focus back to the app the
    /// user came from. Separate from `close()`, which also handles click-
    /// outside dismissal — re-activating there would fight the user's click.
    private func cancel() {
        let target = previousApp
        close()
        target?.activate()
    }

    // MARK: - Commit

    private func commit(_ items: [ClipboardItem], plainText: Bool = false) {
        guard !items.isEmpty else {
            close()
            return
        }

        writePasteboard(for: items, plainText: plainText)
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

    private func writePasteboard(for items: [ClipboardItem], plainText: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Tell the monitor to ignore the upcoming change tick so re-pasted
        // history items don't get bumped to the top of the list. We mark
        // **after** writing below, since we need the post-write change-count.
        defer { ClipboardMonitor.markInternalWrite() }

        if items.count == 1, let item = items.first {
            if plainText {
                pasteboard.setString(plainTextRendition(of: item), forType: .string)
                return
            }
            // Single-select: preserve the item's native type (image, file URL,
            // text, etc.) so paste behaves like a normal re-copy.
            switch item.itemType {
            case .text, .url, .rtf:
                pasteboard.setString(item.content, forType: .string)
              case .image:
                  _ = ImagePayloadStore.writeImage(
                      for: ImagePayloadStore.reference(for: item),
                      to: pasteboard
                  )
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
        // `plainText` shares the same code path here since multi-paste was
        // already string-only.
        let joined = items.map { item -> String in
            if plainText { return plainTextRendition(of: item) }
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

    /// Best-effort plain-text rendition of `item`. Mirrors `ClipboardViewModel`'s
    /// own logic so single- and multi-select plain-text pastes share semantics.
    private func plainTextRendition(of item: ClipboardItem) -> String {
        switch item.itemType {
        case .text, .url:
            return item.content
        case .rtf:
            if let data = item.content.data(using: .utf8) ?? item.content.data(using: .ascii),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtf],
                   documentAttributes: nil
               ) {
                return attributed.string
            }
            return item.content
        case .file, .video:
            return item.resolvedFileURL?.path ?? item.content
        case .image:
            if let ocr = item.ocrText, !ocr.isEmpty { return ocr }
            return item.preview ?? item.content
        }
    }

    // MARK: - NSWindowDelegate

    /// Click-outside / focus-loss dismissal.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
