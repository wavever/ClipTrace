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

enum ScriptError: Error, CustomStringConvertible {
    case scriptNotFound(String)
    case notInManagedDirectory(String)
    case notRegularFile(String)
    case timeout
    case nonZeroExit(Int32)
    case javascript(String)
    case launchFailed(String)

    var description: String {
        switch self {
        case .scriptNotFound(let n): return "script not found: \(n)"
        case .notInManagedDirectory(let n): return "script outside managed dir: \(n)"
        case .notRegularFile(let n): return "not a regular file: \(n)"
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
    /// Run the managed `.sh` file named `scriptName` against `input`. Clip text
    /// goes to stdin; metadata to env; image bytes to a temp file path. stdout
    /// is the result (plain text → replaceText, or a JSON envelope → rich
    /// effects); a non-zero exit means "skip" (no effect). Bounded by `timeout`.
    /// Runs synchronously on the calling (background) executor.
    static func run(scriptName: String, input: ScriptClipInput, timeout: TimeInterval) throws -> [ScriptEffect] {
        let url = try resolve(scriptName)

        let process = Process()
        let fm = FileManager.default
        // Honour a shebang when the file is executable; otherwise run via /bin/sh
        // so a plain, non-+x `.sh` still works.
        if fm.isExecutableFile(atPath: url.path) {
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
            let tmp = fm.temporaryDirectory.appendingPathComponent("cliptrace-clip-\(UUID().uuidString)")
            try? data.write(to: tmp)
            env["CLIP_IMAGE_PATH"] = tmp.path
            tempImage = tmp
        }
        process.environment = env
        defer { if let t = tempImage { try? fm.removeItem(at: t) } }

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

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

    /// Resolve `scriptName` to a vetted file inside the managed scripts dir:
    /// no path traversal escaping the tree, and a regular file.
    private static func resolve(_ scriptName: String) throws -> URL {
        let dir = ScriptRuleEngine.scriptsDirectory.standardizedFileURL
        let url = dir.appendingPathComponent(scriptName).standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/") else {
            throw ScriptError.notInManagedDirectory(scriptName)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ScriptError.scriptNotFound(scriptName)
        }
        guard !isDir.boolValue else { throw ScriptError.notRegularFile(scriptName) }
        return url
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
    static func run(source: String, input: ScriptClipInput, timeout: TimeInterval, capabilities: Set<ScriptCapability>) throws -> [ScriptEffect] {
        final class ResultBox { var effects: [ScriptEffect] = []; var error: Error? }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let worker = Thread {
            do { box.effects = try evaluate(source: source, input: input) }
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

    private static func evaluate(source: String, input: ScriptClipInput) throws -> [ScriptEffect] {
        guard let context = JSContext() else { throw ScriptError.javascript("no JS context") }

        var thrown: String?
        context.exceptionHandler = { _, exc in thrown = exc?.toString() ?? "unknown exception" }

        let clip: [String: Any] = [
            "text": input.text,
            "type": input.type,
            "sourceApp": input.sourceApp,
            "tags": input.tags,
        ]
        context.setObject(clip, forKeyedSubscript: "clip" as NSString)

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

// MARK: - Engine

/// Orchestrates rule actions: resolves the managed scripts directory and
/// dispatches an action to the right backend, returning effects. Stateless and
/// nonisolated so it can run off the main actor; the ViewModel owns matching,
/// chaining, and effect application on the main actor.
enum ScriptRuleEngine {
    static let defaultTimeout: TimeInterval = 3.0

    static var scriptsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ClipTrace/Scripts", isDirectory: true)
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
    static func runAction(_ action: RuleAction, input: ScriptClipInput, timeout: TimeInterval, capabilities: Set<ScriptCapability>) throws -> [ScriptEffect] {
        switch action {
        case .drop:
            return [.drop]
        case .replaceRegex(let pattern, let replacement):
            guard let re = ScriptingRule.compiledRegex(pattern) else { return [] }
            let range = NSRange(input.text.startIndex..., in: input.text)
            let out = re.stringByReplacingMatches(in: input.text, options: [], range: range, withTemplate: replacement)
            return [.replaceText(out)]
        case .shell(let name):
            return try ShellScriptRunner.run(scriptName: name, input: input, timeout: timeout)
        case .javascript(let source):
            return try JSScriptRunner.run(source: source, input: input, timeout: timeout, capabilities: capabilities)
        }
    }
}
