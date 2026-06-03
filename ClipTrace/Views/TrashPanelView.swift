import SwiftUI
import SwiftData
import AppKit

/// Lists soft-deleted clipboard items. Each row offers "恢复" (move back to
/// active history) and "彻底删除" (hard-delete). A header shows how many
/// items are queued and how soon they'll be auto-purged.
struct TrashPanelView: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Query private var trashed: [ClipboardItem]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject private var nav = AppNavigation.shared
    @ObservedObject private var filters = FilterSettingsStore.shared

    init() {
        // Fetch only the soft-deleted rows. The previous query had no predicate,
        // so it pulled the *entire* history — every active clip plus its image
        // and embedding blobs — into memory just to display the trash, then
        // re-filtered in Swift on every render. Worse, an unpredicated @Query
        // re-runs on every save, so each purge/clear re-materialised the whole
        // database on the main thread: that is what made opening the panel and
        // confirming a clear stutter and beachball.
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        )
        // The trash rows never render raw image bytes or embedding vectors;
        // keep them faulted so entering the panel doesn't materialise every blob
        // in the trash. ThumbnailView faults imageData back in lazily for the
        // handful of visible rows, exactly like the main list does.
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
        _trashed = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            bulkClearBar
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

            if trashed.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(trashed) { item in
                            row(for: item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.10), Color.clear],
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

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: { nav.showList() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(PaperIconButtonStyle(size: 34))
            .help(L("common.back"))
            .keyboardShortcut(.escape, modifiers: [])

            VStack(alignment: .leading, spacing: 2) {
                Text(L("trash.title"))
                    .font(.system(size: 28, weight: .bold))
                Text(captionText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !trashed.isEmpty {
                Button {
                    ConfirmationCenter.shared.confirm(
                        title: L("confirm.empty.title"),
                        message: L("confirm.empty.messageFormat", trashed.count),
                        confirmLabel: L("trash.emptyButton"),
                        icon: "trash.slash"
                    ) {
                        vm.emptyTrash(context: modelContext)
                        ToastCenter.shared.show(L("trash.emptyDone"), systemImage: "trash.slash.fill", tint: .red)
                    }
                } label: {
                    Label(L("trash.emptyButton"), systemImage: "trash.slash")
                }
                .buttonStyle(PaperActionButtonStyle(role: .destructive))
            }
        }
    }

    private var captionText: String {
        if trashed.isEmpty { return L("trash.captionEmpty") }
        let retention = filters.trashRetentionDays
        if retention <= 0 {
            return L("trash.captionForeverFormat", trashed.count)
        }
        return L("trash.captionRetentionFormat", trashed.count, retention)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text(L("trash.empty.title"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L("trash.empty.subtitle"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for item: ClipboardItem) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item, size: 40, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(for: item))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: item.itemType.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.descriptiveTag)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(.secondary.opacity(0.14))
                    )
                    ForEach(item.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(Color.appAccent.opacity(0.14))
                        )
                    }
                    Text(L("trash.deletedAtFormat", relativeDeleted(item)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(expiryHint(for: item))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            HoverIconButton(
                systemName: "arrow.uturn.backward",
                help: L("trash.restore"),
                tint: .appAccent
            ) {
                vm.restoreItem(item, context: modelContext)
                ToastCenter.shared.show(L("trash.restored"), systemImage: "arrow.uturn.backward", tint: .appAccent)
            }

            HoverIconButton(
                systemName: "trash",
                help: L("trash.purge"),
                tint: .red
            ) {
                ConfirmationCenter.shared.confirm(
                    title: L("confirm.purge.title"),
                    message: L("confirm.permanent.message"),
                    confirmLabel: L("trash.purge"),
                    icon: "trash"
                ) {
                    vm.purgeItem(item, context: modelContext)
                    ToastCenter.shared.show(L("trash.purged"), systemImage: "trash.fill", tint: .red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(.regularMaterial)
                .opacity(0.55)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.separator.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func displayTitle(for item: ClipboardItem) -> String {
        if let preview = item.preview,
           preview.hasPrefix("[合并 ") || preview.hasPrefix("[Merged ") {
            return preview.components(separatedBy: .newlines).first ?? preview
        }
        if let url = item.resolvedFileURL { return url.lastPathComponent }
        let firstLine = (item.preview ?? item.content)
            .components(separatedBy: .newlines)
            .first ?? ""
        return firstLine.isEmpty ? item.itemType.displayName : firstLine
    }

    private func relativeDeleted(_ item: ClipboardItem) -> String {
        guard let deletedAt = item.deletedAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.shared.effectiveLanguage == .zh
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
        f.unitsStyle = .short
        return f.localizedString(for: deletedAt, relativeTo: Date())
    }

    /// Row of chips that lets the user bulk-purge recently captured clips
    /// (5/15/60 min, today). Acts on **active history**, not on the trash
    /// itself — the items are soft-deleted into trash when the user has the
    /// trash enabled, hard-deleted otherwise. Pinned/favorited rows are
    /// preserved by the underlying VM call.
    private var bulkClearBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L("trash.clearLast.sectionTitle"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(filters.trashEnabled
                     ? L("trash.clearLast.sectionHintSoft")
                     : L("trash.clearLast.sectionHintHard"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                BulkClearChip(label: L("trash.clearLast.fiveMin"),
                              systemImage: "5.circle") {
                    confirmClear(rangeLabel: L("trash.clearLast.fiveMin")) {
                        performClearLast(minutes: 5)
                    }
                }
                BulkClearChip(label: L("trash.clearLast.fifteenMin"),
                              systemImage: "15.circle") {
                    confirmClear(rangeLabel: L("trash.clearLast.fifteenMin")) {
                        performClearLast(minutes: 15)
                    }
                }
                BulkClearChip(label: L("trash.clearLast.oneHour"),
                              systemImage: "1.circle") {
                    confirmClear(rangeLabel: L("trash.clearLast.oneHour")) {
                        performClearLast(minutes: 60)
                    }
                }
                BulkClearChip(label: L("trash.clearLast.today"),
                              systemImage: "sun.max") {
                    confirmClear(rangeLabel: L("trash.clearLast.today")) {
                        performClearToday()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .opacity(0.55)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// Pops the shared confirm dialog before running a bulk-clear. `rangeLabel`
    /// is the chip's own label (e.g. "最近 5 分钟") so the dialog names exactly
    /// what's about to be cleared.
    private func confirmClear(rangeLabel: String, _ action: @escaping () -> Void) {
        ConfirmationCenter.shared.confirm(
            title: L("confirm.clearRange.titleFormat", rangeLabel),
            message: filters.trashEnabled
                ? L("confirm.clearRange.softMessage")
                : L("confirm.permanent.message"),
            confirmLabel: L("common.clear"),
            icon: "clock.arrow.circlepath",
            action: action
        )
    }

    private func performClearLast(minutes: Int) {
        let count = vm.clearLastMinutes(minutes, context: modelContext)
        guard count > 0 else {
            ToastCenter.shared.show(
                L("trash.clearLast.empty"),
                systemImage: "tray",
                tint: .secondary
            )
            return
        }
        ToastCenter.shared.show(
            L("trash.clearLast.doneFormat", count),
            systemImage: "trash.fill",
            tint: .appAccent
        )
    }

    private func performClearToday() {
        let count = vm.clearToday(context: modelContext)
        guard count > 0 else {
            ToastCenter.shared.show(
                L("trash.clearLast.empty"),
                systemImage: "tray",
                tint: .secondary
            )
            return
        }
        ToastCenter.shared.show(
            L("trash.clearLast.doneFormat", count),
            systemImage: "trash.fill",
            tint: .appAccent
        )
    }

    private func expiryHint(for item: ClipboardItem) -> String {
        let days = filters.trashRetentionDays
        guard days > 0, let deletedAt = item.deletedAt else { return "" }
        let remaining = deletedAt.addingTimeInterval(Double(days) * 86_400)
            .timeIntervalSince(Date())
        if remaining <= 0 { return L("trash.expiry.soon") }
        let hours = Int(remaining / 3600)
        if hours < 24 { return L("trash.expiry.hoursFormat", hours) }
        return L("trash.expiry.daysFormat", hours / 24)
    }
}

/// Pill button used by the bulk-clear bar at the top of the trash panel.
private struct BulkClearChip: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(hovering ? Color.white : Color.appAccent)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering ? Color.appAccent : Color.appAccent.opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.appAccent.opacity(hovering ? 0 : 0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
