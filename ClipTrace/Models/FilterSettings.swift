import Foundation
import SwiftUI

struct AppFilterEntry: Codable, Identifiable, Hashable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
}

struct TextFilterRule: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case contains
        case excludes

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .contains: return L("settings.filter.textRules.contains")
            case .excludes: return L("settings.filter.textRules.excludes")
            }
        }
    }

    var id: UUID = UUID()
    var mode: Mode
    var text: String
}

@MainActor
final class FilterSettingsStore: ObservableObject {
    static let shared = FilterSettingsStore()

    @Published var excludedApps: [AppFilterEntry] = [] { didSet { save() } }
    @Published var excludedTypes: Set<ClipboardItemType> = [] { didSet { save() } }
    @Published var textFilters: [TextFilterRule] = [] { didSet { save() } }
    @Published var stripURLTracking: Bool = true { didSet { save() } }
    /// Per-type retention in days. 0 (or missing) means "keep forever".
    @Published var retentionByType: [String: Int] = [:] { didSet { save() } }
    /// When true, `deleteItem` soft-deletes into trash; otherwise it's a hard delete.
    @Published var trashEnabled: Bool = true { didSet { save() } }
    /// How long trashed items live before being purged. 0 means "keep forever".
    @Published var trashRetentionDays: Int = 7 { didSet { save() } }
    /// User-defined scripting/automation rules (match → action), evaluated on
    /// capture and runnable on demand. The legacy `excludedApps`/`excludedTypes`/
    /// `textFilters` above remain the always-on synchronous pre-insert exclusion
    /// tier (no migration, no behavior change); these rules layer richer actions
    /// (transform, shell, JS) on top and run asynchronously post-insert — except
    /// a code-free `.drop`, which may also exclude pre-insert. Ordered by array
    /// position.
    @Published var scriptingRules: [ScriptingRule] = [] { didSet { save() } }

    /// Insert a new rule or replace the existing one with the same id. Backs the
    /// rule editor's save path.
    func upsertScriptingRule(_ rule: ScriptingRule) {
        if let idx = scriptingRules.firstIndex(where: { $0.id == rule.id }) {
            scriptingRules[idx] = rule
        } else {
            scriptingRules.append(rule)
        }
    }

    private let key = "filterSettings.v1"
    private var loading = false

    private init() {
        load()
    }

    private struct StoredState: Codable {
        var excludedApps: [AppFilterEntry] = []
        var excludedTypes: [String] = []
        var textFilters: [TextFilterRule] = []
        var stripURLTracking: Bool? = true
        var retentionByType: [String: Int]? = nil
        var trashEnabled: Bool? = true
        var trashRetentionDays: Int? = 7
        // Optional so blobs written before scripting rules existed still decode.
        var scriptingRules: [ScriptingRule]? = nil
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
            return
        }
        excludedApps = state.excludedApps
        excludedTypes = Set(state.excludedTypes.compactMap { ClipboardItemType(rawValue: $0) })
        textFilters = state.textFilters
        stripURLTracking = state.stripURLTracking ?? true
        retentionByType = state.retentionByType ?? [:]
        trashEnabled = state.trashEnabled ?? true
        trashRetentionDays = state.trashRetentionDays ?? 7
        scriptingRules = state.scriptingRules ?? []
    }

    private func save() {
        guard !loading else { return }
        let state = StoredState(
            excludedApps: excludedApps,
            excludedTypes: excludedTypes.map { $0.rawValue }.sorted(),
            textFilters: textFilters,
            stripURLTracking: stripURLTracking,
            retentionByType: retentionByType.isEmpty ? nil : retentionByType,
            trashEnabled: trashEnabled,
            trashRetentionDays: trashRetentionDays,
            scriptingRules: scriptingRules.isEmpty ? nil : scriptingRules
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Retention window in days for `type`. `0` means "keep forever".
    func retentionDays(for type: ClipboardItemType) -> Int {
        retentionByType[type.rawValue] ?? 0
    }

    func setRetentionDays(_ days: Int, for type: ClipboardItemType) {
        if days <= 0 {
            retentionByType.removeValue(forKey: type.rawValue)
        } else {
            retentionByType[type.rawValue] = days
        }
    }

    func shouldExclude(type: ClipboardItemType, content: String, sourceBundleId: String) -> Bool {
        if !sourceBundleId.isEmpty,
           excludedApps.contains(where: { $0.bundleId == sourceBundleId }) {
            return true
        }
        if excludedTypes.contains(type) {
            return true
        }
        for rule in textFilters where !rule.text.isEmpty {
            switch rule.mode {
            case .contains:
                if content.localizedCaseInsensitiveContains(rule.text) { return true }
            case .excludes:
                if !content.localizedCaseInsensitiveContains(rule.text) { return true }
            }
        }
        return false
    }
}

// MARK: - Content Protection settings

/// Persisted Content Protection preferences and the observable model the
/// settings UI binds to. The pure redactor (`ContentProtector`) never touches
/// this store — it reads the same `UserDefaults` keys via
/// `ContentProtectionSettings.current()`, so a toggle here is visible to display
/// and egress code on its next read. Built-in protection and every category
/// default to **enabled**; raw-egress opt-ins default to **off**.
@MainActor
final class ContentProtectionStore: ObservableObject {
    static let shared = ContentProtectionStore()

    @Published var isEnabled: Bool {
        didSet { persist(ContentProtectionSettings.Keys.enabled, isEnabled); bumpVersion() }
    }
    @Published var enabledCategories: Set<ContentProtectionCategory> {
        didSet { persistCategories(); bumpVersion() }
    }
    /// Opt-in: include raw (un-redacted) protected content in bulk export.
    @Published var allowRawExport: Bool {
        didSet { persist(ContentProtectionSettings.Keys.allowRawExport, allowRawExport) }
    }
    /// Opt-in: return raw protected content through MCP text responses.
    @Published var allowRawMCP: Bool {
        didSet { persist(ContentProtectionSettings.Keys.allowRawMCP, allowRawMCP) }
    }
    /// User-authored keyword/regex detectors, applied alongside the built-in
    /// categories while the `.custom` category is enabled.
    @Published var customRules: [CustomProtectionRule] {
        didSet { persistCustomRules(); bumpVersion() }
    }

    /// Monotonic counter bumped whenever a *display-affecting* setting (master
    /// toggle or a category) changes. Persistent display surfaces feed this into
    /// their row `Equatable` inputs so an already-rendered list re-computes its
    /// redaction immediately instead of waiting for the next incidental refresh.
    @Published private(set) var version = 0

    private var loading = false

    private func bumpVersion() {
        guard !loading else { return }
        version &+= 1
    }

    private init() {
        let snapshot = ContentProtectionSettings.current()
        isEnabled = snapshot.isEnabled
        enabledCategories = snapshot.categories
        allowRawExport = snapshot.allowRawExport
        allowRawMCP = snapshot.allowRawMCP
        customRules = snapshot.customRules
    }

    /// Live snapshot for callers that prefer the value type over the store.
    var snapshot: ContentProtectionSettings {
        ContentProtectionSettings(
            isEnabled: isEnabled,
            categories: enabledCategories,
            allowRawExport: allowRawExport,
            allowRawMCP: allowRawMCP,
            customRules: customRules
        )
    }

    func isCategoryEnabled(_ category: ContentProtectionCategory) -> Bool {
        enabledCategories.contains(category)
    }

    func setCategory(_ category: ContentProtectionCategory, enabled: Bool) {
        if enabled {
            enabledCategories.insert(category)
        } else {
            enabledCategories.remove(category)
        }
    }

    /// Two-way binding for a single category toggle in the settings UI.
    func categoryBinding(_ category: ContentProtectionCategory) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isCategoryEnabled(category) ?? false },
            set: { [weak self] in self?.setCategory(category, enabled: $0) }
        )
    }

    private func persist(_ key: String, _ value: Bool) {
        guard !loading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persistCategories() {
        guard !loading else { return }
        for category in ContentProtectionCategory.allCases {
            UserDefaults.standard.set(
                enabledCategories.contains(category),
                forKey: ContentProtectionSettings.Keys.category(category)
            )
        }
    }

    private func persistCustomRules() {
        guard !loading else { return }
        if customRules.isEmpty {
            UserDefaults.standard.removeObject(forKey: ContentProtectionSettings.Keys.customRules)
        } else if let data = try? JSONEncoder().encode(customRules) {
            UserDefaults.standard.set(data, forKey: ContentProtectionSettings.Keys.customRules)
        }
    }
}

// MARK: - Scripting rules

/// The atomic outcome a rule action can request. Both script backends (shell,
/// JS) and the code-free tiers converge on this set, so the engine applies any
/// result through one path that reuses existing `ClipboardViewModel` verbs. A
/// runner may return several effects at once (e.g. JS returning
/// `{text, tags, title}`); the engine applies them in array order and `.drop`
/// short-circuits the rest of the chain.
enum ScriptEffect: Equatable {
    case replaceText(String)
    case newClip(String)
    case setTags([String])
    case rename(String)
    case copyToPasteboard(String)
    case drop
    case none
}

/// Host capabilities a JavaScript rule may be granted. Default-deny: a rule with
/// an empty grant set is limited to pure computation over the injected `clip`
/// data — no network, no filesystem. v1 exposes none of these to scripts yet;
/// the set is persisted so the gating UI and runner can light them up later.
enum ScriptCapability: String, Codable, Hashable, CaseIterable {
    case network
    case filesystem
}

/// What a rule does when it matches. `drop` and `replaceRegex` are code-free and
/// may run synchronously before insert; `shell` and `javascript` execute
/// user-authored code and always defer to asynchronous post-insert execution
/// behind the enable-time authorization gate.
enum RuleAction: Codable, Hashable {
    case drop
    case replaceRegex(pattern: String, replacement: String)
    case shell(scriptName: String)
    case javascript(source: String)

    /// True for actions that run user-authored code and therefore require the
    /// authorization gate before a rule carrying them can be armed.
    var isScript: Bool {
        switch self {
        case .drop, .replaceRegex: return false
        case .shell, .javascript: return true
        }
    }
}

/// A capture/automation rule: a set of match conditions plus one action.
/// Generalizes the legacy `TextFilterRule` — its contains/excludes modes map to
/// a content-regex condition, and "exclude" becomes the `.drop` action. Rules
/// are ordered by their position in the store's array and individually
/// enableable; a disabled rule never runs, automatically or manually.
struct ScriptingRule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    /// Scripts stay inert until armed via the authorization gate; new rules
    /// therefore default to disabled.
    var isEnabled: Bool = false

    // MARK: Match conditions
    // All *specified* conditions must hold (logical AND); an unset condition
    // (empty set / empty string / nil) is ignored, so a rule with no conditions
    // matches every non-sensitive clip.

    /// Clip types this rule applies to. Empty = any type.
    var matchTypes: Set<ClipboardItemType> = []
    /// Regular expression the clip content must match. Empty = no regex gate.
    var contentRegex: String = ""
    /// Source application bundle id the clip must originate from. Empty = any.
    var sourceBundleId: String = ""
    /// Inclusive content-length bounds. nil = unbounded on that side.
    var minLength: Int? = nil
    var maxLength: Int? = nil

    // MARK: Action + execution config

    var action: RuleAction = .drop
    /// Per-run timeout override in seconds; nil uses the engine's global default.
    var timeoutSeconds: Double? = nil
    /// Host capabilities granted to a JS action (default-deny when empty).
    var grantedCapabilities: Set<ScriptCapability> = []

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("settings.rules.untitled") : trimmed
    }
}

extension ScriptingRule {
    /// Shared LRU of compiled patterns. Matching runs on every captured clip, so
    /// recompiling per evaluation would tax hot copy paths (URLs, tokens).
    /// NSCache is thread-safe and evicts under memory pressure. Mirrors
    /// `ClipboardItem.tagsCache`.
    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let c = NSCache<NSString, NSRegularExpression>()
        c.countLimit = 256
        return c
    }()

    /// Compile (and cache) `pattern`, or nil when it is empty or invalid.
    static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(re, forKey: key)
        return re
    }

    /// True when the regex is empty (no gate) or compiles cleanly. The editor
    /// surfaces the inverse to flag a bad pattern; an invalid pattern makes the
    /// rule match nothing rather than crash.
    var isRegexValid: Bool {
        contentRegex.isEmpty || Self.compiledRegex(contentRegex) != nil
    }

    /// Evaluate the match conditions against a captured clip. ANDs every
    /// specified condition; unset conditions are skipped. Cheap conditions
    /// (type, source, length) are checked before the regex so non-matching clips
    /// short-circuit before any pattern work, and an invalid regex is inert
    /// (returns false) rather than fatal.
    func matches(type: ClipboardItemType, content: String, sourceBundleId bundleId: String) -> Bool {
        if !matchTypes.isEmpty, !matchTypes.contains(type) { return false }
        if !sourceBundleId.isEmpty, sourceBundleId != bundleId { return false }
        let length = content.count
        if let lo = minLength, length < lo { return false }
        if let hi = maxLength, length > hi { return false }
        if !contentRegex.isEmpty {
            guard let re = Self.compiledRegex(contentRegex) else { return false }
            let range = NSRange(content.startIndex..., in: content)
            if re.firstMatch(in: content, options: [], range: range) == nil { return false }
        }
        return true
    }
}
