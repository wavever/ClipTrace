import SwiftUI
import AppKit

/// UI-facing discriminator for `RuleAction` (which carries associated values).
/// Drives the action-type picker; composed back into a `RuleAction` on save.
enum RuleActionKind: String, CaseIterable, Hashable, Identifiable {
    case drop, replaceRegex, shell, javascript
    var id: String { rawValue }
    var displayName: String { L("settings.rules.action.\(rawValue)") }
    var icon: String {
        switch self {
        case .drop: return "trash"
        case .replaceRegex: return "textformat"
        case .shell: return "terminal"
        case .javascript: return "curlybraces"
        }
    }
    /// Whether this action runs user-authored code (needs the authorization gate).
    var isScript: Bool { self == .shell || self == .javascript }
}

/// Hosts the single rule-editor overlay, mirroring `ConfirmationCenter` so the
/// editor springs in over the window with the app's motion instead of a system
/// sheet. `MainWindowContent` renders the overlay; any site calls `present`.
@MainActor
final class RuleEditorCenter: ObservableObject {
    static let shared = RuleEditorCenter()
    @Published var editing: ScriptingRule?
    private init() {}

    func present(_ rule: ScriptingRule) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { editing = rule }
    }
    func dismiss() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { editing = nil }
    }
}

// MARK: - Rules tab content

struct RulesSection: View {
    @ObservedObject private var store = FilterSettingsStore.shared
    @ObservedObject private var runLog = ScriptRunLog.shared

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "bolt.badge.automatic", title: L("settings.rules.intro.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "info.circle",
                    iconTint: .appAccent,
                    title: L("settings.rules.intro.row"),
                    subtitle: L("settings.rules.intro.subtitle")
                ) { EmptyView() }
                SettingsRow(
                    icon: "folder",
                    iconTint: .appAccent,
                    title: L("settings.rules.folder.row"),
                    subtitle: L("settings.rules.folder.subtitle")
                ) {
                    Button {
                        revealScriptsFolder()
                    } label: {
                        Label(L("settings.rules.folder.open"), systemImage: "folder")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }

            rulesCard
            if !runLog.records.isEmpty { runLogCard }
        }
    }

    private var rulesCard: some View {
        SettingCard(title: L("settings.rules.list.title"), subtitle: L("settings.rules.list.subtitle")) {
            VStack(spacing: 8) {
                if store.scriptingRules.isEmpty {
                    Text(L("settings.rules.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(store.scriptingRules) { rule in
                        ruleRow(rule)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        RuleEditorCenter.shared.present(ScriptingRule(name: ""))
                    } label: {
                        Label(L("settings.rules.add"), systemImage: "plus")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
        }
    }

    private func ruleRow(_ rule: ScriptingRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: RuleActionKind(from: rule.action).icon)
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(conditionSummary(rule))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { requestEnable(rule, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.appAccent)
            Button { RuleEditorCenter.shared.present(rule) } label: { Image(systemName: "pencil") }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .help(L("common.edit"))
            Button { delete(rule) } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .foregroundStyle(Color.appDanger)
                .help(L("common.remove"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.appChipFill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
    }

    private var runLogCard: some View {
        SettingCard(title: L("settings.rules.log.title"), subtitle: L("settings.rules.log.subtitle")) {
            VStack(spacing: 4) {
                ForEach(runLog.records.prefix(8)) { rec in
                    HStack(spacing: 8) {
                        Image(systemName: outcomeIcon(rec.outcome))
                            .font(.system(size: 11))
                            .foregroundStyle(outcomeTint(rec.outcome))
                            .frame(width: 16)
                        Text(rec.ruleName).font(.system(size: 12, weight: .medium))
                        if let detail = rec.detail {
                            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Text(rec.date, style: .time).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button { runLog.clear() } label: { Text(L("settings.rules.log.clear")) }
                        .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
        }
    }

    // MARK: helpers

    private func requestEnable(_ rule: ScriptingRule, _ isOn: Bool) {
        // Arming a script rule requires explicit consent that it runs code on
        // captured clipboard content.
        if isOn, rule.action.isScript {
            ConfirmationCenter.shared.confirm(
                title: L("settings.rules.authorize.title"),
                message: L("settings.rules.authorize.message"),
                confirmLabel: L("settings.rules.authorize.confirm"),
                icon: "exclamationmark.shield",
                isDestructive: false,
                action: { setEnabled(rule, true) }
            )
        } else {
            setEnabled(rule, isOn)
        }
    }

    private func setEnabled(_ rule: ScriptingRule, _ isOn: Bool) {
        guard let idx = store.scriptingRules.firstIndex(where: { $0.id == rule.id }) else { return }
        store.scriptingRules[idx].isEnabled = isOn
    }

    private func delete(_ rule: ScriptingRule) {
        store.scriptingRules.removeAll { $0.id == rule.id }
    }

    private func revealScriptsFolder() {
        let dir = ScriptRuleEngine.ensureScriptsDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func conditionSummary(_ rule: ScriptingRule) -> String {
        var parts: [String] = [RuleActionKind(from: rule.action).displayName]
        if !rule.matchTypes.isEmpty {
            parts.append(rule.matchTypes.map { $0.displayName }.sorted().joined(separator: "/"))
        }
        if !rule.contentRegex.isEmpty { parts.append("/\(rule.contentRegex)/") }
        return parts.joined(separator: " · ")
    }

    private func outcomeIcon(_ o: ScriptRunRecord.Outcome) -> String {
        switch o {
        case .applied: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    private func outcomeTint(_ o: ScriptRunRecord.Outcome) -> Color {
        switch o {
        case .applied: return .green
        case .skipped: return .secondary
        case .error: return .orange
        }
    }
}

extension RuleActionKind {
    init(from action: RuleAction) {
        switch action {
        case .drop: self = .drop
        case .replaceRegex: self = .replaceRegex
        case .shell: self = .shell
        case .javascript: self = .javascript
        }
    }
}

// MARK: - Rule editor

struct RuleEditorPanel: View {
    let onSave: (ScriptingRule) -> Void
    let onCancel: () -> Void

    /// Default scaffold for a fresh JS rule — the familiar userscript IIFE.
    static let jsBoilerplate = """
        (function() {
            'use strict';

            // Your code here...
        })();
        """

    @State private var draft: ScriptingRule
    @State private var kind: RuleActionKind
    @State private var regexPattern: String
    @State private var regexReplacement: String
    @State private var shellName: String
    @State private var jsSource: String
    @State private var minLengthText: String
    @State private var maxLengthText: String

    init(rule: ScriptingRule, onSave: @escaping (ScriptingRule) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
        _kind = State(initialValue: RuleActionKind(from: rule.action))
        switch rule.action {
        case .replaceRegex(let p, let r):
            _regexPattern = State(initialValue: p); _regexReplacement = State(initialValue: r)
            _shellName = State(initialValue: ""); _jsSource = State(initialValue: Self.jsBoilerplate)
        case .shell(let n):
            _shellName = State(initialValue: n)
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: ""); _jsSource = State(initialValue: Self.jsBoilerplate)
        case .javascript(let s):
            // Existing scripts keep their source; a blank one gets the scaffold.
            _jsSource = State(initialValue: s.isEmpty ? Self.jsBoilerplate : s)
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: ""); _shellName = State(initialValue: "")
        case .drop:
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: ""); _shellName = State(initialValue: ""); _jsSource = State(initialValue: Self.jsBoilerplate)
        }
        _minLengthText = State(initialValue: rule.minLength.map(String.init) ?? "")
        _maxLengthText = State(initialValue: rule.maxLength.map(String.init) ?? "")
    }

    private var regexValid: Bool {
        draft.contentRegex.isEmpty || ScriptingRule.compiledRegex(draft.contentRegex) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.rules.editor.title"))
                .font(.system(size: 16, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(L("settings.rules.editor.name")) {
                        TextField(L("settings.rules.editor.namePlaceholder"), text: $draft.name)
                            .paperTextField()
                    }

                    field(L("settings.rules.editor.match")) {
                        VStack(alignment: .leading, spacing: 8) {
                            typeChips
                            VStack(alignment: .leading, spacing: 3) {
                                TextField("/regex/  —  " + L("settings.rules.editor.regexPlaceholder"), text: $draft.contentRegex)
                                    .paperTextField()
                                if !regexValid {
                                    Text(L("settings.rules.editor.regexInvalid"))
                                        .font(.system(size: 10)).foregroundStyle(Color.appDanger)
                                }
                            }
                            HStack(spacing: 8) {
                                TextField(L("settings.rules.editor.minLen"), text: $minLengthText).paperTextField().frame(width: 110)
                                TextField(L("settings.rules.editor.maxLen"), text: $maxLengthText).paperTextField().frame(width: 110)
                            }
                        }
                    }

                    field(L("settings.rules.editor.action")) {
                        VStack(alignment: .leading, spacing: 8) {
                            PaperMenuPicker(
                                options: RuleActionKind.allCases.map { PaperMenuOption($0, $0.displayName, icon: $0.icon) },
                                selection: $kind,
                                width: 220
                            )
                            actionDetail
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 360)

            HStack {
                if kind.isScript {
                    Label(L("settings.rules.editor.scriptHint"), systemImage: "exclamationmark.shield")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("common.cancel")) { onCancel() }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                Button(L("common.save")) { save() }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appCard)
                .shadow(color: Color.appCardShadow.opacity(0.5), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
    }

    @ViewBuilder private var actionDetail: some View {
        switch kind {
        case .drop:
            Text(L("settings.rules.action.drop.desc")).font(.system(size: 11)).foregroundStyle(.secondary)
        case .replaceRegex:
            VStack(spacing: 6) {
                TextField(L("settings.rules.editor.find"), text: $regexPattern).paperTextField()
                TextField(L("settings.rules.editor.replace"), text: $regexReplacement).paperTextField()
            }
        case .shell:
            shellPicker
        case .javascript:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.rules.editor.jsHint")).font(.system(size: 10)).foregroundStyle(.tertiary)
                JSCodeEditor(text: $jsSource)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.appChipFill))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
            }
        }
    }

    private var shellPicker: some View {
        let scripts = ScriptRuleEngine.availableScripts()
        return VStack(alignment: .leading, spacing: 6) {
            if scripts.isEmpty {
                Text(L("settings.rules.editor.noScripts")).font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([ScriptRuleEngine.ensureScriptsDirectory()])
                } label: { Label(L("settings.rules.folder.open"), systemImage: "folder") }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
            } else {
                PaperMenuPicker(
                    options: scripts.map { PaperMenuOption($0, $0) },
                    selection: Binding(get: { shellName.isEmpty ? scripts[0] : shellName }, set: { shellName = $0 }),
                    width: 260
                )
            }
        }
    }

    private var typeChips: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardItemType.allCases, id: \.self) { type in
                let on = draft.matchTypes.contains(type)
                Button {
                    if on { draft.matchTypes.remove(type) } else { draft.matchTypes.insert(type) }
                } label: {
                    Text(type.displayName).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.appAccent.opacity(0.18) : Color.appChipFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.appAccent : Color.appCardBorder, lineWidth: 0.5))
                        .foregroundStyle(on ? Color.appAccent : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canSave: Bool {
        guard regexValid else { return false }
        switch kind {
        case .drop: return true
        case .replaceRegex: return !regexPattern.isEmpty
        case .shell: return !shellName.isEmpty || !ScriptRuleEngine.availableScripts().isEmpty
        case .javascript: return !jsSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        draft.minLength = Int(minLengthText.trimmingCharacters(in: .whitespaces))
        draft.maxLength = Int(maxLengthText.trimmingCharacters(in: .whitespaces))
        switch kind {
        case .drop:
            draft.action = .drop
        case .replaceRegex:
            draft.action = .replaceRegex(pattern: regexPattern, replacement: regexReplacement)
        case .shell:
            let scripts = ScriptRuleEngine.availableScripts()
            draft.action = .shell(scriptName: shellName.isEmpty ? (scripts.first ?? "") : shellName)
        case .javascript:
            draft.action = .javascript(source: jsSource)
        }
        // Changing a rule's action to a script invalidates a prior consent, so a
        // freshly edited script rule re-arms via the toggle (stays as-is here).
        onSave(draft)
    }
}

// MARK: - JS code editor (syntax highlight + auto-indent)

/// Lightweight JavaScript editor: a monospaced `NSTextView` with regex-based
/// syntax highlighting (warm/earth palette to match the app, not cool IDE
/// blues) plus newline/tab auto-indentation — the "new userscript" feel that
/// SwiftUI's `TextEditor` can't provide.
struct JSCodeEditor: NSViewRepresentable {
    @Binding var text: String

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        context.coordinator.textView = tv
        JSHighlighter.apply(to: tv.textStorage, font: Self.font)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        JSHighlighter.apply(to: tv.textStorage, font: Self.font)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: JSCodeEditor
        weak var textView: NSTextView?
        init(_ parent: JSCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            JSHighlighter.apply(to: tv.textStorage, font: JSCodeEditor.font)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Carry the current line's indent to the next line, and add one
                // level after an opening brace — basic editor auto-indent.
                let ns = textView.string as NSString
                let sel = textView.selectedRange()
                let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
                let prefix = ns.substring(with: NSRange(location: lineStart, length: max(0, sel.location - lineStart)))
                let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
                let extra = prefix.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? "    " : ""
                textView.insertText("\n" + indent + extra, replacementRange: sel)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}

/// Regex syntax highlighter for the JS editor. Re-colours the whole document on
/// each edit — cheap for short rule scripts. Colours are dynamic so they read on
/// both the light (paper) and dark backgrounds.
enum JSHighlighter {
    private static let keywords = [
        "function","var","let","const","return","if","else","for","while","do","switch",
        "case","default","break","continue","new","typeof","instanceof","this","null",
        "undefined","true","false","in","of","try","catch","finally","throw","class",
        "extends","super","yield","async","await","delete","void","with","debugger",
    ]

    private static let keywordRegex = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b")
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`")
    private static let commentRegex = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    private static let keywordColor = dyn(NSColor(srgbRed: 0.64, green: 0.30, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.86, green: 0.57, blue: 0.43, alpha: 1))
    private static let stringColor  = dyn(NSColor(srgbRed: 0.36, green: 0.44, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.67, green: 0.76, blue: 0.52, alpha: 1))
    private static let numberColor  = dyn(NSColor(srgbRed: 0.60, green: 0.42, blue: 0.13, alpha: 1), NSColor(srgbRed: 0.85, green: 0.67, blue: 0.37, alpha: 1))
    private static let commentColor = dyn(NSColor(srgbRed: 0.58, green: 0.53, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.55, green: 0.51, blue: 0.45, alpha: 1))

    static func apply(to storage: NSTextStorage?, font: NSFont) {
        guard let storage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
        paint(keywordRegex, keywordColor, text, full, storage)
        paint(numberRegex, numberColor, text, full, storage)
        // Strings and comments run last so they win over keyword/number colouring
        // that falls inside them.
        paint(stringRegex, stringColor, text, full, storage)
        paint(commentRegex, commentColor, text, full, storage)
        storage.endEditing()
    }

    private static func paint(_ re: NSRegularExpression, _ color: NSColor, _ text: String, _ range: NSRange, _ storage: NSTextStorage) {
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
        }
    }
}
