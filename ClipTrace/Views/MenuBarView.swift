import SwiftUI
import SwiftData
import AppKit

enum MenuBarSurfaceStyle {
    case paper
    case dynamicIsland

    var isIsland: Bool { self == .dynamicIsland }

    var background: Color {
        switch self {
        case .paper:
            Color.appPaper
        case .dynamicIsland:
            Color.black
        }
    }

    var primaryText: Color {
        switch self {
        case .paper:
            Color.appMetal
        case .dynamicIsland:
            Color.white.opacity(0.94)
        }
    }

    var secondaryText: Color {
        switch self {
        case .paper:
            Color.secondary
        case .dynamicIsland:
            Color.white.opacity(0.58)
        }
    }

    var tertiaryText: Color {
        switch self {
        case .paper:
            Color.secondary.opacity(0.65)
        case .dynamicIsland:
            Color.white.opacity(0.36)
        }
    }

    var divider: Color {
        switch self {
        case .paper:
            Color.primary.opacity(0.16)
        case .dynamicIsland:
            Color.white.opacity(0.10)
        }
    }

    var rowHoverFill: Color {
        switch self {
        case .paper:
            Color.appAccent.opacity(0.12)
        case .dynamicIsland:
            Color.white.opacity(0.09)
        }
    }

    var controlFill: Color {
        switch self {
        case .paper:
            Color.secondary.opacity(0.18)
        case .dynamicIsland:
            Color.white.opacity(0.10)
        }
    }

    var controlFillActive: Color {
        switch self {
        case .paper:
            Color.appAccent.opacity(0.16)
        case .dynamicIsland:
            Color.appAccent.opacity(0.24)
        }
    }

    var headerButtonFill: Color {
        switch self {
        case .paper:
            Color.clear
        case .dynamicIsland:
            Color.white.opacity(0.08)
        }
    }

    var thumbnailTint: Color {
        switch self {
        case .paper:
            Color.primary
        case .dynamicIsland:
            Color.white.opacity(0.86)
        }
    }
}

struct MenuBarView: View {
    @State private var searchText = ""
    /// Query actually sent to SwiftData. Trails `searchText` by a short
    /// debounce so a fetch never runs per keystroke; clearing applies
    /// immediately so leaving search feels instant.
    @State private var debouncedQuery = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var fetchLimit = Self.pageSize
    @State private var totalActiveRecords = 0
    @State private var isLoadingMore = false
    @State private var paginationGeneration = 0
    @State private var selectedGroupFilter: ClipboardGroupFilter = .all

    private let onRequestClose: (() -> Void)?
    private let onOpenMain: (() -> Void)?
    private let onOpenSettings: (() -> Void)?
    private let surfaceStyle: MenuBarSurfaceStyle

    private static let pageSize = 20

    init(
        surfaceStyle: MenuBarSurfaceStyle = .paper,
        onRequestClose: (() -> Void)? = nil,
        onOpenMain: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.surfaceStyle = surfaceStyle
        self.onRequestClose = onRequestClose
        self.onOpenMain = onOpenMain
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        MenuBarContent(
            searchText: $searchText,
            searchQuery: debouncedQuery,
            selectedGroupFilter: $selectedGroupFilter,
            fetchLimit: fetchLimit,
            totalActiveRecords: $totalActiveRecords,
            isLoadingMore: isLoadingMore,
            onRequestMore: loadMore,
            surfaceStyle: surfaceStyle,
            onRequestClose: onRequestClose,
            onOpenMain: onOpenMain,
            onOpenSettings: onOpenSettings
        )
        .onChange(of: searchText) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: selectedGroupFilter) { _, _ in
            resetPagination()
        }
        .onChange(of: totalActiveRecords) { _, _ in
            clampFetchLimit()
        }
    }

    private func scheduleSearch(_ raw: String) {
        searchDebounce?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != debouncedQuery else { return }
        if query.isEmpty {
            applySearch("")
            return
        }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            applySearch(query)
        }
    }

    private func applySearch(_ query: String) {
        debouncedQuery = query
        resetPagination()
    }

    private func resetPagination() {
        isLoadingMore = false
        fetchLimit = Self.pageSize
        paginationGeneration &+= 1
    }

    private func clampFetchLimit() {
        fetchLimit = max(Self.pageSize, min(fetchLimit, max(totalActiveRecords, Self.pageSize)))
    }

    private func loadMore() {
        guard !isLoadingMore, fetchLimit < totalActiveRecords else { return }
        isLoadingMore = true
        let generation = paginationGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard generation == paginationGeneration else { return }
            fetchLimit = min(fetchLimit + Self.pageSize, totalActiveRecords)
            isLoadingMore = false
        }
    }
}

/// Owns the paged history list for the menu-bar window. This intentionally
/// uses an explicit `ModelContext(AppContainer.shared)` instead of `@Query`:
/// on macOS 26 the `MenuBarExtra` window can fail to see the SwiftData
/// environment even while the main window and Quick Paste read the store fine.
struct MenuBarContent: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = UpdaterService.shared
    @StateObject private var historyStore = MenuBarHistoryStore()
    /// The panel hosting this view, captured so the open-main/settings actions
    /// can dismiss it deterministically — SwiftUI exposes no dismiss API for a
    /// `.window`-style `MenuBarExtra`, and waiting for it to resign key fails
    /// when the main window opens on another Space.
    @State private var hostWindow: NSWindow?
    @FocusState private var searchFocused: Bool

    private static let listHeight: CGFloat = 460

    @Binding var searchText: String
    let searchQuery: String
    @Binding var selectedGroupFilter: ClipboardGroupFilter
    let fetchLimit: Int
    @Binding var totalActiveRecords: Int
    let isLoadingMore: Bool
    let onRequestMore: () -> Void
    let surfaceStyle: MenuBarSurfaceStyle
    let onRequestClose: (() -> Void)?
    let onOpenMain: (() -> Void)?
    let onOpenSettings: (() -> Void)?

    init(
        searchText: Binding<String>,
        searchQuery: String,
        selectedGroupFilter: Binding<ClipboardGroupFilter>,
        fetchLimit: Int,
        totalActiveRecords: Binding<Int>,
        isLoadingMore: Bool,
        onRequestMore: @escaping () -> Void,
        surfaceStyle: MenuBarSurfaceStyle = .paper,
        onRequestClose: (() -> Void)? = nil,
        onOpenMain: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        _searchText = searchText
        self.searchQuery = searchQuery
        _selectedGroupFilter = selectedGroupFilter
        self.fetchLimit = fetchLimit
        _totalActiveRecords = totalActiveRecords
        self.isLoadingMore = isLoadingMore
        self.onRequestMore = onRequestMore
        self.surfaceStyle = surfaceStyle
        self.onRequestClose = onRequestClose
        self.onOpenMain = onOpenMain
        self.onOpenSettings = onOpenSettings
    }

    private var allItems: [ClipboardItem] {
        historyStore.items
    }

    var body: some View {
        let items = allItems
        let canLoadMore = items.count < totalActiveRecords

        return VStack(spacing: 0) {
            header
            groupStrip
            searchField
            Rectangle()
                .fill(surfaceStyle.divider)
                .frame(height: 1)

            if items.isEmpty {
                emptyState
            } else {
                itemList(items: items, canLoadMore: canLoadMore)
            }

            Rectangle()
                .fill(surfaceStyle.divider)
                .frame(height: 1)
            footer
        }
        // The menu-bar window sizes itself to this fixed width; inside the
        // island the surface dictates the size, so fill it instead — a fixed
        // frame there leaves black bands between the content and the surface.
        .frame(width: surfaceStyle.isIsland ? nil : 340)
        .frame(
            maxWidth: surfaceStyle.isIsland ? .infinity : nil,
            maxHeight: surfaceStyle.isIsland ? .infinity : nil,
            alignment: .top
        )
        .background {
            panelBackground
        }
        .menuBarWindowContainerBackground(surfaceStyle)
        .preferredColorScheme(surfaceStyle.isIsland ? .dark : nil)
        .background(HostWindowReader { window in
            hostWindow = window
            applyWindowChrome(to: window)
        })
        .background(
            // Invisible ⌘F target: routes the shortcut into the search field
            // whenever this panel is the key window.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .onAppear {
            reloadHistory()
        }
        .onChange(of: fetchLimit) { _, _ in
            reloadHistory()
        }
        .onChange(of: searchQuery) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) {
                reloadHistory()
            }
        }
        .onChange(of: selectedGroupFilter) { _, _ in
            reloadHistory()
        }
        .onChange(of: vm.pinsVersion) { _, _ in
            withAnimation(.easeOut(duration: 0.16)) {
                reloadHistory()
            }
        }
        .onChange(of: vm.groupsVersion) { _, _ in
            withAnimation(.easeOut(duration: 0.16)) {
                reloadHistory()
            }
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        MenuBarPanelBackground(surfaceStyle: surfaceStyle)
            .ignoresSafeArea()
    }

    /// On macOS 26 the `MenuBarExtra` window reserves bands above and below
    /// the content — the stretch that carries the window's rounded corners —
    /// which neither `.background` nor `containerBackground` paints anymore,
    /// so they show through as transparent slots. Painting the hosting window
    /// itself keeps the paper surface continuous under whatever chrome the
    /// system adds. The island variant must not paint: its hosting panel stays
    /// transparent around the black island surface.
    private func applyWindowChrome(to window: NSWindow?) {
        guard surfaceStyle == .paper, let window else { return }
        guard #available(macOS 26.0, *) else { return }
        window.backgroundColor = Color.appPaperNSColor
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppLogoMark(size: 26, shadowRadius: 2, shadowOpacity: 0.35)
            Text(L("main.title"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(surfaceStyle.primaryText)
            Spacer()

            // Update reminder sits beside the capture toggle (same placement
            // as the main window header) so both status chips share one spot.
            if updater.updateAvailable {
                UpdateReminderPill(showsLabel: false)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
            }

            CaptureToggle(isPaused: $vm.isCapturePaused, showsLabel: false)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(surfaceStyle.primaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(surfaceStyle.headerButtonFill)
                    )
            }
            .buttonStyle(.plain)
            .help(L("menubar.openSettings"))

            Button {
                openMain()
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(surfaceStyle.primaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(surfaceStyle.headerButtonFill)
                    )
            }
            .buttonStyle(.plain)
            .help(L("menubar.openMainWindow"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.16), value: updater.updateAvailable)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(searchFocused ? Color.appAccent : surfaceStyle.secondaryText)
            TextField(L("common.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(surfaceStyle.primaryText)
                .focused($searchFocused)
                .onExitCommand {
                    handleSearchEscape()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(surfaceStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            } else if !searchFocused {
                Text(verbatim: "⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(surfaceStyle.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(surfaceStyle.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(searchFocused ? Color.appAccent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Esc in the search field: first press clears the query, second press
    /// (field already empty) drops focus — so a double-Esc always exits
    /// search from any state. With focus released, the next Esc reaches the
    /// window and closes the panel as before.
    private func handleSearchEscape() {
        if searchText.isEmpty {
            searchFocused = false
        } else {
            searchText = ""
        }
    }

    private var groupStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                groupChip(title: L("group.all"), icon: "tray.full", filter: .all)
                ForEach(historyStore.groups.sortedForDisplay()) { group in
                    groupChip(title: group.displayName, icon: "folder.fill", filter: .group(group.id))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func groupChip(title: String, icon: String, filter: ClipboardGroupFilter) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedGroupFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: selectedGroupFilter == filter ? .semibold : .medium))
            .foregroundStyle(selectedGroupFilter == filter ? Color.white : surfaceStyle.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedGroupFilter == filter ? Color.appAccent : surfaceStyle.controlFill)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(surfaceStyle.secondaryText)
            Text(!searchQuery.isEmpty
                ? L("menubar.empty.noMatch")
                : L("menubar.empty.noRecords"))
                .font(.caption)
                .foregroundStyle(surfaceStyle.secondaryText)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.listHeight,
            maxHeight: surfaceStyle.isIsland ? .infinity : nil
        )
        .padding(20)
    }

    private func itemList(items: [ClipboardItem], canLoadMore: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                menuRows(items: items)

                if canLoadMore {
                    loadMoreTrigger
                }
            }
            .padding(6)
        }
        // Use a fixed height, not just `maxHeight`: the menu panel must grow
        // even when the current history has fewer rows than the visible area.
        // The island body has a fixed size already, so the list stretches to
        // fill it there instead.
        .frame(height: surfaceStyle.isIsland ? nil : Self.listHeight)
        .frame(maxHeight: surfaceStyle.isIsland ? .infinity : nil)
    }

    @ViewBuilder
    private func menuRows(items: [ClipboardItem]) -> some View {
        ForEach(items) { item in
            menuRow(item)
        }
    }

    private func menuRow(_ item: ClipboardItem) -> some View {
        MenuBarRow(
            item: item,
            groupName: nil,
            surfaceStyle: surfaceStyle,
            onCopy: { vm.copyToClipboard(item) },
            onCopyPlainText: { vm.copyAsPlainText(item) },
            onTogglePin: { togglePin(item) }
        )
    }

    private var loadMoreTrigger: some View {
        Button {
            onRequestMore()
        } label: {
            HStack(spacing: 6) {
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isLoadingMore ? L("menubar.loadingMore") : L("menubar.loadMore"))
                    .font(.caption2)
            }
            .foregroundStyle(surfaceStyle.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
        .onAppear {
            onRequestMore()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("menubar.recordCountFormat", totalActiveRecords))
                .font(.caption2)
                .foregroundStyle(surfaceStyle.secondaryText)
            Spacer()
            Text(L("menubar.shortcutHint"))
                .font(.caption2)
                .foregroundStyle(surfaceStyle.tertiaryText)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L("menubar.quit"))
                    .font(.caption2)
                    .foregroundStyle(surfaceStyle.secondaryText)
            }
            .buttonStyle(.plain)
            .help(L("menubar.quit"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func refreshRecordCount() {
        historyStore.refreshRecordCount()
        totalActiveRecords = historyStore.totalActiveRecords
    }

    private func reloadHistory() {
        historyStore.reload(fetchLimit: fetchLimit, groupFilter: selectedGroupFilter, searchQuery: searchQuery)
        totalActiveRecords = historyStore.totalActiveRecords
    }

    private func togglePin(_ item: ClipboardItem) {
        vm.togglePin(item)
    }

    private func openMain() {
        if let onOpenMain {
            onOpenMain()
        } else {
            // Order matters: the window must exist (and count as visible for
            // the activation-policy pinning) before the panel close triggers
            // the window-close policy re-sync; the actual activation + Space
            // switch runs deferred inside `openMainWindow`.
            openWindow(id: "main")
            AppNavigation.shared.showList()
            hostWindow?.close()
            AppDelegate.openMainWindow()
        }
        onRequestClose?()
    }

    private func openSettings() {
        if let onOpenSettings {
            onOpenSettings()
        } else {
            openWindow(id: "main")
            AppNavigation.shared.showSettings()
            hostWindow?.close()
            AppDelegate.openMainWindow()
        }
        onRequestClose?()
    }
}

/// Invisible probe that reports the `NSWindow` hosting the menu-bar panel back
/// to SwiftUI (deferred a tick — `viewDidMoveToWindow` fires mid view-update).
private struct HostWindowReader: NSViewRepresentable {
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

private struct MenuBarPanelBackground: View {
    let surfaceStyle: MenuBarSurfaceStyle

    var body: some View {
        switch surfaceStyle {
        case .paper:
            Color.appPaper
        case .dynamicIsland:
            ZStack(alignment: .top) {
                Color.black
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.03),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)

                RadialGradient(
                    colors: [
                        Color.appAccent.opacity(0.22),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 10,
                    endRadius: 210
                )
                .frame(height: 260)
                .blendMode(.screen)
            }
        }
    }
}

private extension View {
    /// On macOS 26 the SwiftUI `MenuBarExtra` window can reserve translucent
    /// safe-area bands above/below the content. Painting the window container,
    /// not just the content background, keeps the paper surface continuous.
    @ViewBuilder
    func menuBarWindowContainerBackground(_ surfaceStyle: MenuBarSurfaceStyle) -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(for: .window) {
                MenuBarPanelBackground(surfaceStyle: surfaceStyle)
                    .ignoresSafeArea()
            }
        } else {
            self
        }
    }
}

@MainActor
private final class MenuBarHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var groups: [ClipboardGroup] = []
    @Published private(set) var totalActiveRecords = 0

    private let context = ModelContext(AppContainer.shared)

    func reload(fetchLimit: Int, groupFilter: ClipboardGroupFilter, searchQuery: String = "") {
        reloadGroups()
        let limit = max(fetchLimit, 1)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            reloadSearch(limit: limit, groupFilter: groupFilter, query: query)
            return
        }

        switch groupFilter {
        case .all:
            var pinnedDescriptor = Self.itemDescriptor(pinned: true, groupFilter: .all)
            Self.keepRowPropertiesFaulted(in: &pinnedDescriptor)

            var recentDescriptor = Self.itemDescriptor(pinned: false, groupFilter: .all)
            recentDescriptor.fetchLimit = limit
            Self.keepRowPropertiesFaulted(in: &recentDescriptor)

            let pinned = (try? context.fetch(pinnedDescriptor)) ?? []
            let recent = (try? context.fetch(recentDescriptor)) ?? []
            items = pinned + recent
            refreshRecordCount(groupFilter: groupFilter)

        case .ungrouped:
            var descriptor = Self.itemDescriptor(pinned: false, groupFilter: .ungrouped)
            descriptor.fetchLimit = limit
            Self.keepRowPropertiesFaulted(in: &descriptor)

            items = (try? context.fetch(descriptor)) ?? []
            refreshRecordCount(groupFilter: groupFilter)

        case .group(let groupID):
            var descriptor = Self.groupedCandidateDescriptor()
            Self.keepRowPropertiesFaulted(in: &descriptor)

            let candidates = (try? context.fetch(descriptor)) ?? []
            let matching = candidates.filter { $0.isInGroup(groupID) }
            items = Array(matching.prefix(limit))
            totalActiveRecords = matching.count
        }
    }

    /// Search stays bounded end-to-end: the page fetch carries `limit` and the
    /// match total comes from `fetchCount`, so even a huge history filters in
    /// SQLite instead of being loaded and scanned in memory.
    private func reloadSearch(limit: Int, groupFilter: ClipboardGroupFilter, query: String) {
        switch groupFilter {
        case .group(let groupID):
            var descriptor = ClipboardHistorySearch.descriptor(groupFilter: groupFilter, query: query)
            Self.keepRowPropertiesFaulted(in: &descriptor)
            let candidates = (try? context.fetch(descriptor)) ?? []
            let matching = candidates.filter { $0.isInGroup(groupID) }
            items = Array(matching.prefix(limit))
            totalActiveRecords = matching.count

        default:
            var descriptor = ClipboardHistorySearch.descriptor(groupFilter: groupFilter, query: query)
            descriptor.fetchLimit = limit
            Self.keepRowPropertiesFaulted(in: &descriptor)
            items = (try? context.fetch(descriptor)) ?? []

            let countDescriptor = FetchDescriptor<ClipboardItem>(
                predicate: ClipboardHistorySearch.predicate(groupFilter: groupFilter, query: query)
            )
            totalActiveRecords = (try? context.fetchCount(countDescriptor)) ?? items.count
        }
    }

    func refreshRecordCount(groupFilter: ClipboardGroupFilter = .all) {
        if case .group(let groupID) = groupFilter {
            let candidates = (try? context.fetch(Self.groupedCandidateDescriptor())) ?? []
            totalActiveRecords = candidates.filter { $0.isInGroup(groupID) }.count
            return
        }

        let descriptor = Self.countDescriptor(groupFilter: groupFilter)
        totalActiveRecords = (try? context.fetchCount(descriptor)) ?? items.count
    }

    private func reloadGroups() {
        let descriptor = FetchDescriptor<ClipboardGroup>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt)
            ]
        )
        groups = (try? context.fetch(descriptor)) ?? []
    }

    private static func itemDescriptor(
        pinned: Bool,
        groupFilter: ClipboardGroupFilter
    ) -> FetchDescriptor<ClipboardItem> {
        switch groupFilter {
        case .all:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == pinned },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        case .ungrouped:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        case .group:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw != nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        }
    }

    private static func countDescriptor(groupFilter: ClipboardGroupFilter) -> FetchDescriptor<ClipboardItem> {
        switch groupFilter {
        case .all:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil }
            )
        case .ungrouped:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw == nil }
            )
        case .group:
            return FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw != nil }
            )
        }
    }

    private static func groupedCandidateDescriptor() -> FetchDescriptor<ClipboardItem> {
        FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.isPinned == false && $0.groupIDsRaw != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    private static func keepRowPropertiesFaulted(in descriptor: inout FetchDescriptor<ClipboardItem>) {
        // Keep large blobs faulted while the menu bar page is built. The store
        // keeps its ModelContext alive, so visible rows can fault thumbnails in
        // lazily just like the main window list.
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
        ]
    }
}

struct MenuBarRow: View {
    let item: ClipboardItem
    var groupName: String? = nil
    var surfaceStyle: MenuBarSurfaceStyle = .paper
    let onCopy: () -> Void
    var onCopyPlainText: (() -> Void)? = nil
    var onTogglePin: () -> Void = {}

    @State private var isHovered = false
    @State private var copySucceeded = false
    @State private var showQRCodePreview = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 9) {
            ThumbnailView(item: item, size: 26, cornerRadius: 5, placeholderTint: surfaceStyle.thumbnailTint)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    Text(item.effectiveCustomTitle ?? item.redactedForDisplay(item.preview ?? item.content))
                        .font(.system(size: 12))
                        .foregroundStyle(surfaceStyle.primaryText)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if item.sourceApp == L("remote.universalClipboard") {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    Text("\(item.sourceApp) · \(item.formattedDate)")
                        .font(.system(size: 10))
                        .foregroundStyle(surfaceStyle.secondaryText)
                        .lineLimit(1)
                    if let groupName {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(surfaceStyle.tertiaryText)
                        HStack(spacing: 2) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(groupName)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appAccent)
                        .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            if isHovered || copySucceeded {
                Button {
                    triggerCopy()
                } label: {
                    Image(systemName: copySucceeded ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: copySucceeded ? .bold : .regular))
                        .foregroundStyle(copySucceeded ? Color.appAccent : surfaceStyle.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(copySucceeded ? surfaceStyle.controlFillActive : surfaceStyle.controlFill)
                        )
                }
                .buttonStyle(.plain)
                .help(copySucceeded ? L("common.copied") : L("common.copy"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? surfaceStyle.rowHoverFill : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { triggerCopy() }
        .onHover { isHovered = $0 }
        .onDisappear { resetTask?.cancel() }
        .sheet(isPresented: $showQRCodePreview) {
            TextQRCodePreviewView(item: item, onClose: { showQRCodePreview = false })
        }
        .contextMenu {
            Button(L("action.copy"), systemImage: "doc.on.doc") { triggerCopy() }
            if let onCopyPlainText {
                Button(L("action.copyAsPlainText"), systemImage: "doc.plaintext") {
                    onCopyPlainText()
                    triggerCopySuccessFlash()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
            if canPreviewQRCode {
                Button(L("action.qrPreview"), systemImage: "qrcode") {
                    showQRCodePreview = true
                }
            }
            Divider()
            Button(item.isPinned ? L("action.unpin") : L("action.pin"),
                   systemImage: item.isPinned ? "pin.slash" : "pin") {
                onTogglePin()
            }
        }
    }

    private var canPreviewQRCode: Bool {
        item.itemType == .text &&
        !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Flash the "copied" check without re-issuing the underlying copy — the
    /// caller already wrote to the pasteboard via a different code path
    /// (e.g. copy-as-plain-text).
    private func triggerCopySuccessFlash() {
        resetTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            copySucceeded = true
        }
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                copySucceeded = false
            }
        }
    }

    private func triggerCopy() {
        onCopy()
        resetTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
            copySucceeded = true
        }
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                copySucceeded = false
            }
        }
    }
}
