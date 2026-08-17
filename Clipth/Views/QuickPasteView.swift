import SwiftUI
import AppKit
import KeyboardShortcuts

struct QuickPasteView: View {
    @ObservedObject var state: QuickPastePanelState
    @ObservedObject private var itemContextMenu: ClipboardItemContextMenuCoordinator

    init(
        state: QuickPastePanelState,
        itemContextMenu: ClipboardItemContextMenuCoordinator
    ) {
        _state = ObservedObject(wrappedValue: state)
        _itemContextMenu = ObservedObject(wrappedValue: itemContextMenu)
    }

    /// Selection in click order. Used to drive numeric badges and to preserve
    /// concatenation order at commit time.
    @State private var selectedIDs: [UUID] = []
    @State private var hoverID: UUID? = nil
    /// Card highlighted by the arrow-key flow. Distinct from `selectedIDs`:
    /// focus just marks where the cursor is; the commit key acts on it.
    @State private var focusedID: UUID? = nil
    /// Live text in the search field. Trails into `state.searchQuery` after a
    /// short debounce so a SwiftData fetch never runs per keystroke; clearing
    /// applies immediately so leaving search feels instant.
    @State private var searchDraft = ""
    @State private var searchDebounce: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    /// Bumped to hand first-responder back to the key catcher when search
    /// focus ends — otherwise ↑/↓ would go nowhere after Esc.
    @State private var keyClaimToken = 0
    @State private var contextMenuRequestSequence = 0
    @State private var contextMenuKeyboardRequest: ClipboardItemContextMenuKeyboardRequest?
    @State private var copiedIDs: Set<UUID> = []
    @State private var copyFeedbackTask: Task<Void, Never>?
    @AppStorage("quickPasteContentLayout") private var contentLayoutRaw = PanelContentLayout.list.rawValue
    @AppStorage("quickPasteKeyboardGuideExpanded") private var keyboardGuideExpanded = true

    @ObservedObject private var keyStore = QuickPasteKeyStore.shared
    @ObservedObject private var previewSettings = HoverPreviewSettings.shared
    /// Panel hosting this view; the dwell preview anchors its floating window
    /// beside it. Captured once — the panel is reused across invocations.
    @State private var hostWindow: NSWindow?

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

    private func groupNames(for item: ClipboardItem) -> [String] {
        let namesByID = Dictionary(
            sortedGroups.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return item.groupIDs.compactMap { namesByID[$0] }
    }

    private var selectedItems: [ClipboardItem] {
        selectedIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }
    private var contentLayout: PanelContentLayout {
        PanelContentLayout(rawValue: contentLayoutRaw) ?? .list
    }
    private var usesGrid: Bool { contentLayout == .grid }

    var body: some View {
        VStack(spacing: 0) {
            header
            keyboardGuide
            if !sortedGroups.isEmpty {
                groupStrip
            }
            searchField
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
                claimFocusToken: keyClaimToken,
                isContextMenuOpen: { itemContextMenu.isMenuOpen },
                onLeft: { handleHorizontalNavigation(by: -1) },
                onRight: { handleHorizontalNavigation(by: 1) },
                onUp: { moveFocusVertically(by: -1) },
                onDown: { moveFocusVertically(by: 1) },
                onToggleSelect: { toggleFocusedSelection() },
                onCopy: { copyFromKeyboard() },
                onCommit: { plainText in commitFromKeyboard(plainText: plainText) },
                onOpenContextMenu: { openFocusedContextMenu() },
                onItemAction: { performFocusedItemAction($0) },
                onQuickPasteIndex: { quickPasteByIndex($0) }
            )
        )
        .background(
            // Invisible ⌘F target: routes the shortcut into the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
            // previous popup session don't leak into the next one. During
            // search this doubles as "focus lands on the first match".
            selectedIDs.removeAll(keepingCapacity: true)
            hoverID = nil
            focusedID = ids.first
            if let request = contextMenuKeyboardRequest,
               !ids.contains(request.itemID) {
                contextMenuKeyboardRequest = nil
            }
        }
        .onChange(of: state.selectedGroupFilter) { _, _ in
            selectedIDs.removeAll(keepingCapacity: true)
            hoverID = nil
            focusedID = visualItems.first?.id
        }
        .onChange(of: searchDraft) { _, draft in
            scheduleSearch(draft)
        }
        .onChange(of: state.session) { _, _ in
            resetPanelSession()
        }
        .background(PanelWindowReader { hostWindow = $0 })
        // Dwell preview: resting on a row — keyboard focus or pointer, the
        // most recent one wins — pops the full preview beside the panel.
        .onChange(of: focusedID) { _, newValue in
            guard let newValue else { return }
            schedulePreview(for: newValue)
        }
        .onChange(of: hoverID) { oldValue, newValue in
            if let newValue {
                schedulePreview(for: newValue)
            } else if let oldValue {
                HoverPreviewController.shared.noteExit(itemID: oldValue)
            }
        }
        .clipboardItemContextMenuPresenter(itemContextMenu)
    }

    private func schedulePreview(for id: UUID) {
        guard previewSettings.quickPasteEnabled else { return }
        guard let item = visualItems.first(where: { $0.id == id }) else { return }
        HoverPreviewController.shared.schedule(
            item: item,
            host: hostWindow,
            after: previewSettings.quickPasteDelay,
            style: .popover
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L("quickpaste.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !selectedIDs.isEmpty {
                Text(L("quickpaste.selectedCountFormat", selectedIDs.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    keyboardGuideExpanded.toggle()
                }
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .rotationEffect(.degrees(keyboardGuideExpanded ? 0 : -8))
            }
            .buttonStyle(.plain)
            .help(L(keyboardGuideExpanded ? "quickpaste.hint.collapse" : "quickpaste.hint.expand"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Surfaces the complete keyboard flow and the customized panel keys right
    /// in the panel, including the fixed native copy command.
    private var keyboardHint: String {
        let group: String?
        if sortedGroups.isEmpty {
            group = nil
        } else if usesGrid {
            group = L("quickpaste.hint.kbdGridGroup")
        } else {
            group = "←→ \(L("quickpaste.hint.kbdGroup"))"
        }
        let arrows = usesGrid ? "←↑↓→" : "↑↓"
        let move = "\(arrows) \(L("quickpaste.hint.kbdMove"))"
        let toggle = "\(keyStore.toggleSelectShortcut.description) \(L("quickpaste.hint.kbdToggle"))"
        let copy = "⌘C \(L("common.copy"))"
        let paste = "\(keyStore.commitShortcut.description) \(L("quickpaste.hint.kbdPaste"))"
        let numberedPaste = L("quickpaste.hint.kbdQuickPaste")
        return [group, move, toggle, copy, paste, numberedPaste]
            .compactMap(\.self)
            .joined(separator: "  ·  ")
    }

    private var keyboardGuide: some View {
        Group {
            if keyboardGuideExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("quickpaste.hint.keyboardShortcuts"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(keyboardHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var groupStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(groupFilters, id: \.id) { filter in
                        groupChip(filter)
                    }
                }
                .redirectsVerticalWheelToHorizontal()
            }
            // 8pt on the scroll view, not its content: chips, search box and
            // the list rows' card edge share one line on *both* sides — with
            // the inset on the content, overflowing chips would scroll under
            // the panel edge past that line before being clipped.
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            // ←/→ wraps through groups that may overflow the strip; follow the
            // selection so the active chip is always visible. Also snap there
            // when the reused panel reopens with a group still selected.
            .onChange(of: state.selectedGroupFilter) { _, newValue in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(newValue.id)
                }
            }
            .onAppear {
                proxy.scrollTo(state.selectedGroupFilter.id)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(searchFocused ? Color.appAccent : .secondary)
            TextField(L("common.search"), text: $searchDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    // Keyboard-only flow: type to filter, ⏎ pastes the
                    // focused (by default the first) match without leaving
                    // the field.
                    commitFromKeyboard(plainText: false)
                }
                .onExitCommand {
                    handleSearchEscape()
                }
                .background(
                    SearchArrowRouter(
                        isActive: { searchFocused && !itemContextMenu.isMenuOpen },
                        onMove: { delta in moveFocusVertically(by: delta) }
                    )
                )
            if !searchDraft.isEmpty {
                Button {
                    searchDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else if !searchFocused {
                Text(verbatim: "⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(searchFocused ? Color.appAccent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        // 8pt like the group strip and the list's card inset — the three
        // stacked surfaces (chips / search box / row cards) share one edge.
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if items.isEmpty {
                        emptyState
                    } else if usesGrid {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 6, alignment: .top),
                                GridItem(.flexible(), spacing: 6, alignment: .top)
                            ],
                            spacing: 6
                        ) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                gridCard(
                                    for: item,
                                    ordinal: QuickPasteOrdinal.badge(forIndex: index)
                                )
                            }
                        }
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(
                                    for: item,
                                    ordinal: QuickPasteOrdinal.badge(forIndex: index)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .id(contentLayout)
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
            Image(systemName: !state.searchQuery.isEmpty ? "magnifyingglass" : "tray")
                .font(.system(size: 24, weight: .light))
            Text(emptyStateText)
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(20)
    }

    private var emptyStateText: String {
        if !state.searchQuery.isEmpty { return L("quickpaste.emptySearch") }
        return state.selectedGroupFilter.isAll ? L("quickpaste.emptyClipboard") : L("quickpaste.emptyGroup")
    }

    private func row(for item: ClipboardItem, ordinal: Int? = nil) -> some View {
        let order = selectedIDs.firstIndex(of: item.id).map { $0 + 1 }
        let isSelected = order != nil
        let isHover = hoverID == item.id
        let isFocused = focusedID == item.id
        let detectedColor = item.itemType == .text
            ? ColorValueParser.color(from: item.content)
            : nil

        return HStack(spacing: 6) {
            HStack(spacing: 10) {
                if let order {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent)
                            .frame(width: 22, height: 22)
                        Text("\(order)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else if let detectedColor {
                    ColorSwatchThumbnail(color: detectedColor, size: 22)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 22, height: 22)
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
                        if detectedColor != nil {
                            ColorValueBadge(
                                fontSize: 9,
                                background: Color.appChipFill,
                                horizontalPadding: 6,
                                verticalPadding: 2
                            )
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // Double-click on a single item pastes it directly.
                state.onCommit([item], false)
            }
            .onTapGesture {
                focusedID = item.id
                toggle(item.id)
            }

            if isHover || copiedIDs.contains(item.id) {
                copyButton(for: item)
            }
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
        .clipboardItemContextMenu(
            item: item,
            groups: sortedGroups,
            coordinator: itemContextMenu,
            surfaceStyle: .popover,
            keyboardRequest: contextMenuKeyboardRequest,
            onKeyboardRequestHandled: { contextMenuKeyboardRequest = nil },
            onMutation: state.reloadSnapshot
        )
        .overlay(alignment: .topTrailing) {
            if let ordinal {
                Text("\(ordinal)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.appPaper.opacity(0.94)))
                    .overlay(Circle().strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 0.6))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func gridCard(for item: ClipboardItem, ordinal: Int? = nil) -> some View {
        let order = selectedIDs.firstIndex(of: item.id).map { $0 + 1 }
        let isSelected = order != nil
        let isHover = hoverID == item.id
        let isFocused = focusedID == item.id
        let previewContent = item.gridPreviewContent
        let showsCopyButton = isHover || copiedIDs.contains(item.id)
        let detectedColor = item.itemType == .text
            ? ColorValueParser.color(from: item.content)
            : nil

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.appChipFill)

                    if let detectedColor {
                        ColorValueGridPreview(
                            color: detectedColor,
                            text: previewContent,
                            fontSize: 10.5,
                            checkerSquareSize: 7,
                            contentPadding: 7
                        )
                    } else if showsGridThumbnail(item) {
                        GeometryReader { proxy in
                            ThumbnailView(
                                item: item,
                                width: proxy.size.width,
                                height: proxy.size.height,
                                cornerRadius: 7,
                                contentMode: item.itemType == .image ? .fit : .fill
                            )
                        }
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: item.itemType.icon)
                                .font(.system(size: 38, weight: .ultraLight))
                                .foregroundStyle(Color.appAccent.opacity(0.08))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(7)
                            Text(previewContent)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.primary.opacity(0.78))
                                .lineLimit(6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(7)
                        }
                    }

                    if item.itemType == .image {
                        VStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                Text(item.gridImageTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.appMetal.opacity(0.82))
                        }
                    }
                }
                .frame(height: 99)
                .overlay(alignment: .top) {
                    HStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.appAccent : Color.appPaper.opacity(0.92))
                                .frame(width: 22, height: 22)
                            if let order {
                                Text("\(order)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: item.itemType.icon)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if detectedColor != nil {
                            Text(item.descriptiveTag)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.appPaper.opacity(0.92)))
                            ColorValueBadge(fontSize: 8.5)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(5)
                    .padding(.trailing, gridTrailingControlWidth(
                        isPinned: item.isPinned,
                        showsCopyButton: showsCopyButton
                    ))
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                ClipboardItemMetadataRail(
                    groupNames: groupNames(for: item),
                    tags: item.tags,
                    fontSize: 8.5,
                    maxTitleWidth: 58
                )
                .frame(height: 16)

                HStack(spacing: 4) {
                    Text(item.sourceApp.isEmpty ? L("common.unknownSource") : item.sourceApp)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(item.formattedDate)
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? Color.appAccent.opacity(0.12)
                          : (isHover ? Color.secondary.opacity(0.10) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Color.appAccent : Color.appCardBorder.opacity(0.55), lineWidth: isFocused ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture(count: 2) {
                state.onCommit([item], false)
            }
            .onTapGesture {
                focusedID = item.id
                toggle(item.id)
            }

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.appPaper.opacity(0.92)))
                    .padding(.top, 11)
                    .padding(.trailing, showsCopyButton ? 37 : 11)
                    .allowsHitTesting(false)
            }
            if showsCopyButton {
                copyButton(for: item)
                    .padding(11)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoverID = hovering ? item.id : nil
            }
        }
        .clipboardItemContextMenu(
            item: item,
            groups: sortedGroups,
            coordinator: itemContextMenu,
            surfaceStyle: .popover,
            keyboardRequest: contextMenuKeyboardRequest,
            onKeyboardRequestHandled: { contextMenuKeyboardRequest = nil },
            onMutation: state.reloadSnapshot
        )
        .overlay(alignment: .topTrailing) {
            if let ordinal {
                Text("\(ordinal)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.appPaper.opacity(0.94)))
                    .overlay(Circle().strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 0.6))
                    .padding(9)
                    .allowsHitTesting(false)
            }
        }
    }

    private func showsGridThumbnail(_ item: ClipboardItem) -> Bool {
        switch item.itemType {
        case .image, .video, .file: return true
        case .text, .url, .rtf: return false
        }
    }

    private func gridTrailingControlWidth(isPinned: Bool, showsCopyButton: Bool) -> CGFloat {
        switch (isPinned, showsCopyButton) {
        case (true, true): return 54
        case (true, false), (false, true): return 27
        case (false, false): return 0
        }
    }

    private func copyButton(for item: ClipboardItem) -> some View {
        let copied = copiedIDs.contains(item.id)
        return Button {
            focusedID = item.id
            copyItems([item])
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? Color.appAccent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(copied ? Color.appAccent.opacity(0.14) : Color.appChipFill)
                )
        }
        .buttonStyle(.plain)
        .help(copied ? L("common.copied") : L("common.copy"))
        .transition(.opacity)
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
            // While the search field owns the keyboard, Esc belongs to it
            // (clear → exit search); only afterwards may Esc close the panel.
            .escapeShortcut(enabled: !searchFocused)

            Spacer()

            Text("\(keyStore.openMenuShortcut.description) \(L("quickpaste.hint.kbdMenu"))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

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

    // MARK: - Search flow

    private func scheduleSearch(_ draft: String) {
        searchDebounce?.cancel()
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != state.searchQuery else { return }
        if query.isEmpty {
            applySearch("")
            return
        }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            applySearch(query)
        }
    }

    private func applySearch(_ query: String) {
        withAnimation(.easeOut(duration: 0.14)) {
            state.updateSearch(query)
        }
    }

    /// Esc in the search field: first press clears the query, second press
    /// (field already empty) leaves search — a double-Esc always exits from
    /// any state. Only after that does Esc reach the Cancel button and close
    /// the panel, as before.
    private func handleSearchEscape() {
        if searchDraft.isEmpty {
            exitSearch()
        } else {
            searchDraft = ""
        }
    }

    private func exitSearch() {
        searchFocused = false
        keyClaimToken &+= 1
    }

    /// The panel window and SwiftUI view are reused across invocations. Reset
    /// every transient interaction state explicitly because an unchanged item
    /// id snapshot will not trigger the list-change cleanup on its own.
    private func resetPanelSession() {
        searchDebounce?.cancel()
        copyFeedbackTask?.cancel()
        selectedIDs.removeAll(keepingCapacity: true)
        copiedIDs.removeAll(keepingCapacity: true)
        hoverID = nil
        focusedID = visualItems.first?.id
        searchDraft = ""
        contextMenuKeyboardRequest = nil
        exitSearch()
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

    /// List rows reserve horizontal arrows for groups. In the two-column grid,
    /// arrows first move within the current row; pressing past either edge
    /// flows into the neighboring group instead of becoming a dead key.
    private func handleHorizontalNavigation(by delta: Int) {
        guard usesGrid else {
            switchGroup(by: delta)
            return
        }
        if !moveFocusHorizontally(by: delta) {
            switchGroup(by: delta)
        }
    }

    private func moveFocusVertically(by delta: Int) {
        let ordered = visualItems
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex(where: { $0.id == focusedID }) ?? 0
        guard usesGrid else {
            let next = min(max(0, current + delta), ordered.count - 1)
            focusedID = ordered[next].id
            return
        }

        let columns = 2
        let row = current / columns
        let lastRow = (ordered.count - 1) / columns
        let next: Int
        if delta < 0 {
            next = row > 0 ? current - columns : current
        } else if row < lastRow {
            next = min(current + columns, ordered.count - 1)
        } else {
            next = current
        }
        focusedID = ordered[next].id
    }

    /// Returns whether focus moved to another card. `false` deliberately also
    /// covers an empty result set so horizontal navigation can escape an empty
    /// group through `handleHorizontalNavigation(by:)`.
    @discardableResult
    private func moveFocusHorizontally(by delta: Int) -> Bool {
        let ordered = visualItems
        guard !ordered.isEmpty else { return false }
        let current = ordered.firstIndex(where: { $0.id == focusedID }) ?? 0
        let column = current % 2
        let candidate = current + delta
        let canMove = delta < 0
            ? column > 0
            : column == 0 && candidate < ordered.count
        guard canMove else { return false }
        focusedID = ordered[candidate].id
        return true
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

    /// Cmd-C mirrors commit targeting but only updates the pasteboard: an
    /// explicit multi-selection keeps its pick order, otherwise the focused
    /// row (or first visible fallback) is copied and the panel stays open.
    private func copyFromKeyboard() {
        if !selectedIDs.isEmpty {
            copyItems(selectedItems)
        } else if let id = focusedID,
                  let item = visualItems.first(where: { $0.id == id }) {
            copyItems([item])
        } else if let first = visualItems.first {
            focusedID = first.id
            copyItems([first])
        }
    }

    private func copyItems(_ items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        state.onCopy(items)

        let ids = Set(items.map(\.id))
        copyFeedbackTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            copiedIDs = ids
        }
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                copiedIDs.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Add/remove the keyboard-focused row from the multi-selection.
    private func toggleFocusedSelection() {
        guard let id = focusedID, visualItems.contains(where: { $0.id == id }) else { return }
        toggle(id)
    }

    /// Ask the focused lazy row to open its shared menu from its own live
    /// AppKit frame. Exiting search first prevents the field editor's arrow
    /// router from intercepting menu navigation on the following key press.
    private func openFocusedContextMenu() {
        guard let id = focusedID ?? visualItems.first?.id,
              visualItems.contains(where: { $0.id == id }) else { return }
        focusedID = id
        if searchFocused { exitSearch() }
        contextMenuRequestSequence &+= 1
        contextMenuKeyboardRequest = ClipboardItemContextMenuKeyboardRequest(
            itemID: id,
            sequence: contextMenuRequestSequence
        )
    }

    private func performFocusedItemAction(_ action: QuickPasteItemShortcutAction) {
        guard let id = focusedID ?? visualItems.first?.id,
              let item = visualItems.first(where: { $0.id == id }) else { return }
        focusedID = id
        if searchFocused { exitSearch() }
        switch action {
        case .toggleFavorite:
            itemContextMenu.toggleFavoriteFromKeyboard(for: item, onMutation: state.reloadSnapshot)
        case .togglePin:
            itemContextMenu.togglePinFromKeyboard(for: item, onMutation: state.reloadSnapshot)
        case .editTags:
            itemContextMenu.presentTagsFromKeyboard(for: item, onMutation: state.reloadSnapshot)
        case .delete:
            itemContextMenu.presentDeleteFromKeyboard(for: item, onMutation: state.reloadSnapshot)
        case .editGroups:
            contextMenuRequestSequence &+= 1
            contextMenuKeyboardRequest = ClipboardItemContextMenuKeyboardRequest(
                itemID: id,
                sequence: contextMenuRequestSequence,
                target: .groups
            )
        }
    }

    private func quickPasteByIndex(_ index: Int) {
        guard index >= 0, index < visualItems.count else { return }
        state.onCommit([visualItems[index]], false)
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
        if let p = item.preview, !p.isEmpty { return item.redactedForDisplay(p) }
        if !item.content.isEmpty { return item.redactedForDisplay(item.content) }
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
/// Arrow keys move the focused item; a grid arrow that crosses a row edge may
/// switch groups. Cmd-C copies, the user-customizable toggle-select key
/// adds/removes the focused item from the multi-selection, and the commit key
/// pastes. Configurable keys read live from `QuickPasteKeyStore`. Matching runs
/// in both `keyDown` (plain keys) and `performKeyEquivalent` (modifier combos)
/// so any recorded shortcut works regardless of AppKit routing.
struct QuickPasteKeyCatcher: NSViewRepresentable {
    /// Bumped by the host to re-claim first responder (e.g. when search focus
    /// ends) so the arrow-key flow resumes without rebuilding the view.
    var claimFocusToken: Int = 0
    var isContextMenuOpen: () -> Bool
    var onLeft: () -> Void
    var onRight: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void
    var onToggleSelect: () -> Void
    var onCopy: () -> Void
    /// `plainText` is `true` when the commit was issued with `⌥` held.
    var onCommit: (_ plainText: Bool) -> Void
    var onOpenContextMenu: () -> Void
    var onItemAction: (QuickPasteItemShortcutAction) -> Void
    var onQuickPasteIndex: (Int) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.claimFocusToken = claimFocusToken
        view.isContextMenuOpen = isContextMenuOpen
        view.onLeft = onLeft
        view.onRight = onRight
        view.onUp = onUp
        view.onDown = onDown
        view.onToggleSelect = onToggleSelect
        view.onCopy = onCopy
        view.onCommit = onCommit
        view.onOpenContextMenu = onOpenContextMenu
        view.onItemAction = onItemAction
        view.onQuickPasteIndex = onQuickPasteIndex
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.isContextMenuOpen = isContextMenuOpen
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onToggleSelect = onToggleSelect
        nsView.onCopy = onCopy
        nsView.onCommit = onCommit
        nsView.onOpenContextMenu = onOpenContextMenu
        nsView.onItemAction = onItemAction
        nsView.onQuickPasteIndex = onQuickPasteIndex
        if nsView.claimFocusToken != claimFocusToken {
            nsView.claimFocusToken = claimFocusToken
            // Deferred: updateNSView runs mid view-update, and yanking first
            // responder synchronously would mutate @FocusState re-entrantly.
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: KeyView, coordinator: Void) {
        nsView.uninstallContextMenuMonitor()
    }

    final class KeyView: NSView {
        var claimFocusToken = 0
        var isContextMenuOpen: (() -> Bool)?
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onToggleSelect: (() -> Void)?
        var onCopy: (() -> Void)?
        var onCommit: ((Bool) -> Void)?
        var onOpenContextMenu: (() -> Void)?
        var onItemAction: ((QuickPasteItemShortcutAction) -> Void)?
        var onQuickPasteIndex: ((Int) -> Void)?
        private var contextMenuMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installContextMenuMonitor()
            // Grab first responder once the panel exists so arrow keys land
            // here instead of beeping. The search field can take focus away
            // (⌘F); the host hands it back via `claimFocusToken` on exit.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        private func installContextMenuMonitor() {
            uninstallContextMenuMonitor()
            guard let hostedWindow = window else { return }
            contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak hostedWindow] event in
                guard let self, let hostedWindow,
                      event.window === hostedWindow,
                      self.isContextMenuOpen?() != true,
                      QuickPasteMenuShortcut.matches(
                        event,
                        configured: QuickPasteKeyStore.shared.openMenuShortcut
                      ) else { return event }
                // Holding the command must never queue multiple menu requests.
                if !event.isARepeat { self.onOpenContextMenu?() }
                return nil
            }
        }

        func uninstallContextMenuMonitor() {
            if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
            contextMenuMonitor = nil
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

        /// Runs the action bound to `event`, if any. Built-in copy is checked
        /// before configurable commands, which cannot be assigned Cmd-C.
        private func handle(_ event: NSEvent) -> Bool {
            guard isContextMenuOpen?() != true else { return false }
            let store = QuickPasteKeyStore.shared
            if matches(event, QuickPasteKeyStore.copyCommand) {
                // The search field's field editor owns native text copy. A
                // background NSView can still receive key equivalents while
                // it is focused, so explicitly let NSTextView handle Cmd-C.
                if window?.firstResponder is NSTextView { return false }
                if !event.isARepeat { onCopy?() }
                return true
            }
            if QuickPasteMenuShortcut.matches(event, configured: store.openMenuShortcut) {
                if !event.isARepeat { onOpenContextMenu?() }
                return true
            }
            let optionHeld = event.modifierFlags.contains(.option)
            if matches(event, store.commitShortcut) {
                if !event.isARepeat { onCommit?(optionHeld) }
                return true
            }
            // ⌥ + commit key reaches us as a different shortcut (e.g. ⌥⏎
            // instead of ⏎). Detect that combo explicitly so plain-text paste
            // works with the default Return commit key.
            if optionHeld, matchesIgnoringOption(event, store.commitShortcut) {
                if !event.isARepeat { onCommit?(true) }
                return true
            }
            if matches(event, store.toggleSelectShortcut) {
                if !event.isARepeat { onToggleSelect?() }
                return true
            }
            if let itemAction = store.matchingItemAction(event) {
                if !event.isARepeat { onItemAction?(itemAction) }
                return true
            }
            if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
               scalar.value >= 49, scalar.value <= 57 {
                if !event.isARepeat { onQuickPasteIndex?(Int(scalar.value - 48) - 1) }
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

/// Window-local key monitor that keeps ↑/↓ driving the list highlight while
/// the search field owns the keyboard — the field editor would otherwise
/// swallow the arrows for caret movement, killing the type-then-pick flow.
/// Only consumes the two arrow keys and only while `isActive`; everything
/// else flows through to normal text editing untouched.
private struct SearchArrowRouter: NSViewRepresentable {
    var isActive: () -> Bool
    /// -1 for ↑, +1 for ↓.
    var onMove: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.isActive = isActive
        context.coordinator.onMove = onMove
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onMove = onMove
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isActive: (() -> Bool)?
        var onMove: ((Int) -> Void)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive?() == true else { return event }
                switch event.keyCode {
                case 126: self.onMove?(-1); return nil // ↑
                case 125: self.onMove?(1); return nil  // ↓
                default: return event
                }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private extension View {
    /// Applies the Escape shortcut only when `enabled`, so the focused search
    /// field can claim Esc (clear → exit) without the Cancel button closing
    /// the panel on the first press.
    @ViewBuilder
    func escapeShortcut(enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(.escape, modifiers: [])
        } else {
            self
        }
    }
}

/// Invisible probe that reports the `NSWindow` hosting the panel back to
/// SwiftUI (deferred a tick — `viewDidMoveToWindow` fires mid view-update).
/// Mirrors the menu-bar panel's reader; both stay private to their views.
private struct PanelWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onResolve = onResolve
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onResolve = onResolve
    }

    final class Probe: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [onResolve] in
                onResolve?(window)
            }
        }
    }
}
