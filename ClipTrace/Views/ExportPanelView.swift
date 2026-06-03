import SwiftUI
import SwiftData

struct ExportPanelView: View {
    /// Pulls the *full* active history (not the paged slice the main window
    /// holds) so an export always covers everything the user could expect.
    @Query private var allItems: [ClipboardItem]
    let onClose: () -> Void

    @State private var filter = ExportFilter()
    @State private var isExporting = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Active history only — trashed clips shouldn't silently land in an
        // export — and keep the heavy image/embedding blobs faulted so opening
        // the sheet doesn't pull every bitmap in the database into memory just
        // to show a count. The export itself runs on the main thread (the
        // NSSavePanel completion), so the handful of blobs it needs fault back
        // in safely there, and only when the user opts into "include image
        // data" (off by default).
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \.id,
            \.type,
            \.content,
            \.preview,
            \.sourceApp,
            \.fileURL,
            \.createdAt,
            \.isFavorite,
            \.isPinned,
            \.deletedAt,
        ]
        _allItems = Query(descriptor)
    }

    private var matched: [ClipboardItem] { filter.apply(to: allItems) }

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
        .background(Color(nsColor: .windowBackgroundColor))
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
                Text(L("export.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.secondary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help(L("common.close"))
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var typesCard: some View {
        ExportCard(title: L("export.types.title"), subtitle: L("export.types.subtitle")) {
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
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn ? Color.appAccent.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isOn ? Color.appAccent.opacity(0.4) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var rangeCard: some View {
        ExportCard(title: L("export.range.title"), subtitle: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $filter.dateRange) {
                    ForEach(ExportFilter.DateRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if filter.dateRange == .custom {
                    HStack(spacing: 10) {
                        DatePicker(L("export.range.from"), selection: $filter.customStart, displayedComponents: [.date])
                        DatePicker(L("export.range.to"), selection: $filter.customEnd, displayedComponents: [.date])
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var favoriteCard: some View {
        ExportCard(title: L("export.favorites.title"), subtitle: nil) {
            Picker("", selection: $filter.favoriteScope) {
                ForEach(ExportFilter.FavoriteScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var optionsCard: some View {
        ExportCard(title: L("export.options.title"), subtitle: nil) {
            Toggle(isOn: $filter.includeImageData) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("export.options.includeImage"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("export.options.includeImage.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L("export.willExportFormat", matched.count, allItems.count))
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
            .disabled(matched.isEmpty || isExporting)
            .opacity(matched.isEmpty || isExporting ? 0.5 : 1)
        }
    }

    private func exportNow() {
        isExporting = true
        ExportService.shared.exportToJSON(items: allItems, filter: filter) { result in
            DispatchQueue.main.async {
                isExporting = false
                switch result {
                case .none:
                    break
                case .success(let url):
                    ToastCenter.shared.show(
                        L("export.successFormat", matched.count, url.lastPathComponent),
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

private struct ExportCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }
}
