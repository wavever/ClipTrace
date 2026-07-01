import SwiftUI
import AppKit

struct ThumbnailView: View {
    let item: ClipboardItem
    let size: CGFloat
    let cornerRadius: CGFloat
    /// When set, overrides the per-type placeholder tint for both the glyph and
    /// its background. The menu bar passes `.primary` so the icon matches the
    /// row's text and stays legible on its translucent dark backdrop, where the
    /// muted per-type colors wash out.
    let placeholderTint: Color?

    @State private var image: NSImage?
    @State private var didAttemptLoad = false

    init(item: ClipboardItem, size: CGFloat = 36, cornerRadius: CGFloat = 6, placeholderTint: Color? = nil) {
        self.item = item
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholderTint = placeholderTint
    }

    // Per-type warm muted palette. Replaces the previous saturated system
    // colors (.blue / .green / .purple / .orange / .cyan / .pink) — those
    // read as "AI tech" next to the sage accent. Each entry ships a light
    // and dark variant so contrast holds in both schemes.
    //
    // Shared as a static lookup so we don't allocate a fresh dynamic NSColor
    // per row on every body re-evaluation (which used to fire on every
    // hover / scroll tick for hundreds of rows).
    private var iconColor: Color {
        placeholderTint ?? Self.iconColors[item.itemType] ?? Self.iconColors[.text]!
    }

    private static let iconColors: [ClipboardItemType: Color] = [
        .text:  dynamicColor(light: NSColor(srgbRed: 0.44, green: 0.55, blue: 0.65, alpha: 1),
                             dark:  NSColor(srgbRed: 0.58, green: 0.67, blue: 0.75, alpha: 1)),
        .image: dynamicColor(light: NSColor(srgbRed: 0.55, green: 0.62, blue: 0.37, alpha: 1),
                             dark:  NSColor(srgbRed: 0.68, green: 0.75, blue: 0.47, alpha: 1)),
        .video: dynamicColor(light: NSColor(srgbRed: 0.55, green: 0.48, blue: 0.67, alpha: 1),
                             dark:  NSColor(srgbRed: 0.66, green: 0.61, blue: 0.77, alpha: 1)),
        .file:  dynamicColor(light: NSColor(srgbRed: 0.75, green: 0.47, blue: 0.35, alpha: 1),
                             dark:  NSColor(srgbRed: 0.83, green: 0.57, blue: 0.46, alpha: 1)),
        .url:   dynamicColor(light: NSColor(srgbRed: 0.36, green: 0.60, blue: 0.60, alpha: 1),
                             dark:  NSColor(srgbRed: 0.48, green: 0.70, blue: 0.70, alpha: 1)),
        .rtf:   dynamicColor(light: NSColor(srgbRed: 0.69, green: 0.47, blue: 0.47, alpha: 1),
                             dark:  NSColor(srgbRed: 0.77, green: 0.58, blue: 0.58, alpha: 1)),
    ]

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }

    private var canHaveThumbnail: Bool {
        switch item.itemType {
        case .image, .video, .file:
            return item.hasImagePayload || item.resolvedFileURL != nil
        case .text, .url, .rtf:
            return false
        }
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: item.itemType.icon)
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(iconColor)
                    }
            }
        }
        .task(id: item.id) {
            guard !didAttemptLoad, canHaveThumbnail else { return }
            didAttemptLoad = true
            let target = CGSize(width: size * 2, height: size * 2)
            // Build the Sendable snapshot on the main actor where the SwiftData
            // model is safe to touch, then hand off to the loader's actor for
            // decode/resize.
            let request = ThumbnailRequest(item: item)
            if let cached = ThumbnailLoader.shared.cached(request, size: target) {
                image = cached
                return
            }
            image = await ThumbnailLoader.shared.thumbnail(request, size: target)
        }
    }
}
