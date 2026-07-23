import Foundation

/// Content Protection: a pure, conservative detector + masker that redacts
/// sensitive spans (phone numbers, API keys / tokens / secrets) in text-like
/// clipboard content **for display and egress**, without ever mutating the
/// stored clip.
///
/// Detection is driven by one unified rule list: two seeded built-in rules
/// (CN mobile numbers, keys/tokens) that stay editable like any user rule,
/// plus user-authored keyword/regex rules.
///
/// This file is intentionally free of SwiftUI / SwiftData / Combine so it can be
/// unit-tested directly (see `scripts/ContentProtectionTests.swift`) and reused
/// from both the UI layer and the export / MCP egress paths. The
/// `ContentProtectionStore` (settings persistence + `ObservableObject`) lives in
/// `FilterSettings.swift`; this file only knows the pure value types.

// MARK: - Categories

/// Coarse tags carried by detections for export metadata
/// (`protectedCategories`) and the test harness. Built-in rules map to
/// `.phone` / `.key`; user-authored rules to `.custom`.
enum ContentProtectionCategory: String, Codable, CaseIterable, Hashable {
    case phone
    case key
    case custom
}

// MARK: - Rules

/// One entry in the unified detection-rule list. Kept Foundation-only (no
/// L(), no UI types) so this file still compiles standalone for the test
/// harness; display names for `Mode` and `BuiltinKind` live in the settings
/// UI layer.
struct ProtectionRule: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Case-insensitive literal substring match.
        case contains
        /// `NSRegularExpression`; invalid patterns are inert. When the pattern
        /// has capture groups only the group spans are masked (labels, quotes
        /// and separators survive); a group-less pattern masks the whole match.
        case regex

        var id: String { rawValue }
    }

    /// Identity of a seeded built-in rule. Built-ins stay editable like any
    /// other rule; the kind only pins the row's name/icon in the UI, the
    /// export category tag, and which default pattern "reset" restores.
    enum BuiltinKind: String, Codable, CaseIterable {
        case phone
        case key

        var icon: String {
            switch self {
            case .phone: return "phone.fill"
            case .key:   return "key.fill"
            }
        }
    }

    var id: UUID = UUID()
    var builtin: BuiltinKind? = nil
    var isEnabled: Bool = true
    var mode: Mode = .contains
    var pattern: String = ""

    init(
        id: UUID = UUID(),
        builtin: BuiltinKind? = nil,
        isEnabled: Bool = true,
        mode: Mode = .contains,
        pattern: String = ""
    ) {
        self.id = id
        self.builtin = builtin
        self.isEnabled = isEnabled
        self.mode = mode
        self.pattern = pattern
    }

    /// Tolerant decoding: pre-unification custom rules (≤0.9.13) persisted
    /// only `id`/`mode`/`pattern`, so the newer fields fall back to their
    /// defaults and the legacy blob decodes as plain enabled user rules.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        builtin = try c.decodeIfPresent(BuiltinKind.self, forKey: .builtin)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .contains
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
    }

    /// True when the rule can match at all: non-empty, and for regex mode the
    /// pattern must compile. The settings UI surfaces the inverse as a warning.
    var isValid: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch mode {
        case .contains: return true
        case .regex:    return (try? NSRegularExpression(pattern: trimmed)) != nil
        }
    }

    /// The category tag this rule's detections carry (export metadata).
    var category: ContentProtectionCategory {
        switch builtin {
        case .phone: return .phone
        case .key:   return .key
        case nil:    return .custom
        }
    }

    // MARK: Built-in defaults

    /// Optional `+86`/`86` prefix (non-capturing, preserved verbatim), then an
    /// `1[3-9]` mobile with space/dash tolerance as group 1, bounded by digit
    /// non-boundaries so it never fires inside a longer number (timestamps,
    /// order ids, UUID digits).
    static let defaultPhonePattern =
        "(?<![0-9+])(?:(?:\\+?86)[ \\-]?)?(1[3-9](?:[ \\-]?[0-9]){9})(?![0-9])"

    /// Three alternatives, one capture group each, so only the secret value is
    /// masked while every bit of surrounding syntax survives:
    /// 1. `label <sep> value` — app/api keys, tokens, secrets, passwords; a
    ///    leading word non-boundary stops `myapikey` style false hits.
    /// 2. Bare `Bearer <token>` (a raw Authorization header value with no
    ///    surrounding `key:` label). Requires a longer value to avoid prose.
    /// 3. High-confidence provider token prefixes — these stay case-sensitive
    ///    on purpose, so only the first two alternatives take `(?i:)`.
    /// The value charset includes `*` so a re-scan captures an already-masked
    /// value whole; `mask` then leaves it untouched, keeping the whole pass
    /// idempotent.
    static let defaultKeyPattern =
        "(?i:(?<![A-Za-z0-9_])(?:app[_-]?key|api[_-]?key|access[_-]?key|access[_-]?token|client[_-]?secret|secret[_-]?key|refresh[_-]?token|auth[_-]?token|authorization|password|passwd|pwd|secret|token|bearer)\\s*[\"']?\\s*[:=]\\s*[\"']?\\s*(?:bearer\\s+)?([A-Za-z0-9\\-._~+/*]{3,}))"
        + "|(?i:(?<![A-Za-z0-9_])bearer\\s+([A-Za-z0-9\\-._~+/*]{8,}))"
        + "|(?<![A-Za-z0-9])(sk-[A-Za-z0-9]{8,}|gh[opsu]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[abprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{12,})"

    static func defaultPattern(for kind: BuiltinKind) -> String {
        switch kind {
        case .phone: return defaultPhonePattern
        case .key:   return defaultKeyPattern
        }
    }

    static func builtinDefault(_ kind: BuiltinKind, enabled: Bool = true) -> ProtectionRule {
        ProtectionRule(builtin: kind, isEnabled: enabled, mode: .regex, pattern: defaultPattern(for: kind))
    }

    static func builtinDefaults() -> [ProtectionRule] {
        BuiltinKind.allCases.map { builtinDefault($0) }
    }
}

// MARK: - Settings snapshot

/// An immutable snapshot of the user's Content Protection preferences. Read from
/// `UserDefaults` via `current()` so the pure redactor never needs the
/// (main-actor) settings store; the store writes the very same keys.
struct ContentProtectionSettings: Equatable {
    var isEnabled: Bool
    /// Allow raw (un-redacted) protected content to leave through bulk export.
    var allowRawExport: Bool
    /// Allow raw protected content to leave through MCP text responses.
    var allowRawMCP: Bool
    /// The unified detection-rule list: seeded built-ins + user rules.
    var rules: [ProtectionRule]

    /// UserDefaults keys — shared verbatim with `ContentProtectionStore` so the
    /// settings UI and the pure redactor agree on storage.
    enum Keys {
        static let enabled = "contentProtection.enabled"
        static let allowRawExport = "contentProtection.allowRawExport"
        static let allowRawMCP = "contentProtection.allowRawMCP"
        static let rules = "contentProtection.rules"
        /// Pre-unification storage (≤0.9.13): one flag per built-in category
        /// plus a separate custom-rule list. Read only by the migration in
        /// `current()`; never written again.
        static let legacyCustomRules = "contentProtection.customRules"
        static func legacyCategory(_ raw: String) -> String {
            "contentProtection.category.\(raw)"
        }
    }

    /// Protection on, both built-in rules seeded and on, raw egress off — the
    /// default privacy-forward posture applied before the user touches any
    /// setting.
    static let defaults = ContentProtectionSettings(
        isEnabled: true,
        allowRawExport: false,
        allowRawMCP: false,
        rules: ProtectionRule.builtinDefaults()
    )

    /// Read the live preferences from `UserDefaults`. Missing keys fall back to
    /// the privacy-forward defaults; a missing rules key derives the list from
    /// the pre-unification keys (`ContentProtectionStore.init` persists that
    /// result once, after which the legacy keys are never consulted again).
    static func current(_ defaults: UserDefaults = .standard) -> ContentProtectionSettings {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? fallback
        }
        let rules: [ProtectionRule]
        if let data = defaults.data(forKey: Keys.rules) {
            rules = normalized(decodeRules(data))
        } else {
            // Legacy migration: the old category toggles become the built-in
            // rules' enabled state; custom rules carry over, gated by their
            // old master toggle.
            var migrated: [ProtectionRule] = [
                .builtinDefault(.phone, enabled: flag(Keys.legacyCategory("phone"), true)),
                .builtinDefault(.key, enabled: flag(Keys.legacyCategory("key"), true))
            ]
            let customOn = flag(Keys.legacyCategory("custom"), true)
            migrated += decodeRules(defaults.data(forKey: Keys.legacyCustomRules)).map { rule in
                var r = rule
                r.isEnabled = customOn && r.isEnabled
                return r
            }
            rules = migrated
        }
        return ContentProtectionSettings(
            isEnabled: flag(Keys.enabled, true),
            allowRawExport: flag(Keys.allowRawExport, false),
            allowRawMCP: flag(Keys.allowRawMCP, false),
            rules: rules
        )
    }

    /// Ensure every built-in exists (defends against corrupt or hand-edited
    /// defaults); missing ones are re-seeded at the top in declaration order.
    static func normalized(_ rules: [ProtectionRule]) -> [ProtectionRule] {
        let missing = ProtectionRule.BuiltinKind.allCases.filter { kind in
            !rules.contains { $0.builtin == kind }
        }
        guard !missing.isEmpty else { return rules }
        return missing.map { ProtectionRule.builtinDefault($0) } + rules
    }

    /// Box so the value-typed rules array can live in `NSCache`.
    private final class CachedRules {
        let rules: [ProtectionRule]
        init(_ rules: [ProtectionRule]) { self.rules = rules }
    }

    /// Decode memo keyed by the raw persisted blob: `current()` runs on every
    /// redaction call (hot row-render paths), so the JSON decode must not
    /// repeat per call. NSCache compares NSData keys by content and is
    /// thread-safe (egress paths call this off the main actor).
    private static let rulesCache: NSCache<NSData, CachedRules> = {
        let c = NSCache<NSData, CachedRules>()
        c.countLimit = 8
        return c
    }()

    static func decodeRules(_ data: Data?) -> [ProtectionRule] {
        guard let data, !data.isEmpty else { return [] }
        let key = data as NSData
        if let hit = rulesCache.object(forKey: key) { return hit.rules }
        let rules = (try? JSONDecoder().decode([ProtectionRule].self, from: data)) ?? []
        rulesCache.setObject(CachedRules(rules), forKey: key)
        return rules
    }
}

// MARK: - Result

/// The outcome of a redaction pass over one text value.
struct ContentProtectionResult: Equatable {
    /// The display/egress-safe string. Equal to the input when nothing matched
    /// (or protection is disabled).
    let redactedText: String
    /// True when at least one enabled rule matched.
    let isProtected: Bool
    /// Which categories actually matched.
    let categories: Set<ContentProtectionCategory>

    static func clear(_ text: String) -> ContentProtectionResult {
        ContentProtectionResult(redactedText: text, isProtected: false, categories: [])
    }
}

// MARK: - Detector + masker

enum ContentProtector {

    /// Redact sensitive spans in `text` according to `settings`. Pure,
    /// deterministic, and idempotent: feeding a redacted string back in returns
    /// it unchanged.
    static func redact(
        _ text: String,
        settings: ContentProtectionSettings = .current()
    ) -> ContentProtectionResult {
        // `pattern.isEmpty` is the cheap activity proxy here — whitespace-only
        // or invalid patterns fall through and are skipped per rule instead.
        let hasActiveRule = settings.rules.contains { $0.isEnabled && !$0.pattern.isEmpty }
        guard settings.isEnabled, hasActiveRule, !text.isEmpty else {
            return .clear(text)
        }

        // Row bodies re-run redaction over the same ≤200-char preview on every
        // hover/scroll re-render (list row title + badge, menu bar rows, quick
        // paste rows), so the regex passes should run once per distinct string.
        // Long inputs (full clip bodies in the preview popover / egress paths)
        // are one-off renders — caching them would only bloat the cache with
        // huge keys, so they always take the direct path.
        let cacheKey: NSString? = text.count <= cacheableLength
            ? cacheKey(for: text, settings: settings)
            : nil
        if let cacheKey, let hit = resultCache.object(forKey: cacheKey) {
            return hit.result
        }
        let result = computeRedaction(text, settings: settings)
        if let cacheKey {
            resultCache.setObject(CachedRedaction(result), forKey: cacheKey)
        }
        return result
    }

    /// Box so the value-typed result can live in `NSCache`.
    private final class CachedRedaction {
        let result: ContentProtectionResult
        init(_ result: ContentProtectionResult) { self.result = result }
    }

    /// Memoized redactions for short display strings, keyed by the rule list +
    /// input so editing or toggling a rule naturally misses. NSCache is
    /// thread-safe and evicts under memory pressure (mirrors the tags/regex
    /// caches elsewhere).
    private static let resultCache: NSCache<NSString, CachedRedaction> = {
        let c = NSCache<NSString, CachedRedaction>()
        c.countLimit = 1_024
        return c
    }()

    private static let cacheableLength = 512

    private static func cacheKey(for text: String, settings: ContentProtectionSettings) -> NSString {
        // Every rule field that affects matching participates so any edit
        // invalidates memoized results (in-memory cache, per-run hash is fine).
        var hasher = Hasher()
        for rule in settings.rules {
            hasher.combine(rule.isEnabled)
            hasher.combine(rule.mode)
            hasher.combine(rule.pattern)
            hasher.combine(rule.builtin)
        }
        return "\(hasher.finalize())|\(text)" as NSString
    }

    private static func computeRedaction(
        _ text: String,
        settings: ContentProtectionSettings
    ) -> ContentProtectionResult {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var detections: [Detection] = []

        for rule in settings.rules where rule.isEnabled {
            detections += ruleDetections(for: rule, in: text, ns: ns, range: full)
        }

        guard !detections.isEmpty else { return .clear(text) }

        // Resolve overlaps: leftmost wins, and on a tie the longer span wins so a
        // labeled `api_key=sk-…` masks the full value rather than a prefix slice.
        detections.sort { a, b in
            a.range.location != b.range.location
                ? a.range.location < b.range.location
                : a.range.length > b.range.length
        }

        var output = ""
        var cursor = 0
        var matchedCategories: Set<ContentProtectionCategory> = []
        for d in detections {
            guard d.range.location >= cursor else { continue } // skip overlap
            if d.range.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: d.range.location - cursor))
            }
            output += d.replacement
            cursor = d.range.location + d.range.length
            matchedCategories.insert(d.category)
        }
        if cursor < ns.length {
            output += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }

        return ContentProtectionResult(
            redactedText: output,
            isProtected: true,
            categories: matchedCategories
        )
    }

    // MARK: - Internal model

    private struct Detection {
        let range: NSRange           // span in the original string to replace
        let replacement: String
        let category: ContentProtectionCategory
    }

    // MARK: - Rule evaluation

    /// Shared LRU of compiled patterns (built-in defaults and user edits alike).
    /// Redaction runs per row render, so recompiling per evaluation would tax
    /// hot paths; invalid patterns are inert (nil) rather than fatal. Mirrors
    /// `ScriptingRule.compiledRegex`, duplicated here to keep this file
    /// standalone-compilable for the tests.
    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let c = NSCache<NSString, NSRegularExpression>()
        c.countLimit = 128
        return c
    }()

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(re, forKey: key)
        return re
    }

    private static func ruleDetections(
        for rule: ProtectionRule,
        in text: String,
        ns: NSString,
        range: NSRange
    ) -> [Detection] {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return [] }
        var out: [Detection] = []
        switch rule.mode {
        case .contains:
            let end = range.location + range.length
            var cursor = range.location
            while cursor < end {
                let remaining = NSRange(location: cursor, length: end - cursor)
                let found = ns.range(of: pattern, options: [.caseInsensitive], range: remaining)
                guard found.location != NSNotFound else { break }
                out.append(Detection(
                    range: found,
                    replacement: mask(ns.substring(with: found)),
                    category: rule.category
                ))
                cursor = found.location + max(found.length, 1)
            }
        case .regex:
            guard let re = compiledRegex(pattern) else { return [] }
            re.enumerateMatches(in: text, range: range) { match, _, _ in
                // Zero-width matches (e.g. `a*`) would loop the masker over
                // nothing — skip them so pathological patterns stay inert.
                guard let match, match.range.length > 0 else { return }
                // Capture groups pin the mask to the secret value itself so
                // labels, quotes and separators survive; a group-less pattern
                // masks the whole match.
                var maskedGroup = false
                if match.numberOfRanges > 1 {
                    for i in 1..<match.numberOfRanges {
                        let r = match.range(at: i)
                        guard r.location != NSNotFound, r.length > 0 else { continue }
                        out.append(Detection(
                            range: r,
                            replacement: mask(ns.substring(with: r)),
                            category: rule.category
                        ))
                        maskedGroup = true
                    }
                }
                if !maskedGroup {
                    out.append(Detection(
                        range: match.range,
                        replacement: mask(ns.substring(with: match.range)),
                        category: rule.category
                    ))
                }
            }
        }
        return out
    }

    // MARK: - Value masking

    /// Mask a matched span. A bare CN mobile number keeps the documented
    /// `138****5678` shape no matter which rule caught it (built-in, edited,
    /// or user-authored); everything else takes the generic value mask.
    static func mask(_ value: String) -> String {
        if value.contains("*") { return value }           // already redacted
        if value.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            let digits = Array(value.filter(\.isNumber))
            if digits.count == 11, digits[0] == "1", "3456789".contains(digits[1]) {
                return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
            }
        }
        return maskValue(value)
    }

    /// Mask the middle of a secret value, preserving recognizable edges.
    ///
    /// - Idempotent: a value that already contains `*` is returned unchanged, so
    ///   re-running redaction never grows the mask.
    /// - Bounded: the `*` run is clamped to 4...12 so a long secret's exact
    ///   length is never exposed by the mask width.
    static func maskValue(_ value: String) -> String {
        if value.contains("*") { return value }           // already redacted
        let chars = Array(value)
        let n = chars.count
        guard n > 0 else { return value }

        let starMin = 4, starMax = 12
        if n >= 8 {
            // Visible edges, shrunk for shorter values so >= starMin stays hidden.
            let visible = min(4, max(1, (n - starMin) / 2))
            let hidden = n - visible * 2
            let stars = String(repeating: "*", count: min(max(hidden, starMin), starMax))
            return String(chars.prefix(visible)) + stars + String(chars.suffix(visible))
        }
        // Short secret: keep at most the first and last character.
        if n <= 2 { return String(repeating: "*", count: starMin) }
        return String(chars.first!) + String(repeating: "*", count: starMin) + String(chars.last!)
    }
}
