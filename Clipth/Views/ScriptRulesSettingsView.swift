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
    @Published var isBrowsingTemplates = false
    @Published var isComposingPrompt = false
    /// Sample clip text the editor's test panel starts with. Carried alongside
    /// the rule (not stored on it) so a template can hand over an input that
    /// actually demonstrates what it does.
    private(set) var editingSample = ""
    private init() {}

    func present(_ rule: ScriptingRule, sample: String = "") {
        editingSample = sample
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            isBrowsingTemplates = false
            isComposingPrompt = false
            editing = rule
        }
    }
    func dismiss() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { editing = nil }
    }

    func presentTemplates() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { isBrowsingTemplates = true }
    }

    func presentPromptComposer() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { isComposingPrompt = true }
    }
    func dismissPromptComposer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isComposingPrompt = false }
    }
    func dismissTemplates() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isBrowsingTemplates = false }
    }

    /// Land rules that arrived from a model or an agent.
    ///
    /// A single rule opens in the editor rather than being filed away: it is
    /// untrusted, possibly-hallucinated code, and the editor is where the user
    /// can read it and hit 试运行 before saving. A batch is appended disabled,
    /// because reviewing five at once in one editor isn't a thing.
    func adopt(imported rules: [ScriptingRule]) {
        guard !rules.isEmpty else { return }
        if rules.count == 1, var rule = rules.first {
            rule.isEnabled = false
            present(rule)
            return
        }
        for var rule in rules {
            rule.isEnabled = false
            FilterSettingsStore.shared.scriptingRules.append(rule)
        }
        dismissPromptComposer()
        ToastCenter.shared.show(
            L("settings.rules.import.doneFormat", rules.count),
            systemImage: "square.and.arrow.down",
            tint: .appAccent
        )
    }

    /// Open the editor pre-filled from `template`. Rules carry their own code,
    /// so nothing has to be written to disk first.
    func adopt(_ template: RuleTemplate) {
        present(template.makeRule(), sample: template.sample)
    }
}

// MARK: - Rules tab content

struct RulesSection: View {
    @ObservedObject private var store = FilterSettingsStore.shared
    @ObservedObject private var runLog = ScriptRunLog.shared
    @ObservedObject private var stats = RuleStatsStore.shared

    @State private var hoveredRuleID: UUID?

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
                    emptyState
                } else {
                    ForEach(Array(store.scriptingRules.enumerated()), id: \.element.id) { index, rule in
                        ruleRow(rule, index: index)
                    }
                }
                HStack(spacing: 8) {
                    // Importing a rule from the clipboard is the natural way to
                    // share one in a clipboard manager: copy the JSON, paste it
                    // anywhere, import it here.
                    Button {
                        importFromClipboard()
                    } label: {
                        Label(L("settings.rules.import"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .help(L("settings.rules.import.help"))
                    Spacer()
                    Button {
                        RuleEditorCenter.shared.presentPromptComposer()
                    } label: {
                        Label(L("settings.rules.prompt.button"), systemImage: "sparkles")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .help(L("settings.rules.prompt.help"))
                    // The empty state already leads with a templates CTA; a
                    // second one right under it is just noise.
                    if !store.scriptingRules.isEmpty {
                        Button {
                            RuleEditorCenter.shared.presentTemplates()
                        } label: {
                            Label(L("settings.rules.template.button"), systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(PaperActionButtonStyle(role: .plain))
                    }
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

    /// First-run state. A blank list with an "add" button teaches nothing about
    /// what a rule can do, so it points at the templates instead.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22))
                .foregroundStyle(Color.appAccent.opacity(0.8))
            Text(L("settings.rules.empty"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appMetal)
            Text(L("settings.rules.empty.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                RuleEditorCenter.shared.presentTemplates()
            } label: {
                Label(L("settings.rules.empty.browse"), systemImage: "square.grid.2x2")
            }
            .buttonStyle(PaperActionButtonStyle(role: .primary))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func ruleRow(_ rule: ScriptingRule, index: Int) -> some View {
        let hovered = hoveredRuleID == rule.id
        let stat = stats.stat(for: rule.id)
        return HStack(spacing: 10) {
            // The chain is evaluated top-down and a `drop` cuts it short, so a
            // rule's position is part of its meaning — show it, and let it move.
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 13)

            Image(systemName: RuleActionKind(from: rule.action).icon)
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.appAccent)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(rule.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if let error = stat?.lastError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .hoverTip(error)
                    }
                }
                Text(conditionSummary(rule))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let line = statsLine(stat) {
                    Text(line)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Muted until hovered: present enough to be discoverable, quiet
            // enough not to compete with the toggle.
            HStack(spacing: 2) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(PaperIconButtonStyle(size: 22))
                    .disabled(index == 0)
                    .help(L("settings.rules.moveUp"))
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(PaperIconButtonStyle(size: 22))
                    .disabled(index == store.scriptingRules.count - 1)
                    .help(L("settings.rules.moveDown"))
            }
            .opacity(hovered ? 1 : 0.3)

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

            PaperIconMenu(
                icon: "ellipsis",
                options: [
                    PaperMenuOption(RowAction.duplicate.rawValue, L("settings.rules.duplicate"), icon: "plus.square.on.square"),
                    PaperMenuOption(RowAction.copyJSON.rawValue, L("settings.rules.copyJSON"), icon: "doc.on.doc"),
                    PaperMenuOption(RowAction.resetStats.rawValue, L("settings.rules.resetStats"), icon: "arrow.counterclockwise"),
                    PaperMenuOption(RowAction.delete.rawValue, L("common.remove"), icon: "trash"),
                ],
                help: L("settings.rules.more"),
                onSelect: { perform(RowAction(rawValue: $0), on: rule, at: index) }
            )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.appChipFill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Color.appCardBorder : Color.appCardBorder.opacity(0.6), lineWidth: 0.5))
        // A disabled rule never runs; fading it says so without a second badge.
        .opacity(rule.isEnabled ? 1 : 0.6)
        .onHover { inside in
            if inside { hoveredRuleID = rule.id }
            else if hoveredRuleID == rule.id { hoveredRuleID = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: rule.isEnabled)
    }

    private enum RowAction: String {
        case duplicate, copyJSON, resetStats, delete
    }

    private func perform(_ action: RowAction?, on rule: ScriptingRule, at index: Int) {
        switch action {
        case .duplicate: duplicate(rule, at: index)
        case .copyJSON: copyAsJSON(rule)
        case .resetStats: RuleStatsStore.shared.reset(rule.id)
        case .delete: confirmDelete(rule)
        case nil: break
        }
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

    /// Rules run in list order, so moving one is a real edit, not decoration.
    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard store.scriptingRules.indices.contains(index),
              store.scriptingRules.indices.contains(target) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            store.scriptingRules.swapAt(index, target)
        }
    }

    private func duplicate(_ rule: ScriptingRule, at index: Int) {
        var copy = rule
        copy.id = UUID()
        copy.name = L("settings.rules.duplicateNameFormat", rule.displayName)
        // A copy of an armed script rule starts disarmed: consent was given for
        // the original's code, and the copy is about to be edited.
        copy.isEnabled = false
        store.scriptingRules.insert(copy, at: min(index + 1, store.scriptingRules.count))
        RuleEditorCenter.shared.present(copy)
    }

    private func copyAsJSON(_ rule: ScriptingRule) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rule), let json = String(data: data, encoding: .utf8) else { return }
        // Our own write — mark it, or the JSON lands back at the top of history.
        ClipboardMonitor.markInternalWrite()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        ToastCenter.shared.show(L("settings.rules.copyJSON.done"), systemImage: "doc.on.doc", tint: .appAccent)
    }

    private func importFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastCenter.shared.show(L("settings.rules.import.empty"), systemImage: "exclamationmark.circle", tint: .orange)
            return
        }
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        var incoming: [ScriptingRule] = []
        if let many = try? decoder.decode([ScriptingRule].self, from: data) {
            incoming = many
        } else if let one = try? decoder.decode(ScriptingRule.self, from: data) {
            incoming = [one]
        } else {
            // Not our own export — try the interchange shape an LLM or an MCP
            // agent writes, so both kinds of JSON land through one button.
            incoming = (try? RuleSpec.rules(fromJSON: raw)) ?? []
        }
        guard !incoming.isEmpty else {
            ToastCenter.shared.show(L("settings.rules.import.failed"), systemImage: "exclamationmark.triangle", tint: .orange)
            return
        }
        // Imported rules arrive fresh and disarmed: they may carry code, and
        // consent is per-install — never inherited from whoever exported them.
        for var rule in incoming {
            rule.id = UUID()
            rule.isEnabled = false
            store.scriptingRules.append(rule)
        }
        ToastCenter.shared.show(
            L("settings.rules.import.doneFormat", incoming.count),
            systemImage: "square.and.arrow.down",
            tint: .appAccent
        )
    }

    private func confirmDelete(_ rule: ScriptingRule) {
        ConfirmationCenter.shared.confirm(
            title: L("settings.rules.delete.title"),
            message: L("settings.rules.delete.messageFormat", rule.displayName),
            confirmLabel: L("common.remove"),
            icon: "trash",
            isDestructive: true,
            action: {
                store.scriptingRules.removeAll { $0.id == rule.id }
                RuleStatsStore.shared.reset(rule.id)
            }
        )
    }

    private func revealScriptsFolder() {
        let dir = ScriptRuleEngine.ensureScriptsDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// One-line recap of a rule's conditions for the list row: action, source
    /// app, categories, then whichever string condition is armed.
    private func conditionSummary(_ rule: ScriptingRule) -> String {
        var parts: [String] = [RuleActionKind(from: rule.action).displayName]
        parts.append(
            RuleTrigger.allCases
                .filter { rule.triggers.contains($0) }
                .map(\.displayName)
                .joined(separator: "+")
        )
        if !rule.apps.isEmpty {
            parts.append(rule.apps.map(\.name).joined(separator: "/"))
        }
        if !rule.matchCategories.isEmpty {
            parts.append(
                RuleMatchCategory.allCases
                    .filter { rule.matchCategories.contains($0) }
                    .map(\.displayName)
                    .joined(separator: "/")
            )
        }
        for match in [rule.contentMatch, rule.fileNameMatch] where match.isActive {
            parts.append("\(match.mode.displayName) “\(match.value)”")
        }
        if !rule.fileExtensions.isEmpty {
            parts.append("." + rule.fileExtensions.prefix(3).joined(separator: "/."))
        }
        return parts.joined(separator: " · ")
    }

    /// "已应用 12 · 跳过 3 · 2 分钟前" — nil until the rule has actually run.
    private func statsLine(_ stat: RuleStatsStore.Stat?) -> String? {
        guard let stat, let lastRun = stat.lastRun else { return nil }
        var parts: [String] = []
        if stat.applied > 0 { parts.append(L("settings.rules.stats.applied", stat.applied)) }
        if stat.skipped > 0 { parts.append(L("settings.rules.stats.skipped", stat.skipped)) }
        if stat.errors > 0 { parts.append(L("settings.rules.stats.errors", stat.errors)) }
        parts.append(Self.relativeTime(lastRun))
        return parts.joined(separator: " · ")
    }

    static func relativeTime(_ date: Date) -> String {
        // Under a minute the formatter says "0 秒后" / "in 0 seconds", which reads
        // like a scheduled run rather than one that just happened.
        guard Date().timeIntervalSince(date) >= 60 else { return L("settings.rules.stats.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.shared.effectiveLanguage == .zh
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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

// MARK: - Template gallery

/// Catalogue of ready-made rules, hosted as its own overlay (same spring idiom
/// as the editor). Templates get a dedicated surface because they are how the
/// feature is discovered: each card is both a working rule and a worked example
/// of the runner contract, and they only read that way side by side.
struct RuleTemplateGalleryPanel: View {
    let onPick: (RuleTemplate) -> Void
    let onCancel: () -> Void

    @State private var hoveredID: String?
    @State private var query = ""

    /// Free-text filter over the catalogue — matches the name, the description
    /// and the action kind, so "js"/"正则" narrow it as readily as a word from
    /// the summary.
    private func matches(in category: RuleTemplate.Category) -> [RuleTemplate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let items = RuleTemplateLibrary.templates(in: category)
        guard !trimmed.isEmpty else { return items }
        return items.filter { template in
            [template.name, template.summary, RuleActionKind(from: template.action).displayName]
                .contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
    }

    private var filteredCount: Int {
        RuleTemplate.Category.allCases.reduce(0) { $0 + matches(in: $1).count }
    }

    var body: some View {
        GeometryReader { geo in
            card
                .frame(
                    width: min(780, max(420, geo.size.width - 56)),
                    height: min(580, max(320, geo.size.height - 56))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("settings.rules.template.title"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("settings.rules.template.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                TextField(L("settings.rules.template.search"), text: $query)
                    .paperTextField()
                    .frame(width: 160)
            }

            if filteredCount == 0 {
                Text(L("settings.rules.template.noMatch"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(RuleTemplate.Category.allCases) { category in
                        let items = matches(in: category)
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(category.displayName, systemImage: category.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.appAccent)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                                    alignment: .leading,
                                    spacing: 10
                                ) {
                                    ForEach(items) { templateCard($0) }
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button(L("common.cancel")) { onCancel() }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func templateCard(_ template: RuleTemplate) -> some View {
        let hovered = hoveredID == template.id
        return Button {
            onPick(template)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(template.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(RuleActionKind(from: template.action).displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Color.appAccent.opacity(0.10) : Color.appChipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovered ? Color.appAccent.opacity(0.55) : Color.appCardBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredID = template.id }
            else if hoveredID == template.id { hoveredID = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - AI prompt composer

/// Bring-your-own-model rule authoring: the user describes what they want, we
/// wrap it in a prompt that carries everything a model can't know (the rule
/// format, the sandbox its script will run in, the output contract), they paste
/// the answer back and import it.
///
/// Deliberately not an API client — no key to configure, no request leaving the
/// machine from Clipth, and it works with whatever model the user already pays
/// for. The clipboard is the transport, which is fitting.
struct RulePromptPanel: View {
    let onImport: ([ScriptingRule]) -> Void
    let onCancel: () -> Void

    @State private var request = ""
    @State private var didCopy = false
    @State private var importError: String?

    private var prompt: String { RulePromptBuilder.prompt(for: request) }

    var body: some View {
        GeometryReader { geo in
            let width = min(760, max(420, geo.size.width - 56))
            let height = min(620, max(320, geo.size.height - 56))
            card
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("settings.rules.prompt.title"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L("settings.rules.prompt.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, L("settings.rules.prompt.step1")) {
                TextField(L("settings.rules.prompt.requestPlaceholder"), text: $request, axis: .vertical)
                    .lineLimit(2...4)
                    .paperTextField()
            }

            step(2, L("settings.rules.prompt.step2")) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(prompt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.appChipFill))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.appCardBorder, lineWidth: 0.5))

                    Button {
                        copyPrompt()
                    } label: {
                        Label(
                            didCopy ? L("settings.rules.prompt.copied") : L("settings.rules.prompt.copy"),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                }
            }
            .frame(maxHeight: .infinity)

            step(3, L("settings.rules.prompt.step3")) {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        importFromClipboard()
                    } label: {
                        Label(L("settings.rules.prompt.import"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    if let importError {
                        Text(importError)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L("common.close")) { onCancel() }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appCard)
                .shadow(color: Color.appCardShadow.opacity(0.5), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .animation(.easeOut(duration: 0.15), value: didCopy)
        .animation(.easeOut(duration: 0.15), value: importError)
    }

    private func step<C: View>(_ number: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.appAccent.opacity(0.16)))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func copyPrompt() {
        // Our own write — mark it, or the prompt lands back at the top of history.
        ClipboardMonitor.markInternalWrite()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        didCopy = true
        importError = nil
    }

    private func importFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = L("settings.rules.import.empty")
            return
        }
        // Guard against importing the prompt we just handed out.
        guard raw != prompt else {
            importError = L("settings.rules.prompt.error.samePrompt")
            return
        }
        do {
            let rules = try RuleSpec.rules(fromJSON: raw)
            importError = nil
            onImport(rules)
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Rule editor

/// Outcome of one editor test run: whether the conditions would even fire, what
/// the action asked for, what it printed, and why it failed. Reported, never
/// applied — trying a rule out must not touch real history.
private struct RuleTestResult {
    var conditionsHit = true
    var effects: [ScriptEffect] = []
    var logs: [String] = []
    var error: String?
}

/// App scope for a rule. Bundle ids are what a rule stores, but the user only
/// ever sees icons and names: running apps come straight from the dropdown,
/// anything else through the same Finder chooser the exclusion list uses.
struct RuleAppsField: View {
    @Binding var apps: [AppFilterEntry]
    let caption: String

    /// Not a bundle id, so it can never collide with a real selection.
    private static let browseSentinel = "  browse  "

    // Snapshotted on appear instead of read per body pass: enumerating every
    // running app on each keystroke elsewhere in the editor would be wasteful.
    @State private var runningApps: [AppFilterEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !apps.isEmpty {
                PaperFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(apps) { app in
                        appChip(app)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PaperMenuPicker(
                options: addOptions,
                selection: Binding(get: { "" }, set: { add($0) }),
                width: 152,
                displayTitle: L("settings.rules.editor.app.add")
            )
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { runningApps = Self.currentRunningApps() }
        .animation(.easeOut(duration: 0.14), value: apps)
    }

    private func appChip(_ app: AppFilterEntry) -> some View {
        HStack(spacing: 5) {
            icon(for: app.bundleId)
            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                // A long name truncates instead of pushing the chip past the
                // column edge; the full id is still in the tooltip.
                .truncationMode(.middle)
                .frame(maxWidth: 132, alignment: .leading)
            Button {
                apps.removeAll { $0.bundleId == app.bundleId }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.appAccent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.appAccent.opacity(0.5), lineWidth: 0.5))
        .help(app.bundleId)
    }

    @ViewBuilder private func icon(for bundleId: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var addOptions: [PaperMenuOption<String>] {
        var out: [PaperMenuOption<String>] = []
        for app in runningApps where !apps.contains(where: { $0.bundleId == app.bundleId }) {
            out.append(PaperMenuOption(app.bundleId, app.name, icon: "app"))
        }
        out.append(PaperMenuOption(Self.browseSentinel, L("settings.rules.editor.app.browse"), icon: "folder"))
        return out
    }

    private func add(_ value: String) {
        guard !value.isEmpty else { return }
        if value == Self.browseSentinel {
            browse()
            return
        }
        guard let app = runningApps.first(where: { $0.bundleId == value }),
              !apps.contains(where: { $0.bundleId == value }) else { return }
        apps.append(app)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = L("settings.rules.editor.app.browse")
        panel.prompt = L("common.select")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let bundleId = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
            let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if !apps.contains(where: { $0.bundleId == bundleId }) {
                apps.append(AppFilterEntry(bundleId: bundleId, name: name))
            }
        }
    }

    private static func currentRunningApps() -> [AppFilterEntry] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppFilterEntry? in
                guard let id = app.bundleIdentifier, let name = app.localizedName, seen.insert(id).inserted else { return nil }
                return AppFilterEntry(bundleId: id, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// One string condition: a mode dropdown plus its operand. Shared by the text
/// and the file-name condition so both read and behave identically.
struct RuleMatchField: View {
    let title: String
    let placeholder: String
    @Binding var match: RuleTextMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            PaperMenuPicker(
                options: RuleTextMatch.Mode.allCases.map { PaperMenuOption($0, $0.displayName) },
                selection: $match.mode,
                width: 120
            )
            if match.mode.needsValue {
                TextField(placeholder, text: $match.value)
                    .paperTextField()
                if !match.isValid {
                    Text(L("settings.rules.editor.regexInvalid"))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appDanger)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: match.mode)
    }
}

struct RuleEditorPanel: View {
    let onSave: (ScriptingRule) -> Void
    let onCancel: () -> Void

    /// Default scaffold for a fresh JS rule. Localized because its comments are
    /// the shortest documentation of the runner contract an author will read.
    static var jsBoilerplate: String { L("settings.rules.editor.jsBoilerplate") }

    @State private var draft: ScriptingRule
    @State private var kind: RuleActionKind
    @State private var regexPattern: String
    @State private var regexReplacement: String
    @State private var shellSource: String
    @State private var jsSource: String
    @State private var timeoutText: String
    @State private var extensionsText: String
    @State private var sampleText: String
    @State private var testCategory: RuleMatchCategory
    @State private var testResult: RuleTestResult?
    @State private var isTesting = false

    init(
        rule: ScriptingRule,
        sample: String = "",
        onSave: @escaping (ScriptingRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
        _kind = State(initialValue: RuleActionKind(from: rule.action))
        switch rule.action {
        case .replaceRegex(let p, let r):
            _regexPattern = State(initialValue: p); _regexReplacement = State(initialValue: r)
            _shellSource = State(initialValue: ScriptRuleEngine.shellBoilerplate)
            _jsSource = State(initialValue: Self.jsBoilerplate)
        case .shell(let s):
            // Existing scripts keep their source; a blank one gets the scaffold.
            _shellSource = State(initialValue: s.isEmpty ? ScriptRuleEngine.shellBoilerplate : s)
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: "")
            _jsSource = State(initialValue: Self.jsBoilerplate)
        case .javascript(let s):
            _jsSource = State(initialValue: s.isEmpty ? Self.jsBoilerplate : s)
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: "")
            _shellSource = State(initialValue: ScriptRuleEngine.shellBoilerplate)
        case .drop:
            _regexPattern = State(initialValue: ""); _regexReplacement = State(initialValue: "")
            _shellSource = State(initialValue: ScriptRuleEngine.shellBoilerplate)
            _jsSource = State(initialValue: Self.jsBoilerplate)
        }
        _timeoutText = State(initialValue: rule.timeoutSeconds.map { String(format: "%g", $0) } ?? "")
        _extensionsText = State(initialValue: rule.fileExtensions.joined(separator: ", "))

        // The test panel stands in for one kind of clip; start on the first kind
        // the rule actually targets.
        let category = RuleMatchCategory.allCases.first { rule.matchCategories.contains($0) } ?? .text
        _testCategory = State(initialValue: category)
        let fallback = Self.defaultSample(for: category, extensions: rule.fileExtensions)
        _sampleText = State(initialValue: sample.isEmpty ? fallback : sample)
    }

    var body: some View {
        // Sized against the window rather than fixed: rule authoring needs room
        // (a code editor plus its test output), but the panel still has to fit
        // the smallest allowed main window.
        GeometryReader { geo in
            let width = min(920, max(440, geo.size.width - 56))
            let height = min(680, max(320, geo.size.height - 56))
            card(isWide: width >= 720)
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("settings.rules.editor.title"))
                .font(.system(size: 16, weight: .semibold))

            if isWide {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        conditionColumn.padding(.trailing, 4)
                    }
                    .frame(width: 250)
                    Rectangle()
                        .fill(Color.appCardBorder)
                        .frame(width: 0.75)
                    actionColumn(isWide: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        conditionColumn
                        actionColumn(isWide: false)
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 10) {
                if kind.isScript {
                    Label(L("settings.rules.editor.scriptHint"), systemImage: "exclamationmark.shield")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                // Esc / ⌘↩ / ⌘R: an editor you may sit in for a while should be
                // driveable from the keyboard, and the tooltips teach the keys.
                Button(L("common.cancel")) { onCancel() }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)
                    .help(L("settings.rules.editor.cancelHint"))
                Button(L("common.save")) { save() }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(L("settings.rules.editor.saveHint"))
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    // MARK: conditions
    //
    // Read top-down as a sentence: 名称 → 生效时机(+应用) → 生效内容 → 名称/内容
    // 匹配 → 后缀名. Each block narrows the one above it, and blocks that can't
    // apply to the chosen content types stay hidden rather than sitting there
    // greyed out.

    private var conditionColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(L("settings.rules.editor.name")) {
                TextField(L("settings.rules.editor.namePlaceholder"), text: $draft.name)
                    .paperTextField()
            }

            field(L("settings.rules.editor.trigger")) {
                VStack(alignment: .leading, spacing: 8) {
                    triggerChips
                    RuleAppsField(apps: $draft.apps, caption: appsCaption)
                }
            }

            field(L("settings.rules.editor.categories")) {
                VStack(alignment: .leading, spacing: 6) {
                    categoryChips
                    Text(L("settings.rules.editor.categoriesHint"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if showsContentMatch {
                RuleMatchField(
                    title: L("settings.rules.editor.contentMatch"),
                    placeholder: contentPlaceholder,
                    match: $draft.contentMatch
                )
            }

            if showsFileConditions {
                RuleMatchField(
                    title: L("settings.rules.editor.fileNameMatch"),
                    placeholder: fileNamePlaceholder,
                    match: $draft.fileNameMatch
                )

                field(L("settings.rules.editor.extensions")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("settings.rules.editor.extensionsPlaceholder"), text: $extensionsText)
                            .paperTextField()
                        Text(L("settings.rules.editor.extensionsHint"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: draft.matchCategories)
        .animation(.easeOut(duration: 0.14), value: draft.triggers)
    }

    private var triggerChips: some View {
        HStack(spacing: 6) {
            ForEach(RuleTrigger.allCases) { trigger in
                let on = draft.triggers.contains(trigger)
                Button {
                    toggleTrigger(trigger)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: trigger.icon).font(.system(size: 9, weight: .semibold))
                        Text(trigger.displayName).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.appAccent.opacity(0.18) : Color.appChipFill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.appAccent : Color.appCardBorder, lineWidth: 0.5))
                    .foregroundStyle(on ? Color.appAccent : Color.primary)
                }
                .buttonStyle(.plain)
                .help(trigger == .copy ? L("settings.rules.trigger.copy.help") : L("settings.rules.trigger.paste.help"))
            }
        }
    }

    /// A rule with no trigger could never fire, so the last one on can't be
    /// switched off — the click is simply ignored.
    private func toggleTrigger(_ trigger: RuleTrigger) {
        if draft.triggers.contains(trigger) {
            guard draft.triggers.count > 1 else { return }
            draft.triggers.remove(trigger)
        } else {
            draft.triggers.insert(trigger)
        }
    }

    /// The app list means "source" at copy time and "target" at paste time, so
    /// the caption has to follow the triggers.
    private var appsCaption: String {
        let copy = draft.triggers.contains(.copy)
        let paste = draft.triggers.contains(.paste)
        if copy && paste { return L("settings.rules.editor.app.captionBoth") }
        return paste ? L("settings.rules.editor.app.captionPaste") : L("settings.rules.editor.app.captionCopy")
    }

    /// No category selected means "every category", so both condition families
    /// are reachable; picking categories narrows the column to what can apply.
    private var showsContentMatch: Bool {
        draft.matchCategories.isEmpty || draft.matchCategories.contains(.text)
    }

    private var showsFileConditions: Bool {
        draft.matchCategories.isEmpty || draft.matchCategories.contains { $0.isFileBased }
    }

    private var contentPlaceholder: String {
        draft.contentMatch.mode == .regex
            ? L("settings.rules.editor.match.regexPlaceholder")
            : L("settings.rules.editor.match.textPlaceholder")
    }

    private var fileNamePlaceholder: String {
        draft.fileNameMatch.mode == .regex
            ? L("settings.rules.editor.match.regexPlaceholder")
            : L("settings.rules.editor.match.filePlaceholder")
    }

    private var categoryChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(RuleMatchCategory.allCases) { category in
                let on = draft.matchCategories.contains(category)
                Button {
                    toggleCategory(category)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: category.icon).font(.system(size: 9, weight: .semibold))
                        Text(category.displayName).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.appAccent.opacity(0.18) : Color.appChipFill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.appAccent : Color.appCardBorder, lineWidth: 0.5))
                    .foregroundStyle(on ? Color.appAccent : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Turning on a media category prefills the extensions it usually means —
    /// the common case works with no typing, and the list stays editable because
    /// what filters is exactly what's on screen.
    private func toggleCategory(_ category: RuleMatchCategory) {
        if draft.matchCategories.contains(category) {
            draft.matchCategories.remove(category)
        } else {
            draft.matchCategories.insert(category)
            if let suggested = category.suggestedExtensions {
                let existing = Self.parseExtensions(extensionsText)
                let merged = existing + suggested.filter { !existing.contains($0) }
                extensionsText = merged.joined(separator: ", ")
            }
        }
        syncTestCategory()
    }

    // MARK: action

    private func actionColumn(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field(L("settings.rules.editor.action")) {
                HStack(spacing: 8) {
                    PaperMenuPicker(
                        options: RuleActionKind.allCases.map { PaperMenuOption($0, $0.displayName, icon: $0.icon) },
                        selection: $kind,
                        width: 180
                    )
                    if kind.isScript {
                        Spacer(minLength: 0)
                        Text(L("settings.rules.editor.timeout"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("3", text: $timeoutText)
                            .paperTextField()
                            .frame(width: 54)
                    }
                }
            }

            actionDetail(isWide: isWide)
            Spacer(minLength: 0)
            testPanel
        }
        .frame(maxWidth: .infinity, maxHeight: isWide ? .infinity : nil, alignment: .topLeading)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: kind)
    }

    @ViewBuilder private func actionDetail(isWide: Bool) -> some View {
        switch kind {
        case .drop:
            Text(L("settings.rules.action.drop.desc"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .replaceRegex:
            VStack(alignment: .leading, spacing: 6) {
                TextField(L("settings.rules.editor.find"), text: $regexPattern).paperTextField()
                TextField(L("settings.rules.editor.replace"), text: $regexReplacement).paperTextField()
            }
        case .shell:
            codeArea(
                hint: L("settings.rules.editor.shellHint"),
                language: .shell,
                text: $shellSource,
                isWide: isWide,
                accessory: AnyView(importScriptButton)
            )
        case .javascript:
            codeArea(
                hint: L("settings.rules.editor.jsHint"),
                language: .javascript,
                text: $jsSource,
                isWide: isWide,
                accessory: nil
            )
        }
    }

    private func codeArea(hint: String, language: CodeLanguage, text: Binding<String>, isWide: Bool, accessory: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(hint)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accessory {
                    Spacer(minLength: 0)
                    accessory
                }
            }
            CodeEditor(text: text, language: language)
                .frame(minHeight: 150, maxHeight: isWide ? .infinity : 200)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.appChipFill))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
        }
        .frame(maxHeight: isWide ? .infinity : nil)
    }

    /// Pulls an existing `.sh` from the managed folder into the editor. Rules
    /// carry their own source now, so this copies the text in rather than
    /// referencing the file.
    private var importScriptButton: some View {
        let scripts = ScriptRuleEngine.availableScripts()
        return PaperMenuPicker(
            options: scripts.map { PaperMenuOption($0, $0) }
                + [PaperMenuOption("  folder  ", L("settings.rules.folder.open"), icon: "folder")],
            selection: Binding(get: { "" }, set: { importScript(named: $0) }),
            width: 150,
            displayTitle: L("settings.rules.editor.importScript")
        )
    }

    private func importScript(named name: String) {
        guard name != "  folder  " else {
            NSWorkspace.shared.activateFileViewerSelecting([ScriptRuleEngine.ensureScriptsDirectory()])
            return
        }
        let url = ScriptRuleEngine.ensureScriptsDirectory().appendingPathComponent(name)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        shellSource = source
    }

    // MARK: test run

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("settings.rules.editor.test.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // In a clipboard manager the most realistic sample is the thing
                // the user just copied — one click beats retyping it.
                Button {
                    fillSampleFromClipboard()
                } label: {
                    Label(L("settings.rules.editor.test.useClipboard"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .help(L("settings.rules.editor.test.useClipboardHelp"))
                Button {
                    runTest()
                } label: {
                    Label(
                        isTesting ? L("settings.rules.editor.test.running") : L("settings.rules.editor.test.run"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut("r", modifiers: .command)
                .help(L("settings.rules.editor.test.runHint"))
                .disabled(isTesting || !canTest)
            }

            // Only the kinds this rule targets: testing a text rule as a video
            // clip would answer a question nobody asked.
            if testableCategories.count > 1 {
                HStack(spacing: 5) {
                    ForEach(testableCategories) { category in
                        let on = testCategory == category
                        Button {
                            selectTestCategory(category)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: category.icon).font(.system(size: 8, weight: .semibold))
                                Text(category.displayName).font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.appAccent.opacity(0.18) : Color.appChipFill))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.appAccent : Color.appCardBorder, lineWidth: 0.5))
                            .foregroundStyle(on ? Color.appAccent : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            TextField(samplePlaceholder, text: $sampleText, axis: .vertical)
                .lineLimit(1...3)
                .paperTextField()

            testOutput
        }
        .animation(.easeOut(duration: 0.14), value: testCategory)
    }

    private var testOutput: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if let result = testResult {
                    Label(
                        result.conditionsHit
                            ? L("settings.rules.editor.test.conditionsHit")
                            : L("settings.rules.editor.test.conditionsMiss"),
                        systemImage: result.conditionsHit ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(result.conditionsHit ? Color.appAccent : .secondary)

                    if let error = result.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.appDanger)
                            .textSelection(.enabled)
                    } else if result.effects.isEmpty {
                        Label(L("settings.rules.editor.test.noEffect"), systemImage: "minus.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(result.effects.enumerated()), id: \.offset) { pair in
                            effectRow(pair.element)
                        }
                    }
                    ForEach(Array(result.logs.enumerated()), id: \.offset) { pair in
                        Text("› " + pair.element)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(L("settings.rules.editor.test.hint"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 96)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.appChipFill))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
    }

    @ViewBuilder private func effectRow(_ effect: ScriptEffect) -> some View {
        switch effect {
        case .replaceText(let text):
            effectDetail(L("settings.rules.editor.test.effect.replace"), text)
        case .newClip(let text):
            effectDetail(L("settings.rules.editor.test.effect.newClip"), text)
        case .setTags(let tags):
            effectDetail(L("settings.rules.editor.test.effect.tags"), tags.joined(separator: ", "))
        case .rename(let title):
            effectDetail(L("settings.rules.editor.test.effect.rename"), title)
        case .copyToPasteboard(let text):
            effectDetail(L("settings.rules.editor.test.effect.copy"), text)
        case .drop:
            Label(L("settings.rules.editor.test.effect.drop"), systemImage: "trash")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.appDanger)
        case .none:
            EmptyView()
        }
    }

    private func effectDetail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.appAccent)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appMetal)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Categories the rule targets — or all of them when it targets everything.
    private var testableCategories: [RuleMatchCategory] {
        let selected = RuleMatchCategory.allCases.filter { draft.matchCategories.contains($0) }
        return selected.isEmpty ? RuleMatchCategory.allCases : selected
    }

    /// Keep the test type inside the rule's own scope as the categories change.
    private func syncTestCategory() {
        guard !testableCategories.contains(testCategory) else { return }
        selectTestCategory(testableCategories.first ?? .text)
    }

    private func selectTestCategory(_ category: RuleMatchCategory) {
        testCategory = category
        sampleText = Self.defaultSample(for: category, extensions: Self.parseExtensions(extensionsText))
        testResult = nil
    }

    private var samplePlaceholder: String {
        testCategory == .text
            ? L("settings.rules.editor.test.samplePlaceholder")
            : L("settings.rules.editor.test.samplePathPlaceholder")
    }

    /// A sample that looks like the kind of clip being simulated: text for text,
    /// a plausible path (with the rule's own extension) for everything else.
    private static func defaultSample(for category: RuleMatchCategory, extensions: [String]) -> String {
        guard category != .text else { return L("settings.rules.editor.test.sampleDefault") }
        let fallback: String
        switch category {
        case .image: fallback = "png"
        case .video: fallback = "mp4"
        case .audio: fallback = "mp3"
        default: fallback = "pdf"
        }
        let ext = extensions.first ?? fallback
        return L("settings.rules.editor.test.samplePathFormat", ext)
    }

    /// Accepts "mp3, m4a", "mp3 m4a", ".MP3、m4a" — anything a person might type.
    private static func parseExtensions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",，、; \n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Pull whatever is on the pasteboard into the sample field. Reading it is
    /// free (no `markInternalWrite` needed — nothing is written).
    private func fillSampleFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            ToastCenter.shared.show(
                L("settings.rules.editor.test.clipboardEmpty"),
                systemImage: "exclamationmark.circle",
                tint: .orange
            )
            return
        }
        sampleText = text
        testResult = nil
    }

    /// Clip type the chosen test category stands in for.
    private var sampleClipType: ClipboardItemType {
        switch testCategory {
        case .text: return .text
        case .image: return .image
        case .video: return .video
        case .audio, .file: return .file
        }
    }

    /// Run the draft — as composed right now, unsaved — against the sample,
    /// reporting both whether the conditions would fire and what the action
    /// produces. Effects are shown rather than applied.
    @MainActor private func runTest() {
        let action = composedAction()
        let type = sampleClipType
        let rule = composedRule()
        let appId = rule.apps.first?.bundleId ?? ""
        let input = ScriptClipInput(
            text: sampleText,
            type: type.rawValue,
            sourceApp: rule.apps.first?.name ?? L("rule.sourceApp"),
            bundleId: appId,
            tags: [],
            imageData: nil
        )
        // The app condition can't be judged from a sample, so feed one of the
        // rule's own apps back in and let the remaining conditions decide.
        let trigger: RuleTrigger = rule.triggers.contains(.copy) ? .copy : .paste
        let hit = rule.matches(trigger: trigger, type: type, content: sampleText, appBundleId: appId)
        let timeout = parsedTimeout ?? ScriptRuleEngine.defaultTimeout
        let caps = draft.grantedCapabilities
        isTesting = true
        testResult = nil
        Task {
            let box = ScriptLogBox()
            var result = RuleTestResult(conditionsHit: hit)
            do {
                result.effects = try await Task.detached(priority: .userInitiated) {
                    try ScriptRuleEngine.runAction(action, input: input, timeout: timeout, capabilities: caps, log: box)
                }.value
            } catch {
                result.error = String(describing: error)
            }
            result.logs = box.lines
            withAnimation(.easeOut(duration: 0.15)) {
                testResult = result
                isTesting = false
            }
        }
    }

    // MARK: composition

    private func composedAction() -> RuleAction {
        switch kind {
        case .drop:
            return .drop
        case .replaceRegex:
            return .replaceRegex(pattern: regexPattern, replacement: regexReplacement)
        case .shell:
            return .shell(source: shellSource)
        case .javascript:
            return .javascript(source: jsSource)
        }
    }

    private func composedRule() -> ScriptingRule {
        var rule = draft
        rule.timeoutSeconds = kind.isScript ? parsedTimeout : nil
        rule.fileExtensions = Self.parseExtensions(extensionsText)
        rule.action = composedAction()
        return rule
    }

    /// Clamped so a typo can't park a rule on a 10-minute timeout.
    private var parsedTimeout: Double? {
        guard let value = Double(timeoutText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return min(value, 30)
    }

    private var hasScriptSource: Bool {
        let source = kind == .shell ? shellSource : jsSource
        return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTest: Bool {
        switch kind {
        case .drop, .replaceRegex: return true
        case .shell, .javascript: return hasScriptSource
        }
    }

    private var canSave: Bool {
        guard draft.isRegexValid, !draft.triggers.isEmpty else { return false }
        switch kind {
        case .drop: return true
        case .replaceRegex: return !regexPattern.isEmpty
        case .shell, .javascript: return hasScriptSource
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        // Changing a rule's action to a script invalidates a prior consent, so a
        // freshly edited script rule re-arms via the toggle (stays as-is here).
        onSave(composedRule())
    }
}

// MARK: - Code editor (syntax highlight + auto-indent)

/// The two languages a rule can be written in. Shell rules carry their source
/// inline just like JS ones, so both get the same editor.
enum CodeLanguage {
    case javascript
    case shell
}

/// Lightweight code editor: a monospaced `NSTextView` with regex-based syntax
/// highlighting (warm/earth palette to match the app, not cool IDE blues), a
/// line-number gutter, newline/tab auto-indentation and bracket auto-closing —
/// the "new userscript" feel that SwiftUI's `TextEditor` can't provide.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage = .javascript

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
        CodeHighlighter.apply(to: tv.textStorage, font: Self.font, language: language)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        CodeHighlighter.apply(to: tv.textStorage, font: Self.font, language: language)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeEditor
        weak var textView: NSTextView?
        init(_ parent: CodeEditor) { self.parent = parent }

        /// Openers that get a partner inserted after the caret.
        private static let pairs: [String: String] = [
            "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
        ]

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            CodeHighlighter.apply(to: tv.textStorage, font: CodeEditor.font, language: parent.language)
        }

        /// Bracket/quote handling. Only single-character insertions at a caret
        /// (never a selection) are touched, so paste and multi-char replacements
        /// stay untouched — and the two-character insert this makes can't recur.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let typed = replacementString, typed.count == 1, range.length == 0 else { return true }
            let ns = textView.string as NSString
            let next = range.location < ns.length
                ? ns.substring(with: NSRange(location: range.location, length: 1))
                : ""

            // Typing the closer that is already sitting there just steps over it.
            if next == typed, [")", "]", "}", "\"", "'", "`"].contains(typed) {
                textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }
            guard let closer = Self.pairs[typed] else { return true }
            // Don't auto-close when the caret is glued to a word — `foo(` inside
            // `foobar` would otherwise inject a stray `)`.
            if !next.isEmpty, next.rangeOfCharacter(from: .alphanumerics) != nil { return true }
            textView.insertText(typed + closer, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return false
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
                let opensBlock = prefix.trimmingCharacters(in: .whitespaces).hasSuffix("{")
                let extra = opensBlock ? "    " : ""
                let next = sel.location < ns.length
                    ? ns.substring(with: NSRange(location: sel.location, length: 1))
                    : ""
                if opensBlock, next == "}" {
                    // Split an auto-closed pair open: caret lands on the indented
                    // blank line, the brace drops to its own line below.
                    textView.insertText("\n" + indent + extra + "\n" + indent, replacementRange: sel)
                    textView.setSelectedRange(NSRange(location: sel.location + 1 + indent.count + extra.count, length: 0))
                } else {
                    textView.insertText("\n" + indent + extra, replacementRange: sel)
                }
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

/// Regex syntax highlighter for the code editor. Re-colours the whole document
/// on each edit — cheap for short rule scripts. Colours are dynamic so they read
/// on both the light (paper) and dark backgrounds.
enum CodeHighlighter {
    private static let jsKeywords = [
        "function","var","let","const","return","if","else","for","while","do","switch",
        "case","default","break","continue","new","typeof","instanceof","this","null",
        "undefined","true","false","in","of","try","catch","finally","throw","class",
        "extends","super","yield","async","await","delete","void","with","debugger",
    ]
    private static let shellKeywords = [
        "if","then","elif","else","fi","for","while","until","do","done","case","esac",
        "in","function","return","exit","local","export","readonly","shift","set","unset",
        "echo","printf","read","cd","trap","source","eval","test",
    ]

    private static func words(_ list: [String]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "\\b(" + list.joined(separator: "|") + ")\\b")
    }

    private static let jsKeywordRegex = words(jsKeywords)
    private static let shellKeywordRegex = words(shellKeywords)
    private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRegex = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`")
    private static let jsCommentRegex = try! NSRegularExpression(pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/")
    private static let shellCommentRegex = try! NSRegularExpression(pattern: "#[^\\n]*")
    /// `$VAR`, `${VAR}`, `$1` — the thing you most want to spot in a shell script.
    private static let shellVariableRegex = try! NSRegularExpression(pattern: "\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|\\$[0-9@#?*]")

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    private static let keywordColor = dyn(NSColor(srgbRed: 0.64, green: 0.30, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.86, green: 0.57, blue: 0.43, alpha: 1))
    private static let stringColor  = dyn(NSColor(srgbRed: 0.36, green: 0.44, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.67, green: 0.76, blue: 0.52, alpha: 1))
    private static let numberColor  = dyn(NSColor(srgbRed: 0.60, green: 0.42, blue: 0.13, alpha: 1), NSColor(srgbRed: 0.85, green: 0.67, blue: 0.37, alpha: 1))
    private static let commentColor = dyn(NSColor(srgbRed: 0.58, green: 0.53, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.55, green: 0.51, blue: 0.45, alpha: 1))

    static func apply(to storage: NSTextStorage?, font: NSFont, language: CodeLanguage) {
        guard let storage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
        switch language {
        case .javascript:
            paint(jsKeywordRegex, keywordColor, text, full, storage)
            paint(numberRegex, numberColor, text, full, storage)
            // Strings and comments run last so they win over keyword/number
            // colouring that falls inside them.
            paint(stringRegex, stringColor, text, full, storage)
            paint(jsCommentRegex, commentColor, text, full, storage)
        case .shell:
            paint(shellKeywordRegex, keywordColor, text, full, storage)
            paint(shellVariableRegex, numberColor, text, full, storage)
            paint(stringRegex, stringColor, text, full, storage)
            paint(shellCommentRegex, commentColor, text, full, storage)
        }
        storage.endEditing()
    }

    private static func paint(_ re: NSRegularExpression, _ color: NSColor, _ text: String, _ range: NSRange, _ storage: NSTextStorage) {
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let r = match?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
        }
    }
}
