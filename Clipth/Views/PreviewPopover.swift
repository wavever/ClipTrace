import SwiftUI
import AVKit
import AppKit

struct PreviewPopover: View {
    let item: ClipboardItem
    var allowsOriginalReveal = false
    var onClose: (() -> Void)? = nil
    @AppStorage("videoPreviewMode") private var videoPreviewModeRaw = VideoPreviewMode.video.rawValue
    @AppStorage("videoPreviewMuted") private var videoPreviewMuted = true
    @State private var previewImage: NSImage?
    @State private var didAttemptImageLoad = false
    @State private var revealsOriginal = false

    private var videoPreviewMode: VideoPreviewMode {
        VideoPreviewMode(rawValue: videoPreviewModeRaw) ?? .video
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: item.itemType.icon)
                    .foregroundStyle(.secondary)
                Text(item.itemType.displayName)
                    .font(.headline)
                Spacer()
                Text(item.formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if canRevealOriginal {
                    Label(L("preview.protected"), systemImage: "lock.shield.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            revealsOriginal.toggle()
                        }
                    } label: {
                        Label(
                            revealsOriginal
                                ? L("preview.hideOriginal")
                                : L("preview.revealOriginal"),
                            systemImage: revealsOriginal ? "eye.slash" : "eye"
                        )
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .help(
                        revealsOriginal
                            ? L("preview.hideOriginal.tooltip")
                            : L("preview.revealOriginal.tooltip")
                    )
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(PaperIconButtonStyle(size: 28))
                    .help(L("common.close"))
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
          .frame(minWidth: 360, idealWidth: 460, minHeight: 240, idealHeight: 320)
          .task(id: item.id) {
              await loadPreviewImageIfNeeded()
          }
          .onChange(of: item.id) { _, _ in
              revealsOriginal = false
          }
          // Revealed text is session-only. Switching away from the app hides
          // it before another app or screen-sharing surface becomes active.
          .onReceive(NotificationCenter.default.publisher(
              for: NSApplication.didResignActiveNotification
          )) { _ in
              revealsOriginal = false
          }
    }

    private var protectionResult: ContentProtectionResult {
        item.contentProtectionResult
    }

    /// Original-content disclosure is deliberately limited to the interactive
    /// text preview. Passive dwell previews remain non-interactive and masked,
    /// while file/image/video previews keep their native rendering behavior.
    private var canRevealOriginal: Bool {
        guard allowsOriginalReveal, protectionResult.isProtected else { return false }
        return item.itemType == .text || item.itemType == .url || item.itemType == .rtf
    }

    /// Display/egress-safe by default; the raw value is read directly from the
    /// model only during an explicit, in-memory reveal session.
    private var protectedContent: String {
        protectionResult.redactedText
    }

    private var displayedContent: String {
        canRevealOriginal && revealsOriginal ? item.content : protectedContent
    }

    @ViewBuilder
    private var content: some View {
        switch item.itemType {
        case .text, .url:
            VStack(spacing: 8) {
                ScrollView {
                    Text(displayedContent)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .privacySensitive(revealsOriginal)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                decodeCard(for: displayedContent)
            }
        case .rtf:
            VStack(spacing: 8) {
                ScrollView {
                    Text(displayedContent)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .privacySensitive(revealsOriginal)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                decodeCard(for: displayedContent)
            }
        case .image:
            if let img = previewImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else if !didAttemptImageLoad {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L("preview.cannotImage"), systemImage: "photo.badge.exclamationmark")
            }
        case .video:
            if let url = item.resolvedFileURL, FileManager.default.fileExists(atPath: url.path) {
                switch videoPreviewMode {
                case .firstFrame:
                    VideoPosterPreview(item: item)
                        .padding(8)
                case .video:
                    VideoPreviewPlayer(url: url, muted: videoPreviewMuted)
                        .padding(8)
                }
            } else {
                ContentUnavailableView(L("preview.cannotVideo"), systemImage: "video.badge.exclamationmark")
            }
        case .file:
            VStack(spacing: 12) {
                if let url = item.resolvedFileURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                    Text(url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(item.content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func loadPreviewImageIfNeeded() async {
        guard item.itemType == .image else { return }
        didAttemptImageLoad = false
        previewImage = await ImagePayloadStore.imageAsync(
            for: ImagePayloadStore.reference(for: item)
        )
        didAttemptImageLoad = true
    }

    // MARK: - Decode Card

    @ViewBuilder
    private func decodeCard(for raw: String) -> some View {
        let epoch = PreviewPopover.epochInterpretation(of: raw)
        // Decoding can surface sensitive text that the encoded form hid from the
        // detector (e.g. a Base64 blob of `appkey=…`). Keep derived plaintext
        // masked unless this is the same explicit in-memory reveal session.
        let base64 = PreviewPopover.base64Decoded(of: raw).map {
            revealsOriginal ? $0 : item.redactedForDisplay($0)
        }
        let json = PreviewPopover.prettyJSON(of: raw).map {
            revealsOriginal ? $0 : item.redactedForDisplay($0)
        }

        if epoch != nil || base64 != nil || json != nil {
            VStack(spacing: 8) {
                if let epoch = epoch {
                    detectionCard(icon: "clock", title: L("preview.detection.timestamp")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("preview.utcFormat", epoch.utc))
                            Text(L("preview.localFormat", epoch.local))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let decoded = base64 {
                    detectionCard(icon: "lock.shield", title: L("preview.detection.base64")) {
                        Text(decoded)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let pretty = json {
                    detectionCard(icon: "curlybraces", title: L("preview.detection.json")) {
                        ScrollView {
                            Text(pretty)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func detectionCard<Body: View>(
        icon: String,
        title: String,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            body()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Detectors

    private static func epochInterpretation(of s: String) -> (utc: String, local: String)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count == 10 || trimmed.count == 13 else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Double(trimmed) else { return nil }

        let seconds: TimeInterval = trimmed.count == 13 ? value / 1000.0 : value

        // 1990-01-01 .. 2100-12-31 23:59:59 UTC
        let lower: TimeInterval = 631_152_000     // 1990-01-01
        let upper: TimeInterval = 4_133_980_799   // 2100-12-31
        guard seconds >= lower && seconds <= upper else { return nil }

        let date = Date(timeIntervalSince1970: seconds)

        let utcFormatter = DateFormatter()
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(identifier: "UTC")
        utcFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone.current
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"

        return (utc: utcFormatter.string(from: date), local: localFormatter.string(from: date))
    }

    private static func base64Decoded(of s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }
        guard trimmed.count % 4 == 0 else { return nil }

        // Charset check.
        let allowed: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }

        // Reduce false positives: require at least one non-letter character.
        let hasNonLetter = trimmed.contains { ch in
            ch == "+" || ch == "/" || ch == "=" || ch.isNumber
        }
        guard hasNonLetter else { return nil }

        guard let data = Data(base64Encoded: trimmed) else { return nil }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }

        // Require at least 1 non-control character.
        let hasPrintable = decoded.unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
        guard hasPrintable else { return nil }

        if decoded.count > 280 {
            let idx = decoded.index(decoded.startIndex, offsetBy: 280)
            return String(decoded[..<idx]) + "…"
        }
        return decoded
    }

    private static func prettyJSON(of s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        // Parsed for validity only; formatting below preserves the source tokens.
        guard (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else { return nil }
        var str = reindentedJSON(trimmed)

        if str.count > 600 {
            let idx = str.index(str.startIndex, offsetBy: 600)
            str = String(str[..<idx]) + "\n…"
        }
        return str
    }

    /// Reformat only structural whitespace so JSON previews preserve key order,
    /// slash escaping, and numeric spelling from the user's original text.
    private static func reindentedJSON(_ source: String) -> String {
        let chars = Array(source)
        var output = ""
        output.reserveCapacity(chars.count + chars.count / 3)
        var depth = 0
        var index = 0
        var inString = false
        var escaped = false

        func nextSignificant(after position: Int) -> Int? {
            var next = position + 1
            while next < chars.count,
                  chars[next] == " " || chars[next] == "\n"
                    || chars[next] == "\r" || chars[next] == "\t" {
                next += 1
            }
            return next < chars.count ? next : nil
        }

        func newline(indent: Int) {
            output.append("\n")
            output.append(String(repeating: "  ", count: max(0, indent)))
        }

        while index < chars.count {
            let character = chars[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                let closer: Character = character == "{" ? "}" : "]"
                if let next = nextSignificant(after: index), chars[next] == closer {
                    output.append(closer)
                    index = next
                } else {
                    depth += 1
                    newline(indent: depth)
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline(indent: depth)
                output.append(character)
            case ",":
                output.append(character)
                newline(indent: depth)
            case ":":
                output.append(": ")
            case " ", "\n", "\r", "\t":
                break
            default:
                output.append(character)
            }
            index += 1
        }
        return output
    }
}

private struct VideoPreviewPlayer: NSViewRepresentable {
    let url: URL
    let muted: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, muted: muted)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = context.coordinator.player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        context.coordinator.playWhenReady()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.setMuted(muted)
        let changed = context.coordinator.update(url: url)
        if view.player !== context.coordinator.player {
            view.player = context.coordinator.player
        }
        if changed {
            context.coordinator.playWhenReady()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        nsView.player = nil
    }

    final class Coordinator {
        let player: AVPlayer
        private var currentURL: URL

        init(url: URL, muted: Bool) {
            self.currentURL = url
            self.player = AVPlayer(url: url)
            self.player.isMuted = muted
        }

        func update(url: URL) -> Bool {
            guard url != currentURL else { return false }
            currentURL = url
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            return true
        }

        func playWhenReady() {
            DispatchQueue.main.async { [player] in
                player.play()
            }
        }

        func setMuted(_ muted: Bool) {
            player.isMuted = muted
        }
    }
}

private struct VideoPosterPreview: View {
    let item: ClipboardItem
    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                ContentUnavailableView(L("preview.cannotVideo"), systemImage: "video.badge.exclamationmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            loading = true
            let request = ThumbnailRequest(item: item)
            image = await ThumbnailLoader.shared.thumbnail(
                request,
                size: CGSize(width: 720, height: 420)
            )
            loading = false
        }
    }
}

enum VideoPreviewMode: String, CaseIterable, Identifiable {
    case firstFrame
    case video

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .firstFrame: return L("settings.preview.videoMode.firstFrame")
        case .video:      return L("settings.preview.videoMode.video")
        }
    }

    var icon: String {
        switch self {
        case .firstFrame: return "photo"
        case .video:      return "play.rectangle"
        }
    }
}

// MARK: - Dwell preview (menu-bar panel & Quick Paste panel)

/// Persisted knobs for the dwell-to-preview behavior on the two lightweight
/// panels. One shared store so Settings and both panels observe the same
/// source of truth without threading bindings through the view trees.
@MainActor
final class HoverPreviewSettings: ObservableObject {
    static let shared = HoverPreviewSettings()

    @Published var menuBarEnabled: Bool {
        didSet { UserDefaults.standard.set(menuBarEnabled, forKey: "menuBarHoverPreviewEnabled") }
    }
    @Published var menuBarDelay: Double {
        didSet { UserDefaults.standard.set(menuBarDelay, forKey: "menuBarHoverPreviewDelay") }
    }
    @Published var quickPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(quickPasteEnabled, forKey: "quickPasteHoverPreviewEnabled") }
    }
    @Published var quickPasteDelay: Double {
        didSet { UserDefaults.standard.set(quickPasteDelay, forKey: "quickPasteHoverPreviewDelay") }
    }

    private init() {
        let defaults = UserDefaults.standard
        menuBarEnabled = defaults.object(forKey: "menuBarHoverPreviewEnabled") as? Bool ?? true
        menuBarDelay = defaults.object(forKey: "menuBarHoverPreviewDelay") as? Double ?? 1.0
        quickPasteEnabled = defaults.object(forKey: "quickPasteHoverPreviewEnabled") as? Bool ?? true
        quickPasteDelay = defaults.object(forKey: "quickPasteHoverPreviewDelay") as? Double ?? 1.0
    }
}

/// Which host the preview floats beside. The surface adopts the host's own
/// chrome so the pair reads as one unit: warm paper beside the menu-bar
/// panel, translucent popover material beside the Quick Paste panel.
enum HoverPreviewSurfaceStyle {
    case paper
    case popover

    var cornerRadius: CGFloat {
        switch self {
        case .paper: return 14
        case .popover: return 12   // matches the Quick Paste panel's chrome
        }
    }
}

/// Model behind the floating preview window, so the hosted SwiftUI tree can
/// swap items in place (crossfade) instead of tearing the window down.
@MainActor
private final class HoverPreviewState: ObservableObject {
    @Published var item: ClipboardItem?
    @Published var surfaceStyle: HoverPreviewSurfaceStyle = .paper
}

private struct HoverPreviewSurface: View {
    @ObservedObject var state: HoverPreviewState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: state.surfaceStyle.cornerRadius, style: .continuous)
        ZStack {
            if let item = state.item {
                PreviewPopover(item: item)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .frame(
            width: HoverPreviewController.surfaceSize.width,
            height: HoverPreviewController.surfaceSize.height
        )
        .background(surfaceBackground)
        .overlay(surfaceBorder(shape: shape))
        .clipShape(shape)
        .animation(.easeOut(duration: 0.14), value: state.item?.id)
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        switch state.surfaceStyle {
        case .paper:
            Color.appPaper
        case .popover:
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
        }
    }

    @ViewBuilder
    private func surfaceBorder(shape: RoundedRectangle) -> some View {
        switch state.surfaceStyle {
        case .paper:
            shape.strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        case .popover:
            shape.strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        }
    }
}

/// Drives the dwell-to-preview window for the menu-bar panel and the Quick
/// Paste panel. The window is deliberately *never* key and ignores the mouse:
/// both host panels dismiss themselves on `windowDidResignKey`, so a preview
/// surface that could steal key status would close the very panel it belongs
/// to. It therefore floats beside the host as a purely visual sibling.
@MainActor
final class HoverPreviewController {
    static let shared = HoverPreviewController()
    static let surfaceSize = NSSize(width: 420, height: 340)

    private let state = HoverPreviewState()
    private var panel: NSPanel?
    private var dwellTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    /// Row currently pending or presented; exits for any other row are stale
    /// (row-to-row moves can deliver the old row's exit after the new row's
    /// enter) and must not cancel the fresh dwell timer.
    private var activeItemID: UUID?
    /// Bumped on every present/hide so a fade-out completion from a superseded
    /// hide never orders out a window that has been re-shown meanwhile.
    private var generation = 0
    private weak var hostWindow: NSWindow?
    private var hostResignObserver: NSObjectProtocol?

    private init() {}

    /// Ask for a preview of `item` after `delay`. While a preview is already
    /// on screen the swap happens immediately (QuickLook-style browsing);
    /// otherwise the dwell timer restarts, so sweeping across rows never fires.
    func schedule(
        item: ClipboardItem,
        host: NSWindow?,
        after delay: TimeInterval,
        style: HoverPreviewSurfaceStyle = .paper
    ) {
        graceTask?.cancel()
        graceTask = nil

        // Protected clips stay redacted inside the popover, but auto-popping
        // an enlarged view of masked content still defeats the point of the
        // masking — sensitive rows simply don't auto-preview. Prefix-bounded
        // so a hover never runs the detector over megabytes of text.
        if ContentProtector.redact(String(item.content.prefix(4000))).isProtected {
            let previous = activeItemID
            activeItemID = nil
            dwellTask?.cancel()
            dwellTask = nil
            if previous != nil { beginGraceHide() }
            return
        }

        activeItemID = item.id
        if isPresented {
            dwellTask?.cancel()
            dwellTask = nil
            present(item: item, host: host, style: style)
            return
        }

        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.present(item: item, host: host, style: style)
        }
    }

    /// Hover/focus left `itemID` without landing on another row. Ignored when
    /// a newer row already took over; otherwise the pending timer dies and a
    /// visible preview fades after a short grace (which absorbs the hover gap
    /// between adjacent rows without flickering the window off and on).
    func noteExit(itemID: UUID) {
        guard activeItemID == itemID else { return }
        activeItemID = nil
        dwellTask?.cancel()
        dwellTask = nil
        beginGraceHide()
    }

    /// Immediate dismissal — host panel is closing or committing.
    func hide() {
        dwellTask?.cancel()
        dwellTask = nil
        graceTask?.cancel()
        graceTask = nil
        activeItemID = nil
        fadeOut()
    }

    private var isPresented: Bool {
        panel?.isVisible == true && state.item != nil
    }

    private func beginGraceHide() {
        guard isPresented else { return }
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func present(item: ClipboardItem, host: NSWindow?, style: HoverPreviewSurfaceStyle) {
        guard let host, host.isVisible else { return }
        let panel = preparePanel()
        attachHostObserver(to: host)
        generation &+= 1

        let alreadyShowing = isPresented
        state.surfaceStyle = style
        state.item = item
        position(panel, beside: host)

        if !alreadyShowing {
            panel.alphaValue = 0
            panel.level = host.level
            panel.order(.above, relativeTo: host.windowNumber)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else {
            state.item = nil
            return
        }
        generation &+= 1
        let expected = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == expected else { return }
                self.panel?.orderOut(nil)
                self.state.item = nil
                self.detachHostObserver()
            }
        })
    }

    /// Anchor beside the host panel: to its right when the screen has room,
    /// flipped to the left otherwise, vertically centered and clamped so the
    /// window never spills off the visible frame.
    private func position(_ panel: NSPanel, beside host: NSWindow) {
        let size = Self.surfaceSize
        let hostFrame = host.frame
        let visible = (host.screen ?? NSScreen.main)?.visibleFrame ?? hostFrame
        let gap: CGFloat = 10

        var x = hostFrame.maxX + gap
        if x + size.width > visible.maxX {
            x = hostFrame.minX - size.width - gap
        }
        x = min(max(visible.minX, x), visible.maxX - size.width)

        var y = hostFrame.midY - size.height / 2
        y = min(max(visible.minY, y), visible.maxY - size.height)

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Built once and reused (same rationale as the Quick Paste panel: a fresh
    /// hosting tree per dwell would make the first preview feel sluggish).
    private func preparePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingController(rootView: HoverPreviewSurface(state: state))
        hosting.view.wantsLayer = true

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.surfaceSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // The whole point: a borderless NSPanel reports canBecomeKey == false
        // (we do NOT use KeyablePanel here), and ignoring the mouse means the
        // host panel keeps hover/keyboard even if the preview overlaps it.
        panel.ignoresMouseEvents = true
        panel.contentViewController = hosting
        self.panel = panel
        return panel
    }

    /// The host panels close on losing key status; the preview must never
    /// outlive them, even when no explicit hide() call reaches us (e.g. the
    /// menu-bar window closing itself on a click elsewhere).
    private func attachHostObserver(to host: NSWindow) {
        guard hostWindow !== host else { return }
        detachHostObserver()
        hostWindow = host
        hostResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: host,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func detachHostObserver() {
        if let hostResignObserver {
            NotificationCenter.default.removeObserver(hostResignObserver)
        }
        hostResignObserver = nil
        hostWindow = nil
    }
}
