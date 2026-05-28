import SwiftUI
import SwiftData
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var allItems: [ClipboardItem]
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    private var recentItems: [ClipboardItem] {
        let items = Array(allItems.prefix(20))
        if searchText.isEmpty { return items }
        return items.filter {
            $0.content.lowercased().contains(searchText.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().opacity(0.4)

            if recentItems.isEmpty {
                emptyState
            } else {
                itemList
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 340)
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
            Text(searchText.isEmpty ? L("menubar.empty.noRecords") : L("menubar.empty.noMatch"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(20)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(recentItems) { item in
                    MenuBarRow(item: item) {
                        vm.copyToClipboard(item)
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 420)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("menubar.recordCountFormat", allItems.count))
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
}

struct MenuBarRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void

    @State private var isHovered = false
    @State private var copySucceeded = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 9) {
            ThumbnailView(item: item, size: 26, cornerRadius: 5)

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
