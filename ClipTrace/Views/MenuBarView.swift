import SwiftUI
import SwiftData
import AppKit

struct MenuBarView: View {
    @State private var searchText = ""
    @State private var fetchLimit = Self.pageSize
    @State private var totalActiveRecords = 0
    @State private var isLoadingMore = false
    @State private var paginationGeneration = 0

    private static let pageSize = 20
    /// Menu bar search currently expands the SwiftData fetch to the full
    /// history. Keep the implementation available, but hide it until it can
    /// be replaced with a bounded query that does not block the panel.
    private static let isSearchEnabled = false

    var body: some View {
        let searching = Self.isSearchEnabled &&
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        MenuBarContent(
            searchText: $searchText,
            isSearchEnabled: Self.isSearchEnabled,
            fetchLimit: searching ? max(totalActiveRecords, Self.pageSize) : fetchLimit,
            totalActiveRecords: $totalActiveRecords,
            isLoadingMore: isLoadingMore,
            onRequestMore: loadMore
        )
        .onChange(of: searchText) { _, _ in
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

/// Owns the paged SwiftData query. Keeping this separate from `MenuBarView`
/// lets a load-more request rebuild the query with a larger `fetchLimit`
/// instead of materializing the whole clipboard history when the panel opens.
struct MenuBarContent: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Query private var allItems: [ClipboardItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Binding var searchText: String
    let isSearchEnabled: Bool
    let fetchLimit: Int
    @Binding var totalActiveRecords: Int
    let isLoadingMore: Bool
    let onRequestMore: () -> Void

    init(
        searchText: Binding<String>,
        isSearchEnabled: Bool,
        fetchLimit: Int,
        totalActiveRecords: Binding<Int>,
        isLoadingMore: Bool,
        onRequestMore: @escaping () -> Void
    ) {
        _searchText = searchText
        self.isSearchEnabled = isSearchEnabled
        self.fetchLimit = fetchLimit
        _totalActiveRecords = totalActiveRecords
        self.isLoadingMore = isLoadingMore
        self.onRequestMore = onRequestMore

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        _allItems = Query(descriptor)
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
            if isSearchEnabled {
                searchField
            }
            Divider().opacity(0.4)

            if items.isEmpty {
                emptyState
            } else {
                itemList(items: items, canLoadMore: canLoadMore)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 340)
        .onAppear {
            refreshRecordCount()
        }
        .onChange(of: allItems.map(\.id)) { _, _ in
            refreshRecordCount()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppLogoMark(size: 26, shadowRadius: 2, shadowOpacity: 0.35)
            Text(L("main.title"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                openWindow(id: "main")
                AppNavigation.shared.showSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L("menubar.openSettings"))

            Button {
                openWindow(id: "main")
                AppNavigation.shared.showList()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
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
                .foregroundStyle(.secondary)
            TextField(L("common.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.secondary.opacity(0.15))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(isSearchEnabled && !searchText.isEmpty
                ? L("menubar.empty.noMatch")
                : L("menubar.empty.noRecords"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(20)
    }

    private func itemList(items: [ClipboardItem], canLoadMore: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    MenuBarRow(
                        item: item,
                        onCopy: { vm.copyToClipboard(item) },
                        onCopyPlainText: { vm.copyAsPlainText(item) }
                    )
                }

                if canLoadMore {
                    loadMoreTrigger
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 420)
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
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Spacer()
            Text(L("menubar.shortcutHint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text(L("menubar.quit"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("menubar.quit"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func refreshRecordCount() {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        totalActiveRecords = (try? modelContext.fetchCount(descriptor)) ?? allItems.count
    }
}

struct MenuBarRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    var onCopyPlainText: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var copySucceeded = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 9) {
            ThumbnailView(item: item, size: 26, cornerRadius: 5, placeholderTint: .primary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    Text(item.effectiveCustomTitle ?? item.preview ?? item.content)
                        .font(.system(size: 12))
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if isHovered || copySucceeded {
                Button {
                    triggerCopy()
                } label: {
                    Image(systemName: copySucceeded ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: copySucceeded ? .bold : .regular))
                        .foregroundStyle(copySucceeded ? Color.white : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(copySucceeded ? Color.green : Color.secondary.opacity(0.18))
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
                .fill(isHovered ? Color.appAccent.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { triggerCopy() }
        .onHover { isHovered = $0 }
        .onDisappear { resetTask?.cancel() }
        .contextMenu {
            Button(L("action.copy"), systemImage: "doc.on.doc") { triggerCopy() }
            if let onCopyPlainText {
                Button(L("action.copyAsPlainText"), systemImage: "textformat") {
                    onCopyPlainText()
                    triggerCopySuccessFlash()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
        }
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
