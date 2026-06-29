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

    /// Localization key for the settings row title.
    var titleKey: String {
        switch self {
        case .phone: return "settings.privacy.category.phone"
        case .key:   return "settings.privacy.category.key"
        }
    }

    /// Localization key for the settings row subtitle.
    var subtitleKey: String {
        switch self {
        case .phone: return "settings.privacy.category.phone.subtitle"
        case .key:   return "settings.privacy.category.key.subtitle"
        }
    }

    var icon: String {
        switch self {
        case .phone: return "phone.fill"
        case .key:   return "key.fill"
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

    /// UserDefaults keys — shared verbatim with `ContentProtectionStore` so the
    /// settings UI and the pure redactor agree on storage.
    enum Keys {
        static let enabled = "contentProtection.enabled"
        static let allowRawExport = "contentProtection.allowRawExport"
        static let allowRawMCP = "contentProtection.allowRawMCP"
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
            allowRawMCP: flag(Keys.allowRawMCP, false)
        )
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

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var detections: [Detection] = []

        if settings.categories.contains(.phone) {
            detections += phoneDetections(in: text, ns: ns, range: full)
        }
        if settings.categories.contains(.key) {
            detections += keyDetections(in: text, ns: ns, range: full)
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
