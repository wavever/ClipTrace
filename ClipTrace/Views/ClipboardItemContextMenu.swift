import SwiftUI
import SwiftData
import AppKit

/// A targeted, monotonic request lets the currently materialized lazy row
/// open its menu from the keyboard using that row's real AppKit screen frame.
struct ClipboardItemContextMenuKeyboardRequest: Equatable {
    let itemID: UUID
    let sequence: Int
}

/// Owns the complete clipboard-item context-menu flow for any history surface.
/// The main window, menu-bar panel and Quick Paste panel all route through this
/// coordinator so menu availability, mutations and feedback cannot drift apart.
@MainActor
final class ClipboardItemContextMenuCoordinator: ObservableObject {
    @Published fileprivate var renameTarget: ClipboardItem?
    @Published fileprivate var barcodeScanTarget: ClipboardItem?
    @Published fileprivate var qrPreviewTarget: ClipboardItem?
    @Published fileprivate var newGroupTarget: ClipboardItem?
    @Published fileprivate var deleteTarget: ClipboardItem?

    fileprivate let menu = PaperContextMenuController()

    private let vm = ClipboardRuntime.shared.viewModel
    private var groupsAtOpen: [ClipboardGroup] = []
    private var onMutation: () -> Void = {}
    var onPresentationEnd: () -> Void = {}
    var onPresentationChange: (Bool) -> Void = { _ in }

    var isPresentingSheet: Bool {
        renameTarget != nil || barcodeScanTarget != nil || qrPreviewTarget != nil ||
        newGroupTarget != nil || deleteTarget != nil
    }

    var isMenuOpen: Bool { menu.isOpen }

    /// Opens the shared paper menu at the click location. The item's own model
    /// context is used for every mutation because the menu-bar and Quick Paste
    /// snapshots deliberately live in explicit contexts rather than `@Query`.
    func open(
        item: ClipboardItem,
        groups: [ClipboardGroup],
        at screenPoint: CGPoint,
        in window: NSWindow,
        surfaceStyle: PaperContextMenuSurfaceStyle = .paper,
        keyboardInitiated: Bool = false,
        onMutation: @escaping () -> Void = {}
    ) {
        HoverPreviewController.shared.hide()
        groupsAtOpen = groups
        self.onMutation = onMutation
        let keyboard = ClipboardItemContextMenuKeyboardState(
            focusesFirstItem: keyboardInitiated
        )

        let dismissThen: (@escaping () -> Void) -> () -> Void = { [weak self] action in
            {
                self?.menu.close()
                action()
            }
        }

        menu.open(
            at: screenPoint,
            in: window,
            width: 232,
            keyboardHandler: { keyboard.handle($0) },
            onClose: { keyboard.reset() }
        ) { [weak self] in
            ClipboardItemContextMenuView(
                controller: self?.menu ?? PaperContextMenuController(),
                keyboard: keyboard,
                item: item,
                groups: groups,
                onCopy: dismissThen { [weak self] in self?.copy(item) },
                onCopyPlainText: dismissThen { [weak self] in self?.copyPlainText(item) },
                onPreviewQRCode: dismissThen { [weak self] in self?.presentQRCode(for: item) },
                onScanCodes: dismissThen { [weak self] in self?.presentBarcodeScan(for: item) },
                onBase64Encode: dismissThen { [weak self] in self?.encodeBase64(item) },
                onBase64Decode: dismissThen { [weak self] in self?.decodeBase64(item) },
                onRunRule: { [weak self] rule in
                    self?.menu.close()
                    self?.run(rule, on: item)
                },
                onRename: dismissThen { [weak self] in self?.presentRename(for: item) },
                onToggleGroup: { [weak self] group in self?.toggleGroup(group, for: item) },
                onClearGroups: { [weak self] in self?.clearGroups(for: item) },
                onNewGroup: dismissThen { [weak self] in self?.presentNewGroup(for: item) },
                onOpenInBrowser: dismissThen { Self.openInBrowser(item.content) },
                onReveal: dismissThen { Self.reveal(item) },
                onOpenFile: dismissThen { Self.openFile(item) },
                onOpenWith: dismissThen { Self.openWith(item) },
                onToggleFavorite: dismissThen { [weak self] in self?.toggleFavorite(item) },
                onTogglePin: dismissThen { [weak self] in self?.togglePin(item) },
                onExport: dismissThen { ExportService.shared.exportItem(item) },
                onDelete: dismissThen { [weak self] in self?.presentDelete(for: item) }
            )
            .paperContextMenuSurfaceStyle(surfaceStyle)
        }
    }

    fileprivate func commitRename(_ title: String, for item: ClipboardItem) {
        guard let context = item.modelContext else {
            renameTarget = nil
            return
        }
        vm.rename(item, to: title, context: context)
        renameTarget = nil
        notifyMutation()
    }

    fileprivate func commitNewGroup(named name: String, for item: ClipboardItem) {
        guard let context = item.modelContext else {
            newGroupTarget = nil
            return
        }
        guard let group = vm.createGroup(named: name, groups: groupsAtOpen, context: context) else {
            newGroupTarget = nil
            return
        }
        vm.assign([item], to: group, context: context)
        newGroupTarget = nil
        ToastCenter.shared.show(
            L("group.movedToFormat", group.displayName),
            systemImage: "folder.fill",
            tint: .appAccent
        )
        notifyMutation()
    }

    fileprivate func confirmDelete(_ item: ClipboardItem) {
        guard let context = item.modelContext else {
            deleteTarget = nil
            return
        }
        vm.deleteItem(item, context: context)
        deleteTarget = nil
        ToastCenter.shared.show(L("common.deleted"), systemImage: "trash.fill", tint: .red)
        notifyMutation()
    }

    fileprivate func defaultDisplayTitle(for item: ClipboardItem) -> String {
        if let url = item.resolvedFileURL { return url.lastPathComponent }
        // Keep the rename placeholder useful without exposing content that the
        // protection layer intentionally masks elsewhere in the interface.
        let firstLine = item.redactedForDisplay(item.preview ?? item.content)
            .components(separatedBy: .newlines)
            .first ?? ""
        return firstLine.isEmpty ? item.itemType.displayName : firstLine
    }

    func close() {
        menu.close()
    }

    /// Clears any pending sheet target as well as the paper menu. Explicit
    /// panel teardown uses this because reused AppKit hosts may not make their
    /// SwiftUI root disappear when merely ordered out.
    func resetPresentation() {
        let wasPresenting = isPresentingSheet
        menu.close()
        renameTarget = nil
        barcodeScanTarget = nil
        qrPreviewTarget = nil
        newGroupTarget = nil
        deleteTarget = nil
        groupsAtOpen = []
        onMutation = {}
        if wasPresenting { onPresentationChange(false) }
    }

    fileprivate func presentationDidEnd() {
        guard !isPresentingSheet else { return }
        onPresentationChange(false)
        onPresentationEnd()
    }

    private func presentRename(for item: ClipboardItem) {
        renameTarget = item
        onPresentationChange(true)
    }

    private func presentBarcodeScan(for item: ClipboardItem) {
        barcodeScanTarget = item
        onPresentationChange(true)
    }

    private func presentQRCode(for item: ClipboardItem) {
        qrPreviewTarget = item
        onPresentationChange(true)
    }

    private func presentNewGroup(for item: ClipboardItem) {
        newGroupTarget = item
        onPresentationChange(true)
    }

    private func presentDelete(for item: ClipboardItem) {
        deleteTarget = item
        onPresentationChange(true)
    }

    private func copy(_ item: ClipboardItem) {
        vm.copyToClipboard(item)
        ToastCenter.shared.show(L("common.copied"))
    }

    private func copyPlainText(_ item: ClipboardItem) {
        vm.copyAsPlainText(item)
        ToastCenter.shared.show(L("common.copiedPlainText"))
    }

    private func encodeBase64(_ item: ClipboardItem) {
        if vm.copyBase64Encoded(item) {
            ToastCenter.shared.show(L("action.base64Encoded"), systemImage: "doc.on.doc")
        }
    }

    private func decodeBase64(_ item: ClipboardItem) {
        if vm.copyBase64Decoded(item) {
            ToastCenter.shared.show(L("action.base64Decoded"), systemImage: "doc.on.doc")
        } else {
            ToastCenter.shared.show(
                L("action.base64DecodeFailed"),
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
    }

    private func run(_ rule: ScriptingRule, on item: ClipboardItem) {
        guard let context = item.modelContext else { return }
        vm.runRuleManually(rule, on: item, context: context) { [weak self] in
            self?.notifyMutation()
        }
    }

    private func toggleGroup(_ group: ClipboardGroup, for item: ClipboardItem) {
        guard let context = item.modelContext else { return }
        let wasMember = item.isInGroup(group.id)
        vm.toggleGroup(item, group: group, context: context)
        ToastCenter.shared.show(
            wasMember
                ? L("group.removedFromFormat", group.displayName)
                : L("group.addedToFormat", group.displayName),
            systemImage: wasMember ? "folder.badge.minus" : "folder.fill",
            tint: .appAccent
        )
        notifyMutation()
    }

    private func clearGroups(for item: ClipboardItem) {
        guard let context = item.modelContext else { return }
        vm.clearGroups(item, context: context)
        ToastCenter.shared.show(L("group.removedFromGroup"), systemImage: "folder.badge.minus")
        notifyMutation()
    }

    private func toggleFavorite(_ item: ClipboardItem) {
        let willFavorite = !item.isFavorite
        vm.toggleFavorite(item)
        ToastCenter.shared.show(
            willFavorite ? L("action.favorited") : L("action.unfavorited"),
            systemImage: "star.fill",
            tint: .yellow
        )
        notifyMutation()
    }

    private func togglePin(_ item: ClipboardItem) {
        let willPin = !item.isPinned
        vm.togglePin(item)
        ToastCenter.shared.show(
            willPin ? L("action.pinned") : L("action.unpinned"),
            systemImage: "pin.fill",
            tint: .orange
        )
        notifyMutation()
    }

    private func notifyMutation() {
        onMutation()
    }

    private static func openInBrowser(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let url = URL(string: candidate) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func reveal(_ item: ClipboardItem) {
        if let url = item.resolvedFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func openFile(_ item: ClipboardItem) {
        if let url = item.resolvedFileURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openWith(_ item: ClipboardItem) {
        if let url = item.resolvedFileURL {
            FileOpener.openWithChooser(url: url)
        }
    }
}

extension View {
    /// Adds only the right-click source to a row/card. One coordinator is owned
    /// by the surrounding surface, so list and grid presentations share menu
    /// state and only one paper menu can be open there at a time.
    func clipboardItemContextMenu(
        item: ClipboardItem,
        groups: [ClipboardGroup],
        coordinator: ClipboardItemContextMenuCoordinator,
        surfaceStyle: PaperContextMenuSurfaceStyle = .paper,
        keyboardRequest: ClipboardItemContextMenuKeyboardRequest? = nil,
        onKeyboardRequestHandled: @escaping () -> Void = {},
        onMutation: @escaping () -> Void = {}
    ) -> some View {
        overlay(
            RightClickCatcher(
                keyboardRequestSequence: keyboardRequest?.itemID == item.id
                    ? keyboardRequest?.sequence
                    : nil,
                onKeyboardRequest: { screenPoint, window in
                    coordinator.open(
                        item: item,
                        groups: groups,
                        at: screenPoint,
                        in: window,
                        surfaceStyle: surfaceStyle,
                        keyboardInitiated: true,
                        onMutation: onMutation
                    )
                    onKeyboardRequestHandled()
                },
                onRightClick: { screenPoint, window in
                    coordinator.open(
                        item: item,
                        groups: groups,
                        at: screenPoint,
                        in: window,
                        surfaceStyle: surfaceStyle,
                        onMutation: onMutation
                    )
                }
            )
        )
    }

    /// Hosts the sheets and destructive confirmation required by the shared
    /// menu. Attach once to the root of each surface, not to every lazy row.
    func clipboardItemContextMenuPresenter(
        _ coordinator: ClipboardItemContextMenuCoordinator
    ) -> some View {
        modifier(ClipboardItemContextMenuPresenter(coordinator: coordinator))
    }
}

private struct ClipboardItemContextMenuPresenter: ViewModifier {
    @ObservedObject var coordinator: ClipboardItemContextMenuCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(item: $coordinator.renameTarget, onDismiss: coordinator.presentationDidEnd) { item in
                ClipboardRenameSheet(
                    initialTitle: item.effectiveCustomTitle ?? "",
                    fallback: coordinator.defaultDisplayTitle(for: item),
                    onCommit: { coordinator.commitRename($0, for: item) },
                    onCancel: { coordinator.renameTarget = nil }
                )
            }
            .sheet(item: $coordinator.barcodeScanTarget, onDismiss: coordinator.presentationDidEnd) { item in
                BarcodeResultView(item: item, onClose: { coordinator.barcodeScanTarget = nil })
            }
            .sheet(item: $coordinator.qrPreviewTarget, onDismiss: coordinator.presentationDidEnd) { item in
                TextQRCodePreviewView(item: item, onClose: { coordinator.qrPreviewTarget = nil })
            }
            .sheet(item: $coordinator.newGroupTarget, onDismiss: coordinator.presentationDidEnd) { item in
                ClipboardNewGroupSheet(
                    onCommit: { coordinator.commitNewGroup(named: $0, for: item) },
                    onCancel: { coordinator.newGroupTarget = nil }
                )
            }
            .sheet(item: $coordinator.deleteTarget, onDismiss: coordinator.presentationDidEnd) { item in
                let request = ConfirmRequest(
                    title: L("confirm.deleteItem.title"),
                    message: FilterSettingsStore.shared.trashEnabled
                        ? L("confirm.deleteItem.message")
                        : L("confirm.permanent.message"),
                    confirmLabel: L("common.delete"),
                    cancelLabel: L("common.cancel"),
                    icon: "trash",
                    isDestructive: true,
                    action: { coordinator.confirmDelete(item) }
                )
                ConfirmationDialogView(
                    request: request,
                    onConfirm: request.action,
                    onCancel: { coordinator.deleteTarget = nil }
                )
                .padding(18)
                .background(Color.appPaper)
            }
            .onDisappear { coordinator.resetPresentation() }
    }
}

private struct ClipboardRenameSheet: View {
    let initialTitle: String
    let fallback: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.appAccent)
                Text(L("rename.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Text(L("rename.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField(fallback, text: $draft)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .paperTextField(focused: focused)

            HStack {
                Spacer()
                Button(L("common.cancel"), action: onCancel)
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save")) { onCommit(draft) }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            draft = initialTitle
            focused = true
        }
    }
}

private struct ClipboardNewGroupSheet: View {
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.appAccent)
                Text(L("group.create.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Text(L("group.editor.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField(L("group.name.placeholder"), text: $draft)
                .focused($focused)
                .onSubmit { onCommit(draft) }
                .paperTextField(focused: focused)

            HStack {
                Spacer()
                Button(L("common.cancel"), action: onCancel)
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)
                Button(L("common.add")) { onCommit(draft) }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

private enum ClipboardItemContextMenuRootEntry: Hashable {
    case copy
    case copyPlainText
    case previewQRCode
    case scanCodes
    case base64Encode
    case base64Decode
    case runRule(UUID)
    case rename
    case groups
    case newGroup
    case openInBrowser
    case reveal
    case openFile
    case openWith
    case toggleFavorite
    case togglePin
    case export
    case delete
}

private enum ClipboardGroupContextMenuEntry: Hashable {
    case group(UUID)
    case clear
    case newGroup
}

/// Routes keys while the nonactivating menu panels remain visually above the
/// key Quick Paste window. Keeping focus in the parent avoids the resign-key
/// lifecycle that would otherwise dismiss the entire Quick Paste panel.
@MainActor
private final class ClipboardItemContextMenuKeyboardState: ObservableObject {
    private enum Level { case root, groups }

    @Published private(set) var focusedRoot: ClipboardItemContextMenuRootEntry?
    @Published private(set) var focusedGroup: ClipboardGroupContextMenuEntry?

    private let focusesFirstItem: Bool
    private var level = Level.root
    private var rootEntries: [ClipboardItemContextMenuRootEntry] = []
    private var groupEntries: [ClipboardGroupContextMenuEntry] = []
    private var activateRoot: ((ClipboardItemContextMenuRootEntry) -> Void)?
    private var activateGroup: ((ClipboardGroupContextMenuEntry) -> Void)?
    private var openSubmenu: (() -> Void)?
    private var closeSubmenu: (() -> Void)?
    private var dismiss: (() -> Void)?
    private var cleanup: (() -> Void)?
    private var pendingActivationKeyCode: UInt16?

    init(focusesFirstItem: Bool) {
        self.focusesFirstItem = focusesFirstItem
    }

    func configure(
        rootEntries: [ClipboardItemContextMenuRootEntry],
        groupEntries: [ClipboardGroupContextMenuEntry],
        activateRoot: @escaping (ClipboardItemContextMenuRootEntry) -> Void,
        activateGroup: @escaping (ClipboardGroupContextMenuEntry) -> Void,
        openSubmenu: @escaping () -> Void,
        closeSubmenu: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        cleanup: @escaping () -> Void
    ) {
        self.rootEntries = rootEntries
        self.groupEntries = groupEntries
        self.activateRoot = activateRoot
        self.activateGroup = activateGroup
        self.openSubmenu = openSubmenu
        self.closeSubmenu = closeSubmenu
        self.dismiss = dismiss
        self.cleanup = cleanup
        if focusesFirstItem, focusedRoot == nil {
            focusedRoot = rootEntries.first
        }
    }

    func updateGroupEntries(_ entries: [ClipboardGroupContextMenuEntry]) {
        groupEntries = entries
        if let focusedGroup, !entries.contains(focusedGroup) {
            self.focusedGroup = entries.first
        }
    }

    func reset() {
        let cleanup = cleanup
        rootEntries = []
        groupEntries = []
        activateRoot = nil
        activateGroup = nil
        openSubmenu = nil
        closeSubmenu = nil
        dismiss = nil
        self.cleanup = nil
        pendingActivationKeyCode = nil
        cleanup?()
    }

    func isFocused(_ entry: ClipboardItemContextMenuRootEntry) -> Bool {
        level == .root && focusedRoot == entry
    }

    func isFocused(_ entry: ClipboardGroupContextMenuEntry) -> Bool {
        level == .groups && focusedGroup == entry
    }

    func submenuDidClose() {
        guard level == .groups else { return }
        level = .root
        focusedGroup = nil
        focusedRoot = .groups
    }

    /// Returns true for every menu-local key while the menu is open so a
    /// customized Quick Paste commit/select key cannot act on the list behind
    /// the menu. Only the conventional app-wide Quit command passes through.
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            if pendingActivationKeyCode == event.keyCode {
                pendingActivationKeyCode = nil
                activateFocusedEntry()
            }
            return true
        }
        if event.keyCode != 36, event.keyCode != 76, event.keyCode != 49 {
            pendingActivationKeyCode = nil
        }

        switch event.keyCode {
        case 53: // Esc: back out of the submenu before dismissing the root.
            if level == .groups {
                leaveGroups()
            } else {
                dismiss?()
            }
            return true
        case 126: // ↑
            move(by: -1)
            return true
        case 125: // ↓
            move(by: 1)
            return true
        case 123: // ←
            if level == .groups { leaveGroups() }
            return true
        case 124: // →
            if level == .root, focusedRoot == .groups { enterGroups() }
            return true
        case 36, 76, 49: // Return, keypad Enter, Space
            if !event.isARepeat { pendingActivationKeyCode = event.keyCode }
            return true
        case 48: // Tab / Shift-Tab mirrors Down / Up.
            move(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 115: // Home
            focusBoundary(first: true)
            return true
        case 119: // End
            focusBoundary(first: false)
            return true
        default:
            let isQuit = event.modifierFlags.contains(.command) &&
                event.charactersIgnoringModifiers?.lowercased() == "q"
            return !isQuit
        }
    }

    private func move(by delta: Int) {
        switch level {
        case .root:
            focusedRoot = movedSelection(in: rootEntries, from: focusedRoot, by: delta)
            focusedGroup = nil
            if focusedRoot != .groups { closeSubmenu?() }
        case .groups:
            focusedGroup = movedSelection(in: groupEntries, from: focusedGroup, by: delta)
        }
    }

    private func focusBoundary(first: Bool) {
        switch level {
        case .root:
            focusedRoot = first ? rootEntries.first : rootEntries.last
            if focusedRoot != .groups { closeSubmenu?() }
        case .groups:
            focusedGroup = first ? groupEntries.first : groupEntries.last
        }
    }

    private func movedSelection<Entry: Equatable>(
        in entries: [Entry],
        from selection: Entry?,
        by delta: Int
    ) -> Entry? {
        guard !entries.isEmpty else { return nil }
        guard let selection, let index = entries.firstIndex(of: selection) else {
            return delta < 0 ? entries.last : entries.first
        }
        return entries[(index + delta + entries.count) % entries.count]
    }

    private func activateFocusedEntry() {
        switch level {
        case .root:
            guard let focusedRoot else {
                self.focusedRoot = rootEntries.first
                return
            }
            if focusedRoot == .groups {
                enterGroups()
            } else {
                activateRoot?(focusedRoot)
            }
        case .groups:
            guard let focusedGroup else {
                self.focusedGroup = groupEntries.first
                return
            }
            activateGroup?(focusedGroup)
        }
    }

    private func enterGroups() {
        guard !groupEntries.isEmpty else { return }
        level = .groups
        focusedGroup = groupEntries.first
        openSubmenu?()
    }

    private func leaveGroups() {
        closeSubmenu?()
        level = .root
        focusedGroup = nil
        focusedRoot = .groups
    }
}

/// Shared, observable group-membership set so the root menu and flyout remain
/// synchronized even though each is hosted in a separate SwiftUI tree.
@MainActor
private final class PaperGroupMembership: ObservableObject {
    @Published var ids: Set<UUID>

    init(ids: Set<UUID>) {
        self.ids = ids
    }

    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func clear() {
        ids.removeAll()
    }
}

private struct ClipboardItemContextMenuView: View {
    let controller: PaperContextMenuController
    @ObservedObject var keyboard: ClipboardItemContextMenuKeyboardState
    let item: ClipboardItem
    let groups: [ClipboardGroup]
    let onCopy: () -> Void
    let onCopyPlainText: () -> Void
    let onPreviewQRCode: () -> Void
    let onScanCodes: () -> Void
    let onBase64Encode: () -> Void
    let onBase64Decode: () -> Void
    let onRunRule: (ScriptingRule) -> Void
    let onRename: () -> Void
    let onToggleGroup: (ClipboardGroup) -> Void
    let onClearGroups: () -> Void
    let onNewGroup: () -> Void
    let onOpenInBrowser: () -> Void
    let onReveal: () -> Void
    let onOpenFile: () -> Void
    let onOpenWith: () -> Void
    let onToggleFavorite: () -> Void
    let onTogglePin: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @StateObject private var membership: PaperGroupMembership
    @StateObject private var submenu = PaperSubmenuCoordinator()
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    init(
        controller: PaperContextMenuController,
        keyboard: ClipboardItemContextMenuKeyboardState,
        item: ClipboardItem,
        groups: [ClipboardGroup],
        onCopy: @escaping () -> Void,
        onCopyPlainText: @escaping () -> Void,
        onPreviewQRCode: @escaping () -> Void,
        onScanCodes: @escaping () -> Void,
        onBase64Encode: @escaping () -> Void,
        onBase64Decode: @escaping () -> Void,
        onRunRule: @escaping (ScriptingRule) -> Void,
        onRename: @escaping () -> Void,
        onToggleGroup: @escaping (ClipboardGroup) -> Void,
        onClearGroups: @escaping () -> Void,
        onNewGroup: @escaping () -> Void,
        onOpenInBrowser: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onOpenFile: @escaping () -> Void,
        onOpenWith: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.controller = controller
        _keyboard = ObservedObject(wrappedValue: keyboard)
        self.item = item
        self.groups = groups
        self.onCopy = onCopy
        self.onCopyPlainText = onCopyPlainText
        self.onPreviewQRCode = onPreviewQRCode
        self.onScanCodes = onScanCodes
        self.onBase64Encode = onBase64Encode
        self.onBase64Decode = onBase64Decode
        self.onRunRule = onRunRule
        self.onRename = onRename
        self.onToggleGroup = onToggleGroup
        self.onClearGroups = onClearGroups
        self.onNewGroup = onNewGroup
        self.onOpenInBrowser = onOpenInBrowser
        self.onReveal = onReveal
        self.onOpenFile = onOpenFile
        self.onOpenWith = onOpenWith
        self.onToggleFavorite = onToggleFavorite
        self.onTogglePin = onTogglePin
        self.onExport = onExport
        self.onDelete = onDelete
        _membership = StateObject(
            wrappedValue: PaperGroupMembership(ids: Set(groups.map(\.id).filter(item.isInGroup)))
        )
    }

    private var hasFile: Bool { item.resolvedFileURL != nil }
    private var enabledRules: [ScriptingRule] {
        FilterSettingsStore.shared.scriptingRules.filter(\.isEnabled)
    }
    private var canScanCodes: Bool { item.hasImagePayload }
    private var canPreviewQRCode: Bool {
        item.itemType == .text &&
        !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canBase64Encode: Bool {
        guard let text = ClipboardViewModel.transformableText(of: item) else { return false }
        return !text.isEmpty
    }
    private var canBase64Decode: Bool {
        guard let text = ClipboardViewModel.transformableText(of: item) else { return false }
        return ClipboardViewModel.base64Decoded(text) != nil
    }

    private var keyboardRootEntries: [ClipboardItemContextMenuRootEntry] {
        var entries: [ClipboardItemContextMenuRootEntry] = [.copy, .copyPlainText]
        if canPreviewQRCode { entries.append(.previewQRCode) }
        if canScanCodes { entries.append(.scanCodes) }
        if canBase64Encode { entries.append(.base64Encode) }
        if canBase64Decode { entries.append(.base64Decode) }
        entries.append(contentsOf: enabledRules.map { .runRule($0.id) })
        entries.append(.rename)
        entries.append(groups.isEmpty ? .newGroup : .groups)
        if item.itemType == .url { entries.append(.openInBrowser) }
        if hasFile { entries.append(contentsOf: [.reveal, .openFile, .openWith]) }
        entries.append(contentsOf: [.toggleFavorite, .togglePin, .export, .delete])
        return entries
    }

    private var keyboardGroupEntries: [ClipboardGroupContextMenuEntry] {
        var entries = groups.map { ClipboardGroupContextMenuEntry.group($0.id) }
        if !membership.ids.isEmpty { entries.append(.clear) }
        entries.append(.newGroup)
        return entries
    }

    private func activateRootEntry(_ entry: ClipboardItemContextMenuRootEntry) {
        switch entry {
        case .copy: onCopy()
        case .copyPlainText: onCopyPlainText()
        case .previewQRCode: onPreviewQRCode()
        case .scanCodes: onScanCodes()
        case .base64Encode: onBase64Encode()
        case .base64Decode: onBase64Decode()
        case .runRule(let id):
            if let rule = enabledRules.first(where: { $0.id == id }) { onRunRule(rule) }
        case .rename: onRename()
        case .groups: submenu.openNow()
        case .newGroup: onNewGroup()
        case .openInBrowser: onOpenInBrowser()
        case .reveal: onReveal()
        case .openFile: onOpenFile()
        case .openWith: onOpenWith()
        case .toggleFavorite: onToggleFavorite()
        case .togglePin: onTogglePin()
        case .export: onExport()
        case .delete: onDelete()
        }
    }

    private func activateGroupEntry(_ entry: ClipboardGroupContextMenuEntry) {
        switch entry {
        case .group(let id):
            guard let group = groups.first(where: { $0.id == id }) else { return }
            membership.toggle(id)
            onToggleGroup(group)
        case .clear:
            membership.clear()
            onClearGroups()
        case .newGroup:
            onNewGroup()
        }
        keyboard.updateGroupEntries(keyboardGroupEntries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PaperMenuActionRow(
                icon: "doc.on.doc",
                title: L("action.copy"),
                isKeyboardFocused: keyboard.isFocused(.copy),
                action: onCopy
            )
            PaperMenuActionRow(
                icon: "doc.plaintext",
                title: L("action.copyAsPlainText"),
                isKeyboardFocused: keyboard.isFocused(.copyPlainText),
                action: onCopyPlainText
            )
            if canPreviewQRCode {
                PaperMenuActionRow(
                    icon: "qrcode",
                    title: L("action.qrPreview"),
                    isKeyboardFocused: keyboard.isFocused(.previewQRCode),
                    action: onPreviewQRCode
                )
            }
            if canScanCodes {
                PaperMenuActionRow(
                    icon: "qrcode.viewfinder",
                    title: L("action.scanCodes"),
                    isKeyboardFocused: keyboard.isFocused(.scanCodes),
                    action: onScanCodes
                )
            }
            if canBase64Encode {
                PaperMenuActionRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: L("action.base64Encode"),
                    isKeyboardFocused: keyboard.isFocused(.base64Encode),
                    action: onBase64Encode
                )
            }
            if canBase64Decode {
                PaperMenuActionRow(
                    icon: "abc",
                    title: L("action.base64Decode"),
                    isKeyboardFocused: keyboard.isFocused(.base64Decode),
                    action: onBase64Decode
                )
            }

            if !enabledRules.isEmpty {
                PaperMenuDivider()
                ForEach(enabledRules) { rule in
                    PaperMenuActionRow(
                        icon: "wand.and.stars",
                        title: L("action.runRule", rule.displayName),
                        isKeyboardFocused: keyboard.isFocused(.runRule(rule.id)),
                        action: { onRunRule(rule) }
                    )
                }
            }

            PaperMenuDivider()
            PaperMenuActionRow(
                icon: "pencil",
                title: L("action.rename"),
                isKeyboardFocused: keyboard.isFocused(.rename),
                action: onRename
            )
            if groups.isEmpty {
                PaperMenuActionRow(
                    icon: "folder.badge.plus",
                    title: L("group.newAndMove"),
                    isKeyboardFocused: keyboard.isFocused(
                        ClipboardItemContextMenuRootEntry.newGroup
                    ),
                    action: onNewGroup
                )
            } else {
                PaperSubmenuRow(
                    icon: "folder",
                    title: L("group.moveTo"),
                    coordinator: submenu,
                    isKeyboardFocused: keyboard.isFocused(.groups)
                )
            }

            if item.itemType == .url {
                PaperMenuDivider()
                PaperMenuActionRow(
                    icon: "safari",
                    title: L("action.openInBrowser"),
                    isKeyboardFocused: keyboard.isFocused(.openInBrowser),
                    action: onOpenInBrowser
                )
            }

            if hasFile {
                PaperMenuDivider()
                PaperMenuActionRow(
                    icon: "folder",
                    title: L("action.revealInFinder"),
                    isKeyboardFocused: keyboard.isFocused(.reveal),
                    action: onReveal
                )
                PaperMenuActionRow(
                    icon: "arrow.up.forward.app",
                    title: L("action.openFile"),
                    isKeyboardFocused: keyboard.isFocused(.openFile),
                    action: onOpenFile
                )
                PaperMenuActionRow(
                    icon: "app.badge",
                    title: L("action.openWith"),
                    isKeyboardFocused: keyboard.isFocused(.openWith),
                    action: onOpenWith
                )
            }

            PaperMenuDivider()
            PaperMenuActionRow(
                icon: item.isFavorite ? "star.slash" : "star",
                title: item.isFavorite ? L("action.unfavorite") : L("action.favorite"),
                isKeyboardFocused: keyboard.isFocused(.toggleFavorite),
                action: onToggleFavorite
            )
            PaperMenuActionRow(
                icon: item.isPinned ? "pin.slash" : "pin",
                title: item.isPinned ? L("action.unpin") : L("action.pin"),
                isKeyboardFocused: keyboard.isFocused(.togglePin),
                action: onTogglePin
            )

            PaperMenuDivider()
            PaperMenuActionRow(
                icon: "square.and.arrow.up",
                title: L("action.exportOne"),
                isKeyboardFocused: keyboard.isFocused(.export),
                action: onExport
            )

            PaperMenuDivider()
            PaperMenuActionRow(
                icon: "trash",
                title: L("action.delete"),
                role: .destructive,
                isKeyboardFocused: keyboard.isFocused(.delete),
                action: onDelete
            )
        }
        .padding(5)
        .frame(width: 232, alignment: .leading)
        .background(
            ClipboardContextMenuSurface(style: surfaceStyle, cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(surfaceStyle.border, lineWidth: surfaceStyle.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            submenu.present = { [weak submenu, weak controller, weak membership, weak keyboard] in
                guard let submenu, let controller, let membership, let keyboard,
                      let frame = submenu.rowScreenFrame() else { return }
                controller.openSubmenu(besideRowAt: frame, width: 222) {
                    ClipboardGroupContextSubmenu(
                        membership: membership,
                        groups: groups,
                        coordinator: submenu,
                        keyboard: keyboard,
                        onToggleGroup: onToggleGroup,
                        onClearGroups: onClearGroups,
                        onNewGroup: onNewGroup
                    )
                    .paperContextMenuSurfaceStyle(surfaceStyle)
                }
            }
            submenu.dismiss = { [weak controller, weak keyboard] in
                controller?.closeSubmenu()
                keyboard?.submenuDidClose()
            }
            keyboard.configure(
                rootEntries: keyboardRootEntries,
                groupEntries: keyboardGroupEntries,
                activateRoot: activateRootEntry,
                activateGroup: activateGroupEntry,
                openSubmenu: { [weak submenu] in submenu?.openNow() },
                closeSubmenu: { [weak submenu] in submenu?.closeNow() },
                dismiss: { [weak controller] in controller?.close() },
                cleanup: { [weak submenu] in
                    submenu?.present = nil
                    submenu?.dismiss = nil
                }
            )
        }
        .onChange(of: membership.ids) { _, _ in
            keyboard.updateGroupEntries(keyboardGroupEntries)
        }
    }
}

private struct ClipboardGroupContextSubmenu: View {
    @ObservedObject var membership: PaperGroupMembership
    let groups: [ClipboardGroup]
    @ObservedObject var coordinator: PaperSubmenuCoordinator
    @ObservedObject var keyboard: ClipboardItemContextMenuKeyboardState
    let onToggleGroup: (ClipboardGroup) -> Void
    let onClearGroups: () -> Void
    let onNewGroup: () -> Void
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            groupRows

            if !membership.ids.isEmpty {
                PaperMenuActionRow(
                    icon: "folder.badge.minus",
                    title: L("group.removeFromGroup"),
                    isKeyboardFocused: keyboard.isFocused(.clear),
                    action: {
                        membership.clear()
                        onClearGroups()
                    }
                )
            }
            PaperMenuDivider()
            PaperMenuActionRow(
                icon: "folder.badge.plus",
                title: L("group.newAndMove"),
                isKeyboardFocused: keyboard.isFocused(
                    ClipboardGroupContextMenuEntry.newGroup
                ),
                action: onNewGroup
            )
        }
        .padding(5)
        .frame(width: 222, alignment: .leading)
        .background(
            ClipboardContextMenuSurface(style: surfaceStyle, cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(surfaceStyle.border, lineWidth: surfaceStyle.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { coordinator.submenuHover($0) }
    }

    @ViewBuilder
    private var groupRows: some View {
        let rows = ForEach(groups) { group in
            PaperMenuCheckRow(
                title: group.displayName,
                isMember: membership.ids.contains(group.id),
                isKeyboardFocused: keyboard.isFocused(.group(group.id)),
                action: {
                    membership.toggle(group.id)
                    onToggleGroup(group)
                }
            )
            .id(ClipboardGroupContextMenuEntry.group(group.id))
        }
        if groups.count > 7 {
            ScrollViewReader { proxy in
                ScrollView { VStack(spacing: 1) { rows } }
                    .frame(height: 232)
                    .onChange(of: keyboard.focusedGroup) { _, entry in
                        guard let entry else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(entry, anchor: .center)
                        }
                    }
            }
        } else {
            rows
        }
    }
}

/// The popover variant intentionally uses the same AppKit material as Quick
/// Paste itself. It remains a separate child panel, but no longer reads as a
/// warm paper card pasted on top of the cooler translucent surface.
private struct ClipboardContextMenuSurface: View {
    let style: PaperContextMenuSurfaceStyle
    let cornerRadius: CGFloat

    @ViewBuilder
    var body: some View {
        switch style {
        case .paper:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.appPaper)
        case .popover:
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
