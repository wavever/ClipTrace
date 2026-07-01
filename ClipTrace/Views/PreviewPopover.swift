import SwiftUI
import AVKit
import AppKit

struct PreviewPopover: View {
    let item: ClipboardItem
    @AppStorage("videoPreviewMode") private var videoPreviewModeRaw = VideoPreviewMode.video.rawValue
    @AppStorage("videoPreviewMuted") private var videoPreviewMuted = true
    @State private var previewImage: NSImage?
    @State private var didAttemptImageLoad = false

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
    }

    /// Display/egress-safe rendition of the clip. Sensitive spans are masked
    /// before the popover renders or runs its base64/JSON decode helpers, so the
    /// raw value never appears here even though it stays intact in storage.
    private var protectedContent: String {
        item.redactedForDisplay(item.content)
    }

    @ViewBuilder
    private var content: some View {
        switch item.itemType {
        case .text, .url:
            VStack(spacing: 8) {
                ScrollView {
                    Text(protectedContent)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                decodeCard(for: protectedContent)
            }
        case .rtf:
            VStack(spacing: 8) {
                ScrollView {
                    Text(protectedContent)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                decodeCard(for: protectedContent)
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
        // detector (e.g. a Base64 blob of `appkey=…`), so the derived plaintext
        // is run back through redaction before it is rendered.
        let base64 = PreviewPopover.base64Decoded(of: raw).map { item.redactedForDisplay($0) }
        let json = PreviewPopover.prettyJSON(of: raw).map { item.redactedForDisplay($0) }

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
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        guard var str = String(data: pretty, encoding: .utf8) else { return nil }

        if str.count > 600 {
            let idx = str.index(str.startIndex, offsetBy: 600)
            str = String(str[..<idx]) + "\n…"
        }
        return str
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
