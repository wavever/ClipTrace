import SwiftUI
import AppKit
import KeyboardShortcuts

struct QuickPasteView: View {
    @ObservedObject var state: QuickPastePanelState

    /// Selection in click order. Used to drive numeric badges and to preserve
    /// concatenation order at commit time.
    @State private var selectedIDs: [UUID] = []
    @State private var hoverID: UUID? = nil
    /// Row highlighted by the keyboard flow (↑/↓). Distinct from `selectedIDs`:
    /// focus just marks where the cursor is; the commit key acts on it.
    @State private var focusedID: UUID? = nil

    @ObservedObject private var keyStore = QuickPasteKeyStore.shared

    private var items: [ClipboardItem] { state.items }
    private var visualItems: [ClipboardItem] {
        items
    }
    private var sortedGroups: [ClipboardGroup] {
        state.groups.sortedForDisplay()
    }
    private var groupFilters: [ClipboardGroupFilter] {
        [.all] + sortedGroups.map { .group($0.id) }
    }

    private var selectedItems: [ClipboardItem] {
        selectedIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !sortedGroups.isEmpty {
                groupStrip
            }
            Divider().opacity(0.4)
            list
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 360, height: 440)
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
        )
        .background(
            QuickPasteKeyCatcher(
                onLeft: { switchGroup(by: -1) },
                onRight: { switchGroup(by: 1) },
                onUp: { moveFocus(by: -1) },
                onDown: { moveFocus(by: 1) },
                onToggleSelect: { toggleFocusedSelection() },
                onCommit: { plainText in commitFromKeyboard(plainText: plainText) }
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            // Pre-focus the first row so the panel is usable with the keyboard
            // alone: open → ↑/↓ → commit key, no mouse required.
            if focusedID == nil { focusedID = visualItems.first?.id }
        }
        .onChange(of: visualItems.map(\.id)) { _, ids in
            // The panel window is now reused across invocations for speed.
            // Reset transient selection/focus whenever the freshly-fetched
            // history snapshot is swapped in, so stale selections from the
            // previous popup session don't leak into the next one.
            selectedIDs.removeAll(keepingCapacity: true)
            hoverID = nil
            focusedID = ids.first
        }
        .onChange(of: state.selectedGroupFilter) { _, _ in
            selectedIDs.removeAll(keepingCapacity: true)
            hoverID = nil
            focusedID = visualItems.first?.id
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L("quickpaste.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(selectedIDs.isEmpty
                 ? keyboardHint
                 : L("quickpaste.selectedCountFormat", selectedIDs.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// "↑↓ move · Space select · ↩ paste" — surfaces the keyboard flow and the
    /// (possibly customized) toggle/commit keys right in the panel.
    private var keyboardHint: String {
        let group = sortedGroups.isEmpty ? nil : "←→ \(L("quickpaste.hint.kbdGroup"))"
        let move = "↑↓ \(L("quickpaste.hint.kbdMove"))"
        let toggle = "\(keyStore.toggleSelectShortcut.description) \(L("quickpaste.hint.kbdToggle"))"
        let paste = "\(keyStore.commitShortcut.description) \(L("quickpaste.hint.kbdPaste"))"
        return [group, move, toggle, paste].compactMap(\.self).joined(separator: "  ·  ")
    }

    private var groupStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groupFilters, id: \.id) { filter in
                    groupChip(filter)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if items.isEmpty {
                        emptyState
                    } else {
                        ForEach(items, id: \.id) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: focusedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func groupChip(_ filter: ClipboardGroupFilter) -> some View {
        let isSelected = state.selectedGroupFilter == filter
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                state.selectGroup(filter)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: groupIcon(for: filter))
                    .font(.system(size: 9, weight: .semibold))
                Text(groupTitle(for: filter))
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.appAccent : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
            Text(state.selectedGroupFilter.isAll ? L("quickpaste.emptyClipboard") : L("quickpaste.emptyGroup"))
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(20)
    }

    private func row(for item: ClipboardItem) -> some View {
        let order = selectedIDs.firstIndex(of: item.id).map { $0 + 1 }
        let isSelected = order != nil
        let isHover = hoverID == item.id
        let isFocused = focusedID == item.id

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.appAccent : Color.secondary.opacity(0.18))
                    .frame(width: 22, height: 22)
                if let order {
                    Text("\(order)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: item.itemType.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(displayPreview(for: item))
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Image(systemName: item.itemType.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.descriptiveTag)
                    }
                    ForEach(item.tags, id: \.self) { tag in
                        HStack(spacing: 2) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(tag)
                        }
                        .foregroundStyle(Color.appAccent)
                    }
                    Text("·")
                    if item.sourceApp == L("remote.universalClipboard") {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    Text(item.sourceApp.isEmpty ? L("common.unknownSource") : item.sourceApp)
                    Spacer(minLength: 0)
                    Text(item.formattedDate)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected
                      ? Color.appAccent.opacity(0.12)
                      : (isHover ? Color.secondary.opacity(0.10) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isFocused ? Color.appAccent : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hoverID = $0 ? item.id : nil }
        .onTapGesture(count: 2) {
            // Double-click on a single item: paste it directly without needing
            // the button (mirrors the typical clipboard-popup interaction).
            state.onCommit([item], false)
        }
        .onTapGesture {
            focusedID = item.id
            toggle(item.id)
        }
        .contextMenu {
            Button(item.isPinned ? L("action.unpin") : L("action.pin"),
                   systemImage: item.isPinned ? "pin.slash" : "pin") {
                state.onTogglePin(item)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                state.onCancel()
            } label: {
                Text(L("common.cancel"))
                    .frame(minWidth: 56)
            }
            .buttonStyle(PaperActionButtonStyle(role: .plain))
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button {
                commitFromKeyboard(plainText: false)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "return")
                    Text(selectedIDs.count <= 1
                         ? L("quickpaste.paste")
                         : L("quickpaste.pasteInOrderFormat", selectedIDs.count))
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 120)
            }
            .buttonStyle(PaperActionButtonStyle(role: .primary))
            .disabled(selectedIDs.isEmpty && focusedID == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Keyboard flow

    private func switchGroup(by delta: Int) {
        let filters = groupFilters
        guard filters.count > 1,
              let current = filters.firstIndex(of: state.selectedGroupFilter) else { return }
        let next = (current + delta + filters.count) % filters.count
        withAnimation(.easeOut(duration: 0.14)) {
            state.selectGroup(filters[next])
        }
    }

    private func moveFocus(by delta: Int) {
        let ordered = visualItems
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex(where: { $0.id == focusedID }) ?? 0
        let next = min(max(0, current + delta), ordered.count - 1)
        focusedID = ordered[next].id
    }

    /// Commit triggered by the commit key or the Paste button. Honors an
    /// explicit click multi-selection when present, otherwise pastes the
    /// keyboard-focused row. `plainText` is forwarded so callers (e.g. ⌥⏎)
    /// can request a string-only pasteboard write.
    private func commitFromKeyboard(plainText: Bool) {
        if !selectedIDs.isEmpty {
            state.onCommit(selectedItems, plainText)
        } else if let id = focusedID, let item = visualItems.first(where: { $0.id == id }) {
            state.onCommit([item], plainText)
        } else if let first = visualItems.first {
            state.onCommit([first], plainText)
        }
    }

    /// Add/remove the keyboard-focused row from the multi-selection.
    private func toggleFocusedSelection() {
        guard let id = focusedID, visualItems.contains(where: { $0.id == id }) else { return }
        toggle(id)
    }

    private func toggle(_ id: UUID) {
        if let idx = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: idx)
        } else {
            selectedIDs.append(id)
        }
    }

    private func displayPreview(for item: ClipboardItem) -> String {
        if let title = item.effectiveCustomTitle { return title }
        if let p = item.preview, !p.isEmpty { return p }
        if !item.content.isEmpty { return item.content }
        return item.descriptiveTag
    }

    private func groupTitle(for filter: ClipboardGroupFilter) -> String {
        switch filter {
        case .all:
            return L("group.all")
        case .ungrouped:
            return L("group.ungrouped")
        case .group(let id):
            return sortedGroups.first { $0.id == id }?.displayName ?? L("group.missing")
        }
    }

    private func groupIcon(for filter: ClipboardGroupFilter) -> String {
        switch filter {
        case .all:
            return "tray.full"
        case .ungrouped:
            return "tray"
        case .group:
            return "folder.fill"
        }
    }
}

/// Invisible AppKit view that drives the QuickPaste panel's keyboard flow.
///
/// `↑` / `↓` move the focused row; the user-customizable toggle-select key
/// adds/removes it from the multi-selection, and the commit key pastes (both
/// read live from `QuickPasteKeyStore`). Matching runs in both `keyDown`
/// (plain keys) and `performKeyEquivalent` (modifier combos) so any recorded
/// shortcut works regardless of whether AppKit routes it as a key equivalent.
struct QuickPasteKeyCatcher: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void
    var onToggleSelect: () -> Void
    /// `plainText` is `true` when the commit was issued with `⌥` held.
    var onCommit: (_ plainText: Bool) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onLeft = onLeft
        view.onRight = onRight
        view.onUp = onUp
        view.onDown = onDown
        view.onToggleSelect = onToggleSelect
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onToggleSelect = onToggleSelect
        nsView.onCommit = onCommit
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onToggleSelect: (() -> Void)?
        var onCommit: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Grab first responder once the panel exists so arrow keys land
            // here instead of beeping. The panel has no text fields, so it is
            // safe to hold focus for the panel's whole lifetime.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        private func matches(_ event: NSEvent, _ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
            guard let typed = KeyboardShortcuts.Shortcut(event: event) else { return false }
            return typed == shortcut
        }

        /// Same matcher with `⌥` masked out, so commit detection survives the
        /// user holding the option modifier for a plain-text paste.
        private func matchesIgnoringOption(
            _ event: NSEvent, _ shortcut: KeyboardShortcuts.Shortcut
        ) -> Bool {
            let stripped = event.modifierFlags.subtracting(.option)
            // Synthesize an event with the option flag stripped so the library's
            // initializer doesn't see ⌥+Return as a different shortcut than ⏎.
            let cleaned = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: stripped,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.charactersIgnoringModifiers ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
            guard let cleaned,
                  let typed = KeyboardShortcuts.Shortcut(event: cleaned) else { return false }
            return typed == shortcut
        }

        /// Runs the action bound to `event`, if any. Commit is checked before
        /// toggle so a user who maps both to the same key still gets a paste.
        private func handle(_ event: NSEvent) -> Bool {
            let store = QuickPasteKeyStore.shared
            let optionHeld = event.modifierFlags.contains(.option)
            if matches(event, store.commitShortcut) {
                onCommit?(optionHeld)
                return true
            }
            // ⌥ + commit key reaches us as a different shortcut (e.g. ⌥⏎
            // instead of ⏎). Detect that combo explicitly so plain-text paste
            // works with the default Return commit key.
            if optionHeld, matchesIgnoringOption(event, store.commitShortcut) {
                onCommit?(true)
                return true
            }
            if matches(event, store.toggleSelectShortcut) {
                onToggleSelect?()
                return true
            }
            return false
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeft?(); return  // ←
            case 124: onRight?(); return // →
            case 126: onUp?(); return   // ↑
            case 125: onDown?(); return // ↓
            default: break
            }
            if handle(event) { return }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if handle(event) { return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}
