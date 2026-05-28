import AppKit
import ImageIO
import QuickLookThumbnailing

/// Generates and caches list thumbnails for clipboard items.
///
/// Lives as an `actor` so callers (the SwiftUI row's `.task`) hop off the main
/// thread automatically — decoding TIFF/PNG data and resizing used to happen
/// on `@MainActor`, which spiked CPU on the main queue during scroll for any
/// row backed by image data.
///
/// The public API takes a `ThumbnailRequest` rather than the SwiftData
/// `ClipboardItem` directly. `@Model` classes aren't `Sendable`; extracting
/// the few fields we need on the caller (still on its model context's actor)
/// keeps decoding off the main thread without violating actor isolation.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    /// Backing cache. `NSCache` is documented thread-safe, so we mark it
    /// `nonisolated(unsafe)` to allow the synchronous `cached(...)` probe
    /// from the main actor without an actor hop.
    nonisolated(unsafe) private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    private init() {}

    private static func cacheKey(_ request: ThumbnailRequest, size: CGSize) -> String {
        "\(request.id.uuidString)_\(Int(size.width))x\(Int(size.height))"
    }

    /// Non-blocking cache probe used by the view to avoid awaiting a Task hop
    /// for already-resolved thumbnails. Safe to call from the main actor.
    nonisolated func cached(_ request: ThumbnailRequest, size: CGSize) -> NSImage? {
        let key = Self.cacheKey(request, size: size)
        return cache.object(forKey: key as NSString)
    }

    func thumbnail(_ request: ThumbnailRequest, size: CGSize) async -> NSImage? {
        let key = Self.cacheKey(request, size: size)
        if let img = cache.object(forKey: key as NSString) { return img }

        if let task = inflight[key] {
            return await task.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            await Self.generate(request: request, size: size)
        }
        inflight[key] = task
        let image = await task.value
        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        inflight[key] = nil
        return image
    }

    /// Decode + resize entirely off the main thread.
    ///
    /// - For raw image bytes (clipboard images, screenshots) we use ImageIO's
    ///   `CGImageSourceCreateThumbnailAtIndex` with a max-pixel-size hint —
    ///   that decodes just enough of the source to fill our target box
    ///   instead of decoding the full image and resampling on the main thread.
    /// - For file URLs we hand off to `QLThumbnailGenerator`, which already
    ///   runs on its own background queue.
    private static func generate(request: ThumbnailRequest, size: CGSize) async -> NSImage? {
        if let data = request.imageData {
            return makeThumbnail(from: data, size: size)
        }

        guard let url = request.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: qlRequest) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    /// ImageIO-backed downsample. Avoids `NSImage.lockFocus()` (which only
    /// works on the main thread) and the full-image decode `NSImage(data:)`
    /// performs internally.
    private static func makeThumbnail(from data: Data, size: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let maxDimension = Int(max(size.width, size.height).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: size)
    }
}

/// Sendable snapshot of the bits of a `ClipboardItem` we need to render a
/// thumbnail. Built on the caller's context (main actor) so the actor below
/// never touches a `@Model` instance directly.
struct ThumbnailRequest: Sendable {
    let id: UUID
    let imageData: Data?
    let fileURL: URL?

    init(item: ClipboardItem) {
        self.id = item.id
        self.imageData = item.imageData
        self.fileURL = item.resolvedFileURL
    }
}
