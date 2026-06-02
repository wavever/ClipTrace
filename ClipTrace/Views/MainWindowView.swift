import SwiftUI
import SwiftData
import AppKit

/// Thin wrapper that owns the pagination state and hands the current page
/// size to `MainWindowContent`. Splitting the view here lets the inner view
/// rebuild its `@Query` with a fresh `fetchLimit` whenever `pageSize` bumps,
/// without resetting any of the row-level `@State` (hover, focused item).
struct MainWindowView: View {
    @EnvironmentObject var vm: ClipboardViewModel

    /// First-page fetch cap. Cold start renders at most this many rows from
    /// SwiftData — the rest are pulled in by the load-more sentinel as the
    /// user scrolls. Chosen so the initial viewport (~10–15 rows) is well-
    /// covered without ever materialising the whole history up front.
    @State private var pageSize: Int = 40
    /// Debounce so a chain of sentinel `.onAppear` calls (which can fire
    /// rapidly while the bottom rebalances) only triggers one bump.
    @State private var isBumpingPage: Bool = false

    private static let pageStep: Int = 40
    private static let pageCap: Int = 600

    var body: some View {
        // When the user is searching or filtering by tag, results may live
        // beyond the current page; bypass pagination so they're never hidden.
        let searching = !vm.searchText.isEmpty || !vm.activeTags.isEmpty
        let effective = searching ? Self.pageCap : pageSize

        MainWindowContent(
            pageSize: effective,
            canLoadMore: !searching && pageSize < Self.pageCap,
            onRequestMore: requestMore
        )
    }

    private func requestMore() {
        guard !isBumpingPage, pageSize < Self.pageCap else { return }
        isBumpingPage = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            pageSize = min(pageSize + Self.pageStep, Self.pageCap)
            isBumpingPage = false
        }
    }
}

struct MainWindowContent: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Query private var allItems: [ClipboardItem]
    @Environment(\.modelContext) private var modelContext

    let pageSize: Int
    let canLoadMore: Bool
    let onRequestMore: () -> Void

    init(pageSize: Int, canLoadMore: Bool, onRequestMore: @escaping () -> Void) {
        self.pageSize = pageSize
        self.canLoadMore = canLoadMore
        self.onRequestMore = onRequestMore
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = pageSize
        // Keep large image bytes and embedding vectors faulted until a visible
        // row or an active semantic search actually needs them.
        descriptor.propertiesToFetch = [
            \.id,
            \.type,
            \.content,
            \.fileURL,
            \.sourceApp,
            \.createdAt,
            \.isFavorite,
            \.isPinned,
            \.preview,
            \.deletedAt,
            \.tagsRaw,
            \.customTitle,
        ]
        _allItems = Query(descriptor)
    }

    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var toasts = ToastCenter.shared
    @ObservedObject private var stats = CopyStatsStore.shared
    @ObservedObject private var confirm = ConfirmationCenter.shared

    @AppStorage("fdaOnboardingDismissed") private var fdaOnboardingDismissed = false
    @AppStorage("pinnedCollapsed") private var pinnedCollapsed = false
    @State private var isMergingSelection = false
    /// Non-nil when the user picked "Rename" from a row's context menu —
    /// drives the rename sheet at the root level so it survives row-view churn.
    @State private var renameTarget: ClipboardItem?

    /// Header-stat caches. With pagination, `allItems` only contains the
    /// current page so these come from dedicated `fetchCount` / tag queries
    /// against the model context — that way the header always shows the true
    /// total even when the visible list is just the first few rows.
    @State private var totalRecordsCache: Int = 0
    @State private var favoritesCountCache: Int = 0
    @State private var allKnownTagsCache: [String] = []

    /// One spring drives both the highlight glide and the scroll follow, in a
    /// single transaction, so they move as one. `interpolatingSpring` is the key
    /// to continuity: unlike `.spring` (which *retargets* and restarts its curve
    /// on every key-repeat event — the stutter), it's additive, so overlapping
    /// presses accumulate velocity into one unbroken glide. A small `bounce`
    /// leaves the soft "带点阻尼" settle without wobbling during fast repeats.
    private static let focusSpring: Animation = .interpolatingSpring(duration: 0.3, bounce: 0.16)

    private var filteredItems: [ClipboardItem] {
        vm.filteredItems(allItems)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            backgroundDecoration
                .allowsHitTesting(false)

            // The card list stays mounted as the base layer; Settings / Stats /
            // Trash cross-fade in over it. Returning is then a pure reveal — we
            // no longer tear down and rebuild the (heavy) list view tree on
            // every back-navigation, which is what made the settings→list
            // transition hitch (and occasionally spin the beachball).
            listScreen

            if nav.screen != .list {
                secondaryScreen
                    .transition(.opacity)
            }

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

            // Single host for every confirm-before-delete dialog in the app.
            if let request = confirm.request {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { confirm.dismiss() }
                    .transition(.opacity)
                    .zIndex(4)

                ConfirmationDialogView(
                    request: request,
                    onConfirm: { confirm.runAndDismiss() },
                    onCancel: { confirm.dismiss() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(5)
            }
        }
        .animation(.easeOut(duration: 0.22), value: nav.screen)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: confirm.request?.id)
        .animation(.easeOut(duration: 0.22), value: fdaOnboardingDismissed)
        .onAppear {
            // Foreground work: the pasteboard poller must be running before
            // the user can copy anything.
            vm.startMonitoring(context: modelContext)
            refreshDerivedCaches()
        }
        .task {
            // Historical OCR + embedding repair is maintenance work, not part
            // of first paint. Run it sequentially after launch settles; the
            // task is cancelled automatically if this window disappears.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await vm.backfillOCR(context: modelContext)
            guard !Task.isCancelled else { return }
            await vm.backfillEmbeddings(context: modelContext)
        }
        .onChange(of: allItems.count) { _, _ in
            refreshDerivedCaches()
        }
        .onChange(of: vm.tagCatalogVersion) { _, _ in
            refreshTagCatalog()
        }
        .onChange(of: vm.favoritesVersion) { _, _ in
            refreshFavoritesCount()
        }
        .onDisappear {
            vm.stopMonitoring()
        }
        .sheet(isPresented: $vm.showExportPanel) {
            ExportPanelView {
                vm.showExportPanel = false
            }
        }
        .sheet(item: $renameTarget) { item in
            RenameClipSheet(
                initialTitle: item.effectiveCustomTitle ?? "",
                fallback: defaultDisplayTitle(for: item),
                onCommit: { newTitle in
                    vm.rename(item, to: newTitle, context: modelContext)
                    renameTarget = nil
                },
                onCancel: { renameTarget = nil }
            )
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

    /// Single, restrained accent halo in the upper-left — avoids the
    /// overlapping multi-gradient look that reads as generic.
    ///
    /// `equatable` lets SwiftUI bail out of re-laying-out this layer when the
    /// parent body re-runs (which it does on every keystroke / scope toggle).
    private var backgroundDecoration: some View {
        BackgroundHaloView()
    }

    /// Settings / Stats / Trash, each layered over a private copy of the shared
    /// backdrop (blur + accent halo). The `.behindWindow` material samples the
    /// desktop, not the in-window content beneath it, so this fully occludes the
    /// list that stays mounted behind — letting us keep the list warm without it
    /// bleeding through the panel.
    @ViewBuilder
    private var secondaryScreen: some View {
        ZStack(alignment: .top) {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            backgroundDecoration
                .allowsHitTesting(false)

            switch nav.screen {
            case .settings: SettingsPanelView()
            case .stats:    StatsPanelView()
            case .trash:    TrashPanelView()
            case .list:     EmptyView()
            }
        }
    }

    /// Refresh the cached aggregates by querying the model context directly.
    /// Required since `allItems` is now a *paged* slice — counting/iterating
    /// it would underreport once the user scrolls past the first batch. We
    /// hand off to lighter SwiftData APIs (`fetchCount` for headcounts, a
    /// predicate-filtered fetch for the tag catalog) so this stays fast even
    /// when the live history is at its 500-item cap.
    private func refreshDerivedCaches() {
        refreshTotalRecords()
        refreshFavoritesCount()
        refreshTagCatalog()
    }

    private func refreshTotalRecords() {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        totalRecordsCache = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func refreshFavoritesCount() {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isFavorite }
        )
        favoritesCountCache = (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func refreshTagCatalog() {
        // Only items that actually carry tags participate, keeping this much
        // cheaper than a full history walk.
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.tagsRaw != nil }
        )
        descriptor.propertiesToFetch = [\.deletedAt, \.tagsRaw]
        if let tagged = try? modelContext.fetch(descriptor) {
            allKnownTagsCache = vm.allKnownTags(in: tagged)
        } else {
            allKnownTagsCache = []
        }
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
                // Lift the toolbar (and the search field's suggestion panel,
                // which overlays downward into the list area) above the card
                // list so the dropdown isn't drawn behind the rows.
                .zIndex(1)

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
        // Sits behind everything else — captures Space/↑/↓/Return/⌫ when no
        // editable control owns focus, so QL preview, row navigation, copy,
        // and delete all work from the keyboard even though the actual list
        // rows are SwiftUI views. `navigableItems` (not the raw filtered list)
        // is the navigation order so "next row" always means the next *visible*
        // row — pinned-first, skipping a collapsed pinned section.
        .background {
            // The list now stays mounted behind Settings/Stats/Trash, so only
            // arm the key catcher on the list screen — a persistent catcher
            // would hold first-responder there and let Space/⌫/arrows act on the
            // hidden list (a stray ⌫ could even delete a clip).
            if nav.screen == .list {
                PreviewKeyCatcher(
                    items: { navigableItems },
                focusedID: { vm.focusedItemID },
                setFocused: { id in
                    // Animate just the focus move so the sliding highlight
                    // springs from the old row to the new one. The scroll-follow
                    // is a separate, layout-settled step (see `cardList`'s
                    // onChange): doing it here, synchronously inside the key
                    // event, raced the layout and stranded the list during fast
                    // key-repeat. Coherence is automatic anyway — the highlight
                    // tracks the row's real frame, so it glides with the scroll
                    // however the scroll is triggered.
                    withAnimation(Self.focusSpring) { vm.focusedItemID = id }
                },
                copyAction: { item in
                    vm.copyToClipboard(item)
                    ToastCenter.shared.show(L("common.copied"))
                },
                deleteAction: { item in
                    deleteFocusedAndAdvance(item)
                }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        // Same thin top tint as Settings/Stats/Trash, layered over the shared
        // VisualEffect + accent halo so the list screen carries the identical
        // theme-colored gradient as every other screen.
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.appAccent.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)
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
            AppLogoMark(size: 36, shadowRadius: 3, shadowOpacity: 0.45)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("main.title"))
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(0.2)
                HStack(spacing: 8) {
                    HeaderStat(value: "\(totalRecordsCache)", label: L("main.stat.records"))
                    HeaderStatDivider()
                    HeaderStat(value: "\(favoritesCountCache)", label: L("main.stat.favorites"))
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

            PaperMenuPicker(
                options: [PaperMenuOption(nil as ClipboardItemType?, L("common.allTypes"), icon: "square.grid.2x2")]
                    + ClipboardItemType.allCases.map { PaperMenuOption($0, $0.displayName, icon: $0.icon) },
                selection: $vm.selectedType,
                width: 128
            )

            // Sort control — only meaningful inside 收藏, where the list no
            // longer has to stay strictly reverse-chronological.
            if vm.selectedScope == .favorites {
                PaperMenuPicker(
                    options: FavoritesSortOrder.allCases.map { PaperMenuOption($0, $0.displayName, icon: $0.icon) },
                    selection: $vm.favoritesSortOrder,
                    width: 120,
                    help: L("favorites.sort.help")
                )
            }

            ToolbarSearchField(
                text: $vm.searchText,
                mode: $vm.searchMode,
                activeTags: $vm.activeTags,
                availableTags: allKnownTagsCache,
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

    /// Any active filter — a keyword query or a tag chip — means an empty list
    /// is a "no match" result, not just an empty scope.
    private var isFiltering: Bool {
        !vm.searchText.isEmpty || !vm.activeTags.isEmpty
    }

    private var emptyStateIcon: String {
        if isFiltering { return "magnifyingglass" }
        switch vm.selectedScope {
        case .all: return "tray"
        case .favorites: return "star"
        }
    }

    private var emptyStateTitle: String {
        if isFiltering { return L("main.empty.title.noMatch") }
        switch vm.selectedScope {
        case .all: return L("main.empty.title.all")
        case .favorites: return L("main.empty.title.favorites")
        }
    }

    private var emptyStateSubtitle: String {
        if isFiltering { return L("main.empty.subtitle.noMatch") }
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
        // Single partition pass; previous implementation walked the list
        // twice (filter pinned + filter not-pinned).
        var pinned: [ClipboardItem] = []
        var others: [ClipboardItem] = []
        pinned.reserveCapacity(items.count / 4)
        others.reserveCapacity(items.count)
        for item in items {
            if item.isPinned { pinned.append(item) } else { others.append(item) }
        }
        if vm.selectedScope == .all {
            return (pinned, others)
        }
        return ([], pinned + others)
    }

    /// The list flattened in the exact order it's drawn on screen, for
    /// keyboard navigation: pinned rows first (when that section is expanded),
    /// then the rest. Arrow keys, Return, and ⌫ all walk this so the focused
    /// row matches what the user sees and never lands on a hidden/collapsed one.
    private var navigableItems: [ClipboardItem] {
        let split = splitItems(for: filteredItems)
        guard !split.pinned.isEmpty else { return split.others }
        return pinnedCollapsed ? split.others : split.pinned + split.others
    }

    /// Copy used by both the row trash button and the context-menu delete:
    /// pops the shared confirm dialog, then soft-deletes (to trash) or
    /// hard-deletes depending on the trash setting.
    private func requestDeleteItem(_ item: ClipboardItem) {
        ConfirmationCenter.shared.confirm(
            title: L("confirm.deleteItem.title"),
            message: FilterSettingsStore.shared.trashEnabled
                ? L("confirm.deleteItem.message")
                : L("confirm.permanent.message"),
            confirmLabel: L("common.delete"),
            icon: "trash"
        ) {
            vm.deleteItem(item, context: modelContext)
            ToastCenter.shared.show(L("common.deleted"), systemImage: "trash.fill", tint: .red)
        }
    }

    /// Delete the focused row from the keyboard, then move focus to whichever
    /// neighbor slides into its slot — the following row, or the previous one
    /// if it was the last — so repeated ⌫ presses keep clearing without
    /// leaving focus stranded on a now-deleted item. Gated behind the same
    /// confirm dialog as every other delete; the neighbor is resolved at
    /// confirm time so the focus lands correctly even if the list shifted.
    private func deleteFocusedAndAdvance(_ item: ClipboardItem) {
        ConfirmationCenter.shared.confirm(
            title: L("confirm.deleteItem.title"),
            message: FilterSettingsStore.shared.trashEnabled
                ? L("confirm.deleteItem.message")
                : L("confirm.permanent.message"),
            confirmLabel: L("common.delete"),
            icon: "trash"
        ) {
            let list = navigableItems
            let idx = list.firstIndex(where: { $0.id == item.id })
            vm.deleteItem(item, context: modelContext)
            if let idx {
                if idx + 1 < list.count {
                    vm.focusedItemID = list[idx + 1].id
                } else if idx - 1 >= 0 {
                    vm.focusedItemID = list[idx - 1].id
                } else {
                    vm.focusedItemID = nil
                }
            }
            ToastCenter.shared.show(L("common.deleted"), systemImage: "trash.fill", tint: .red)
        }
    }

    private func cardList(split: (pinned: [ClipboardItem], others: [ClipboardItem])) -> some View {
        ScrollViewReader { proxy in
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
                    // Load-more sentinel: a near-invisible footer that, when it
                    // scrolls into view inside the LazyVStack, asks the parent to
                    // grow the page size. `.id(pageSize)` makes each new page
                    // produce a fresh sentinel so its one-shot `.onAppear` re-arms
                    // after every successful expansion.
                    if canLoadMore && allItems.count >= pageSize {
                        LoadMoreSentinel(onAppear: onRequestMore)
                            .id(pageSize)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, vm.isSelectionMode ? 80 : 14)
            }
            .scrollContentBackground(.hidden)
            // Single sliding focus highlight, positioned from the focused row's
            // live frame. Because it tracks the real frame every layout pass, it
            // stays glued to the row through a scroll (matching the content's
            // speed exactly) and only the focus *change* is animated — see
            // `focusHighlight`.
            .overlayPreferenceValue(RowBoundsKey.self) { anchors in
                focusHighlight(anchors: anchors)
            }
            // Follow keyboard focus. Done here (after the state settles and the
            // row is laid out) rather than inside the key handler, so it keeps up
            // reliably during fast key-repeat — synchronous scrolling there got
            // dropped and left the list stranded. `anchor: nil` scrolls only the
            // minimum: nothing moves until the focused row would slide off the
            // top or bottom edge. The anchor-driven highlight tracks the row's
            // real frame, so it stays glued through the scroll at matching speed.
            .onChange(of: vm.focusedItemID) { _, id in
                guard let id else { return }
                withAnimation(Self.focusSpring) {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }

    /// The one keyboard-focus highlight, parked over the focused row via its
    /// published frame. Drawn only in browse mode — selection/merge mode keeps
    /// its static per-row checkmarks/tint since several rows can be active.
    @ViewBuilder
    private func focusHighlight(anchors: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if !vm.isSelectionMode,
               let id = vm.focusedItemID,
               let anchor = anchors[id] {
                let rect = geo[anchor]
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.appAccent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.appAccent, lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        // Clip to the scroll viewport so the highlight gets cut at the top/bottom
        // edge exactly like the row content does. Without this it's an unclipped
        // overlay, so a focused row sitting at (or mid-scroll past) an edge drew
        // its highlight outside the list, over the toolbar.
        .clipped()
        // Purely decorative — never let it intercept scroll or row clicks.
        .allowsHitTesting(false)
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
            onDelete: { requestDeleteItem(item) },
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
        // Gate the heavy row body on its value inputs (id + selection) so a
        // focus move only re-renders the two rows that actually change, not
        // every visible row. Keeps arrow-key scrolling smooth — see the
        // `==` on ClipboardItemRow.
        .equatable()
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
        // Publish this row's live frame so the list can park a single sliding
        // highlight on whichever row is focused (see `focusHighlight`). Driving
        // the highlight from the real frame is what keeps it glued to the row
        // during a scroll — it moves at exactly the content's speed because it
        // *is* the content's position, not a second animation racing it.
        .anchorPreference(key: RowBoundsKey.self, value: .bounds) { [item.id: $0] }
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
        Button(L("action.copyAsPlainText"), systemImage: "textformat") {
            vm.copyAsPlainText(item)
            ToastCenter.shared.show(L("common.copiedPlainText"))
        }
        .keyboardShortcut("c", modifiers: [.command, .option])
        Divider()
        Button(L("action.rename"), systemImage: "pencil") {
            renameTarget = item
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
            requestDeleteItem(item)
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

    /// Heuristic title used as the rename sheet's placeholder/fallback so
    /// users see what the row currently shows before they type anything.
    private func defaultDisplayTitle(for item: ClipboardItem) -> String {
        if let url = item.resolvedFileURL { return url.lastPathComponent }
        let firstLine = (item.preview ?? item.content)
            .components(separatedBy: .newlines)
            .first ?? ""
        return firstLine.isEmpty ? item.itemType.displayName : firstLine
    }

}

// MARK: - Rename sheet

/// Modal for assigning a custom title to a clipboard row. Empty / whitespace
/// input clears the custom title back to the default heuristic.
private struct RenameClipSheet: View {
    let initialTitle: String
    let fallback: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""
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
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { onCommit(draft) }

            HStack {
                Spacer()
                Button(L("common.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save")) { onCommit(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
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
    /// Tag mode's text field is a *local* typing buffer — it filters the
    /// dropdown but is never written to `vm.searchText`. Keeping it off the
    /// published binding is the whole performance fix: typing a tag query no
    /// longer re-renders the list or bumps the @Query's fetch limit. Only
    /// committing a chip (which mutates `activeTags`) refilters the history.
    @State private var tagDraft = ""
    /// Natural width of the active-tag chip rail. Measured so the rail can hug
    /// its content (capped) instead of a horizontal ScrollView greedily
    /// reserving its full max width — that reserved-but-empty space was leaving
    /// a gap between the chips and the text cursor.
    @State private var chipsWidth: CGFloat = 0
    /// Measured height of the search bar, used to park the suggestion panel
    /// exactly below it (the earlier alignment-guide trick let the panel drift
    /// up over the field on some layouts; a measured offset can't).
    @State private var barHeight: CGFloat = 0
    /// Measured width of the scrollable chips+field rail. Combined with
    /// `chipsWidth` it decides how much room is left for the text field before
    /// the rail starts scrolling.
    @State private var railWidth: CGFloat = 0
    /// Index (into `sortedActiveTags`) of the chip the keyboard caret currently
    /// sits on. `nil` means the caret is back in the text field — the normal
    /// state. ←/→ walk this through the chips so the user can review tags that
    /// have scrolled off-screen, and Backspace deletes the one it lands on.
    @State private var caretIndex: Int? = nil

    /// Smallest comfortable typing area kept visible at the trailing edge once
    /// the chips fill the rail and it begins scrolling.
    private let minTypingWidth: CGFloat = 90
    /// Scroll anchor for the text field, so the rail can keep the cursor in
    /// view as chips accumulate.
    private let inputFieldID = "tagSearchInput"

    /// Width the text field should take inside the rail: it fills the leftover
    /// space while chips are few, then clamps to `minTypingWidth` so the rail
    /// overflows and scrolls (pushing older chips off to the left) instead of
    /// squeezing the cursor.
    private var typingWidth: CGFloat {
        let gap: CGFloat = sortedActiveTags.isEmpty ? 0 : 4
        return max(minTypingWidth, railWidth - chipsWidth - gap)
    }

    private let tint: Color = .appAccent

    private var placeholder: String {
        // Hide the hint as soon as the user has any active filter chip —
        // TextField hides its own placeholder on non-empty text already.
        guard activeTags.isEmpty else { return "" }
        switch mode {
        case .fullText: return L("common.searchContent")
        case .semantic: return L("common.semanticSearch")
        case .tag:      return L("common.tagSearch")
        }
    }

    /// Which string the text field edits: the local tag buffer in tag mode,
    /// the shared keyword query everywhere else.
    private var fieldText: Binding<String> {
        mode == .tag ? $tagDraft : $text
    }

    /// Tags matching whatever the user has typed into the local buffer, minus
    /// the ones already picked. Returns nothing for an empty buffer — the
    /// picker is a *search*, not a browse-all list, so focusing tag mode no
    /// longer dumps every known tag into the dropdown.
    private var suggestedTags: [String] {
        let q = tagDraft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return availableTags.filter {
            !activeTags.contains($0.lowercased()) && $0.localizedCaseInsensitiveContains(q)
        }
    }

    /// The tag a Return keypress would add — the top of the filtered list.
    /// Highlighted in the dropdown so the Enter target is always visible.
    private var enterTarget: String? {
        tagDraft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : suggestedTags.first
    }

    /// Whether the suggestion dropdown is open. Derived purely from state
    /// (focus + a non-empty query) rather than hand-synced flags, so it can
    /// never get stuck open showing every tag, and stays closed until the user
    /// actually starts typing a tag to search for.
    private var pickerVisible: Bool {
        focused && mode == .tag
            && !tagDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var sortedActiveTags: [String] {
        activeTags.sorted()
    }

    /// Anything that the clear (×) button should be able to wipe.
    private var hasInput: Bool {
        !text.isEmpty || !activeTags.isEmpty || !tagDraft.isEmpty
    }

    private func displayName(forKey key: String) -> String {
        availableTags.first(where: { $0.lowercased() == key }) ?? key
    }

    /// Add `tag` as an active filter chip and reset the buffer, leaving the
    /// dropdown open so the user can keep stacking tags.
    private func selectTag(_ tag: String) {
        activeTags.insert(tag.lowercased())
        tagDraft = ""
        caretIndex = nil
    }

    /// Return key: add the highlighted suggestion, or — if the buffer matches
    /// nothing — accept it verbatim so a remembered tag can still be searched
    /// even when no item carries it yet.
    private func handleSubmit() {
        guard mode == .tag else { return }
        if let target = enterTarget {
            selectTag(target)
            return
        }
        let token = tagDraft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        activeTags.insert(token.lowercased())
        tagDraft = ""
        caretIndex = nil
    }

    /// Window-local key handler for the tag field. Active only while the field
    /// is focused in tag mode; returns `true` to swallow the keystroke. With a
    /// non-empty buffer it defers entirely so normal text editing (moving the
    /// caret through typed characters, deleting them) keeps working — chip
    /// navigation only takes over once the buffer is empty.
    private func handleTagKey(_ keyCode: UInt16) -> Bool {
        guard mode == .tag else { return false }
        let tags = sortedActiveTags
        guard tagDraft.isEmpty else {
            caretIndex = nil
            return false
        }
        switch keyCode {
        case 51:  // Delete (Backspace) → remove the chip the caret is on, or last.
            return deleteAtCaret(in: tags)
        case 123: // ← step the caret left through the chips
            guard !tags.isEmpty else { return false }
            caretIndex = caretIndex.map { max(0, $0 - 1) } ?? (tags.count - 1)
            return true
        case 124: // → step back toward the field
            guard let i = caretIndex else { return false }
            caretIndex = i >= tags.count - 1 ? nil : i + 1
            return true
        default:
            return false
        }
    }

    /// Removes the chip under the caret (or the last chip when the caret is in
    /// the field), then keeps the caret on a sensible neighbor. Returns whether
    /// a chip was actually removed.
    private func deleteAtCaret(in tags: [String]) -> Bool {
        guard !tags.isEmpty else { return false }
        let target = caretIndex ?? (tags.count - 1)
        activeTags.remove(tags[target])
        let newCount = tags.count - 1
        if newCount == 0 {
            caretIndex = nil
        } else if caretIndex != nil {
            caretIndex = min(target, newCount - 1)
        }
        return true
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(focused ? tint : .secondary)
                .animation(.easeOut(duration: 0.15), value: focused)

            // Chips and the text field share one horizontal scroll rail so the
            // bar behaves like a token field: as chips pile up they push the
            // cursor right until the rail overflows, then it scrolls to keep the
            // cursor pinned at the trailing edge while older chips slide off the
            // left — never clipped, never squeezed.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if !sortedActiveTags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(sortedActiveTags.enumerated()), id: \.element) { index, key in
                                    TagChipInline(
                                        label: displayName(forKey: key),
                                        isSelected: caretIndex == index
                                    ) {
                                        activeTags.remove(key)
                                    }
                                    .id(key)
                                }
                            }
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(key: ChipsWidthKey.self, value: g.size.width)
                                }
                            )
                        }

                        TextField(placeholder, text: fieldText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .help(L("common.searchHint.tooltip"))
                            .frame(width: typingWidth, alignment: .leading)
                            .onSubmit(handleSubmit)
                            // SwiftUI's `onKeyPress` never reaches a focused
                            // TextField — the field editor swallows editing keys
                            // first — so Backspace and ←/→ chip navigation are
                            // caught one level up by a window-local monitor.
                            .background(
                                TagFieldKeyMonitor(
                                    isActive: { focused && mode == .tag },
                                    onKey: handleTagKey
                                )
                            )
                            .id(inputFieldID)
                    }
                    // A hair of vertical room so chip borders aren't clipped by
                    // the scroll view's tight content bounds.
                    .padding(.vertical, 1)
                    .onPreferenceChange(ChipsWidthKey.self) { chipsWidth = $0 }
                }
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: RailWidthKey.self, value: g.size.width)
                    }
                )
                .onPreferenceChange(RailWidthKey.self) { railWidth = $0 }
                // Follow the keyboard caret: center the selected chip while
                // walking ←/→, or snap back to the field when the caret returns.
                .onChange(of: caretIndex) { _, idx in
                    withAnimation(.easeOut(duration: 0.18)) {
                        if let idx, idx < sortedActiveTags.count {
                            proxy.scrollTo(sortedActiveTags[idx], anchor: .center)
                        } else {
                            proxy.scrollTo(inputFieldID, anchor: .trailing)
                        }
                    }
                }
                // When the chip set changes, keep a stale selection in range and
                // reveal the cursor as a freshly added chip lands.
                .onChange(of: activeTags.count) { old, new in
                    if let i = caretIndex, i >= new {
                        caretIndex = new > 0 ? new - 1 : nil
                    }
                    if new > old {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(inputFieldID, anchor: .trailing)
                        }
                    }
                }
                // Typing dismisses any chip selection; losing focus clears it.
                .onChange(of: tagDraft) { _, draft in
                    if !draft.isEmpty { caretIndex = nil }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { caretIndex = nil }
                }
            }

            if hasInput {
                Button {
                    text = ""
                    tagDraft = ""
                    activeTags.removeAll()
                    caretIndex = nil
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
                switchMode(to: .tag)
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
        // Measure the bar's own height so the panel below can be offset by it.
        .background(
            GeometryReader { g in
                Color.clear.preference(key: BarHeightKey.self, value: g.size.height)
            }
        )
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        // App-styled dropdown panel (not a system popover bubble) pinned just
        // beneath the bar: a top-left overlay pushed down by the measured bar
        // height, so it always attaches *below* and never covers the search
        // field. The toolbar's zIndex lifts it above the list below.
        .overlay(alignment: .topLeading) {
            if pickerVisible {
                TagSuggestionDropdown(
                    tags: suggestedTags,
                    hasKnownTags: !availableTags.isEmpty,
                    enterTarget: enterTarget,
                    onSelect: selectTag
                )
                // Inherit the bar's width; take the wrapped content's height.
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: barHeight + 6)
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: pickerVisible)
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

    /// Commit a mode change without dragging SwiftUI's implicit animation
    /// transactions along (border tint, popover open/close, segment fill
    /// would otherwise all cross-fade and feel sluggish). Entering tag mode
    /// focuses the field and opens the dropdown; leaving it clears the local
    /// buffer so a stale query can't linger behind another mode.
    private func switchMode(to newMode: SearchMode) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            mode = newMode
            caretIndex = nil
            if newMode == .tag {
                text = ""
                focused = true
            } else {
                tagDraft = ""
            }
        }
    }
}

/// Publishes the natural width of the active-tag chip rail so the search bar
/// can size the rail to its content (capped) rather than reserving the full
/// max width of its horizontal ScrollView.
private struct ChipsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Publishes the search bar's measured height so the tag suggestion panel can
/// be offset to sit flush beneath it.
private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Publishes the width of the scrollable chips+field rail, used to decide how
/// much room is left for the text field before the rail overflows and scrolls.
private struct RailWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Catches editing keys (Backspace, ←, →) while the tag-search field is focused
/// so the chips can be navigated and deleted with the keyboard. SwiftUI's
/// `onKeyPress` doesn't reach a focused TextField (its field editor consumes
/// editing keys first), so we install a window-local key monitor that runs
/// *before* the field and only consumes the event when the handler acted on it;
/// otherwise the keystroke flows through to normal text editing untouched.
private struct TagFieldKeyMonitor: NSViewRepresentable {
    /// Gate: only act while our field owns focus in tag mode.
    var isActive: () -> Bool
    /// Handles a key by its `keyCode`; returns true to swallow the keystroke.
    var onKey: (UInt16) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.isActive = isActive
        context.coordinator.onKey = onKey
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var isActive: (() -> Bool)?
        var onKey: ((UInt16) -> Bool)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isActive?() == true,
                      self.onKey?(event.keyCode) == true
                else { return event }
                return nil                            // handled → consume
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Inline tag pill inside the search bar. Shows the tag label plus an `×`
/// that removes it from the active filter set.
private struct TagChipInline: View {
    let label: String
    /// True when the keyboard caret is resting on this chip — drawn with a
    /// stronger sage fill + ring so the user can see which tag ←/→ landed on.
    var isSelected: Bool = false
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var closeHovering = false

    private var fillOpacity: Double {
        if isSelected { return 0.28 }
        return hovering ? 0.16 : 0.10
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.appAccent.opacity(0.65))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(closeHovering ? .white : Color.appAccent.opacity(0.6))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle().fill(closeHovering ? Color.appAccent : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovering = $0 }
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        // Continuous rounded rect (not a capsule) so the chip speaks the same
        // squircle language as the search bar, mode segments, and toolbar —
        // and a lighter sage fill so it reads as a quiet token, not a badge.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.appAccent.opacity(fillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color.appAccent.opacity(isSelected ? 0.55 : 0.22),
                    lineWidth: isSelected ? 1 : 0.5
                )
        )
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: closeHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// Popover shown beneath the search field while the user is typing a `#tag`
/// query. Lists available tags (filtered by the query) and forwards taps to
/// the caller, which inserts the tag and clears the typed token.
/// Suggestion panel shown beneath the search field in tag mode. Replaces the
/// system `NSPopover` (arrow + vibrant chrome) with the app's own card surface
/// — sage border, warm shadow, continuous corners — and lays the candidate
/// tags out as wrapping pills so a long list fills the width instead of a
/// space-wasting single column.
private struct TagSuggestionDropdown: View {
    let tags: [String]
    /// Whether the history holds *any* tags at all — distinguishes the "no tags
    /// exist yet" hint from a "nothing matches your query" message.
    let hasKnownTags: Bool
    /// The tag Return would commit — drawn with a persistent tint + ↵ hint so
    /// the keyboard target is obvious without arrow-key navigation.
    let enterTarget: String?
    let onSelect: (String) -> Void

    var body: some View {
        Group {
            if tags.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: hasKnownTags ? "magnifyingglass" : "tag.slash")
                        .font(.system(size: 11))
                    Text(hasKnownTags ? L("search.tagPicker.empty") : L("search.tagPicker.none"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagSuggestionChip(
                            tag: tag,
                            isEnterTarget: tag == enterTarget
                        ) { onSelect(tag) }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow, radius: 14, x: 0, y: 8)
    }
}

/// Compact candidate pill in the suggestion panel — same sage rounded-rect
/// language as the active-filter chips, so picking and picked tags read as one
/// family. Highlights on hover and when it's the Return target.
private struct TagSuggestionChip: View {
    let tag: String
    var isEnterTarget: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.appAccent.opacity(0.65))
                Text(tag)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if isEnterTarget {
                    Image(systemName: "return")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.appAccent.opacity(hovering || isEnterTarget ? 0.20 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.appAccent.opacity(0.22), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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

// MARK: - Row bounds preference

/// Each visible row publishes its frame here, keyed by item id, so the list can
/// park a single sliding focus highlight on whichever row is focused. Only the
/// rows the `LazyVStack` actually renders contribute, so this stays to ~a dozen
/// entries regardless of history size.
private struct RowBoundsKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Load-more sentinel

/// Invisible footer that fires its callback the first time it scrolls into
/// view. Used by the paginated list to ask the outer wrapper for another
/// page. A tiny spinner is drawn to hint at "loading more" — it's all the
/// user sees before the new rows pop in.
private struct LoadMoreSentinel: View {
    let onAppear: () -> Void

    @State private var fired = false

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .opacity(0.5)
            Spacer()
        }
        .frame(height: 28)
        .onAppear {
            guard !fired else { return }
            fired = true
            onAppear()
        }
    }
}

// MARK: - Static background halo

/// Wraps the accent radial gradient in an `Equatable` view so SwiftUI bails
/// out of re-evaluating it whenever the parent re-renders (every keystroke,
/// every scope flip). The decoration is constant — there's nothing to diff.
private struct BackgroundHaloView: View, Equatable {
    static func == (_: BackgroundHaloView, _: BackgroundHaloView) -> Bool { true }

    var body: some View {
        RadialGradient(
            colors: [Color.appAccent.opacity(0.10), Color.clear],
            center: UnitPoint(x: 0.08, y: -0.05),
            startRadius: 20,
            endRadius: 520
        )
        .ignoresSafeArea()
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
