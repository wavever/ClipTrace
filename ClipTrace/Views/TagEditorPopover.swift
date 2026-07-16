import SwiftUI
import SwiftData

struct TagEditorPopover: View {
    let item: ClipboardItem
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void
    var width: CGFloat = 340
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var knownTags: [String] = []
    @State private var selectedTags: [String] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(Color.appAccent)
                Text(L("tags.title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                TextField(L("tags.placeholder"), text: $draft)
                    .focused($fieldFocused)
                    .onSubmit(handleSubmit)
                    .paperTextField(focused: fieldFocused)
                Button {
                    commitDraft()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(PaperActionButtonStyle(role: .primary))
                .disabled(trimmedDraft.isEmpty)
            }

            Divider()

            Text(L("tags.existing"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if knownTags.isEmpty {
                Text(L("tags.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(knownTags, id: \.self) { tag in
                            tagChoice(for: tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                Button(L("common.cancel")) {
                    cancelAndDismiss()
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut(.cancelAction)
                Button(L("common.done")) {
                    saveAndDismiss()
                }
                .buttonStyle(PaperActionButtonStyle(role: .primary))
            }
        }
        .padding(18)
        .frame(width: width)
        .onAppear {
            selectedTags = item.tags
            reloadKnownTags()
            fieldFocused = true
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitDraft() {
        let value = trimmedDraft
        guard !value.isEmpty else { return }
        if !selectedTags.contains(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) {
            selectedTags.append(value)
        }
        draft = ""
        includeKnownTag(value)
    }

    /// Return is deliberately two-stage: while text is present it adds that
    /// tag and keeps focus in the field; once the field is empty, the next
    /// Return confirms the accumulated edits and closes the sheet.
    private func handleSubmit() {
        if trimmedDraft.isEmpty {
            saveAndDismiss()
        } else {
            commitDraft()
        }
    }

    private func saveAndDismiss() {
        commitDraft()

        let originalTags = item.tags
        let originalKeys = Set(originalTags.map { $0.lowercased() })
        let selectedKeys = Set(selectedTags.map { $0.lowercased() })

        for tag in originalTags where !selectedKeys.contains(tag.lowercased()) {
            onRemove(tag)
        }
        for tag in selectedTags where !originalKeys.contains(tag.lowercased()) {
            onAdd(tag)
        }
        closeEditor()
    }

    /// All edits live in `selectedTags` until save, so cancellation can close
    /// immediately without rolling back SwiftData or publishing a mutation.
    private func cancelAndDismiss() {
        closeEditor()
    }

    private func closeEditor() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func tagChoice(for tag: String) -> some View {
        let isAssigned = selectedTags.contains {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }

        return Button {
            if isAssigned {
                selectedTags.removeAll {
                    $0.caseInsensitiveCompare(tag) == .orderedSame
                }
            } else {
                selectedTags.append(tag)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAssigned ? "checkmark" : "tag.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.appAccent.opacity(isAssigned ? 0.20 : 0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.appAccent.opacity(isAssigned ? 0.42 : 0.20),
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(isAssigned ? Color.appAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func reloadKnownTags() {
        guard let context = item.modelContext else {
            knownTags = item.tags
            return
        }

        // Fetch only tagged rows and keep payload blobs faulted; the editor
        // needs the global catalog, not the currently paged history slice.
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.tagsRaw != nil }
        )
        descriptor.propertiesToFetch = [\.deletedAt, \.tagsRaw]
        let taggedItems = (try? context.fetch(descriptor)) ?? []

        var displayByKey: [String: String] = [:]
        for taggedItem in taggedItems {
            for tag in taggedItem.tags {
                let key = tag.lowercased()
                if displayByKey[key] == nil { displayByKey[key] = tag }
            }
        }
        // A just-added tag may not have reached a context fetch yet, so fold
        // the edited model in explicitly before sorting the choices.
        for tag in item.tags {
            let key = tag.lowercased()
            if displayByKey[key] == nil { displayByKey[key] = tag }
        }
        knownTags = displayByKey.values.sorted {
            $0.localizedCompare($1) == .orderedAscending
        }
    }

    private func includeKnownTag(_ tag: String) {
        guard !knownTags.contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) else { return }
        knownTags.append(tag)
        knownTags.sort { $0.localizedCompare($1) == .orderedAscending }
    }

}

/// Simple flow layout — wraps child views to multiple lines when they exceed
/// the proposed width. Shared by the tag editor and the search bar's tag
/// suggestion panel.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
