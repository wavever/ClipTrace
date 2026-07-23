import AppKit

enum ImageStitcher {
    /// Stack images along the chosen axis, with `spacing` pixels between each
    /// pair. Returns compressed image data sized to fit every input at its native pixel
    /// dimensions; the bounding axis uses the largest input on that axis.
    static func stitch(
        _ images: [NSImage],
        direction: ImageMergeDirection,
        spacing: CGFloat,
        background: NSColor
    ) -> Data? {
        guard !images.isEmpty else { return nil }

        let sizes = images.map { $0.size }
        let gap = max(0, spacing) * CGFloat(max(0, images.count - 1))

        let totalWidth: CGFloat
        let totalHeight: CGFloat
        switch direction {
        case .vertical:
            totalWidth = sizes.map(\.width).max() ?? 0
            totalHeight = sizes.map(\.height).reduce(0, +) + gap
        case .horizontal:
            totalWidth = sizes.map(\.width).reduce(0, +) + gap
            totalHeight = sizes.map(\.height).max() ?? 0
        }
        guard totalWidth > 0, totalHeight > 0 else { return nil }

        // Render into an NSBitmapImageRep so the output preserves the source
        // pixel dimensions (NSImage.lockFocus is point-based and downsamples
        // Retina captures).
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(totalWidth)),
            pixelsHigh: Int(ceil(totalHeight)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }
        rep.size = NSSize(width: totalWidth, height: totalHeight)

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        background.setFill()
        NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight).fill()

        // NSImage's coordinate space is bottom-left origin. Drawing top-to-bottom
        // for vertical stacks means accumulating offsets from the top.
        var offset: CGFloat = 0
        for image in images {
            let size = image.size
            switch direction {
            case .vertical:
                let x = (totalWidth - size.width) / 2
                let y = totalHeight - offset - size.height
                image.draw(
                    in: NSRect(x: x, y: y, width: size.width, height: size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                offset += size.height + max(0, spacing)
            case .horizontal:
                let y = (totalHeight - size.height) / 2
                image.draw(
                    in: NSRect(x: offset, y: y, width: size.width, height: size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                offset += size.width + max(0, spacing)
            }
        }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Resolve the actual image bytes for a clip through a short-lived context,
    /// falling back to disk for file-backed image clips.
    static func imageFromItem(_ item: ClipboardItem) -> NSImage? {
        ImagePayloadStore.image(for: ImagePayloadStore.reference(for: item))
    }
}
