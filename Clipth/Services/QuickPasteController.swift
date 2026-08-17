import AppKit
import SwiftUI
import SwiftData
import KeyboardShortcuts

/// The user-configured primary menu command plus platform-compatible aliases.
/// Shift-F10 and a hardware Contextual Menu key stay available even when the
/// primary command changes, matching the keyboard-only fallback users expect.
enum QuickPasteMenuShortcut {
    static let alternate = KeyboardShortcuts.Shortcut(.f10, modifiers: [.shift])

    static func isHardwareContextMenuEvent(_ event: NSEvent) -> Bool {
        // U+F735 is AppKit's NSMenuFunctionKey, emitted by the dedicated
        // Contextual Menu key on supported external Apple keyboards.
        event.charactersIgnoringModifiers?.unicodeScalars.first?.value == 0xF735
    }

    static func acceptedShortcuts(
        configured: KeyboardShortcuts.Shortcut
    ) -> Set<KeyboardShortcuts.Shortcut> {
        var accepted: Set<KeyboardShortcuts.Shortcut> = [configured, alternate]
        guard let key = configured.key else { return accepted }
        if key == .return {
            accepted.insert(.init(.keypadEnter, modifiers: configured.modifiers))
        } else if key == .keypadEnter {
            accepted.insert(.init(.return, modifiers: configured.modifiers))
        }
        return accepted
    }

    static func matches(
        _ event: NSEvent,
        configured: KeyboardShortcuts.Shortcut
    ) -> Bool {
        if isHardwareContextMenuEvent(event) { return true }
        guard let typed = KeyboardShortcuts.Shortcut(event: event) else { return false }
        return acceptedShortcuts(configured: configured).contains(typed)
    }
}
enum QuickPasteKeyAction: CaseIterable, Hashable {
    case commit
    case toggleSelect
    case openMenu
    case toggleFavorite
    case editGroups
    case togglePin
    case editTags
    case delete
}

/// Domain actions forwarded from the panel key catcher to the focused item.
/// Their actual keys live in `QuickPasteKeyStore`, so Settings changes take
/// effect immediately without rebuilding the AppKit responder.
enum QuickPasteItemShortcutAction: CaseIterable, Hashable {
    case toggleFavorite
    case editGroups
    case togglePin
    case editTags
    case delete

    var keyAction: QuickPasteKeyAction {
        switch self {
        case .toggleFavorite: .toggleFavorite
        case .editGroups: .editGroups
        case .togglePin: .togglePin
        case .editTags: .editTags
        case .delete: .delete
        }
    }
}

/// Paste-by-position: a plain number key commits the item at that visible row.
///
/// Nine is the ceiling because the badge has to stay one character wide to fit
/// the row's leading column, and "0" cannot honestly stand for the tenth item.
/// The positions are counted over the *visible* list, so a group view numbers
/// its own first nine rather than continuing the global sequence.
enum QuickPasteOrdinal {
    static let limit = 9

    /// The 1-based badge for a row, or `nil` past the ninth — where the badge
    /// would name a key that pastes something else.
    static func badge(forIndex index: Int) -> Int? {
        index < limit ? index + 1 : nil
    }
}

enum QuickPasteKeyAssignmentIssue {
    /// Carries the action already bound to that key so the message can name it —
    /// "this key is taken" leaves the user hunting through eight rows for the
    /// one to free up.
    case conflict(QuickPasteKeyAction)
    case reservedPanelCommand
    case menuFallbackReserved
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

    static let copyCommand = KeyboardShortcuts.Shortcut(.c, modifiers: [.command])

    @Published private var shortcuts: [QuickPasteKeyAction: KeyboardShortcuts.Shortcut]

    var commitShortcut: KeyboardShortcuts.Shortcut { shortcut(for: .commit) }
    var toggleSelectShortcut: KeyboardShortcuts.Shortcut { shortcut(for: .toggleSelect) }
    var openMenuShortcut: KeyboardShortcuts.Shortcut { shortcut(for: .openMenu) }

    private init() {
        var stored: [QuickPasteKeyAction: KeyboardShortcuts.Shortcut] = [:]
        for action in QuickPasteKeyAction.allCases {
            stored[action] = Self.load(Self.storageKey(for: action))
        }
        let prioritizesStoredMenu = stored[.openMenu] != nil
        let normalized = Self.normalizedConfiguration(
            stored: stored,
            prioritizesStoredMenu: prioritizesStoredMenu
        )
        shortcuts = normalized

        // Persist every normalized binding so introducing a new action is a
        // one-shot migration while legacy custom keys retain first priority.
        for action in QuickPasteKeyAction.allCases {
            Self.persist(normalized[action] ?? Self.defaultShortcut(for: action),
                         forKey: Self.storageKey(for: action))
        }
    }

    func shortcut(for action: QuickPasteKeyAction) -> KeyboardShortcuts.Shortcut {
        shortcuts[action] ?? Self.defaultShortcut(for: action)
    }

    func matchingItemAction(_ event: NSEvent) -> QuickPasteItemShortcutAction? {
        guard let typed = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        return QuickPasteItemShortcutAction.allCases.first {
            shortcut(for: $0.keyAction) == typed
        }
    }

    /// Whether the panel would consume this exact global hotkey, including
    /// built-in copy, menu aliases and the Option-modified plain-text commit
    /// variant.
    func captures(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        if shortcut == Self.copyCommand { return true }
        return QuickPasteKeyAction.allCases.contains { action in
            Self.acceptedShortcuts(for: self.shortcut(for: action), action: action)
                .contains(shortcut)
        }
    }

    @discardableResult
    func assign(
        _ shortcut: KeyboardShortcuts.Shortcut,
        from event: NSEvent? = nil,
        to action: QuickPasteKeyAction
    ) -> QuickPasteKeyAssignmentIssue? {
        if Self.isReservedPanelCommand(shortcut) {
            return .reservedPanelCommand
        }
        if event.map({ QuickPasteMenuShortcut.isHardwareContextMenuEvent($0) }) == true ||
            (action != .openMenu && shortcut == QuickPasteMenuShortcut.alternate) {
            return .menuFallbackReserved
        }
        if let taken = Self.conflictingAction(
            candidate: shortcut,
            action: action,
            shortcuts: shortcuts
        ) {
            return .conflict(taken)
        }

        var updated = shortcuts
        updated[action] = shortcut
        shortcuts = updated
        Self.persist(shortcut, forKey: Self.storageKey(for: action))
        return nil
    }

    @discardableResult
    func reset(_ action: QuickPasteKeyAction) -> QuickPasteKeyAssignmentIssue? {
        assign(Self.defaultShortcut(for: action), to: action)
    }

    private static func normalizedConfiguration(
        stored: [QuickPasteKeyAction: KeyboardShortcuts.Shortcut],
        prioritizesStoredMenu: Bool
    ) -> [QuickPasteKeyAction: KeyboardShortcuts.Shortcut] {
        var selected: [(action: QuickPasteKeyAction, shortcut: KeyboardShortcuts.Shortcut)] = []
        var result: [QuickPasteKeyAction: KeyboardShortcuts.Shortcut] = [:]

        func choose(_ action: QuickPasteKeyAction) -> KeyboardShortcuts.Shortcut {
            let candidates = [stored[action], defaultShortcut(for: action)].compactMap { $0 }
                + fallbackShortcuts(for: action)
                // A user can arrive with several legacy custom keys that
                // occupy another action's normal fallback. Try the familiar
                // defaults before entering the migration-only safety pool.
                + QuickPasteKeyAction.allCases.map(defaultShortcut(for:))
                + emergencyFallbacks
            guard let choice = candidates.first(where: { candidate in
                Self.isUsable(candidate, for: action) && selected.allSatisfy { existing in
                    Self.acceptedShortcuts(for: candidate, action: action).isDisjoint(
                        with: Self.acceptedShortcuts(
                            for: existing.shortcut,
                            action: existing.action
                        )
                    )
                }
            }) else {
                // More emergency candidates exist than all other actions and
                // their aliases combined, so reaching this means the routing
                // invariants changed without expanding the safety pool.
                preconditionFailure("No conflict-free Quick Paste shortcut fallback")
            }
            selected.append((action, choice))
            return choice
        }

        var order: [QuickPasteKeyAction] = prioritizesStoredMenu
            ? [.openMenu, .commit, .toggleSelect]
            : [.commit, .toggleSelect, .openMenu]
        order.append(contentsOf: [
            .toggleFavorite, .editGroups, .togglePin, .editTags, .delete
        ])
        for action in order {
            result[action] = choose(action)
        }
        return result
    }

    private static func isUsable(
        _ shortcut: KeyboardShortcuts.Shortcut,
        for action: QuickPasteKeyAction
    ) -> Bool {
        !isReservedPanelCommand(shortcut) &&
            (action == .openMenu || shortcut != QuickPasteMenuShortcut.alternate)
    }

    /// The action already holding this key (directly or through one of its
    /// aliases), if any — returned rather than a plain bool so the settings
    /// message can point at the row to change.
    private static func conflictingAction(
        candidate: KeyboardShortcuts.Shortcut,
        action: QuickPasteKeyAction,
        shortcuts: [QuickPasteKeyAction: KeyboardShortcuts.Shortcut]
    ) -> QuickPasteKeyAction? {
        let candidateSet = acceptedShortcuts(for: candidate, action: action)
        for other in QuickPasteKeyAction.allCases where other != action {
            let otherShortcut = shortcuts[other] ?? defaultShortcut(for: other)
            if !candidateSet.isDisjoint(with: acceptedShortcuts(for: otherShortcut, action: other)) {
                return other
            }
        }
        return nil
    }

    private static func acceptedShortcuts(
        for shortcut: KeyboardShortcuts.Shortcut,
        action: QuickPasteKeyAction
    ) -> Set<KeyboardShortcuts.Shortcut> {
        switch action {
        case .openMenu:
            return QuickPasteMenuShortcut.acceptedShortcuts(configured: shortcut)
        case .toggleSelect:
            return [shortcut]
        case .commit:
            var accepted: Set<KeyboardShortcuts.Shortcut> = [shortcut]
            if let key = shortcut.key, !shortcut.modifiers.contains(.option) {
                accepted.insert(.init(key, modifiers: shortcut.modifiers.union(.option)))
            }
            return accepted
        case .toggleFavorite, .editGroups, .togglePin, .editTags, .delete:
            return [shortcut]
        }
    }

    private static func isReservedPanelCommand(
        _ shortcut: KeyboardShortcuts.Shortcut
    ) -> Bool {
        guard let key = shortcut.key else { return true }
        if key == .leftArrow || key == .rightArrow || key == .upArrow ||
            key == .downArrow || key == .escape {
            return true
        }
        let modifiers = shortcut.modifiers.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, quickPasteNumberKeys.contains(key) { return true }
        // ⌘+ / ⌘− expand and collapse the panel's shortcut guide. `+` is
        // physically ⌘⇧= on most layouts, so the equals key is reserved with
        // and without Shift rather than only in one of the two spellings.
        if key == .equal || key == .minus,
           modifiers == [.command] || modifiers == [.command, .shift] {
            return true
        }
        return (key == .f || key == .c) && modifiers == [.command]
    }

    /// Kept in step with `QuickPasteOrdinal.limit` by hand: `Key` is a struct of
    /// static constants, not an enumerable sequence, so the digits cannot be
    /// derived from the ceiling.
    private static let quickPasteNumberKeys: Set<KeyboardShortcuts.Key> = [
        .one, .two, .three, .four, .five, .six, .seven, .eight, .nine,
        .keypad1, .keypad2, .keypad3, .keypad4, .keypad5,
        .keypad6, .keypad7, .keypad8, .keypad9
    ]

    /// A migration-only pool. Sixteen distinct modified function keys exceed
    /// the seven other actions plus commit/menu aliases, so normalization can
    /// always preserve a reachable, unique binding instead of duplicating one.
    private static let emergencyFallbacks: [KeyboardShortcuts.Shortcut] = [
        .init(.f1, modifiers: [.control, .option, .shift]),
        .init(.f2, modifiers: [.control, .option, .shift]),
        .init(.f3, modifiers: [.control, .option, .shift]),
        .init(.f4, modifiers: [.control, .option, .shift]),
        .init(.f5, modifiers: [.control, .option, .shift]),
        .init(.f6, modifiers: [.control, .option, .shift]),
        .init(.f7, modifiers: [.control, .option, .shift]),
        .init(.f8, modifiers: [.control, .option, .shift]),
        .init(.f9, modifiers: [.control, .option, .shift]),
        .init(.f10, modifiers: [.control, .option, .shift]),
        .init(.f11, modifiers: [.control, .option, .shift]),
        .init(.f12, modifiers: [.control, .option, .shift]),
        .init(.f13, modifiers: [.control, .option, .shift]),
        .init(.f14, modifiers: [.control, .option, .shift]),
        .init(.f15, modifiers: [.control, .option, .shift]),
        .init(.f16, modifiers: [.control, .option, .shift])
    ]

    private static func defaultShortcut(
        for action: QuickPasteKeyAction
    ) -> KeyboardShortcuts.Shortcut {
        switch action {
        case .commit: .init(.return)
        case .toggleSelect: .init(.space)
        case .openMenu: .init(.return, modifiers: [.control])
        case .toggleFavorite: .init(.d, modifiers: [.command])
        case .editGroups: .init(.g, modifiers: [.command, .option])
        case .togglePin: .init(.p, modifiers: [.command, .option])
        case .editTags: .init(.t, modifiers: [.command, .option])
        case .delete: .init(.delete, modifiers: [.command])
        }
    }

    private static func fallbackShortcuts(
        for action: QuickPasteKeyAction
    ) -> [KeyboardShortcuts.Shortcut] {
        switch action {
        case .commit:
            [.init(.return, modifiers: [.command]),
             .init(.return, modifiers: [.command, .shift])]
        case .toggleSelect:
            [.init(.space, modifiers: [.control]),
             .init(.space, modifiers: [.shift]),
             .init(.space, modifiers: [.command, .option])]
        case .openMenu:
            [QuickPasteMenuShortcut.alternate,
             .init(.return, modifiers: [.control, .shift])]
        case .toggleFavorite:
            [.init(.d, modifiers: [.command, .shift]),
             .init(.d, modifiers: [.control, .option])]
        case .editGroups:
            [.init(.g, modifiers: [.command, .shift]),
             .init(.g, modifiers: [.control, .option])]
        case .togglePin:
            [.init(.p, modifiers: [.command, .shift]),
             .init(.p, modifiers: [.control, .option])]
        case .editTags:
            [.init(.t, modifiers: [.command, .shift]),
             .init(.t, modifiers: [.control, .option])]
        case .delete:
            [.init(.delete, modifiers: [.command, .shift]),
             .init(.delete, modifiers: [.control, .option])]
        }
    }

    private static func storageKey(for action: QuickPasteKeyAction) -> String {
        switch action {
        case .commit: "quickPasteCommitShortcut"
        case .toggleSelect: "quickPasteToggleSelectShortcut"
        case .openMenu: "quickPasteOpenMenuShortcut"
        case .toggleFavorite: "quickPasteFavoriteShortcut"
        case .editGroups: "quickPasteGroupsShortcut"
        case .togglePin: "quickPastePinShortcut"
        case .editTags: "quickPasteTagsShortcut"
        case .delete: "quickPasteDeleteShortcut"
        }
    }

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
    /// Debounced query currently narrowing `items` (set via `updateSearch`).
    @Published private(set) var searchQuery = ""
    /// Bumped on every `configure` so the reused panel's view can reset
    /// transient search state (draft text, field focus) between invocations.
    @Published private(set) var session = 0

    var onCommit: (_ items: [ClipboardItem], _ plainText: Bool) -> Void = { _, _ in }
    var onCopy: (_ items: [ClipboardItem]) -> Void = { _ in }
    /// Single data source for the list: empty query means the recents feed
    /// for `filter`, anything else a bounded search within it.
    var onQuery: (_ filter: ClipboardGroupFilter, _ query: String) -> [ClipboardItem] = { _, _ in [] }
    var onQueryGroups: () -> [ClipboardGroup] = { [] }
    var onCancel: () -> Void = {}

    func configure(
        items: [ClipboardItem],
        groups: [ClipboardGroup],
        onCommit: @escaping (_ items: [ClipboardItem], _ plainText: Bool) -> Void,
        onCopy: @escaping (_ items: [ClipboardItem]) -> Void,
        onQuery: @escaping (_ filter: ClipboardGroupFilter, _ query: String) -> [ClipboardItem],
        onQueryGroups: @escaping () -> [ClipboardGroup],
        onCancel: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onCopy = onCopy
        self.onQuery = onQuery
        self.onQueryGroups = onQueryGroups
        self.onCancel = onCancel
        self.selectedGroupFilter = .all
        self.searchQuery = ""
        self.session &+= 1
        self.groups = groups
        self.items = items
    }

    func selectGroup(_ filter: ClipboardGroupFilter) {
        guard selectedGroupFilter != filter else { return }
        selectedGroupFilter = filter
        items = onQuery(filter, searchQuery)
    }

    func updateSearch(_ query: String) {
        guard query != searchQuery else { return }
        searchQuery = query
        items = onQuery(selectedGroupFilter, query)
    }

    /// Context-menu mutations can change ordering, filter membership or the
    /// group catalog, so refresh both snapshots through the controller-owned
    /// context instead of assuming an observed property change is sufficient.
    func reloadSnapshot() {
        groups = onQueryGroups()
        items = onQuery(selectedGroupFilter, searchQuery)
    }
}

@MainActor
final class QuickPasteController: NSObject, NSWindowDelegate {
    static let shared = QuickPasteController()

    private var panel: NSPanel?
    private let panelState = QuickPastePanelState()
    private let itemContextMenu = ClipboardItemContextMenuCoordinator()
    private let context = ModelContext(AppContainer.shared)
    private var appResignObserver: NSObjectProtocol?
    private var sheetResignObserver: NSObjectProtocol?
    private var pausedGlobalShortcuts: [KeyboardShortcuts.Name] = []
    /// App that was frontmost when we opened the panel. We re-activate it
    /// before posting the synthetic ⌘V so the keystroke lands in the right
    /// place even if focus drifted while the user picked clips.
    private var previousApp: NSRunningApplication?

    private override init() {
        super.init()
        itemContextMenu.onPresentationEnd = { [weak self] in
            self?.contextMenuPresentationDidEnd()
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        sheetResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let sheet = notification.object as? NSWindow,
                      self.panel?.attachedSheet === sheet,
                      self.itemContextMenu.isPresentingSheet else { return }
                self.close()
            }
        }
    }

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
            onCopy: { [weak self] selected in
                self?.copy(selected)
            },
            onQuery: { [weak self] filter, query in
                self?.fetchItems(groupFilter: filter, query: query) ?? []
            },
            onQueryGroups: { [weak self] in
                self?.fetchGroups() ?? []
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
        pauseConflictingGlobalShortcuts()
        panel.orderFrontRegardless()
        // A `.nonactivatingPanel` orders front without making our app active,
        // which leaves keyboard focus with the previously-frontmost app — so
        // arrow keys never reach the panel. Activate explicitly so the panel
        // becomes the key window; `commit`/`cancel` hand focus back after.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel

        // Since macOS 14, activation is cooperative and completes a runloop
        // turn (or more) after the request, so the `makeKey()` above can run
        // while the previous app is still active — the panel shows but stays
        // deaf to the keyboard. In practice this bites on external displays,
        // where the timing loses more often. Re-assert until key sticks.
        reassertKey(panel)
    }

    /// Companion to `show`: retries activate + makeKey for a few ticks, since
    /// one attempt isn't guaranteed to land under cooperative activation.
    /// Stops as soon as the panel is key or has been dismissed.
    private func reassertKey(_ panel: NSPanel, attempt: Int = 0) {
        guard self.panel === panel, panel.isVisible else { return }
        if panel.isKeyWindow || itemContextMenu.isPresentingSheet || panel.attachedSheet != nil {
            return
        }
        guard attempt < 6 else {
            // A visible panel without keyboard focus cannot fulfill its
            // keyboard-only contract. Closing also restores any conflicting
            // global shortcuts paused for this presentation.
            close()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.panel === panel,
                  panel.isVisible,
                  !self.itemContextMenu.isPresentingSheet,
                  panel.attachedSheet == nil,
                  !panel.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            self.reassertKey(panel, attempt: attempt + 1)
        }
    }

    /// Lazily build the floating window once and reuse it. Creating a fresh
    /// NSPanel + SwiftUI hosting tree on every global-hotkey press made the
    /// popup feel sluggish, especially on the first invocation after launch.
    /// Reuse keeps the expensive view graph warm; each show only refreshes the
    /// lightweight state array and repositions the already-built window.
    private func preparePanel(size: NSSize) -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingController(
            rootView: QuickPasteView(
                state: panelState,
                itemContextMenu: itemContextMenu
            )
        )
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
        // With “Displays have separate Spaces” every screen runs its own
        // active Space. A panel pinned to the Space it was first shown on can
        // be summoned on another display yet stay un-keyable there. Joining
        // all Spaces keeps it on whichever Space is active where it appears,
        // fullscreen apps included.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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

    /// One entry point for the panel's list: an empty query keeps the recents
    /// feed, anything else swaps to the bounded search fetch.
    private func fetchItems(groupFilter: ClipboardGroupFilter, query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fetchRecentItems(groupFilter: groupFilter) }
        return fetchSearchResults(groupFilter: groupFilter, query: trimmed)
    }

    /// Same shape as `fetchRecentItems`, but matching in SQLite via the shared
    /// search predicate — never an unbounded fetch filtered in memory.
    private func fetchSearchResults(groupFilter: ClipboardGroupFilter, query: String) -> [ClipboardItem] {
        var descriptor = ClipboardHistorySearch.descriptor(groupFilter: groupFilter, query: query)
        if case .group(let groupID) = groupFilter {
            Self.keepPayloadFaulted(in: &descriptor)
            let candidates = (try? context.fetch(descriptor)) ?? []
            return Array(candidates.lazy.filter { $0.isInGroup(groupID) }.prefix(60))
        }
        descriptor.fetchLimit = 60
        Self.keepPayloadFaulted(in: &descriptor)
        return (try? context.fetch(descriptor)) ?? []
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

    // MARK: - Close

    private func close() {
        // The dwell preview floats beside this panel and must never outlive
        // it — commit paths order the panel out without a resign-key tick.
        HoverPreviewController.shared.hide()
        itemContextMenu.resetPresentation()
        if let panel, let sheet = panel.attachedSheet {
            panel.endSheet(sheet)
        }
        panel?.orderOut(nil)
        resumePausedGlobalShortcuts()
    }

    /// Carbon hotkeys are evaluated before the panel's AppKit responder chain.
    /// Temporarily unregister only the global commands that the visible panel
    /// would consume, then restore exactly those that were enabled beforehand.
    private func pauseConflictingGlobalShortcuts() {
        resumePausedGlobalShortcuts()
        let keyStore = QuickPasteKeyStore.shared
        for appShortcut in AppShortcut.allCases {
            let name = appShortcut.name
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name),
                  keyStore.captures(shortcut),
                  AppShortcutActivation.isEnabled(name) else { continue }
            KeyboardShortcuts.disable(name)
            pausedGlobalShortcuts.append(name)
        }
    }

    private func resumePausedGlobalShortcuts() {
        guard !pausedGlobalShortcuts.isEmpty else { return }
        KeyboardShortcuts.enable(pausedGlobalShortcuts)
        pausedGlobalShortcuts.removeAll(keepingCapacity: true)
    }

    /// Returning from a context-menu sheet should hand keyboard navigation
    /// back to the reused panel. If the app deactivated meanwhile, the app
    /// resign observer has already closed it instead.
    private func contextMenuPresentationDidEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel,
                  NSApp.isActive,
                  panel.isVisible,
                  !self.itemContextMenu.isPresentingSheet,
                  panel.attachedSheet == nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            self.reassertKey(panel)
        }
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

    /// Copy keeps the panel active. Single items deliberately use the same
    /// path as the menu-bar button (including trim preferences and native
    /// payloads); multi-selection reuses the ordered Quick Paste writer.
    private func copy(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        if items.count == 1, let item = items.first {
            ClipboardRuntime.shared.viewModel.copyToClipboard(item)
        } else {
            writePasteboard(for: items)
        }
    }

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
                pasteboard.setString(pasteText(plainTextRendition(of: item), type: .text), forType: .string)
                return
            }
            // Single-select: preserve the item's native type (image, file URL,
            // text, etc.) so paste behaves like a normal re-copy.
            switch item.itemType {
            case .text, .url, .rtf:
                pasteboard.setString(pasteText(item.content, type: item.itemType), forType: .string)
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
        pasteboard.setString(pasteText(joined, type: .text), forType: .string)
    }

    /// Hand outgoing text to the paste-time rule chain. Quick Paste knows
    /// exactly which app the text is heading for (`previousApp`), which is the
    /// signal an app-scoped paste rule needs.
    private func pasteText(_ text: String, type: ClipboardItemType) -> String {
        ClipboardRuntime.shared.viewModel.applyPasteRules(
            to: text,
            type: type,
            targetBundleId: previousApp?.bundleIdentifier ?? ""
        )
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
        guard let window = notification.object as? NSWindow else {
            close()
            return
        }
        // The target flips synchronously before SwiftUI begins attaching its
        // sheet, making this guard deterministic even if AppKit's key-window
        // notification arrives before `attachedSheet` is populated.
        guard !itemContextMenu.isPresentingSheet else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  !self.itemContextMenu.isPresentingSheet,
                  window.attachedSheet == nil,
                  !window.isKeyWindow else { return }
            self.close()
        }
    }
}
