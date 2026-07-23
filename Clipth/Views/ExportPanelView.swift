import SwiftUI
import SwiftData

struct ExportPanelView: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var filter = ExportFilter()
    @State private var isExporting = false
    // The panel only needs two numbers to render — how many clips match the
    // current filter, and how many exist in total. Holding the whole history in
    // an unpredicated @Query (and re-running `filter.apply` over all of it on
    // every body evaluation) is what made opening the sheet and every toggle /
    // even the Cancel button stutter. Compute the counts with cheap DB-side
    // COUNT queries instead, and only when the filter actually changes.
    @State private var matchedCount = 0
    @State private var totalCount = 0

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    typesCard
                    rangeCard
                    favoriteCard
                    optionsCard
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }

            Divider().opacity(0.4)

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
        .background(Color.appPaper)
        // Counts are computed after the sheet paints (so presentation stays
        // instant) and refreshed only when the filter changes.
        .task { recount() }
        .onChange(of: filter) { _, _ in recount() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [.appAccent, .appAccent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("export.title"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.appMetal)
                Text(L("export.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PaperIconButtonStyle(size: 28))
            .help(L("common.close"))
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var typesCard: some View {
        SettingCard(title: L("export.types.title"), subtitle: L("export.types.subtitle")) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(ClipboardItemType.allCases, id: \.self) { type in
                    typeChip(type)
                }
            }
        }
    }

    private func typeChip(_ type: ClipboardItemType) -> some View {
        let isOn = filter.types.contains(type)
        return Button {
            if isOn {
                filter.types.remove(type)
            } else {
                filter.types.insert(type)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Color.appAccent : Color.secondary)
                Image(systemName: type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(type.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appMetal)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.appAccent.opacity(0.12) : Color.appChipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isOn ? Color.appAccent.opacity(0.45) : Color.appCardBorder,
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var rangeCard: some View {
        SettingCard(title: L("export.range.title")) {
            VStack(alignment: .leading, spacing: 12) {
                // Five ranges fit a dropdown better than a cramped pill.
                PaperMenuPicker(
                    options: ExportFilter.DateRange.allCases.map {
                        PaperMenuOption($0, $0.displayName)
                    },
                    selection: $filter.dateRange,
                    width: 220
                )

                if filter.dateRange == .custom {
                    HStack(spacing: 10) {
                        DatePicker(L("export.range.from"), selection: $filter.customStart, displayedComponents: [.date])
                        DatePicker(L("export.range.to"), selection: $filter.customEnd, displayedComponents: [.date])
                    }
                    .font(.system(size: 12))
                    .tint(.appAccent)
                }
            }
        }
    }

    private var favoriteCard: some View {
        SettingCard(title: L("export.favorites.title")) {
            SettingsSegmented(
                selection: $filter.favoriteScope,
                options: ExportFilter.FavoriteScope.allCases.map {
                    .init(value: $0, title: $0.displayName, icon: nil)
                }
            )
        }
    }

    private var optionsCard: some View {
        SettingInlineCard(
            title: L("export.options.includeImage"),
            subtitle: L("export.options.includeImage.subtitle")
        ) {
            Toggle("", isOn: $filter.includeImageData)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.appAccent)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L("export.willExportFormat", matchedCount, totalCount))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L("common.cancel"), action: onClose)
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut(.cancelAction)

            Button {
                exportNow()
            } label: {
                HStack(spacing: 6) {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(L("export.exportButton"))
                }
            }
            .buttonStyle(PaperActionButtonStyle(role: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(matchedCount == 0 || isExporting)
        }
    }

    /// COUNT(*) for the active history and for the current filter — no rows are
    /// materialised, so this stays cheap even on a huge history.
    private func recount() {
        totalCount = (try? modelContext.fetchCount(
            FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.deletedAt == nil })
        )) ?? 0
        matchedCount = (try? modelContext.fetchCount(matchingDescriptor())) ?? 0
    }

    /// A descriptor whose predicate mirrors `ExportFilter.apply`, built from
    /// captured locals so the whole filter collapses into one SwiftData query
    /// (used both for the live count and to fetch the rows at export time).
    private func matchingDescriptor() -> FetchDescriptor<ClipboardItem> {
        let typeStrings = filter.types.map(\.rawValue)
        let wantFavoritesOnly = filter.favoriteScope == .favoritesOnly
        let wantPinnedOnly = filter.favoriteScope == .pinnedOnly
        let interval = filter.resolvedInterval
        let start = interval?.start ?? .distantPast
        let end = interval?.end ?? .distantFuture

        return FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { item in
                item.deletedAt == nil &&
                typeStrings.contains(item.type) &&
                (!wantFavoritesOnly || item.isFavorite) &&
                (!wantPinnedOnly || item.isPinned) &&
                item.createdAt >= start &&
                item.createdAt <= end
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }

    private func exportNow() {
        isExporting = true
        // Fetch the matching rows (with their image bytes) only now, on an
        // explicit export — not on every keystroke in the panel.
        let items = (try? modelContext.fetch(matchingDescriptor())) ?? []
        ExportService.shared.exportToJSON(items: items, filter: filter) { result in
            DispatchQueue.main.async {
                isExporting = false
                switch result {
                case .none:
                    break
                case .success(let url):
                    ToastCenter.shared.show(
                        L("export.successFormat", items.count, url.lastPathComponent),
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                    onClose()
                case .failure(let error):
                    ToastCenter.shared.show(
                        L("export.failedFormat", error.localizedDescription),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
        }
    }
}
