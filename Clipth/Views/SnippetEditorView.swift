import SwiftUI

/// Sheet for hand-authoring a clipboard entry. The created item is treated
/// like any other history row — the user can pin / favorite / search it. It
/// gets `sourceApp = "片段"` so it's distinguishable from captured copies.
struct SnippetEditorView: View {
    let onSave: (String, ClipboardItemType, Bool) -> Void
    let onCancel: () -> Void

    @State private var content: String = ""
    @State private var type: ClipboardItemType = .text
    @State private var pinAfterSave: Bool = true
    @FocusState private var editorFocused: Bool

    private var trimmed: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(L("snippet.title"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                PaperMenuPicker(
                    options: [ClipboardItemType.text, .url, .rtf].map {
                        PaperMenuOption($0, $0.displayName, icon: $0.icon)
                    },
                    selection: $type,
                    width: 120
                )
            }

            ZStack(alignment: .topLeading) {
                if content.isEmpty {
                    Text(L("snippet.placeholder"))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $content)
                    .font(.system(size: 13, design: type == .rtf ? .default : .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .focused($editorFocused)
            }
            .frame(minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            )

            HStack(spacing: 14) {
                Toggle(L("snippet.pinAfterSave"), isOn: $pinAfterSave)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button { onCancel() } label: {
                    Text(L("common.cancel"))
                        .frame(minWidth: 60)
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut(.escape, modifiers: [])
                Button {
                    onSave(trimmed, type, pinAfterSave)
                } label: {
                    Text(L("common.save"))
                        .frame(minWidth: 60)
                }
                .buttonStyle(PaperActionButtonStyle(role: .primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { editorFocused = true }
    }
}
