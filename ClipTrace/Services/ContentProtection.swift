import Foundation

/// Content Protection: a pure, conservative detector + masker that redacts
/// sensitive spans (phone numbers, API keys / tokens / secrets) in text-like
/// clipboard content **for display and egress**, without ever mutating the
/// stored clip.
///
/// This file is intentionally free of SwiftUI / SwiftData / Combine so it can be
/// unit-tested directly (see `scripts/ContentProtectionTests.swift`) and reused
/// from both the UI layer and the export / MCP egress paths. The
/// `ContentProtectionStore` (settings persistence + `ObservableObject`) lives in
/// `FilterSettings.swift`; this file only knows the pure value types.

// MARK: - Categories

/// The built-in detector families. Each is independently toggleable in settings.
enum ContentProtectionCategory: String, Codable, CaseIterable, Hashable {
    /// Chinese-mainland mobile numbers (v1 phone focus).
    case phone
    /// App keys, API keys, access/bearer tokens, client secrets, passwords, and
    /// high-confidence provider token prefixes.
    case key
    /// User-authored rules (keyword / regex) — the actual patterns live in
    /// `ContentProtectionSettings.customRules`; this case is their master
    /// toggle and the category tag their detections carry.
    case custom

    /// Localization key for the settings row title.
    var titleKey: String {
        switch self {
        case .phone:  return "settings.privacy.category.phone"
        case .key:    return "settings.privacy.category.key"
        case .custom: return "settings.privacy.category.custom"
        }
    }

    /// Localization key for the settings row subtitle.
    var subtitleKey: String {
        switch self {
        case .phone:  return "settings.privacy.category.phone.subtitle"
        case .key:    return "settings.privacy.category.key.subtitle"
        case .custom: return "settings.privacy.category.custom.subtitle"
        }
    }

    var icon: String {
        switch self {
        case .phone:  return "phone.fill"
        case .key:    return "key.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

// MARK: - Custom rules

/// A user-authored detector: a literal keyword or a regular expression whose
/// matches are masked exactly like the built-in categories. Kept Foundation-only
/// (no L(), no UI types) so this file still compiles standalone for the test
/// harness; display names for `Mode` live in the settings UI layer.
struct CustomProtectionRule: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// Case-insensitive literal substring match.
        case contains
        /// User-supplied `NSRegularExpression`; invalid patterns are inert.
        case regex

        var id: String { rawValue }
    }

    var id: UUID = UUID()
    var mode: Mode = .contains
    var pattern: String = ""

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
}

// MARK: - Settings snapshot

/// An immutable snapshot of the user's Content Protection preferences. Read from
/// `UserDefaults` via `current()` so the pure redactor never needs the
/// (main-actor) settings store; the store writes the very same keys.
struct ContentProtectionSettings: Equatable {
    var isEnabled: Bool
    var categories: Set<ContentProtectionCategory>
    /// Allow raw (un-redacted) protected content to leave through bulk export.
    var allowRawExport: Bool
    /// Allow raw protected content to leave through MCP text responses.
    var allowRawMCP: Bool
    /// User-authored keyword/regex detectors, active while `.custom` is in
    /// `categories`. Defaulted so existing memberwise call sites (tests) keep
    /// compiling unchanged.
    var customRules: [CustomProtectionRule] = []

    /// UserDefaults keys — shared verbatim with `ContentProtectionStore` so the
    /// settings UI and the pure redactor agree on storage.
    enum Keys {
        static let enabled = "contentProtection.enabled"
        static let allowRawExport = "contentProtection.allowRawExport"
        static let allowRawMCP = "contentProtection.allowRawMCP"
        static let customRules = "contentProtection.customRules"
        static func category(_ c: ContentProtectionCategory) -> String {
            "contentProtection.category.\(c.rawValue)"
        }
    }

    /// All built-in categories on, protection on, raw egress off — the default
    /// privacy-forward posture applied before the user touches any setting.
    static let defaults = ContentProtectionSettings(
        isEnabled: true,
        categories: Set(ContentProtectionCategory.allCases),
        allowRawExport: false,
        allowRawMCP: false
    )

    /// Read the live preferences from `UserDefaults`. Missing keys fall back to
    /// the privacy-forward defaults (protection + every category enabled).
    static func current(_ defaults: UserDefaults = .standard) -> ContentProtectionSettings {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? fallback
        }
        let enabled = flag(Keys.enabled, true)
        var categories: Set<ContentProtectionCategory> = []
        for c in ContentProtectionCategory.allCases where flag(Keys.category(c), true) {
            categories.insert(c)
        }
        return ContentProtectionSettings(
            isEnabled: enabled,
            categories: categories,
            allowRawExport: flag(Keys.allowRawExport, false),
            allowRawMCP: flag(Keys.allowRawMCP, false),
            customRules: decodeCustomRules(defaults.data(forKey: Keys.customRules))
        )
    }

    /// Box so the value-typed rules array can live in `NSCache`.
    private final class CachedRules {
        let rules: [CustomProtectionRule]
        init(_ rules: [CustomProtectionRule]) { self.rules = rules }
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

    static func decodeCustomRules(_ data: Data?) -> [CustomProtectionRule] {
        guard let data, !data.isEmpty else { return [] }
        let key = data as NSData
        if let hit = rulesCache.object(forKey: key) { return hit.rules }
        let rules = (try? JSONDecoder().decode([CustomProtectionRule].self, from: data)) ?? []
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
    /// True when at least one enabled category matched.
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
        guard settings.isEnabled, !settings.categories.isEmpty, !text.isEmpty else {
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

    /// Memoized redactions for short display strings, keyed by the enabled
    /// category set + input so a settings flip naturally misses. NSCache is
    /// thread-safe and evicts under memory pressure (mirrors the tags/regex
    /// caches elsewhere).
    private static let resultCache: NSCache<NSString, CachedRedaction> = {
        let c = NSCache<NSString, CachedRedaction>()
        c.countLimit = 1_024
        return c
    }()

    private static let cacheableLength = 512

    private static func cacheKey(for text: String, settings: ContentProtectionSettings) -> NSString {
        let categories = settings.categories.map(\.rawValue).sorted().joined(separator: ",")
        // Custom rules participate in the key so editing one invalidates
        // memoized results naturally (in-memory cache, so per-run hash is fine).
        var hasher = Hasher()
        for rule in settings.customRules {
            hasher.combine(rule.mode)
            hasher.combine(rule.pattern)
        }
        return "\(categories)|\(hasher.finalize())|\(text)" as NSString
    }

    private static func computeRedaction(
        _ text: String,
        settings: ContentProtectionSettings
    ) -> ContentProtectionResult {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var detections: [Detection] = []

        if settings.categories.contains(.phone) {
            detections += phoneDetections(in: text, ns: ns, range: full)
        }
        if settings.categories.contains(.key) {
            detections += keyDetections(in: text, ns: ns, range: full)
        }
        if settings.categories.contains(.custom), !settings.customRules.isEmpty {
            detections += customDetections(in: text, ns: ns, range: full, rules: settings.customRules)
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

    // MARK: - Phone (CN mobile)

    /// Optional `+86`/`86` prefix (group 1), then an `1[3-9]` mobile with
    /// space/dash tolerance (group 2), bounded by digit non-boundaries so it
    /// never fires inside a longer number (timestamps, order ids, UUID digits).
    private static let phoneRegex = try! NSRegularExpression(
        pattern: "(?<![0-9+])((?:\\+?86)[ \\-]?)?(1[3-9](?:[ \\-]?[0-9]){9})(?![0-9])"
    )

    private static func phoneDetections(in text: String, ns: NSString, range: NSRange) -> [Detection] {
        var out: [Detection] = []
        phoneRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let mobileRange = match.range(at: 2)
            guard mobileRange.location != NSNotFound else { return }
            let mobile = ns.substring(with: mobileRange)
            let digits = mobile.filter(\.isNumber)
            guard digits.count == 11 else { return }
            let d = Array(digits)
            let masked = String(d.prefix(3)) + "****" + String(d.suffix(4))

            // Preserve the visible country prefix verbatim; normalize the core.
            let prefixRange = match.range(at: 1)
            let prefix = prefixRange.location != NSNotFound ? ns.substring(with: prefixRange) : ""
            out.append(Detection(range: match.range, replacement: prefix + masked, category: .phone))
        }
        return out
    }

    // MARK: - Keys / tokens / secrets

    /// `label <sep> value` — the value (group 2) is masked, every bit of
    /// surrounding syntax (label, quotes, `:`/`=`, an optional `bearer` keyword)
    /// is preserved. A leading word boundary stops `myapikey` style false hits.
    ///
    /// The value charset includes `*` so a re-scan captures an already-masked
    /// value whole (e.g. `abcd****7890`); `maskValue` then leaves it untouched,
    /// keeping the whole pass idempotent.
    private static let labeledRegex = try! NSRegularExpression(
        pattern: "(?i)(?<![A-Za-z0-9_])(app[_-]?key|api[_-]?key|access[_-]?key|access[_-]?token|client[_-]?secret|secret[_-]?key|refresh[_-]?token|auth[_-]?token|authorization|password|passwd|pwd|secret|token|bearer)\\s*[\"']?\\s*[:=]\\s*[\"']?\\s*(?:[Bb]earer\\s+)?([A-Za-z0-9\\-._~+/*]{3,})"
    )

    /// Bare `Bearer <token>` (e.g. a raw Authorization header value with no
    /// surrounding `key:` label). Requires a longer value to avoid prose.
    private static let bareBearerRegex = try! NSRegularExpression(
        pattern: "(?i)(?<![A-Za-z0-9_])bearer\\s+([A-Za-z0-9\\-._~+/*]{8,})"
    )

    /// High-confidence provider token prefixes — masked with no label needed.
    private static let prefixRegex = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])(sk-[A-Za-z0-9]{8,}|gh[opsu]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[abprs]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{12,})"
    )

    private static func keyDetections(in text: String, ns: NSString, range: NSRange) -> [Detection] {
        var out: [Detection] = []

        labeledRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let valueRange = match.range(at: 2)
            guard valueRange.location != NSNotFound else { return }
            let value = ns.substring(with: valueRange)
            out.append(Detection(range: valueRange, replacement: maskValue(value), category: .key))
        }

        bareBearerRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let valueRange = match.range(at: 1)
            guard valueRange.location != NSNotFound else { return }
            let value = ns.substring(with: valueRange)
            out.append(Detection(range: valueRange, replacement: maskValue(value), category: .key))
        }

        prefixRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound else { return }
            let token = ns.substring(with: tokenRange)
            out.append(Detection(range: tokenRange, replacement: maskValue(token), category: .key))
        }

        return out
    }

    // MARK: - Custom rules (user-authored keyword / regex)

    /// Shared LRU of compiled user patterns. Redaction runs per row render, so
    /// recompiling per evaluation would tax hot paths; invalid patterns are
    /// inert (nil) rather than fatal. Mirrors `ScriptingRule.compiledRegex`,
    /// duplicated here to keep this file standalone-compilable for the tests.
    private static let customRegexCache: NSCache<NSString, NSRegularExpression> = {
        let c = NSCache<NSString, NSRegularExpression>()
        c.countLimit = 128
        return c
    }()

    private static func compiledCustomRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = customRegexCache.object(forKey: key) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        customRegexCache.setObject(re, forKey: key)
        return re
    }

    private static func customDetections(
        in text: String,
        ns: NSString,
        range: NSRange,
        rules: [CustomProtectionRule]
    ) -> [Detection] {
        var out: [Detection] = []
        for rule in rules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
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
                        replacement: maskValue(ns.substring(with: found)),
                        category: .custom
                    ))
                    cursor = found.location + max(found.length, 1)
                }
            case .regex:
                guard let re = compiledCustomRegex(pattern) else { continue }
                re.enumerateMatches(in: text, range: range) { match, _, _ in
                    // Zero-width matches (e.g. `a*`) would loop the masker over
                    // nothing — skip them so pathological patterns stay inert.
                    guard let match, match.range.length > 0 else { return }
                    out.append(Detection(
                        range: match.range,
                        replacement: maskValue(ns.substring(with: match.range)),
                        category: .custom
                    ))
                }
            }
        }
        return out
    }

    // MARK: - Value masking

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
