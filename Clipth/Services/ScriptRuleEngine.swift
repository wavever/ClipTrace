import Foundation
import JavaScriptCore

// MARK: - Inputs & errors

/// Immutable value snapshot of a clip handed to a runner. Value-typed and
/// Sendable so it can cross to a background executor without touching the
/// `@MainActor`-bound SwiftData model off the main thread.
struct ScriptClipInput: Sendable {
    let text: String
    let type: String          // ClipboardItemType raw value
    let sourceApp: String
    let bundleId: String
    let tags: [String]
    let imageData: Data?
}

/// Thread-safe sink for a run's diagnostic output (`console.log` from JS, stderr
/// from a shell script). The runner writes from its worker thread while the
/// caller waits on a semaphore, so the box locks; the cap keeps a chatty — or
/// looping — script from growing it without bound. Only the editor's test panel
/// passes one; automatic runs discard diagnostics.
final class ScriptLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let cap = 200

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < cap else { return }
        storage.append(line)
    }
}

enum ScriptError: Error, CustomStringConvertible {
    case timeout
    case nonZeroExit(Int32)
    case javascript(String)
    case launchFailed(String)

    var description: String {
        switch self {
        case .timeout: return "execution timed out"
        case .nonZeroExit(let c): return "exit code \(c)"
        case .javascript(let m): return "JS error: \(m)"
        case .launchFailed(let m): return "launch failed: \(m)"
        }
    }
}

// MARK: - Run log

/// One recorded rule run, shown in Settings for auditability.
struct ScriptRunRecord: Identifiable {
    enum Outcome: String { case applied, skipped, error }
    let id = UUID()
    let ruleName: String
    let outcome: Outcome
    let detail: String?
    let date: Date
}

/// Bounded, in-memory recent-run log. Surfaces what rules actually did so the
/// scripting feature is auditable instead of invisible. Not persisted across
/// launches in v1 — it is a live diagnostic, not history of record.
@MainActor
final class ScriptRunLog: ObservableObject {
    static let shared = ScriptRunLog()
    @Published private(set) var records: [ScriptRunRecord] = []
    private let cap = 100
    private init() {}

    func record(rule: String, outcome: ScriptRunRecord.Outcome, detail: String? = nil) {
        records.insert(ScriptRunRecord(ruleName: rule, outcome: outcome, detail: detail, date: Date()), at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
    }

    func clear() { records.removeAll() }
}

/// Per-rule tallies, persisted across launches. `ScriptRunLog` answers "what
/// just happened"; this answers "is this rule doing anything at all?" — the
/// question a user actually has when scanning the list weeks after writing a
/// rule, and the one that makes a silently-broken rule visible.
@MainActor
final class RuleStatsStore: ObservableObject {
    struct Stat: Codable, Hashable {
        var applied = 0
        var skipped = 0
        var errors = 0
        var lastRun: Date?
        /// Kept only for the most recent failure — enough to explain a warning
        /// badge without turning this into a second log.
        var lastError: String?

        var total: Int { applied + skipped + errors }
    }

    static let shared = RuleStatsStore()
    private static let defaultsKey = "ruleRunStats"

    @Published private(set) var stats: [UUID: Stat] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([UUID: Stat].self, from: data) {
            stats = decoded
        }
    }

    func stat(for id: UUID) -> Stat? { stats[id] }

    func record(rule id: UUID, outcome: ScriptRunRecord.Outcome, detail: String? = nil) {
        var stat = stats[id] ?? Stat()
        switch outcome {
        case .applied:
            stat.applied += 1
            stat.lastError = nil // a good run clears the warning badge
        case .skipped:
            stat.skipped += 1
        case .error:
            stat.errors += 1
            stat.lastError = detail
        }
        stat.lastRun = Date()
        stats[id] = stat
        save()
    }

    func reset(_ id: UUID) {
        stats[id] = nil
        save()
    }

    func resetAll() {
        stats.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Effect decoding (shared by shell-JSON and JS-object outputs)

private enum EffectDecoder {
    /// Map a `{text?, tags?, title?, newClip?, copy?, drop?}` envelope onto
    /// effects. A truthy `drop` dominates and short-circuits the rest.
    static func effects(fromEnvelope dict: [String: Any]) -> [ScriptEffect] {
        if let drop = dict["drop"] as? Bool, drop { return [.drop] }
        var out: [ScriptEffect] = []
        if let text = dict["text"] as? String { out.append(.replaceText(text)) }
        if let tags = dict["tags"] as? [Any] {
            let strs = tags.compactMap { $0 as? String }
            if !strs.isEmpty { out.append(.setTags(strs)) }
        }
        if let title = dict["title"] as? String { out.append(.rename(title)) }
        if let newClip = dict["newClip"] as? String { out.append(.newClip(newClip)) }
        if let copy = dict["copy"] as? String { out.append(.copyToPasteboard(copy)) }
        return out
    }
}

// MARK: - Shell runner

enum ShellScriptRunner {
    /// Run `source` against `input`. Clip text goes to stdin; metadata to env;
    /// image bytes to a temp file path. stdout is the result (plain text →
    /// replaceText, or a JSON envelope → rich effects); a non-zero exit means
    /// "skip" (no effect). Bounded by `timeout`. Runs synchronously on the
    /// calling (background) executor.
    ///
    /// The source is spilled to a private temp file rather than passed to
    /// `sh -c`, so a shebang still selects the interpreter the author asked for
    /// (python, node, …) instead of always being /bin/sh.
    ///
    /// When `log` is supplied the script's stderr is captured into it instead of
    /// being discarded — that is the only channel a shell script has to explain
    /// itself, so the editor's test panel wires it up.
    static func run(source: String, input: ScriptClipInput, timeout: TimeInterval, log: ScriptLogBox? = nil) throws -> [ScriptEffect] {
        let fm = FileManager.default
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let url = fm.temporaryDirectory.appendingPathComponent("clipth-rule-\(UUID().uuidString).sh")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ScriptError.launchFailed("\(error)")
        }
        defer { try? fm.removeItem(at: url) }

        let process = Process()
        if source.hasPrefix("#!") {
            // Honour the shebang: mark it executable and let the kernel pick the
            // interpreter.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            process.executableURL = url
            process.arguments = []
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [url.path]
        }

        var env = ProcessInfo.processInfo.environment
        env["CLIP_TYPE"] = input.type
        env["CLIP_SOURCE_APP"] = input.sourceApp
        env["CLIP_BUNDLE_ID"] = input.bundleId
        env["CLIP_TAGS"] = input.tags.joined(separator: ",")

        var tempImage: URL?
        if let data = input.imageData {
            let tmp = fm.temporaryDirectory.appendingPathComponent("clipth-clip-\(UUID().uuidString)")
            try? data.write(to: tmp)
            env["CLIP_IMAGE_PATH"] = tmp.path
            tempImage = tmp
        }
        process.environment = env
        defer { if let t = tempImage { try? fm.removeItem(at: t) } }

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        let stderrPipe: Pipe? = log == nil ? nil : Pipe()
        process.standardError = stderrPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ScriptError.launchFailed("\(error)")
        }

        // Feed stdin. Throwing variants avoid the ObjC EPIPE exception that the
        // non-throwing `write(_:)` raises (and Swift can't catch) when a script
        // ignores stdin and exits early.
        let inHandle = stdinPipe.fileHandleForWriting
        try? inHandle.write(contentsOf: Data(input.text.utf8))
        try? inHandle.close()

        // Drain stdout on a background queue and bound it with a timeout so a
        // hung script is terminated rather than wedging the executor.
        final class OutBox { var data = Data() }
        let box = OutBox()
        let outHandle = stdoutPipe.fileHandleForReading
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = (try? outHandle.readToEnd()) ?? Data()
            sem.signal()
        }

        // stderr gets its own drain: reading it only after exit could deadlock a
        // script that fills the 64 KB pipe buffer while we wait on stdout.
        let errSem = DispatchSemaphore(value: 0)
        if let stderrPipe {
            let errHandle = stderrPipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                let data = (try? errHandle.readToEnd()) ?? Data()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    log?.append(String(line))
                }
                errSem.signal()
            }
        }
        defer { if stderrPipe != nil { _ = errSem.wait(timeout: .now() + 1) } }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = sem.wait(timeout: .now() + 1)
            throw ScriptError.timeout
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScriptError.nonZeroExit(process.terminationStatus)
        }

        return effects(fromStdout: String(decoding: box.data, as: UTF8.self))
    }

    private static func effects(fromStdout raw: String) -> [ScriptEffect] {
        // Strip a single trailing newline scripts commonly append via `echo`.
        var text = raw
        if text.hasSuffix("\n") { text.removeLast() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] } // empty stdout → no-op
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return EffectDecoder.effects(fromEnvelope: obj)
        }
        return [.replaceText(text)]
    }
}

// MARK: - JavaScript runner

enum JSScriptRunner {
    /// Evaluate `source` in a bare `JSContext` with only `clip` injected — no
    /// network, filesystem, or `require` (default-deny; `capabilities` is the
    /// hook for future opt-in grants, unused in v1). The script may define
    /// `function run(clip) { ... }` or be a bare expression; its value maps to
    /// effects.
    ///
    /// Timeout: JavaScriptCore's execution-time limit lives in a private header
    /// not exposed to Swift, so instead the evaluation runs on a dedicated
    /// worker thread that the caller waits on with a bounded semaphore. On
    /// overrun we throw `.timeout` and apply no effect, keeping the app and the
    /// capture pipeline responsive. Caveat: a truly infinite loop keeps spinning
    /// its worker thread until it returns — but since the runtime is default-deny
    /// it can only burn CPU, never touch data or the UI.
    static func run(source: String, input: ScriptClipInput, timeout: TimeInterval, capabilities: Set<ScriptCapability>, log: ScriptLogBox? = nil) throws -> [ScriptEffect] {
        final class ResultBox { var effects: [ScriptEffect] = []; var error: Error? }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let worker = Thread {
            do { box.effects = try evaluate(source: source, input: input, log: log) }
            catch { box.error = error }
            sem.signal()
        }
        worker.stackSize = 4 << 20
        worker.start()

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw ScriptError.timeout
        }
        if let error = box.error { throw error }
        return box.effects
    }

    private static func evaluate(source: String, input: ScriptClipInput, log: ScriptLogBox?) throws -> [ScriptEffect] {
        guard let context = JSContext() else { throw ScriptError.javascript("no JS context") }

        var thrown: String?
        context.exceptionHandler = { _, exc in thrown = exc?.toString() ?? "unknown exception" }

        let clip: [String: Any] = [
            "text": input.text,
            "type": input.type,
            "sourceApp": input.sourceApp,
            "bundleId": input.bundleId,
            "tags": input.tags,
        ]
        context.setObject(clip, forKeyedSubscript: "clip" as NSString)

        // A bare JSContext has no `console`, so an author debugging a rule has
        // nowhere to print. Inject one that feeds the caller's log box (dropped
        // when there is none) — the editor's test panel is its audience.
        let printLine: @convention(block) () -> Void = {
            let args = (JSContext.currentArguments() as? [JSValue]) ?? []
            log?.append(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        if let console = JSValue(newObjectIn: context) {
            for name in ["log", "warn", "error", "info", "debug"] {
                console.setObject(printLine, forKeyedSubscript: name as NSString)
            }
            context.setObject(console, forKeyedSubscript: "console" as NSString)
        }

        let completion = context.evaluateScript(source)
        if let thrown { throw ScriptError.javascript(thrown) }

        // Prefer an explicit `run(clip)` entry point; fall back to the script's
        // completion value (supports bare expressions like `clip.text.trim()`).
        let result: JSValue?
        if let runFn = context.objectForKeyedSubscript("run"),
           !runFn.isUndefined, runFn.isObject {
            result = runFn.call(withArguments: [clip])
            if let thrown { throw ScriptError.javascript(thrown) }
        } else {
            result = completion
        }
        return effects(from: result)
    }

    private static func effects(from value: JSValue?) -> [ScriptEffect] {
        guard let value, !value.isUndefined, !value.isNull else { return [] }
        if value.isString { return [.replaceText(value.toString())] }
        if value.isObject, let dict = value.toDictionary() as? [String: Any] {
            return EffectDecoder.effects(fromEnvelope: dict)
        }
        return []
    }
}

// MARK: - Rule specs (interchange format for MCP agents and LLM output)

/// The shape rules take when they are authored *outside* the editor — by an MCP
/// agent, or by a language model following the copy-paste prompt.
///
/// Deliberately flatter and more forgiving than `ScriptingRule`'s own Codable
/// form: `{"action":{"type":"javascript","source":"…"}}` is something a model
/// hits reliably, whereas the storage shape (`{"action":{"javascript":{…}}}`,
/// a synthesized enum encoding) is not. One format serves both AI paths so the
/// MCP schema and the prompt can never drift apart.
enum RuleSpec {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Parse one or many specs out of raw model output. Markdown fences and
    /// chatty preamble are tolerated because that is what models actually emit,
    /// and asking the user to clean it up by hand would defeat the point.
    static func rules(fromJSON raw: String) throws -> [ScriptingRule] {
        guard let payload = jsonPayload(in: raw) else {
            throw Failure(message: L("settings.rules.prompt.error.noJSON"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) else {
            throw Failure(message: L("settings.rules.prompt.error.badJSON"))
        }
        if let dict = object as? [String: Any] {
            return [try rule(from: dict)]
        }
        if let array = object as? [Any] {
            let dicts = array.compactMap { $0 as? [String: Any] }
            guard !dicts.isEmpty else { throw Failure(message: L("settings.rules.prompt.error.badJSON")) }
            return try dicts.map { try rule(from: $0) }
        }
        throw Failure(message: L("settings.rules.prompt.error.badJSON"))
    }

    /// Pull the JSON body out of whatever the model wrapped it in: a fenced
    /// block, or prose with an object/array somewhere inside.
    private static func jsonPayload(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            // Drop an optional language tag on the opening fence.
            let body = afterFence.drop(while: { $0 != "\n" })
            if let fenceEnd = body.range(of: "```") {
                return String(body[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.hasPrefix("{") || text.hasPrefix("[") { return text }

        // Prose around a JSON body: take the widest bracketed span.
        let openers: [Character] = ["{", "["]
        let closers: [Character] = ["}", "]"]
        guard let start = text.firstIndex(where: { openers.contains($0) }),
              let end = text.lastIndex(where: { closers.contains($0) }),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// Map one spec dictionary onto a rule, validating as we go. Messages name
    /// the offending field so an agent (or a user pasting model output) can fix
    /// exactly one thing and retry.
    static func rule(from dict: [String: Any]) throws -> ScriptingRule {
        guard let rawName = dict["name"] as? String else {
            throw Failure(message: "name is required")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Failure(message: "name must not be empty")
        }

        var rule = ScriptingRule(name: String(name.prefix(80)))

        if let raw = dict["triggers"] {
            guard let list = raw as? [Any] else {
                throw Failure(message: "triggers must be an array of \"copy\" and/or \"paste\"")
            }
            var triggers: Set<RuleTrigger> = []
            for value in list {
                guard let string = value as? String, let trigger = RuleTrigger(rawValue: string) else {
                    throw Failure(message: "triggers may only contain \"copy\" or \"paste\"")
                }
                triggers.insert(trigger)
            }
            guard !triggers.isEmpty else {
                throw Failure(message: "triggers must contain at least one of \"copy\" or \"paste\"")
            }
            rule.triggers = triggers
        }

        if let raw = dict["apps"] {
            guard let list = raw as? [Any] else {
                throw Failure(message: "apps must be an array of bundle ids or {bundleId, name} objects")
            }
            var apps: [AppFilterEntry] = []
            for entry in list {
                if let bundleId = entry as? String, !bundleId.isEmpty {
                    apps.append(AppFilterEntry(bundleId: bundleId, name: bundleId))
                } else if let object = entry as? [String: Any],
                          let bundleId = object["bundleId"] as? String, !bundleId.isEmpty {
                    apps.append(AppFilterEntry(bundleId: bundleId, name: (object["name"] as? String) ?? bundleId))
                } else {
                    throw Failure(message: "each apps entry must be a bundle id string or an object with a non-empty bundleId")
                }
            }
            rule.apps = apps
        }

        if let raw = dict["categories"] {
            guard let list = raw as? [Any] else {
                throw Failure(message: "categories must be an array of text/image/video/audio/file")
            }
            var categories: Set<RuleMatchCategory> = []
            for value in list {
                guard let string = value as? String, let category = RuleMatchCategory(rawValue: string) else {
                    throw Failure(message: "categories may only contain text, image, video, audio or file")
                }
                categories.insert(category)
            }
            rule.matchCategories = categories
        }

        rule.contentMatch = try match(dict["contentMatch"], field: "contentMatch")
        rule.fileNameMatch = try match(dict["fileNameMatch"], field: "fileNameMatch")

        if let raw = dict["fileExtensions"] {
            guard let list = raw as? [Any] else {
                throw Failure(message: "fileExtensions must be an array of strings")
            }
            var seen = Set<String>()
            rule.fileExtensions = list.compactMap { value -> String? in
                guard let string = value as? String else { return nil }
                let normalized = string
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
                return normalized
            }
        }

        rule.action = try action(dict["action"])

        if let raw = dict["timeoutSeconds"] {
            guard let seconds = (raw as? NSNumber)?.doubleValue, seconds > 0, seconds <= 30 else {
                throw Failure(message: "timeoutSeconds must be a number greater than 0 and at most 30")
            }
            rule.timeoutSeconds = seconds
        }

        // Anything authored elsewhere arrives disarmed: consent to run code is
        // per-install and belongs to the human in front of the app.
        rule.isEnabled = false
        return rule
    }

    private static func match(_ raw: Any?, field: String) throws -> RuleTextMatch {
        guard let raw else { return RuleTextMatch() }
        guard let dict = raw as? [String: Any] else {
            throw Failure(message: "\(field) must be an object like {\"mode\":\"contains\",\"value\":\"invoice\"}")
        }
        let modeRaw = (dict["mode"] as? String) ?? "any"
        guard let mode = RuleTextMatch.Mode(rawValue: modeRaw) else {
            throw Failure(message: "\(field).mode must be one of any, contains, notContains, regex")
        }
        let value = (dict["value"] as? String) ?? ""
        if mode != .any, value.isEmpty {
            throw Failure(message: "\(field).value is required when mode is \(modeRaw)")
        }
        if mode == .regex, ScriptingRule.compiledRegex(value) == nil {
            throw Failure(message: "\(field).value is not a valid regular expression")
        }
        return RuleTextMatch(mode: mode, value: value)
    }

    private static func action(_ raw: Any?) throws -> RuleAction {
        guard let dict = raw as? [String: Any], let type = dict["type"] as? String else {
            throw Failure(
                message: "action is required, e.g. {\"type\":\"javascript\",\"source\":\"function run(clip){ return clip.text.trim(); }\"}"
            )
        }
        switch type {
        case "drop":
            return .drop
        case "replaceRegex":
            let pattern = (dict["pattern"] as? String) ?? ""
            guard !pattern.isEmpty else {
                throw Failure(message: "action.pattern is required when action.type is replaceRegex")
            }
            guard ScriptingRule.compiledRegex(pattern) != nil else {
                throw Failure(message: "action.pattern is not a valid regular expression")
            }
            return .replaceRegex(pattern: pattern, replacement: (dict["replacement"] as? String) ?? "")
        case "shell", "javascript":
            guard let source = dict["source"] as? String,
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "action.source is required when action.type is \(type)")
            }
            return type == "shell" ? .shell(source: source) : .javascript(source: source)
        default:
            throw Failure(message: "action.type must be one of drop, replaceRegex, shell, javascript")
        }
    }
}

/// Builds the prompt a user copies into whichever model they like. Everything
/// the model needs is inlined — the rule format, the sandbox it is writing for,
/// and the output contract — because the model has no access to this app.
enum RulePromptBuilder {
    static let requestToken = "{{REQUEST}}"

    static func prompt(for request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = trimmed.isEmpty ? L("settings.rules.prompt.requestPlaceholderInline") : trimmed
        return L("settings.rules.prompt.template").replacingOccurrences(of: requestToken, with: placeholder)
    }
}

// MARK: - Rule templates

/// A ready-made rule the user can start from. Templates exist because the
/// scripting surface is powerful but undiscoverable: a blank editor gives no
/// hint of what a rule can do, whereas a filled-in one is simultaneously a
/// working feature and a worked example of the runner contract (return a string
/// to replace, an object for rich effects, `null` to skip).
struct RuleTemplate: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case cleanup, links, dev, filter
        var id: String { rawValue }
        var displayName: String { L("settings.rules.template.category.\(rawValue)") }
        var icon: String {
            switch self {
            case .cleanup: return "wand.and.sparkles"
            case .links: return "link"
            case .dev: return "chevron.left.forwardslash.chevron.right"
            case .filter: return "line.3.horizontal.decrease.circle"
            }
        }
    }

    let id: String
    let category: Category
    let icon: String
    let action: RuleAction
    var triggers: Set<RuleTrigger> = [.copy]
    var matchCategories: Set<RuleMatchCategory> = []
    var contentMatch = RuleTextMatch()
    var fileNameMatch = RuleTextMatch()
    var fileExtensions: [String] = []
    /// Sample clip text the editor preloads into its test panel, so "试运行"
    /// demonstrates the template on first click instead of on empty input.
    var sample: String = ""

    var name: String { L("settings.rules.template.\(id).name") }
    var summary: String { L("settings.rules.template.\(id).desc") }

    /// Instantiate as an unsaved rule for the editor. Stays disabled like any
    /// new rule — a template is a starting point, never an implicit consent to
    /// run code.
    func makeRule() -> ScriptingRule {
        var rule = ScriptingRule(name: name)
        rule.action = action
        rule.triggers = triggers
        rule.matchCategories = matchCategories
        rule.contentMatch = contentMatch
        rule.fileNameMatch = fileNameMatch
        rule.fileExtensions = fileExtensions
        return rule
    }
}

/// The built-in template catalogue. Sources are raw strings so the JavaScript
/// keeps its own escaping (`\s`, `\/`) instead of fighting Swift's.
enum RuleTemplateLibrary {
    static func templates(in category: RuleTemplate.Category) -> [RuleTemplate] {
        all.filter { $0.category == category }
    }

    static let all: [RuleTemplate] = [
        // MARK: cleanup
        RuleTemplate(
            id: "trim",
            category: .cleanup,
            icon: "scissors",
            action: .replaceRegex(pattern: #"^\s+|\s+$"#, replacement: ""),
            matchCategories: [.text],
            sample: "   需要清理的文本   \n"
        ),
        RuleTemplate(
            id: "singleLine",
            category: .cleanup,
            icon: "arrow.right.to.line",
            action: .replaceRegex(pattern: #"[ \t]*\r?\n[ \t]*"#, replacement: " "),
            matchCategories: [.text],
            sample: "第一行\n第二行\n  第三行"
        ),
        RuleTemplate(
            id: "blankLines",
            category: .cleanup,
            icon: "text.justify",
            action: .replaceRegex(pattern: #"\n{3,}"#, replacement: "\n\n"),
            matchCategories: [.text],
            sample: "段落一\n\n\n\n段落二"
        ),
        RuleTemplate(
            id: "tabs",
            category: .cleanup,
            icon: "arrow.right.to.line.compact",
            action: .replaceRegex(pattern: #"\t"#, replacement: "    "),
            matchCategories: [.text],
            sample: "func main() {\n\tprint(\"hi\")\n}"
        ),
        RuleTemplate(
            id: "pangu",
            category: .cleanup,
            icon: "character.textbox",
            action: .javascript(source: #"""
            // 中英文之间补空格,让混排文本更好读。没有可补的位置就返回 null(跳过)。
            function run(clip) {
                var out = clip.text
                    .replace(/([一-龥])([A-Za-z0-9@#$%^&*])/g, '$1 $2')
                    .replace(/([A-Za-z0-9~!%^&*)\]}])([一-龥])/g, '$1 $2');
                return out === clip.text ? null : out;
            }
            """#),
            matchCategories: [.text],
            sample: "今天用Clipth整理了30条剪贴板记录"
        ),

        // MARK: links
        RuleTemplate(
            id: "stripTracking",
            category: .links,
            icon: "link.badge.plus",
            action: .javascript(source: #"""
            // 去掉链接里的追踪参数(utm_*、fbclid、gclid…),其余部分原样保留。
            function run(clip) {
                var junkPrefix = /^(utm_|spm|scm|share_|from_|_hs|mc_)/i;
                var junkExact = ['fbclid', 'gclid', 'dclid', 'msclkid', 'igshid', 'yclid', 'si', 'vd_source', 'ref', 'ref_src'];
                var changed = false;
                var out = clip.text.replace(/https?:\/\/[^\s<>"']+/g, function (raw) {
                    var hash = '';
                    var h = raw.indexOf('#');
                    if (h >= 0) { hash = raw.slice(h); raw = raw.slice(0, h); }
                    var q = raw.indexOf('?');
                    if (q < 0) return raw + hash;
                    var kept = raw.slice(q + 1).split('&').filter(function (pair) {
                        var key = pair.split('=')[0];
                        if (!key) return false;
                        var drop = junkPrefix.test(key) || junkExact.indexOf(key.toLowerCase()) >= 0;
                        if (drop) changed = true;
                        return !drop;
                    });
                    return raw.slice(0, q) + (kept.length ? '?' + kept.join('&') : '') + hash;
                });
                // 返回 null = 本次不做任何改动,规则记为“跳过”。
                return changed ? out : null;
            }
            """#),
            matchCategories: [.text],
            sample: "https://example.com/post?id=42&utm_source=weixin&utm_medium=social&fbclid=abc#top"
        ),
        RuleTemplate(
            id: "tagDomain",
            category: .links,
            icon: "tag",
            action: .javascript(source: #"""
            // 按域名给链接自动打标签,之后可以按站点筛选。返回对象里的 tags 会追加到已有标签上。
            function run(clip) {
                var m = clip.text.match(/^\s*https?:\/\/([^\/\s:]+)/i);
                if (!m) return null;
                return { tags: [m[1].replace(/^www\./i, '')] };
            }
            """#),
            matchCategories: [.text],
            sample: "https://www.apple.com/macos/"
        ),
        RuleTemplate(
            id: "extractLinks",
            category: .links,
            icon: "list.bullet.rectangle",
            action: .javascript(source: #"""
            // 把长文里的链接抽出来,存成一条新的剪贴板条目(原条目保持不变)。
            function run(clip) {
                var urls = clip.text.match(/https?:\/\/[^\s<>"')\]]+/g);
                if (!urls || urls.length < 2) return null;
                var unique = urls.filter(function (u, i) { return urls.indexOf(u) === i; });
                return { newClip: unique.join('\n') };
            }
            """#),
            matchCategories: [.text],
            sample: "参考:https://a.example.com/1 和 https://b.example.com/2 ,以及 https://a.example.com/1"
        ),

        // MARK: dev
        RuleTemplate(
            id: "prettyJSON",
            category: .dev,
            icon: "curlybraces",
            action: .javascript(source: #"""
            // JSON 美化。不是合法 JSON 就返回 null —— 规则跳过,内容不受影响。
            function run(clip) {
                try {
                    return JSON.stringify(JSON.parse(clip.text), null, 2);
                } catch (e) {
                    return null;
                }
            }
            """#),
            matchCategories: [.text],
            sample: "{\"name\":\"Clipth\",\"tags\":[\"clipboard\",\"macOS\"],\"stars\":42}"
        ),
        RuleTemplate(
            id: "minifyJSON",
            category: .dev,
            icon: "arrow.down.right.and.arrow.up.left",
            action: .javascript(source: #"""
            // JSON 压缩成一行,方便贴进配置或命令行。
            function run(clip) {
                try {
                    return JSON.stringify(JSON.parse(clip.text));
                } catch (e) {
                    return null;
                }
            }
            """#),
            matchCategories: [.text],
            sample: "{\n  \"name\": \"Clipth\",\n  \"stars\": 42\n}"
        ),
        RuleTemplate(
            id: "base64",
            category: .dev,
            icon: "arrow.uturn.left.circle",
            action: .javascript(source: #"""
            // 整段 Base64 自动解码(JavaScriptCore 没有 atob,这里手写解码 + UTF-8 还原)。
            // 解不出可读文本就返回 null,避免把二进制内容写进历史。
            function run(clip) {
                var s = clip.text.trim();
                if (s.length < 8 || s.length % 4 !== 0 || !/^[A-Za-z0-9+\/]+={0,2}$/.test(s)) return null;
                var abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
                var bytes = [];
                for (var i = 0; i < s.length; i += 4) {
                    var n = 0, pad = 0;
                    for (var j = 0; j < 4; j++) {
                        var c = s.charAt(i + j);
                        if (c === '=') { pad++; n = n << 6; } else { n = (n << 6) | abc.indexOf(c); }
                    }
                    bytes.push((n >> 16) & 255);
                    if (pad < 2) bytes.push((n >> 8) & 255);
                    if (pad < 1) bytes.push(n & 255);
                }
                var out = '', k = 0;
                while (k < bytes.length) {
                    var b = bytes[k++];
                    if (b < 0x80) { out += String.fromCharCode(b); }
                    else if (b < 0xE0) { out += String.fromCharCode(((b & 31) << 6) | (bytes[k++] & 63)); }
                    else if (b < 0xF0) { out += String.fromCharCode(((b & 15) << 12) | ((bytes[k++] & 63) << 6) | (bytes[k++] & 63)); }
                    else {
                        var cp = ((b & 7) << 18) | ((bytes[k++] & 63) << 12) | ((bytes[k++] & 63) << 6) | (bytes[k++] & 63);
                        cp -= 0x10000;
                        out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 1023));
                    }
                }
                // 含控制字符 = 多半是二进制，别写进历史。
                if (/[\x00-\x08\x0E-\x1F]/.test(out)) return null;
                return out;
            }
            """#),
            matchCategories: [.text],
            sample: "5Ymq6L+55b6I5aW955SoIQ=="
        ),
        RuleTemplate(
            id: "shellStarter",
            category: .dev,
            icon: "terminal",
            action: .shell(source: ScriptRuleEngine.shellBoilerplate),
            matchCategories: [.text],
            sample: "hello from clipth"
        ),

        // MARK: filter
        RuleTemplate(
            id: "dropShort",
            category: .filter,
            icon: "trash",
            action: .drop,
            matchCategories: [.text],
            // Length lives in the condition itself now that the editor has no
            // separate min/max fields: 1–2 characters, newlines included.
            contentMatch: RuleTextMatch(mode: .regex, value: #"^[\s\S]{1,2}$"#),
            sample: "ab"
        ),
        RuleTemplate(
            id: "dropOTP",
            category: .filter,
            icon: "number.circle",
            action: .drop,
            matchCategories: [.text],
            contentMatch: RuleTextMatch(mode: .regex, value: #"^\s*\d{4,8}\s*$"#),
            sample: "123456"
        ),
        RuleTemplate(
            id: "dropScreenshotFiles",
            category: .filter,
            icon: "photo.badge.arrow.down",
            action: .drop,
            matchCategories: [.image, .file],
            fileNameMatch: RuleTextMatch(mode: .regex, value: #"(?i)(screenshot|screen shot|cleanshot|截屏|截图)"#),
            fileExtensions: ["png", "jpg", "jpeg", "heic"],
            sample: "/Users/me/Desktop/截屏 2026-07-25 15.04.png"
        ),

        // A paste-time rule: history keeps the original, the paste gets cleaned.
        RuleTemplate(
            id: "pasteTrim",
            category: .cleanup,
            icon: "arrow.down.doc",
            action: .replaceRegex(pattern: #"^\s+|\s+$"#, replacement: ""),
            triggers: [.paste],
            matchCategories: [.text],
            sample: "  粘贴时才清理的文本  \n"
        ),
    ]
}

// MARK: - Engine

/// Orchestrates rule actions: resolves the managed scripts directory and
/// dispatches an action to the right backend, returning effects. Stateless and
/// nonisolated so it can run off the main actor; the ViewModel owns matching,
/// chaining, and effect application on the main actor.
enum ScriptRuleEngine {
    static let defaultTimeout: TimeInterval = 3.0

    /// Starter script for an empty shell rule. Localized because its comments
    /// are the shortest documentation of the stdin/stdout contract an author
    /// will actually read — the same role `jsBoilerplate` plays for JS.
    static var shellBoilerplate: String { L("settings.rules.editor.shellBoilerplate") }

    static var scriptsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Clipth/Scripts", isDirectory: true)
    }

    @discardableResult
    static func ensureScriptsDirectory() -> URL {
        let dir = scriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Files currently available as shell actions (regular files in the dir).
    static func availableScripts() -> [String] {
        let dir = ensureScriptsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Run one action against `input`, returning the effects it produced. Code-
    /// free actions are immediate; script actions dispatch to their runner.
    /// Synchronous and nonisolated — call from a background executor.
    static func runAction(_ action: RuleAction, input: ScriptClipInput, timeout: TimeInterval, capabilities: Set<ScriptCapability>, log: ScriptLogBox? = nil) throws -> [ScriptEffect] {
        switch action {
        case .drop:
            return [.drop]
        case .replaceRegex(let pattern, let replacement):
            guard let re = ScriptingRule.compiledRegex(pattern) else { return [] }
            let range = NSRange(input.text.startIndex..., in: input.text)
            let out = re.stringByReplacingMatches(in: input.text, options: [], range: range, withTemplate: replacement)
            return [.replaceText(out)]
        case .shell(let source):
            return try ShellScriptRunner.run(source: source, input: input, timeout: timeout, log: log)
        case .javascript(let source):
            return try JSScriptRunner.run(source: source, input: input, timeout: timeout, capabilities: capabilities, log: log)
        }
    }
}
