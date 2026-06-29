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
    /// Menu bar search currently expands the SwiftData fetch to the full
    /// history. Keep the implementation available, but hide it until it can
    /// be replaced with a bounded query that does not block the panel.
    private static let isSearchEnabled = false

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
        let searching = Self.isSearchEnabled &&
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        MenuBarContent(
            searchText: $searchText,
            isSearchEnabled: Self.isSearchEnabled,
            selectedGroupFilter: $selectedGroupFilter,
            fetchLimit: searching ? max(totalActiveRecords, Self.pageSize) : fetchLimit,
            totalActiveRecords: $totalActiveRecords,
            isLoadingMore: isLoadingMore,
            onRequestMore: loadMore,
            surfaceStyle: surfaceStyle,
            onRequestClose: onRequestClose,
            onOpenMain: onOpenMain,
            onOpenSettings: onOpenSettings
        )
        .onChange(of: searchText) { _, _ in
            resetPagination()
        }
        .onChange(of: selectedGroupFilter) { _, _ in
            resetPagination()
        }
        .onChange(of: totalActiveRecords) { _, _ in
            clampFetchLimit()
        }
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
    @StateObject private var historyStore = MenuBarHistoryStore()

    private static let listHeight: CGFloat = 460

    @Binding var searchText: String
    let isSearchEnabled: Bool
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
        isSearchEnabled: Bool,
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
        self.isSearchEnabled = isSearchEnabled
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

    private var matchingItems: [ClipboardItem] {
        guard isSearchEnabled else { return allItems }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allItems }

        return allItems.filter { item in
            item.content.localizedCaseInsensitiveContains(query) ||
            item.sourceApp.localizedCaseInsensitiveContains(query) ||
            item.effectiveCustomTitle?.localizedCaseInsensitiveContains(query) == true ||
            item.ocrText?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        let items = matchingItems
        let searching = isSearchEnabled &&
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canLoadMore = !searching && allItems.count < totalActiveRecords

        return VStack(spacing: 0) {
            header
            groupStrip
            if isSearchEnabled {
                searchField
            }
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
        .frame(width: 340)
        .background {
            panelBackground
        }
        .menuBarWindowContainerBackground(surfaceStyle)
        .preferredColorScheme(surfaceStyle.isIsland ? .dark : nil)
        .onAppear {
            reloadHistory()
        }
        .onChange(of: fetchLimit) { _, _ in
            reloadHistory()
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

    private var header: some View {
        HStack(spacing: 9) {
            AppLogoMark(size: 26, shadowRadius: 2, shadowOpacity: 0.35)
            Text(L("main.title"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(surfaceStyle.primaryText)
            Spacer()

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
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(surfaceStyle.secondaryText)
            TextField(L("common.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(surfaceStyle.primaryText)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(surfaceStyle.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(surfaceStyle.controlFill)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
            .padding(.bottom, isSearchEnabled ? 8 : 10)
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
            Text(isSearchEnabled && !searchText.isEmpty
                ? L("menubar.empty.noMatch")
                : L("menubar.empty.noRecords"))
                .font(.caption)
                .foregroundStyle(surfaceStyle.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: Self.listHeight)
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
        .frame(height: Self.listHeight)
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
        historyStore.reload(fetchLimit: fetchLimit, groupFilter: selectedGroupFilter)
        totalActiveRecords = historyStore.totalActiveRecords
    }

    private func togglePin(_ item: ClipboardItem) {
        vm.togglePin(item)
    }

    private func openMain() {
        if let onOpenMain {
            onOpenMain()
        } else {
            openWindow(id: "main")
            AppNavigation.shared.showList()
            NSApp.activate(ignoringOtherApps: true)
        }
        onRequestClose?()
    }

    private func openSettings() {
        if let onOpenSettings {
            onOpenSettings()
        } else {
            openWindow(id: "main")
            AppNavigation.shared.showSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        onRequestClose?()
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

    func reload(fetchLimit: Int, groupFilter: ClipboardGroupFilter) {
        reloadGroups()
        let limit = max(fetchLimit, 1)

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
