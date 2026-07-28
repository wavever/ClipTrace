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

    private static let key = "filterSettings.v1"
    private var loading = false
    /// Blob we ourselves last wrote, so an external write can be told apart
    /// from the echo of our own `save()`.
    private var lastWrittenData: Data?
    private var externalChangeObserver: NSObjectProtocol?

    private init() {
        load()
        // The MCP server writes rules from a *separate process*. Without this
        // the Settings list would keep showing a stale array until relaunch.
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChangedExternally() }
        }
    }

    deinit {
        if let externalChangeObserver { NotificationCenter.default.removeObserver(externalChangeObserver) }
    }

    /// Cheap on the hot path: the notification fires for every defaults write in
    /// the app, so compare blobs and only re-decode when someone else moved.
    private func reloadIfChangedExternally() {
        let current = UserDefaults.standard.data(forKey: Self.key)
        guard current != lastWrittenData else { return }
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
        let data = UserDefaults.standard.data(forKey: Self.key)
        lastWrittenData = data
        guard let data, let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
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
            lastWrittenData = data
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: - Cross-process access
    //
    // The MCP server runs as a separate process (`--mcp`), so it can neither
    // read the GUI's live array nor safely write through a stale copy of it.
    // These helpers go straight to the persisted blob: read, mutate, write back.

    static func rulesFromDefaults() -> [ScriptingRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
            return []
        }
        return state.scriptingRules ?? []
    }

    /// Append `rule` to the stored rule list, preserving every other setting in
    /// the blob. Returns false only when the write itself fails.
    @discardableResult
    static func appendRuleToDefaults(_ rule: ScriptingRule) -> Bool {
        let defaults = UserDefaults.standard
        var state = StoredState()
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            state = decoded
        }
        var rules = state.scriptingRules ?? []
        rules.append(rule)
        state.scriptingRules = rules
        guard let encoded = try? JSONEncoder().encode(state) else { return false }
        defaults.set(encoded, forKey: key)
        return true
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
/// `ContentProtectionSettings.current()`, so a change here is visible to
/// display and egress code on its next read. Protection and the seeded
/// built-in rules default to **enabled**; raw-egress opt-ins default to **off**.
@MainActor
final class ContentProtectionStore: ObservableObject {
    static let shared = ContentProtectionStore()

    @Published var isEnabled: Bool {
        didSet { persist(ContentProtectionSettings.Keys.enabled, isEnabled); bumpVersion() }
    }
    /// Opt-in: include raw (un-redacted) protected content in bulk export.
    @Published var allowRawExport: Bool {
        didSet { persist(ContentProtectionSettings.Keys.allowRawExport, allowRawExport) }
    }
    /// Opt-in: return raw protected content through MCP text responses.
    @Published var allowRawMCP: Bool {
        didSet { persist(ContentProtectionSettings.Keys.allowRawMCP, allowRawMCP) }
    }
    /// The unified detection-rule list: editable built-ins + user rules.
    @Published var rules: [ProtectionRule] {
        didSet { persistRules(); bumpVersion() }
    }

    /// Monotonic counter bumped whenever a *display-affecting* setting (master
    /// toggle or a rule) changes. Persistent display surfaces feed this into
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
        allowRawExport = snapshot.allowRawExport
        allowRawMCP = snapshot.allowRawMCP
        rules = snapshot.rules
        // Finalize the legacy → unified-rules migration: `current()` derives
        // the list from the pre-0.9.14 keys until the new key exists, so
        // persist the derived list once here.
        if UserDefaults.standard.data(forKey: ContentProtectionSettings.Keys.rules) == nil {
            persistRules()
        }
    }

    /// Live snapshot for callers that prefer the value type over the store.
    var snapshot: ContentProtectionSettings {
        ContentProtectionSettings(
            isEnabled: isEnabled,
            allowRawExport: allowRawExport,
            allowRawMCP: allowRawMCP,
            rules: rules
        )
    }

    private func persist(_ key: String, _ value: Bool) {
        guard !loading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func persistRules() {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: ContentProtectionSettings.Keys.rules)
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
///
/// Both script backends carry their source inline. Shell used to reference a
/// file in the managed scripts folder, but a rule that ships its own code is
/// self-contained, editable in place, and travels with an export — the folder
/// survives as an import source, not as a dependency.
enum RuleAction: Codable, Hashable {
    case drop
    case replaceRegex(pattern: String, replacement: String)
    case shell(source: String)
    case javascript(source: String)

    /// True for actions that run user-authored code and therefore require the
    /// authorization gate before a rule carrying them can be armed.
    var isScript: Bool {
        switch self {
        case .drop, .replaceRegex: return false
        case .shell, .javascript: return true
        }
    }

    // Hand-written Codable: it keeps the shape the synthesized one produced
    // (`{"shell": {…}}`) while accepting the legacy `scriptName` payload, whose
    // file is pulled inline so rules written before the switch keep running.
    private enum CodingKeys: String, CodingKey { case drop, replaceRegex, shell, javascript }
    private enum RegexKeys: String, CodingKey { case pattern, replacement }
    private enum SourceKeys: String, CodingKey { case source, scriptName }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.replaceRegex) {
            let nested = try container.nestedContainer(keyedBy: RegexKeys.self, forKey: .replaceRegex)
            self = .replaceRegex(
                pattern: try nested.decodeIfPresent(String.self, forKey: .pattern) ?? "",
                replacement: try nested.decodeIfPresent(String.self, forKey: .replacement) ?? ""
            )
        } else if container.contains(.shell) {
            let nested = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .shell)
            if let source = try nested.decodeIfPresent(String.self, forKey: .source) {
                self = .shell(source: source)
            } else if let name = try nested.decodeIfPresent(String.self, forKey: .scriptName), !name.isEmpty {
                let url = ScriptRuleEngine.scriptsDirectory.appendingPathComponent(name)
                self = .shell(source: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            } else {
                self = .shell(source: "")
            }
        } else if container.contains(.javascript) {
            let nested = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .javascript)
            self = .javascript(source: try nested.decodeIfPresent(String.self, forKey: .source) ?? "")
        } else {
            self = .drop
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .drop:
            try container.encode(true, forKey: .drop)
        case .replaceRegex(let pattern, let replacement):
            var nested = container.nestedContainer(keyedBy: RegexKeys.self, forKey: .replaceRegex)
            try nested.encode(pattern, forKey: .pattern)
            try nested.encode(replacement, forKey: .replacement)
        case .shell(let source):
            var nested = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .shell)
            try nested.encode(source, forKey: .source)
        case .javascript(let source):
            var nested = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .javascript)
            try nested.encode(source, forKey: .source)
        }
    }
}

/// How a rule compares one string — the clip's text, or a file's name. Replaces
/// the old bare regex field: most conditions people actually write are "contains
/// this word", and forcing those through a regex was the main reason the match
/// section read as a developer-only corner.
struct RuleTextMatch: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case any, contains, notContains, regex
        var id: String { rawValue }
        var displayName: String { L("settings.rules.match.mode.\(rawValue)") }
        /// `any` needs no operand, so the editor hides the value field for it.
        var needsValue: Bool { self != .any }
    }

    var mode: Mode = .any
    var value: String = ""

    /// A mode with no operand yet is inert rather than "matches nothing" — a
    /// half-typed condition shouldn't silently stop a rule from running.
    var isActive: Bool { mode != .any && !value.isEmpty }

    var isValid: Bool {
        guard mode == .regex, !value.isEmpty else { return true }
        return ScriptingRule.compiledRegex(value) != nil
    }

    func matches(_ string: String) -> Bool {
        guard isActive else { return true }
        switch mode {
        case .any:
            return true
        case .contains:
            return string.range(of: value, options: [.caseInsensitive]) != nil
        case .notContains:
            return string.range(of: value, options: [.caseInsensitive]) == nil
        case .regex:
            guard let re = ScriptingRule.compiledRegex(value) else { return false }
            return re.firstMatch(in: string, options: [], range: NSRange(string.startIndex..., in: string)) != nil
        }
    }

    /// File clips carry several paths at once. A positive condition holds when
    /// any name matches; a negative one only when none does.
    func matches(anyOf strings: [String]) -> Bool {
        guard isActive else { return true }
        if mode == .notContains { return strings.allSatisfy { matches($0) } }
        return strings.contains { matches($0) }
    }
}

/// When a rule runs. The two moments are genuinely different: a copy-time rule
/// rewrites what gets *stored*, while a paste-time rule rewrites only what
/// leaves for another app and never touches history. A rule can do both, but
/// never neither — a rule with no trigger could never run.
enum RuleTrigger: String, Codable, CaseIterable, Identifiable {
    case copy, paste

    var id: String { rawValue }
    var displayName: String { L("settings.rules.trigger.\(rawValue)") }
    var icon: String { self == .copy ? "doc.on.doc" : "arrow.down.doc" }
}

/// User-facing content category a rule targets. Deliberately coarser than
/// `ClipboardItemType`: links and rich text are text as far as a rule is
/// concerned, and audio has no clip type of its own — it arrives as a file, so
/// the category recognizes it by extension.
enum RuleMatchCategory: String, Codable, CaseIterable, Identifiable {
    case text, image, video, audio, file

    var id: String { rawValue }
    var displayName: String { L("settings.rules.category.\(rawValue)") }
    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "music.note"
        case .file: return "folder"
        }
    }

    /// Categories matched on the clip's file name instead of its text.
    var isFileBased: Bool { self != .text }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "flv", "wmv", "mpg", "mpeg"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus", "wma"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    /// Extensions the editor prefills when this category is switched on. Nil for
    /// categories where an extension list would only get in the way.
    var suggestedExtensions: [String]? {
        switch self {
        case .video: return ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        case .audio: return ["mp3", "m4a", "wav", "aac", "flac", "aiff"]
        case .image: return ["png", "jpg", "jpeg", "gif", "heic", "webp"]
        case .text, .file: return nil
        }
    }

    func covers(type: ClipboardItemType, fileNames: [String]) -> Bool {
        switch self {
        case .text: return type == .text || type == .url || type == .rtf
        case .image: return type == .image
        case .video:
            if type == .video { return true }
            return type == .file && fileNames.contains { Self.videoExtensions.contains(Self.ext($0)) }
        case .audio:
            // Audio files land in `.file` (the monitor only special-cases video
            // and image extensions), so the extension is the only signal.
            return type == .file && fileNames.contains { Self.audioExtensions.contains(Self.ext($0)) }
        case .file: return type == .file
        }
    }

    private static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
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
    // Four axes — when it fires, which apps are involved, what kind of content,
    // and the string conditions — ANDed together. Every axis except the trigger
    // is optional: unset means "any", so a rule with nothing set matches every
    // non-sensitive clip.

    /// Moments this rule fires at. Never empty — the editor keeps at least one
    /// on, and decoding falls back to `.copy`.
    var triggers: Set<RuleTrigger> = [.copy]
    /// Apps the rule is scoped to: the source app at copy time, the target app
    /// at paste time. Empty = any app.
    var apps: [AppFilterEntry] = []
    /// Content categories this rule applies to. Empty = every category.
    var matchCategories: Set<RuleMatchCategory> = []
    /// Condition on the clip's text — used for text/link/rich-text clips.
    var contentMatch = RuleTextMatch()
    /// Condition on the clip's file name(s) — used for image/video/audio/file clips.
    var fileNameMatch = RuleTextMatch()
    /// File extensions (lowercase, no dot) a file-ish clip must carry. Empty =
    /// any extension. Prefilled by the editor when a media category is picked,
    /// then freely editable — the filter is whatever the user can see.
    var fileExtensions: [String] = []

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

    init(name: String = "") {
        self.name = name
    }

    // Hand-written decoding so rules stored under the old shape survive: types
    // fold into categories, the bare content regex becomes a regex condition,
    // and the length bounds — dropped from the model — are read once and folded
    // into an equivalent regex rather than silently changing what a rule matches.
    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, triggers, apps
        case matchCategories, contentMatch, fileNameMatch, fileExtensions
        case action, timeoutSeconds, grantedCapabilities
        // legacy
        case sourceBundleId, sourceAppName, matchTypes, contentRegex, minLength, maxLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // Rules written before triggers existed all ran at capture time.
        let storedTriggers = try c.decodeIfPresent(Set<RuleTrigger>.self, forKey: .triggers) ?? []
        triggers = storedTriggers.isEmpty ? [.copy] : storedTriggers
        if let apps = try c.decodeIfPresent([AppFilterEntry].self, forKey: .apps) {
            self.apps = apps
        } else if let bundleId = try c.decodeIfPresent(String.self, forKey: .sourceBundleId), !bundleId.isEmpty {
            let name = try c.decodeIfPresent(String.self, forKey: .sourceAppName) ?? ""
            apps = [AppFilterEntry(bundleId: bundleId, name: name.isEmpty ? bundleId : name)]
        }
        fileExtensions = try c.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action) ?? .drop
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        grantedCapabilities = try c.decodeIfPresent(Set<ScriptCapability>.self, forKey: .grantedCapabilities) ?? []
        fileNameMatch = try c.decodeIfPresent(RuleTextMatch.self, forKey: .fileNameMatch) ?? RuleTextMatch()

        if let categories = try c.decodeIfPresent(Set<RuleMatchCategory>.self, forKey: .matchCategories) {
            matchCategories = categories
        } else {
            let legacyTypes = try c.decodeIfPresent(Set<ClipboardItemType>.self, forKey: .matchTypes) ?? []
            matchCategories = Set(legacyTypes.map { type in
                switch type {
                case .text, .url, .rtf: return RuleMatchCategory.text
                case .image: return .image
                case .video: return .video
                case .file: return .file
                }
            })
        }

        if let match = try c.decodeIfPresent(RuleTextMatch.self, forKey: .contentMatch) {
            contentMatch = match
        } else {
            let regex = try c.decodeIfPresent(String.self, forKey: .contentRegex) ?? ""
            let lo = try c.decodeIfPresent(Int.self, forKey: .minLength)
            let hi = try c.decodeIfPresent(Int.self, forKey: .maxLength)
            if !regex.isEmpty {
                contentMatch = RuleTextMatch(mode: .regex, value: regex)
            } else if lo != nil || hi != nil {
                contentMatch = RuleTextMatch(mode: .regex, value: "^[\\s\\S]{\(lo ?? 0),\(hi.map(String.init) ?? "")}$")
            }
        }
    }

    // Written out because `CodingKeys` carries legacy cases with no matching
    // property, which blocks synthesis. Only the current shape is ever written.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(apps, forKey: .apps)
        try c.encode(matchCategories, forKey: .matchCategories)
        try c.encode(contentMatch, forKey: .contentMatch)
        try c.encode(fileNameMatch, forKey: .fileNameMatch)
        try c.encode(fileExtensions, forKey: .fileExtensions)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encode(grantedCapabilities, forKey: .grantedCapabilities)
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

    /// True when both string conditions compile. The editor surfaces the inverse
    /// to flag a bad pattern; an invalid pattern makes the rule match nothing
    /// rather than crash.
    var isRegexValid: Bool {
        contentMatch.isValid && fileNameMatch.isValid
    }

    /// File-ish clips store their paths as newline-joined text, so the names a
    /// file condition compares against come straight out of the content.
    static func fileNames(in content: String) -> [String] {
        content.split(separator: "\n").map { (String($0) as NSString).lastPathComponent }
    }

    /// Evaluate the match conditions for one moment in a clip's life. ANDs every
    /// specified condition; unset conditions are skipped. Cheap conditions
    /// (trigger, app, category) come before the string work so non-matching
    /// clips short-circuit early, and an invalid regex is inert (returns false)
    /// rather than fatal.
    ///
    /// `appBundleId` is the source app at copy time and the target app at paste
    /// time; an empty string means "unknown", which an app-scoped rule treats as
    /// a miss rather than a free pass.
    func matches(
        trigger: RuleTrigger,
        type: ClipboardItemType,
        content: String,
        appBundleId: String
    ) -> Bool {
        guard triggers.contains(trigger) else { return false }
        if !apps.isEmpty, !apps.contains(where: { $0.bundleId == appBundleId }) { return false }

        let isTextual = type == .text || type == .url || type == .rtf
        let names = isTextual ? [] : Self.fileNames(in: content)

        if !matchCategories.isEmpty,
           !matchCategories.contains(where: { $0.covers(type: type, fileNames: names) }) {
            return false
        }

        if !isTextual, !fileExtensions.isEmpty {
            let wanted = Set(fileExtensions)
            guard names.contains(where: { wanted.contains(($0 as NSString).pathExtension.lowercased()) }) else {
                return false
            }
        }

        // The clip's own kind picks the condition: text conditions never see a
        // file path, and file-name conditions never see a wall of text.
        return isTextual ? contentMatch.matches(content) : fileNameMatch.matches(anyOf: names)
    }
}
