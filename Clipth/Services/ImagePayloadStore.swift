import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers

enum ImagePayloadStore {
    struct Payload: Sendable {
        let data: Data
        let uti: String
        let pixelWidth: Int?
        let pixelHeight: Int?

        var byteCount: Int { data.count }
    }

    struct Reference: Sendable {
        let id: UUID
        let fileURL: URL?
        let hasEmbeddedData: Bool
    }

    static let storageVersion = 2
    static let maxStoredImageEdge = 4_096
    static let maxStoredImageBytes = 12 * 1024 * 1024

    private static let pasteboardImageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
        .tiff
    ]

    static func reference(for item: ClipboardItem) -> Reference {
        Reference(
            id: item.id,
            fileURL: item.resolvedFileURL,
            hasEmbeddedData: item.hasStoredImageData
        )
    }

    /// Raw image datas on the pasteboard, in preference order. Reading
    /// `data(forType:)` only copies bytes, so this is safe inside the poll
    /// tick (where the pasteboard is coherent); the potentially expensive
    /// decode + re-encode in `normalizedPayload` can then run off the main
    /// thread against the captured bytes.
    static func rawPasteboardImageCandidates(from pasteboard: NSPasteboard) -> [(data: Data, uti: String)] {
        var candidates: [(data: Data, uti: String)] = []
        for type in pasteboardImageTypes {
            if let data = pasteboard.data(forType: type) {
                candidates.append((data: data, uti: type.rawValue))
            }
        }
        return candidates
    }

    /// First candidate that survives normalization — the same type-by-type
    /// fallthrough the synchronous pasteboard path used to do.
    static func normalizedPayload(fromCandidates candidates: [(data: Data, uti: String)]) -> Payload? {
        for candidate in candidates {
            if let payload = normalizedPayload(from: candidate.data, preferredUTI: candidate.uti) {
                return payload
            }
        }
        return nil
    }

    static func normalizedPayload(from data: Data, preferredUTI: String? = nil) -> Payload? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }

            let metadata = imageMetadata(source: source)
            let detectedUTI = preferredUTI ?? detectUTI(data: data, source: source)
            if canStoreOriginal(data: data, uti: detectedUTI, metadata: metadata) {
                return Payload(
                    data: data,
                    uti: detectedUTI ?? UTType.png.identifier,
                    pixelWidth: metadata.width,
                    pixelHeight: metadata.height
                )
            }

            return encodeNormalized(source: source, metadata: metadata)
        }
    }

    static func normalizedPayload(from image: NSImage) -> Payload? {
        autoreleasepool {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let maxEdge = max(cgImage.width, cgImage.height)
            if maxEdge <= maxStoredImageEdge {
                return encodePNG(cgImage: cgImage)
            }
            return encodeDownsampled(cgImage: cgImage, maxPixelSize: maxStoredImageEdge)
        }
    }

    static func payload(for id: UUID) -> Payload? {
        autoreleasepool {
            let context = ModelContext(AppContainer.shared)
            let targetID = id
            var descriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.id == targetID }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [
                \.id,
                \.imageData,
                \.imageUTI,
                \.imageByteCount,
                \.imagePixelWidth,
                \.imagePixelHeight
            ]

            guard let item = try? context.fetch(descriptor).first,
                  let data = item.imageData else {
                return nil
            }
            return Payload(
                data: data,
                uti: item.imageUTI ?? detectUTI(data: data, source: nil) ?? UTType.png.identifier,
                pixelWidth: item.imagePixelWidth,
                pixelHeight: item.imagePixelHeight
            )
        }
    }

    static func payload(for reference: Reference) -> Payload? {
        guard reference.hasEmbeddedData else { return nil }
        return payload(for: reference.id)
    }

    static func payloadAsync(for reference: Reference) async -> Payload? {
        await Task.detached(priority: .utility) {
            payload(for: reference)
        }.value
    }

    static func image(for reference: Reference) -> NSImage? {
        if let payload = payload(for: reference),
           let image = NSImage(data: payload.data) {
            return image
        }
        if let url = reference.fileURL {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    static func imageAsync(for reference: Reference) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            image(for: reference)
        }.value
    }

    @discardableResult
    static func write(_ payload: Payload, to pasteboard: NSPasteboard) -> Bool {
        let wroteNative = pasteboard.setData(
            payload.data,
            forType: NSPasteboard.PasteboardType(payload.uti)
        )
        guard shouldAddPasteboardCompatibilityFlavor(for: payload.uti),
              let tiffData = compatiblePasteboardTIFFData(from: payload.data) else {
            return wroteNative
        }
        let wroteCompatible = pasteboard.setData(tiffData, forType: .tiff)
        return wroteNative || wroteCompatible
    }

    @discardableResult
    static func writeImage(for reference: Reference, to pasteboard: NSPasteboard) -> Bool {
        if let payload = payload(for: reference) {
            return write(payload, to: pasteboard)
        }
        if let url = reference.fileURL {
            return pasteboard.writeObjects([url as NSURL])
        }
        return false
    }

    static func applyMetadata(from payload: Payload, to item: ClipboardItem) {
        item.imageUTI = payload.uti
        item.imageByteCount = payload.byteCount
        item.imagePixelWidth = payload.pixelWidth
        item.imagePixelHeight = payload.pixelHeight
        item.imageStorageVersion = storageVersion
    }

    @MainActor
    static func migrateStoredImagesInBackground(context: ModelContext) {
        Task { @MainActor in
            while !Task.isCancelled {
                let migrated = migrateBatch(in: context)
                if migrated == 0 { break }
                await Task.yield()
            }
        }
    }

    @MainActor
    private static func migrateBatch(in context: ModelContext, limit: Int = 4) -> Int {
        autoreleasepool {
            let imageType = ClipboardItemType.image.rawValue
            let version = storageVersion
            var descriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate {
                    $0.type == imageType
                    && $0.imageData != nil
                    && ($0.imageStorageVersion == nil || $0.imageStorageVersion != version)
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            descriptor.propertiesToFetch = [
                \.id,
                \.type,
                \.imageData,
                \.imageUTI,
                \.imageByteCount,
                \.imagePixelWidth,
                \.imagePixelHeight,
                \.imageStorageVersion
            ]

            guard let items = try? context.fetch(descriptor), !items.isEmpty else {
                return 0
            }

            for item in items {
                guard let data = item.imageData else {
                    item.imageStorageVersion = storageVersion
                    continue
                }
                guard let payload = normalizedPayload(from: data, preferredUTI: item.imageUTI) else {
                    item.imageByteCount = data.count
                    item.imageStorageVersion = storageVersion
                    continue
                }
                item.imageData = payload.data
                applyMetadata(from: payload, to: item)
            }
            try? context.save()
            return items.count
        }
    }

    private static func canStoreOriginal(
        data: Data,
        uti: String?,
        metadata: (width: Int?, height: Int?)
    ) -> Bool {
        guard let uti else { return false }
        guard uti != UTType.tiff.identifier else { return false }
        guard data.count <= maxStoredImageBytes else { return false }
        let maxEdge = max(metadata.width ?? 0, metadata.height ?? 0)
        guard maxEdge == 0 || maxEdge <= maxStoredImageEdge else { return false }
        return true
    }

    private static func shouldAddPasteboardCompatibilityFlavor(for uti: String) -> Bool {
        guard let type = UTType(uti) else { return true }
        return type != .png && type != .jpeg && type != .tiff
    }

    private static func compatiblePasteboardTIFFData(from data: Data) -> Data? {
        autoreleasepool {
            NSImage(data: data)?.tiffRepresentation
        }
    }

    private static func encodeNormalized(
        source: CGImageSource,
        metadata: (width: Int?, height: Int?)
    ) -> Payload? {
        let maxEdge = max(metadata.width ?? 0, metadata.height ?? 0)
        if maxEdge > maxStoredImageEdge {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxStoredImageEdge
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return encodePNG(cgImage: cgImage)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: false] as CFDictionary
        ) else {
            return nil
        }
        return encodePNG(cgImage: cgImage)
    }

    private static func encodeDownsampled(cgImage: CGImage, maxPixelSize: Int) -> Payload? {
        let ratio = Double(maxPixelSize) / Double(max(cgImage.width, cgImage.height))
        let width = max(1, Int(Double(cgImage.width) * ratio))
        let height = max(1, Int(Double(cgImage.height) * ratio))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return encodePNG(cgImage: scaled)
    }

    private static func encodePNG(cgImage: CGImage) -> Payload? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        if data.count <= maxStoredImageBytes || max(cgImage.width, cgImage.height) <= 1_024 {
            return Payload(
                data: data,
                uti: UTType.png.identifier,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height
            )
        }

        let nextEdge = max(1_024, Int(Double(max(cgImage.width, cgImage.height)) * 0.75))
        if nextEdge < max(cgImage.width, cgImage.height) {
            return encodeDownsampled(cgImage: cgImage, maxPixelSize: nextEdge)
        }
        return Payload(
            data: data,
            uti: UTType.png.identifier,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
    }

    private static func imageMetadata(source: CGImageSource) -> (width: Int?, height: Int?) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return (
            props[kCGImagePropertyPixelWidth] as? Int,
            props[kCGImagePropertyPixelHeight] as? Int
        )
    }

    static func detectUTI(data: Data, source: CGImageSource?) -> String? {
        if let source,
           let type = CGImageSourceGetType(source) as String? {
            return type
        }

        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return UTType.png.identifier }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return UTType.jpeg.identifier }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return UTType.gif.identifier }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return UTType.tiff.identifier
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "public.heic"
        }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "org.webmproject.webp"
        }
        return nil
    }
}
