import AppKit
import Combine

class ClipboardMonitor: ObservableObject {
    typealias Callback = (ClipboardItemType, String, Data?, String?, String, String) -> Void

    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general
    private var onNewContent: Callback?

    /// When true the poll timer is suspended — the app keeps running and the
    /// history stays browsable, but nothing new is captured. Distinct from
    /// "not monitoring": the stored callback is preserved so resuming is cheap.
    private(set) var isPaused = false

    /// `changeCount` values produced by our own writes (re-copy from history,
    /// quick-paste, merge, …). When the poller sees one of these, it should
    /// skip processing — otherwise the existing item gets its `createdAt`
    /// bumped to "now" and visibly jumps to the top of the list.
    private static var internalChangeCounts: Set<Int> = []

    /// Call this **right after** writing to `NSPasteboard.general` from within
    /// the app so the monitor knows to ignore the resulting change-count tick.
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/clipboard-debug.log")

    /// Verbose clipboard tracing. Off by default: it does synchronous file I/O
    /// on the polling (main) thread, and several call sites re-decode the
    /// pasteboard image (`NSImage(pasteboard:)`) just to build the message — so
    /// leaving it on stutters every single copy and writes clipboard contents
    /// to /tmp in the clear. Flip on via the `clipboardDebugLogging` user
    /// default only while diagnosing capture issues.
    private static let debugLoggingEnabled =
        UserDefaults.standard.bool(forKey: "clipboardDebugLogging")

    /// `message` is an autoclosure so the (sometimes expensive) interpolation is
    /// never evaluated when logging is disabled — the common case.
    static func debugLog(_ message: @autoclosure () -> String) {
        guard debugLoggingEnabled else { return }
        let line = "\(Date()) \(message())\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: debugLogURL)
            }
        }
    }

    static func markInternalWrite() {
        internalChangeCounts.insert(NSPasteboard.general.changeCount)
        // Bound the buffer so a long-running session can't leak ints forever
        // if some write somehow never gets observed by the poller.
        if internalChangeCounts.count > 32 {
            internalChangeCounts.removeAll()
        }
    }

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func startMonitoring(interval: TimeInterval = 0.5, onNewContent: @escaping Callback) {
        self.onNewContent = onNewContent
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Suspend or resume capture without tearing down the stored callback.
    /// Resuming re-syncs `lastChangeCount` to the live pasteboard so anything
    /// copied while paused isn't retroactively recorded on the next tick.
    func setPaused(_ paused: Bool, interval: TimeInterval) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            timer?.invalidate()
            timer = nil
        } else {
            // Only spin a timer back up if monitoring was actually started.
            guard onNewContent != nil, timer == nil else { return }
            lastChangeCount = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.checkForChanges()
            }
        }
    }

    /// Reschedule the poll timer at a new interval, reusing the stored
    /// `onNewContent` callback. No-op when not currently monitoring.
    func updateInterval(_ interval: TimeInterval) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }
    
    private func checkForChanges() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // Skip ticks we caused ourselves — re-copying a history item should
        // leave its position untouched, not boost it to the top.
        if Self.internalChangeCounts.remove(currentChangeCount) != nil {
            Self.debugLog("[Clipboard] skip internal write @\(currentChangeCount)")
            return
        }

        // Password managers, OTP fields and other secret-bearing apps tag the
        // pasteboard with one of the community-standard concealment markers;
        // never record those payloads. (1Password, Bitwarden, Keychain, …)
        if let types = pasteboard.types, Self.containsConcealedMarker(types) {
            Self.debugLog("[Clipboard] skip concealed/transient types=\(types.map { $0.rawValue })")
            return
        }

        Self.debugLog("[Clipboard] tick @\(currentChangeCount) types=\(pasteboard.types?.map { $0.rawValue } ?? [])")

        let (sourceApp, bundleId): (String, String)
        if isRemoteClipboard() {
            // Universal Clipboard delivery (iPhone/iPad/other Mac via
            // Handoff). The "frontmost app" at this instant is whatever the
            // user happens to be focused on locally, which is misleading —
            // tag it as remote so the row and toast can show that.
            sourceApp = L("remote.universalClipboard")
            bundleId = ClipboardMonitor.remoteBundleID
        } else {
            (sourceApp, bundleId) = getActiveApp()
        }

        // 1. 文件 URL 优先：从 Finder 复制时同时存在 file URL 与 string，先认 file URL。
        let fileOnlyOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOnlyOptions) as? [URL],
           !urls.isEmpty {
            Self.debugLog("[Clipboard] -> file branch urls=\(urls.map { $0.absoluteString })")
            let paths = urls.map { $0.path }.joined(separator: "\n")
            let firstURL = urls[0]
            let ext = firstURL.pathExtension.lowercased()
            let videoExts = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
            let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic", "heif"]
            let type: ClipboardItemType
            if videoExts.contains(ext) {
                type = .video
            } else if imageExts.contains(ext) {
                type = .image
            } else {
                type = .file
            }
            onNewContent?(type, paths, nil, firstURL.absoluteString, sourceApp, bundleId)
            return
        }

        // 2. 原始图片数据（截图、浏览器复制、应用拷贝出来的位图）。
        // Keep compressed image representations and rewrite TIFF fallbacks to PNG
        // before the bytes ever enter SwiftData.
        if let imagePayload = ImagePayloadStore.pasteboardPayload(from: pasteboard) {
            let imageData = imagePayload.data
            Self.debugLog("[Clipboard] -> image branch bytes=\(imageData.count)")
            let content = L("merge.imagePlaceholderFormat", imageData.count / 1024)
            onNewContent?(.image, content, imageData, nil, sourceApp, bundleId)
            return
        }
        Self.debugLog("[Clipboard] -> no image found; image=\(NSImage(pasteboard: pasteboard) != nil) tiff=\(pasteboard.data(forType: .tiff)?.count ?? -1) png=\(pasteboard.data(forType: .png)?.count ?? -1)")

        // 3. 普通字符串
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let isURL = string.hasPrefix("http://") || string.hasPrefix("https://")
            let type: ClipboardItemType = isURL ? .url : .text
            onNewContent?(type, string, nil, nil, sourceApp, bundleId)
            return
        }

        // 4. 富文本
        if let rtfData = pasteboard.data(forType: .rtf) {
            let content = String(data: rtfData, encoding: .utf8) ?? L("merge.rtfPlaceholder")
            onNewContent?(.rtf, content, nil, nil, sourceApp, bundleId)
            return
        }
    }

    private func getActiveApp() -> (name: String, bundleId: String) {
        if let app = NSWorkspace.shared.frontmostApplication {
            return (app.localizedName ?? L("common.unknown"), app.bundleIdentifier ?? "")
        }
        return (L("common.unknown"), "")
    }

    /// Sentinel bundle id used for clips delivered by macOS Universal
    /// Clipboard. Anything in the UI that wants to render a special badge
    /// for those clips can compare against this string.
    static let remoteBundleID = "com.apple.universalclipboard"

    /// Pasteboard type identifiers that signal the writer does not want the
    /// payload archived. Mostly the community-adopted `org.nspasteboard.*`
    /// hints plus Apple's own confidential-data marker.
    /// See: http://nspasteboard.org/
    private static let concealedMarkerTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.apple.is-sensitive",
    ]

    private static func containsConcealedMarker(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        for type in types where concealedMarkerTypes.contains(type.rawValue) {
            return true
        }
        return false
    }

    /// `true` when the current pasteboard contents were delivered by
    /// Universal Clipboard / Handoff. macOS publishes an undocumented but
    /// stable type marker on the pasteboard in that case.
    private func isRemoteClipboard() -> Bool {
        let marker = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        return pasteboard.types?.contains(marker) ?? false
    }
    
    deinit {
        stopMonitoring()
    }
}
