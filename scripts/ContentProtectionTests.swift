import Foundation

// Deterministic harness for the pure `ContentProtector`. There is no XCTest
// target in this project, so this self-contained `main` is compiled together
// with the production source and asserts the detector/masker contract. swiftc
// only allows top-level code in a file named `main.swift`, so copy this file
// before compiling:
//
//   cp scripts/ContentProtectionTests.swift /tmp/main.swift && \
//   swiftc Clipth/Services/ContentProtection.swift /tmp/main.swift \
//       -o /tmp/cptests && /tmp/cptests
//
// Exit code 0 = all cases passed; non-zero = at least one failure (printed).

var failures = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL: \(name)\(detail().isEmpty ? "" : " — \(detail())")")
    }
}

let all = ContentProtectionSettings.defaults

func redact(_ s: String, _ settings: ContentProtectionSettings = all) -> ContentProtectionResult {
    ContentProtector.redact(s, settings: settings)
}

// 1. CN mobile number -> 138****5678
do {
    let r = redact("13812345678")
    check("phone.basic", r.redactedText == "138****5678", r.redactedText)
    check("phone.basic.protected", r.isProtected && r.categories == [.phone])
}

// 1b. Phone with +86 prefix and separators, prefix preserved + core normalized
do {
    let r = redact("+86 138 1234 5678")
    check("phone.prefixSeparators", r.redactedText == "+86 138****5678", r.redactedText)
}

// 1c. Phone embedded in a sentence
do {
    let r = redact("打给我 13912345678 谢谢")
    check("phone.inSentence", r.redactedText == "打给我 139****5678 谢谢", r.redactedText)
}

// 2. App key value -> label/delimiter kept, value masked, full value gone
do {
    let r = redact("appkey=abcdef1234567890")
    check("key.appkey", r.redactedText == "appkey=abcd********7890", r.redactedText)
    check("key.appkey.noRaw", !r.redactedText.contains("abcdef1234567890"))
    check("key.appkey.category", r.categories == [.key])
}

// 2b. JSON-shaped api_key, surrounding quotes/structure preserved
do {
    let r = redact("{\"api_key\": \"sk-abcdEFGH12345678ZZZ\"}")
    check("key.jsonApiKey.struct", r.redactedText.hasPrefix("{\"api_key\": \"") && r.redactedText.hasSuffix("\"}"), r.redactedText)
    check("key.jsonApiKey.masked", !r.redactedText.contains("abcdEFGH12345678ZZZ"), r.redactedText)
}

// 2c. URL query token masked, structure (host, &) preserved
do {
    let r = redact("https://api.example.com/v1?access_token=ABCDwxyz1234567890&page=2")
    check("key.urlToken.host", r.redactedText.hasPrefix("https://api.example.com/v1?access_token="), r.redactedText)
    check("key.urlToken.tail", r.redactedText.hasSuffix("&page=2"), r.redactedText)
    check("key.urlToken.masked", !r.redactedText.contains("ABCDwxyz1234567890"), r.redactedText)
}

// 2d. High-confidence prefix without any label
do {
    let r = redact("ghp_ABCDEFGHIJKLMNOpqrstuvwxyz0123")
    check("key.ghPrefix.protected", r.isProtected && r.categories == [.key])
    check("key.ghPrefix.masked", !r.redactedText.contains("ABCDEFGHIJKLMNOpqrstuvwxyz0123"), r.redactedText)
}

// 2e. Bearer authorization header
do {
    let r = redact("Authorization: Bearer abcdef0123456789ABCDEF")
    check("key.bearer.label", r.redactedText.hasPrefix("Authorization: Bearer "), r.redactedText)
    check("key.bearer.masked", !r.redactedText.contains("abcdef0123456789ABCDEF"), r.redactedText)
}

// 3. Multiple sensitive spans in one clip, both redacted, context intact
do {
    let r = redact("call 13812345678 with token=ABCDEFGH12345678")
    check("multi.phone", r.redactedText.contains("138****5678"), r.redactedText)
    check("multi.token", !r.redactedText.contains("ABCDEFGH12345678"), r.redactedText)
    check("multi.context", r.redactedText.hasPrefix("call ") && r.redactedText.contains(" with token="), r.redactedText)
    check("multi.categories", r.categories == [.phone, .key])
}

// 4. Short secret keeps at most first/last char
do {
    let r = redact("pwd=abc")
    check("short.secret", r.redactedText == "pwd=a****c", r.redactedText)
}

// 5. Idempotence — redacting redacted output changes nothing / adds no stars
do {
    for sample in [
        "appkey=abcdef1234567890",
        "13812345678",
        "ghp_ABCDEFGHIJKLMNOpqrstuvwxyz0123",
        "call 13812345678 token=ABCDEFGH12345678",
        "pwd=abc",
    ] {
        let once = redact(sample).redactedText
        let twice = redact(once).redactedText
        check("idempotent[\(sample)]", once == twice, "once=\(once) twice=\(twice)")
        // Re-running must not add stars.
        let onceStars = once.filter { $0 == "*" }.count
        let twiceStars = twice.filter { $0 == "*" }.count
        check("idempotent.starCount[\(sample)]", onceStars == twiceStars)
    }
}

// 6. False positives — must NOT be masked solely for being long/alphanumeric
do {
    let fps: [String] = [
        "550e8400-e29b-41d4-a716-446655440000",        // UUID
        "9fceb02d0ae598e95dc970b74767f19372d61af8",    // commit SHA (40 hex)
        "1719360000",                                   // unix timestamp (10)
        "1719360000000",                                // unix ms timestamp (13)
        "https://example.com/products/12345678?ref=home", // ordinary URL
        "Order #20240615123456 shipped",                // order number
        "The quick brown fox jumps over the lazy dog",  // prose
    ]
    for fp in fps {
        let r = redact(fp)
        check("falsePositive[\(fp)]", !r.isProtected && r.redactedText == fp, r.redactedText)
    }
}

// 7. Bounded mask — a very long secret does not expose its exact length
do {
    let longSecret = String(repeating: "A", count: 80)
    let r = redact("secret=\(longSecret)")
    let stars = r.redactedText.filter { $0 == "*" }.count
    check("bounded.maxStars", stars <= 12, "stars=\(stars)")
    check("bounded.shorter", r.redactedText.count < ("secret=" + longSecret).count, r.redactedText)
}

// 8. Rule toggle — disabling the phone built-in leaves keys working
do {
    var keyOnly = ContentProtectionSettings.defaults
    keyOnly.rules = keyOnly.rules.map { rule in
        var r = rule
        if r.builtin == .phone { r.isEnabled = false }
        return r
    }
    let r = redact("13812345678 token=ABCDEFGH12345678", keyOnly)
    check("toggle.phoneOff", r.redactedText.contains("13812345678"), r.redactedText)
    check("toggle.keyStillOn", !r.redactedText.contains("ABCDEFGH12345678"), r.redactedText)
}

// 9. Master disabled -> raw passthrough, not protected
do {
    let off = ContentProtectionSettings(
        isEnabled: false,
        allowRawExport: false,
        allowRawMCP: false,
        rules: ProtectionRule.builtinDefaults()
    )
    let r = redact("appkey=abcdef1234567890", off)
    check("master.off", !r.isProtected && r.redactedText == "appkey=abcdef1234567890", r.redactedText)
}

// 10. Custom keyword rule masks its matches and tags .custom
do {
    var s = ContentProtectionSettings.defaults
    s.rules.append(ProtectionRule(mode: .contains, pattern: "ProjectPhoenix"))
    let r = redact("docs for projectphoenix are ready", s)
    check("custom.keyword.masked", !r.redactedText.lowercased().contains("projectphoenix"), r.redactedText)
    check("custom.keyword.context", r.redactedText.hasPrefix("docs for ") && r.redactedText.hasSuffix(" are ready"), r.redactedText)
    check("custom.keyword.category", r.categories.contains(.custom))
}

// 11. Custom regex with a capture group masks only the group, label survives
do {
    var s = ContentProtectionSettings.defaults
    s.rules.append(ProtectionRule(mode: .regex, pattern: "employee-id:\\s*([0-9]{6})"))
    let r = redact("employee-id: 123456", s)
    check("custom.group.label", r.redactedText.hasPrefix("employee-id: "), r.redactedText)
    check("custom.group.masked", !r.redactedText.contains("123456"), r.redactedText)
}

// 12. Edited built-in phone rule still applies the 138****5678 phone mask
do {
    var s = ContentProtectionSettings.defaults
    s.rules = s.rules.map { rule in
        var r = rule
        // Narrow the built-in to 138-prefixed numbers only.
        if r.builtin == .phone { r.pattern = "(?<![0-9+])(138(?:[ \\-]?[0-9]){8})(?![0-9])" }
        return r
    }
    let r = redact("13812345678 and 13912345678", s)
    check("editedPhone.masked", r.redactedText.contains("138****5678"), r.redactedText)
    check("editedPhone.narrowed", r.redactedText.contains("13912345678"), r.redactedText)
}

// 13. Invalid regex rule is inert; the rest keep working
do {
    var s = ContentProtectionSettings.defaults
    s.rules.append(ProtectionRule(mode: .regex, pattern: "([unclosed"))
    let r = redact("call 13812345678", s)
    check("invalidRegex.inert", r.redactedText == "call 138****5678", r.redactedText)
}

// 14. Disabled custom rule does not fire
do {
    var s = ContentProtectionSettings.defaults
    s.rules.append(ProtectionRule(isEnabled: false, mode: .contains, pattern: "hello"))
    let r = redact("hello world", s)
    check("disabledRule.inert", !r.isProtected && r.redactedText == "hello world", r.redactedText)
}

// 15. Legacy custom-rule blob (id/mode/pattern only) decodes as enabled user rule
do {
    let legacy = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"mode\":\"contains\",\"pattern\":\"secretword\"}]"
    let rules = ContentProtectionSettings.decodeRules(legacy.data(using: .utf8))
    check("legacy.decode.count", rules.count == 1)
    check("legacy.decode.fields", rules.first.map { $0.isEnabled && $0.builtin == nil && $0.pattern == "secretword" } ?? false)
}

// 16. normalized() re-seeds missing built-ins ahead of user rules
do {
    let userOnly = [ProtectionRule(mode: .contains, pattern: "x")]
    let fixed = ContentProtectionSettings.normalized(userOnly)
    check("normalized.reseeds", fixed.count == 3)
    check("normalized.order", fixed[0].builtin == .phone && fixed[1].builtin == .key && fixed[2].builtin == nil)
}

print("\nContentProtection harness: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
