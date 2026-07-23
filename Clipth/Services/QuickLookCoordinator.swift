import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Bridges clipboard items into the native macOS QuickLook panel
/// (QLPreviewPanel) — the same one Finder shows when you press Space on a
/// selection. The panel stays open until the user dismisses it; arrow keys
/// navigate between neighboring clips while it's up.
///
/// Each clip is materialized into a temp file (text → .txt, image → .png, etc.)
/// because QuickLook only previews on-disk URLs. The temp directory is cleaned
/// up when the panel loses control.
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    /// Snapshot of the user's current list at the moment Preview was triggered.
    /// We keep the snapshot so re-renders of the main list (filter changes,
    /// new clips arriving) don't shift the indices out from under us while
    /// the panel is showing.
    private var items: [ClipboardItem] = []
    private var previewURLs: [URL?] = []
    private var currentIndex: Int = 0
    private var tempDirectory: URL?
    /// We hook the shared panel's `willCloseNotification` once and keep the
    /// observer around for the app lifetime — the panel itself is a singleton,
    /// so re-subscribing every call would just churn.
    private var closeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        if let panel = QLPreviewPanel.shared() {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.handlePanelDidClose()
            }
        }
    }

    deinit {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Show the QuickLook panel for `items`, starting at `index`. Subsequent
    /// arrow keys navigate inside the same list — to switch lists, call this
    /// again with a new array.
    func preview(items: [ClipboardItem], startingAt index: Int) {
        guard !items.isEmpty else { return }
        self.items = items
        self.currentIndex = max(0, min(index, items.count - 1))
        rebuildPreviewURLs()

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = currentIndex
        panel.makeKeyAndOrderFront(nil)
    }

    /// Convenience for "preview a single item" — wraps it as a one-item list.
    func preview(item: ClipboardItem) {
        preview(items: [item], startingAt: 0)
    }

    /// True while the shared panel is on-screen showing our data. The main
    /// window uses this to decide whether Space should open a new preview vs.
    /// be ignored (the panel handles its own key events when it has focus).
    var isPanelVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        guard let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && panel.dataSource === self
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // The panel asks even for indices outside the current selection (so it
        // can prefetch neighbors). Materialize lazily on demand.
        guard index >= 0 && index < items.count else {
            return placeholderItem(title: "—")
        }
        if let url = previewURLs[index] {
            return url as NSURL
        }
        if let url = materialize(items[index]) {
            previewURLs[index] = url
            return url as NSURL
        }
        return placeholderItem(title: items[index].itemType.displayName)
    }

    // MARK: - QLPreviewPanelDelegate

    /// Returning `true` from this lets QuickLook know we want to handle the
    /// arrow keys (next/prev item) and Esc (close) ourselves. We forward by
    /// re-dispatching to the panel, which already has the right behavior
    /// baked in once it owns the keyDown.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            // Let the panel process navigation/close natively.
            panel.keyDown(with: event)
            return true
        }
        return false
    }

    // MARK: - Lifecycle

    /// Fires off the shared panel's `willCloseNotification`. Wipes temp files
    /// and drops our snapshot so the next open starts from a clean slate. We
    /// only react when the panel was actually showing our data — if some other
    /// controller had taken it over, we shouldn't be touching its state.
    private func handlePanelDidClose() {
        guard let panel = QLPreviewPanel.shared(), panel.dataSource === self else {
            return
        }
        panel.dataSource = nil
        panel.delegate = nil
        cleanupTempFiles()
        items = []
        previewURLs = []
        currentIndex = 0
    }

    // MARK: - Materialization

    private func rebuildPreviewURLs() {
        cleanupTempFiles()
        previewURLs = Array(repeating: nil, count: items.count)
        ensureTempDirectory()
        // Eagerly materialize the current item so the panel has something to
        // show immediately; neighbors are lazy.
        if currentIndex >= 0 && currentIndex < items.count {
            previewURLs[currentIndex] = materialize(items[currentIndex])
        }
    }

    private func ensureTempDirectory() {
        if let dir = tempDirectory, FileManager.default.fileExists(atPath: dir.path) {
            return
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipthQuickLook-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            tempDirectory = base
        } catch {
            tempDirectory = nil
        }
    }

    private func cleanupTempFiles() {
        guard let dir = tempDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        tempDirectory = nil
    }

    /// Produce a URL that QuickLook can render for `item`. Strategy:
    /// - file/video → existing file URL if it's still readable
        /// - image → write stored image payload (or copy on-disk image) as PNG/original
    /// - text/url/rtf → write content to a temp .txt / .rtf
    private func materialize(_ item: ClipboardItem) -> URL? {
        ensureTempDirectory()
        guard let dir = tempDirectory else { return nil }

        switch item.itemType {
        case .file, .video:
            // Prefer the original file URL if it still exists — QL gives us
            // a richer preview (PDF pagination, video scrubbing, etc.) when
            // it can read the file directly.
            if let url = item.resolvedFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return writeFallbackText(
                "[File: \(item.resolvedFileURL?.lastPathComponent ?? item.content)]",
                id: item.id,
                in: dir
            )

        case .image:
            if let payload = ImagePayloadStore.payload(for: ImagePayloadStore.reference(for: item)) {
                let data = payload.data
                let ext = imageExtension(for: data)
                let url = dir.appendingPathComponent("\(item.id.uuidString).\(ext)")
                try? data.write(to: url)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            if let src = item.resolvedFileURL,
               FileManager.default.fileExists(atPath: src.path) {
                return src
            }
            return writeFallbackText("[Image]", id: item.id, in: dir)

        case .text:
            // Materialize the redacted rendition: the on-disk preview file is a
            // display surface (and could be picked up by Spotlight/screenshots),
            // so sensitive spans must not land in it. The stored clip is intact.
            return writeText(item.redactedForDisplay(item.content), id: item.id, ext: "txt", in: dir)

        case .url:
            return writeText(item.redactedForDisplay(item.content), id: item.id, ext: "txt", in: dir)

        case .rtf:
            // RTF strings round-trip through QL fine when saved with the
            // `.rtf` extension; plain string write is enough because the
            // clipboard already stores the raw RTF source. Redaction only masks
            // detected sensitive values, leaving the RTF control words intact.
            let redacted = item.redactedForDisplay(item.content)
            let ext = redacted.hasPrefix("{\\rtf") ? "rtf" : "txt"
            return writeText(redacted, id: item.id, ext: ext, in: dir)
        }
    }

    private func writeText(_ string: String, id: UUID, ext: String, in dir: URL) -> URL? {
        let url = dir.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try string.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func writeFallbackText(_ string: String, id: UUID, in dir: URL) -> URL? {
        writeText(string, id: id, ext: "txt", in: dir)
    }

    /// Sniff a few magic-byte prefixes to pick a sensible extension — falling
    /// back to .png keeps QL happy since macOS's image previewer will detect
    /// the real format from header bytes anyway. Picking the right extension
    /// just gives QuickLook a hint for the renderer chain.
    private func imageExtension(for data: Data) -> String {
        guard data.count >= 4 else { return "png" }
        let bytes = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        // GIF: 47 49 46 38
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        // HEIC: bytes 4..11 contain "ftypheic" / "ftypheix" / "ftyphevc"
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "heic"
        }
        // WebP: "RIFF....WEBP"
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        // TIFF: II*\0 or MM\0*
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        return "png"
    }

    /// Placeholder preview item used when we can't materialize a real file —
    /// e.g. a deleted file URL. Shows an inline title in the QL panel rather
    /// than throwing.
    private func placeholderItem(title: String) -> QLPreviewItem {
        QuickLookPlaceholder(title: title)
    }
}

/// Trivial in-memory `QLPreviewItem` so the panel can render a title even
/// when no on-disk URL is available.
private final class QuickLookPlaceholder: NSObject, QLPreviewItem {
    let previewItemTitle: String?
    var previewItemURL: URL? { nil }

    init(title: String) {
        self.previewItemTitle = title
    }
}
