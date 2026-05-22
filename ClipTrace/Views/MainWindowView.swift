import SwiftUI
import SwiftData
import AppKit

struct MainWindowView: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var allItems: [ClipboardItem]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var toasts = ToastCenter.shared
    @ObservedObject private var stats = CopyStatsStore.shared

    @AppStorage("fdaOnboardingDismissed") private var fdaOnboardingDismissed = false
    @AppStorage("pinnedCollapsed") private var pinnedCollapsed = false
    @State private var isMergingSelection = false

    private var filteredItems: [ClipboardItem] {
        vm.filteredItems(allItems)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            backgroundDecoration
                .allowsHitTesting(false)

            Group {
                switch nav.screen {
                case .list:
                    listScreen
                case .settings:
                    SettingsPanelView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .stats:
                    StatsPanelView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .trash:
                    TrashPanelView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: nav.screen)

            if let toast = toasts.current {
                ToastView(toast: toast) { toasts.dismiss() }
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                    .id(toast.id)
            }

            if !fdaOnboardingDismissed {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            fdaOnboardingDismissed = true
                        }
                    }
                    .transition(.opacity)
                    .zIndex(2)

                FullDiskAccessOnboardingView {
                    withAnimation(.easeOut(duration: 0.2)) {
                        fdaOnboardingDismissed = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.22), value: fdaOnboardingDismissed)
        .onAppear {
            vm.startMonitoring(context: modelContext)
            vm.backfillEmbeddings(context: modelContext)
        }
        .onDisappear {
            vm.stopMonitoring()
        }
        .sheet(isPresented: $vm.showExportPanel) {
            ExportPanelView(allItems: allItems) {
                vm.showExportPanel = false
            }
        }
        .sheet(isPresented: $vm.showSnippetEditor) {
            SnippetEditorView(
                onSave: { content, type, pinned in
                    vm.createSnippet(
                        content: content,
                        type: type,
                        pinned: pinned,
                        context: modelContext
                    )
                    vm.showSnippetEditor = false
                    ToastCenter.shared.show(
                        pinned ? L("snippet.savedAndPinned") : L("snippet.saved"),
                        systemImage: "square.and.pencil",
                        tint: .appAccent
                    )
                },
                onCancel: { vm.showSnippetEditor = false }
            )
        }
    }

    private var backgroundDecoration: some View {
        // Single, restrained accent halo in the upper-left — avoids the
        // overlapping multi-gradient look that reads as generic.
        RadialGradient(
            colors: [Color.appAccent.opacity(0.10), Color.clear],
            center: UnitPoint(x: 0.08, y: -0.05),
            startRadius: 20,
            endRadius: 520
        )
        .ignoresSafeArea()
    }

    private var listScreen: some View {
        // Compute the filtered list once per render — the empty check, the
        // selection bar, and the card list all consumed it independently
        // before, forcing 2–3 full filter passes per scope toggle.
        let items = filteredItems
        let split = splitItems(for: items)

        return VStack(spacing: 0) {
            header
            toolbar
                .background(
                    Rectangle()
                        .fill(.regularMaterial)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(.separator.opacity(0.5))
                                .frame(height: 0.5)
                        }
                )

            if items.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .bottom) {
                    cardList(split: split)
                    if vm.isSelectionMode {
                        selectionActionBar(for: items)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: vm.isSelectionMode)
            }
        }
        // Sits behind everything else — captures Space/↑/↓ when no editable
        // control owns focus, so QL preview + row navigation work from the
        // keyboard even though the actual list rows are SwiftUI views.
        .background(
            PreviewKeyCatcher(
                items: { filteredItems },
                focusedID: { vm.focusedItemID },
                setFocused: { vm.focusedItemID = $0 }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    private func selectionActionBar(for items: [ClipboardItem]) -> some View {
        let selected = vm.orderedSelectedItems(items)
        let blockReason = vm.mergeBlockReason(selectedItems: selected)
        let canMerge = blockReason == nil
        let allSelected = !items.isEmpty && selected.count == items.count

        return HStack(spacing: 10) {
            Text(L("selection.selectedFormat", selected.count, items.count))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            if let reason = blockReason, !selected.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            SelectionBarButton(
                systemName: allSelected ? "checkmark.circle.badge.xmark" : "checkmark.circle",
                title: allSelected ? L("selection.clear") : L("selection.selectAll")
            ) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    if allSelected { vm.clearSelection() }
                    else { vm.selectAll(items) }
                }
            }
            SelectionBarButton(systemName: "arrow.triangle.2.circlepath", title: L("selection.invert")) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    vm.invertSelection(items)
                }
            }

            Divider().frame(height: 18).opacity(0.5)

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    vm.exitSelectionMode()
                }
            } label: {
                Text(L("common.cancel"))
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.15))
            )
            .disabled(isMergingSelection)

            Button {
                performMerge(selected)
            } label: {
                HStack(spacing: 6) {
                    if isMergingSelection {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(.white)
                            .frame(width: 13, height: 13)
                        Text(L("selection.merging"))
                    } else {
                        Image(systemName: "square.stack.3d.up.fill")
                        Text(L("selection.mergeCountFormat", selected.count))
                    }
                }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(canMerge && !isMergingSelection ? Color.appAccent : Color.appAccent.opacity(0.35))
            )
            .disabled(!canMerge || isMergingSelection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thickMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    private func performMerge(_ selected: [ClipboardItem]) {
        guard !isMergingSelection else { return }
        let selectedCount = selected.count
        isMergingSelection = true

        Task { @MainActor in
            await Task.yield()
            let result = withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                vm.mergeSelected(selected, context: modelContext)
            }
            isMergingSelection = false

            guard result != nil else {
                ToastCenter.shared.show(
                    L("selection.mergeFailed"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                return
            }
            let suffix = MergeSettingsStore.shared.deleteOriginals ? L("selection.mergedSuffix.deleted") : ""
            ToastCenter.shared.show(
                L("selection.mergedFormat", selectedCount) + suffix,
                systemImage: "square.stack.3d.up.fill",
                tint: .appAccent
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("main.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(0.2)
                HStack(spacing: 8) {
                    HeaderStat(value: "\(allItems.count)", label: L("main.stat.records"))
                    HeaderStatDivider()
                    HeaderStat(value: "\(allItems.filter { $0.isFavorite }.count)", label: L("main.stat.favorites"))
                    if stats.enabled {
                        HeaderStatDivider()
                        HeaderStat(value: "\(stats.todayCount())", label: L("main.stat.today"), tint: .appAccent)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ScopeSegmentedControl(selected: $vm.selectedScope)

            Picker("", selection: $vm.selectedType) {
                Text(L("common.allTypes")).tag(nil as ClipboardItemType?)
                ForEach(ClipboardItemType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.icon).tag(type as ClipboardItemType?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 128)

            // Sort control — only meaningful inside 收藏, where the list no
            // longer has to stay strictly reverse-chronological.
            if vm.selectedScope == .favorites {
                Picker("", selection: $vm.favoritesSortOrder) {
                    ForEach(FavoritesSortOrder.allCases) { order in
                        Label(order.displayName, systemImage: order.icon).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .help(L("favorites.sort.help"))
            }

            ToolbarSearchField(
                text: $vm.searchText,
                mode: $vm.searchMode,
                activeTags: $vm.activeTags,
                availableTags: vm.allKnownTags(in: allItems),
                featureEnabled: vm.semanticFeatureEnabled,
                indexing: vm.isBackfillingEmbeddings
            )

            ToolbarIconButton(systemName: "square.and.pencil", help: L("toolbar.newSnippet")) {
                vm.showSnippetEditor = true
            }
            .keyboardShortcut("n", modifiers: .command)

            ToolbarIconButton(
                systemName: vm.isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle",
                help: vm.isSelectionMode ? L("toolbar.exitSelection") : L("toolbar.selectAndMerge")
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if vm.isSelectionMode {
                        vm.exitSelectionMode()
                    } else {
                        vm.enterSelectionMode()
                    }
                }
            }

            ToolbarIconButton(systemName: "trash", help: L("toolbar.trash")) {
                nav.showTrash()
            }

            ToolbarIconButton(systemName: "chart.bar.xaxis", help: L("toolbar.stats")) {
                nav.showStats()
            }

            ToolbarIconButton(systemName: "gearshape", help: L("toolbar.settings")) {
                nav.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.appAccent.opacity(0.15), lineWidth: 1)
                    .frame(width: 110, height: 110)
                Circle()
                    .stroke(Color.appAccent.opacity(0.08), lineWidth: 1)
                    .frame(width: 150, height: 150)
                Image(systemName: emptyStateIcon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.appAccent.opacity(0.85))
            }
            VStack(spacing: 6) {
                Text(emptyStateTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(emptyStateSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateIcon: String {
        if !vm.searchText.isEmpty { return "magnifyingglass" }
        switch vm.selectedScope {
        case .all: return "tray"
        case .favorites: return "star"
        }
    }

    private var emptyStateTitle: String {
        if !vm.searchText.isEmpty { return L("main.empty.title.noMatch") }
        switch vm.selectedScope {
        case .all: return L("main.empty.title.all")
        case .favorites: return L("main.empty.title.favorites")
        }
    }

    private var emptyStateSubtitle: String {
        if !vm.searchText.isEmpty { return L("main.empty.subtitle.noMatch") }
        switch vm.selectedScope {
        case .all: return L("main.empty.subtitle.all")
        case .favorites: return L("main.empty.subtitle.favorites")
        }
    }

    /// Split filtered items into a pinned section + the rest, but only when
    /// the user is on the "全部" scope — inside "收藏" a section header
    /// would just be noise so we fold pinned entries back to the top of the
    /// list. Pin-ordering lives here (not in the VM) so we only walk the list
    /// once per render.
    private func splitItems(for items: [ClipboardItem]) -> (pinned: [ClipboardItem], others: [ClipboardItem]) {
        let pinned = items.filter { $0.isPinned }
        let others = items.filter { !$0.isPinned }
        if vm.selectedScope == .all {
            return (pinned, others)
        }
        return ([], pinned + others)
    }

    private func cardList(split: (pinned: [ClipboardItem], others: [ClipboardItem])) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !split.pinned.isEmpty {
                    pinnedHeader(count: split.pinned.count)
                    if !pinnedCollapsed {
                        ForEach(split.pinned) { item in
                            cardRow(for: item)
                        }
                    }
                }
                ForEach(split.others) { item in
                    cardRow(for: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, vm.isSelectionMode ? 80 : 14)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func cardRow(for item: ClipboardItem) -> some View {
        ClipboardItemRow(
            item: item,
            isSelectionMode: vm.isSelectionMode,
            // In normal browsing mode the same "selected" affordance doubles
            // as the keyboard-focus marker for arrow-nav + Space preview.
            isSelected: vm.isSelectionMode ? vm.isSelected(item) : (vm.focusedItemID == item.id),
            onCopy: {
                vm.copyToClipboard(item)
                ToastCenter.shared.show(L("common.copied"))
            },
            onDelete: {
                vm.deleteItem(item, context: modelContext)
                ToastCenter.shared.show(L("common.deleted"), systemImage: "trash.fill", tint: .red)
            },
            onToggleFavorite: {
                let willFavorite = !item.isFavorite
                vm.toggleFavorite(item)
                ToastCenter.shared.show(
                    willFavorite ? L("action.favorited") : L("action.unfavorited"),
                    systemImage: "star.fill",
                    tint: .yellow
                )
            },
            onTogglePin: {
                let willPin = !item.isPinned
                vm.togglePin(item)
                ToastCenter.shared.show(
                    willPin ? L("action.pinned") : L("action.unpinned"),
                    systemImage: "pin.fill",
                    tint: .orange
                )
            },
            onRevealInFinder: {
                if let url = item.resolvedFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
            onOpenFile: {
                if let url = item.resolvedFileURL {
                    NSWorkspace.shared.open(url)
                }
            },
            onOpenURL: {
                openInBrowser(item.content)
            },
            onSaveImage: {
                ExportService.shared.exportItem(item)
            },
            onPreview: {
                showQuickLook(for: item)
            },
            onAddTag: { tag in
                vm.addTag(tag, to: item)
                try? modelContext.save()
            },
            onRemoveTag: { tag in
                vm.removeTag(tag, from: item)
                try? modelContext.save()
            }
        )
        .contextMenu { contextMenu(for: item) }
        // Mount only one tap gesture at a time. Having both a single- and a
        // double-tap on the same view makes SwiftUI delay the single tap
        // until it can rule out a second click — that's the lag we were
        // seeing on selection.
        // Single tap (non-selection mode) sets keyboard focus so Space and the
        // arrow keys know which row the user is "on". Kept as a simultaneous
        // gesture so it doesn't compete with the double-tap-to-copy below
        // (SwiftUI would otherwise add the click-disambiguation delay).
        .modifier(FocusTapModifier(enabled: !vm.isSelectionMode) {
            vm.focusedItemID = item.id
        })
        .gesture(
            vm.isSelectionMode
                ? TapGesture(count: 1).onEnded {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                        vm.toggleSelection(item)
                    }
                }
                : TapGesture(count: 2).onEnded {
                    vm.copyToClipboard(item)
                    ToastCenter.shared.show(L("common.copied"))
                }
        )
    }

    private func pinnedHeader(count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { pinnedCollapsed.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(L("main.pinnedCountFormat", count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Image(systemName: pinnedCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button(L("action.copy"), systemImage: "doc.on.doc") {
            vm.copyToClipboard(item)
            ToastCenter.shared.show(L("common.copied"))
        }
        if item.itemType == .url {
            Divider()
            Button(L("action.openInBrowser"), systemImage: "safari") {
                openInBrowser(item.content)
            }
        }
        if item.resolvedFileURL != nil {
            Divider()
            Button(L("action.revealInFinder"), systemImage: "folder") {
                if let url = item.resolvedFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button(L("action.openFile"), systemImage: "arrow.up.forward.app") {
                if let url = item.resolvedFileURL {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L("action.openWith"), systemImage: "app.badge") {
                if let url = item.resolvedFileURL {
                    FileOpener.openWithChooser(url: url)
                }
            }
        }
        Divider()
        Button(item.isFavorite ? L("action.unfavorite") : L("action.favorite"),
               systemImage: item.isFavorite ? "star.slash" : "star") {
            let willFavorite = !item.isFavorite
            vm.toggleFavorite(item)
            ToastCenter.shared.show(
                willFavorite ? L("action.favorited") : L("action.unfavorited"),
                systemImage: "star.fill",
                tint: .yellow
            )
        }
        Button(item.isPinned ? L("action.unpin") : L("action.pin"),
               systemImage: item.isPinned ? "pin.slash" : "pin") {
            let willPin = !item.isPinned
            vm.togglePin(item)
            ToastCenter.shared.show(
                willPin ? L("action.pinned") : L("action.unpinned"),
                systemImage: "pin.fill",
                tint: .orange
            )
        }
        Divider()
        Button(L("action.exportOne"), systemImage: "square.and.arrow.up") {
            ExportService.shared.exportItem(item)
        }
        Divider()
        Button(L("action.delete"), systemImage: "trash", role: .destructive) {
            vm.deleteItem(item, context: modelContext)
            ToastCenter.shared.show(L("common.deleted"), systemImage: "trash.fill", tint: .red)
        }
    }

    /// Open the native QuickLook panel for `item`, using the current filtered
    /// list as the navigation stack so arrow keys move through neighbors.
    private func showQuickLook(for item: ClipboardItem) {
        let items = filteredItems
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        vm.focusedItemID = item.id
        QuickLookCoordinator.shared.preview(items: items, startingAt: index)
    }

    private func openInBrowser(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate: String = {
            if trimmed.contains("://") { return trimmed }
            return "https://\(trimmed)"
        }()
        if let url = URL(string: candidate) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Conditional simultaneous tap gesture used by the row to set keyboard focus
/// on single click without triggering the double-tap disambiguation delay.
private struct FocusTapModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(TapGesture(count: 1).onEnded(action))
        } else {
            content
        }
    }
}

// MARK: - Header stat chip

private struct HeaderStat: View {
    let value: String
    let label: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct HeaderStatDivider: View {
    var body: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 2.5, height: 2.5)
            .opacity(0.6)
    }
}

// MARK: - Search field

private struct ToolbarSearchField: View {
    @Binding var text: String
    @Binding var mode: SearchMode
    /// Lowercased keys of tags that are currently narrowing the list. Owned
    /// by the VM so other components (filters, list rendering) can observe.
    @Binding var activeTags: Set<String>
    /// Display strings (original casing) of every tag in the live history —
    /// the source for the autocomplete picker.
    var availableTags: [String]
    /// Master feature toggle from settings — when false, the semantic
    /// segment hides entirely so the search bar collapses to plain text.
    var featureEnabled: Bool
    /// True while the VM is backfilling embeddings. Disables the semantic
    /// segment with a "building index" hint instead of letting users switch
    /// into a half-populated mode.
    var indexing: Bool

    @FocusState private var focused: Bool
    @State private var showingTagPicker = false

    /// Active mode color — distinct per mode so users can tell at a glance
    /// which engine is driving the results.
    private var tint: Color {
        switch mode {
        case .fullText: return .appAccent
        case .semantic: return .appAccent
        case .tag:      return .appAccent
        }
    }

    private var placeholder: String {
        // Hide the hint as soon as the user has any active filter (chips or
        // typed text) — TextField hides its placeholder on non-empty text
        // automatically, but chips don't, so we suppress it manually.
        guard activeTags.isEmpty else { return "" }
        switch mode {
        case .fullText: return L("common.searchContent")
        case .semantic: return L("common.semanticSearch")
        case .tag:      return L("common.tagSearch")
        }
    }

    /// Trailing `#token` at the end of `text` in non-tag modes, or the whole
    /// trailing token in tag mode (where every word is a tag candidate). Nil
    /// means "no token currently being typed".
    private var tagQuery: String? {
        if mode == .tag {
            // Last whitespace-separated word, or empty buffer if the user
            // just typed a space — either way we want the picker open.
            let trailing = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return trailing
        }
        guard let hashIdx = text.lastIndex(of: "#") else { return nil }
        if hashIdx > text.startIndex,
           !text[text.index(before: hashIdx)].isWhitespace {
            return nil
        }
        let rest = text[text.index(after: hashIdx)...]
        if rest.contains(where: { $0.isWhitespace }) { return nil }
        return String(rest)
    }

    /// Tags shown in the popover: not already selected, and (when the user
    /// has typed characters into the trailing token) case-insensitively
    /// contains the query.
    private var suggestedTags: [String] {
        let pool = availableTags.filter { !activeTags.contains($0.lowercased()) }
        guard let q = tagQuery, !q.isEmpty else { return pool }
        return pool.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private var sortedActiveTags: [String] {
        activeTags.sorted()
    }

    private func displayName(forKey key: String) -> String {
        availableTags.first(where: { $0.lowercased() == key }) ?? key
    }

    private func selectTag(_ tag: String) {
        if mode == .tag {
            // Replace the trailing typing buffer with the picked tag — append
            // a trailing space so the user can immediately type the next one.
            if let lastSpace = text.lastIndex(of: " ") {
                text = String(text[...lastSpace])
            } else {
                text = ""
            }
        } else if let hashIdx = text.lastIndex(of: "#") {
            text = String(text[..<hashIdx])
        }
        activeTags.insert(tag.lowercased())
        showingTagPicker = false
    }

    /// Called whenever `text` changes in tag mode. Commits any whitespace-
    /// terminated tokens as chips (matching available tags case-insensitively
    /// with prefix fallback). The last token stays in the buffer until the
    /// user types another space.
    private func commitTagBufferIfNeeded() {
        guard mode == .tag else { return }
        guard text.contains(" ") else { return }

        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        let trailing = parts.last.map(String.init) ?? ""
        let committed = parts.dropLast()
        let lowercasedTags = availableTags.map { ($0, $0.lowercased()) }

        for raw in committed {
            let token = String(raw).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let key = token.lowercased()
            if let match = lowercasedTags.first(where: { $0.1 == key })?.0 {
                activeTags.insert(match.lowercased())
            } else if let prefix = lowercasedTags.first(where: { $0.1.hasPrefix(key) })?.0 {
                activeTags.insert(prefix.lowercased())
            } else {
                // Unknown tag — still accept it so the user can search for
                // a tag they remember even if no item carries it yet.
                activeTags.insert(key)
            }
        }
        text = trailing
    }

    private func handleSubmit() {
        guard mode == .tag else { return }
        let token = text.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        let key = token.lowercased()
        if let match = availableTags.first(where: { $0.lowercased() == key }) {
            activeTags.insert(match.lowercased())
        } else if let prefix = availableTags.first(where: { $0.lowercased().hasPrefix(key) }) {
            activeTags.insert(prefix.lowercased())
        } else {
            activeTags.insert(key)
        }
        text = ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? tint : .secondary)
                .animation(.easeOut(duration: 0.15), value: focused)

            // Chips live inside a horizontal scroll so they can never push
            // the outer bar past its max width, regardless of how many
            // tags the user stacks up.
            if !sortedActiveTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(sortedActiveTags, id: \.self) { key in
                            TagChipInline(label: displayName(forKey: key)) {
                                activeTags.remove(key)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxWidth: 140)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .help(L("common.searchHint.tooltip"))
                .frame(maxWidth: .infinity)
                .onChange(of: text) { _, _ in
                    commitTagBufferIfNeeded()
                    showingTagPicker = pickerShouldShow()
                }
                .onChange(of: focused) { _, isFocused in
                    if mode == .tag {
                        showingTagPicker = isFocused
                    }
                }
                .onSubmit { handleSubmit() }
                .popover(
                    isPresented: $showingTagPicker,
                    attachmentAnchor: .point(.bottomLeading),
                    arrowEdge: .top
                ) {
                    TagSuggestionPopover(
                        tags: suggestedTags,
                        onSelect: selectTag
                    )
                }

            if !text.isEmpty || !activeTags.isEmpty {
                Button {
                    text = ""
                    activeTags.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("common.clearSearch"))
                .transition(.opacity)
            }

            Divider().frame(height: 12).opacity(0.4)
            SearchModeSegment(
                icon: "text.magnifyingglass",
                title: L("common.searchMode.full"),
                isOn: mode == .fullText,
                tint: .appAccent
            ) {
                switchMode(to: .fullText)
            }
            .focusable(false)
            if featureEnabled {
                SearchModeSegment(
                    icon: indexing ? "hourglass" : "sparkle",
                    title: indexing
                        ? L("common.searchMode.indexing")
                        : L("common.searchMode.semantic"),
                    isOn: mode == .semantic && !indexing,
                    tint: .appAccent,
                    disabled: indexing,
                    showsSpinner: indexing
                ) {
                    if indexing {
                        ToastCenter.shared.show(
                            L("search.semantic.indexing.toast"),
                            systemImage: "hourglass",
                            tint: .orange
                        )
                        return
                    }
                    switchMode(to: .semantic)
                }
                .focusable(false)
            }
            SearchModeSegment(
                icon: "tag",
                title: L("common.searchMode.tag"),
                isOn: mode == .tag,
                tint: .appAccent
            ) {
                switchMode(to: .tag, clearText: true)
            }
            .focusable(false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .opacity(focused ? 0.95 : 0.7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focused ? tint.opacity(0.6) : Color.secondary.opacity(0.18),
                    lineWidth: focused ? 1 : 0.5
                )
        )
        .frame(minWidth: 200, maxWidth: .infinity)
        .layoutPriority(1)
        // If settings flip the feature off while we're in semantic mode,
        // fall back to plain text — otherwise the search bar would behave
        // semantically with no visible affordance.
        .onChange(of: featureEnabled) { _, isOn in
            if !isOn, mode == .semantic { mode = .fullText }
        }
        // Same idea while a backfill is in-flight: drop into text mode so
        // the user actually sees results until the index is ready.
        .onChange(of: indexing) { _, isOn in
            if isOn, mode == .semantic { mode = .fullText }
        }
    }

    private func pickerShouldShow() -> Bool {
        if mode == .tag {
            return focused
        }
        return tagQuery != nil
    }

    /// Commit a mode change without dragging SwiftUI's implicit animation
    /// transactions along (border tint, popover open/close, segment fill
    /// would otherwise all cross-fade and feel sluggish).
    private func switchMode(to newMode: SearchMode, clearText: Bool = false) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            mode = newMode
            if clearText { text = "" }
            showingTagPicker = pickerShouldShow()
        }
    }
}

/// Inline tag pill inside the search bar. Shows the tag label plus an `×`
/// that removes it from the active filter set.
private struct TagChipInline: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appAccent.opacity(0.18))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 0.5)
        )
        .foregroundStyle(Color.appAccent)
        .fixedSize()
    }
}

/// Popover shown beneath the search field while the user is typing a `#tag`
/// query. Lists available tags (filtered by the query) and forwards taps to
/// the caller, which inserts the tag and clears the typed token.
private struct TagSuggestionPopover: View {
    let tags: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tags.isEmpty {
                Text(L("search.tagPicker.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tags, id: \.self) { tag in
                            TagSuggestionRow(tag: tag) { onSelect(tag) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 200)
    }
}

private struct TagSuggestionRow: View {
    let tag: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appAccent)
                Text(tag)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle().fill(hovering ? Color.appAccent.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ScopeSegmentedControl: View {
    @Binding var selected: ListScope

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ListScope.allCases) { scope in
                let isOn = selected == scope
                Button {
                    selected = scope
                } label: {
                    Image(systemName: scope.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .secondary)
                        .frame(width: 30, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isOn ? Color.appAccent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .hoverTip(scope.displayName)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.separator.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct SearchModeSegment: View {
    let icon: String
    let title: String
    let isOn: Bool
    let tint: Color
    /// When true, the segment looks dimmed and reads as non-interactive.
    /// The click handler still fires (the parent uses it to surface a toast
    /// explaining why the mode is currently unavailable).
    var disabled: Bool = false
    /// Replaces the icon with a tiny progress indicator so users can tell at
    /// a glance that the disabled state is "loading" rather than "broken".
    var showsSpinner: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isOn
                            ? AnyShapeStyle(tint)
                            : AnyShapeStyle(hovering && !disabled
                                ? Color.secondary.opacity(0.18)
                                : Color.clear)
                    )
            )
            .opacity(disabled ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if disabled { return .secondary }
        if isOn { return .white }
        return hovering ? .primary : .secondary
    }
}

// MARK: - Selection bar button

private struct SelectionBarButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Color.secondary.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Toolbar icon button

struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isHovered ? Color.secondary.opacity(0.18) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .hoverTip(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Hover tooltip

/// Lightweight hover tooltip that pops up faster than macOS's default
/// `.help(...)` (which sits behind a ~1.5s system delay). Renders a small
/// rounded label below the icon after `delay` seconds of sustained hover.
private struct HoverTipModifier: ViewModifier {
    let text: String
    let delay: TimeInterval

    @State private var hovering = false
    @State private var showTip = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard hovering else { return }
                        withAnimation(.easeOut(duration: 0.12)) { showTip = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { showTip = false }
                }
            }
            .overlay(alignment: .bottom) {
                if showTip {
                    HoverTipBubble(text: text)
                        .fixedSize()
                        .offset(y: 24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(999)
                }
            }
    }
}

private struct HoverTipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.85))
            )
    }
}

extension View {
    /// Faster hover tooltip than the system `.help(...)`. Default ~0.35s
    /// delay (vs. macOS's ~1.5s) so the label appears almost immediately.
    func hoverTip(_ text: String, delay: TimeInterval = 0.35) -> some View {
        modifier(HoverTipModifier(text: text, delay: delay))
    }
}
