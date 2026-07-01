import AppKit
import UniformTypeIdentifiers

struct ExportFilter: Equatable {
    enum FavoriteScope: String, CaseIterable, Identifiable {
        case all
        case favoritesOnly
        case pinnedOnly
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return L("export.favoriteScope.all")
            case .favoritesOnly: return L("export.favoriteScope.favorites")
            case .pinnedOnly: return L("export.favoriteScope.pinned")
            }
        }
    }

    enum DateRange: String, CaseIterable, Identifiable {
        case allTime
        case today
        case last7Days
        case last30Days
        case custom
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .allTime: return L("export.range.allTime")
            case .today: return L("export.range.today")
            case .last7Days: return L("export.range.last7")
            case .last30Days: return L("export.range.last30")
            case .custom: return L("export.range.custom")
            }
        }
    }

    var types: Set<ClipboardItemType> = Set(ClipboardItemType.allCases)
    var favoriteScope: FavoriteScope = .all
    var dateRange: DateRange = .allTime
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var customEnd: Date = Date()
    var includeImageData = false

    func apply(to items: [ClipboardItem]) -> [ClipboardItem] {
        var result = items.filter { types.contains($0.itemType) }

        switch favoriteScope {
        case .all: break
        case .favoritesOnly: result = result.filter { $0.isFavorite }
        case .pinnedOnly: result = result.filter { $0.isPinned }
        }

        if let interval = resolvedInterval {
            result = result.filter { interval.contains($0.createdAt) }
        }

        return result
    }

    var resolvedInterval: DateInterval? {
        let now = Date()
        let cal = Calendar.current
        switch dateRange {
        case .allTime: return nil
        case .today:
            let start = cal.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .last7Days:
            let start = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .last30Days:
            let start = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .custom:
            let s = min(customStart, customEnd)
            let e = max(customStart, customEnd)
            return DateInterval(start: s, end: e)
        }
    }
}

class ExportService {
    static let shared = ExportService()
    
    @discardableResult
    func exportItem(_ item: ClipboardItem, to directory: URL? = nil) -> URL? {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        
        switch item.itemType {
        case .text, .rtf, .url:
            savePanel.allowedContentTypes = [.plainText]
            savePanel.nameFieldStringValue = "clipboard_\(item.id.uuidString.prefix(8)).txt"
         case .image:
             let imageType = Self.imageExportType(for: item)
             let ext = imageType.preferredFilenameExtension ?? "png"
             savePanel.allowedContentTypes = [imageType]
             savePanel.nameFieldStringValue = "clipboard_\(item.id.uuidString.prefix(8)).\(ext)"
        case .video:
            savePanel.allowedContentTypes = [.movie]
            savePanel.nameFieldStringValue = "clipboard_\(item.id.uuidString.prefix(8)).mp4"
        case .file:
            savePanel.allowedContentTypes = [.data]
            savePanel.nameFieldStringValue = "clipboard_\(item.id.uuidString.prefix(8))"
        }
        
        guard let directory = directory else {
            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    self.writeItem(item, to: url)
                }
            }
            return nil
        }
        
        let filename = savePanel.nameFieldStringValue
        let url = directory.appendingPathComponent(filename)
        return writeItem(item, to: url) ? url : nil
    }
    
    func exportBatch(_ items: [ClipboardItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("export.batchPanel.prompt")
        
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            for item in items {
                _ = self.exportItem(item, to: directory)
            }
        }
    }
    
    /// Build a JSON file from `items` filtered by `filter` and prompt the user
    /// to pick a destination. Returns the chosen URL once the file is written,
    /// or nil if the user cancelled / the write failed.
    func exportToJSON(items: [ClipboardItem], filter: ExportFilter, completion: @escaping (Result<URL, Error>?) -> Void) {
        let filtered = filter.apply(to: items)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        let stamp = Self.filenameDateFormatter.string(from: Date())
        panel.nameFieldStringValue = "clipboard_export_\(stamp).json"
        panel.title = L("export.savePanel.title")

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            do {
                let payload = Self.makePayload(items: filtered, includeImageData: filter.includeImageData)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(payload)
                try data.write(to: url, options: [.atomic])
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func makePayload(items: [ClipboardItem], includeImageData: Bool) -> ExportPayload {
        // Egress guardrail: protected clips export their redacted value plus
        // `isProtected`/`protectedCategories` metadata by default. Raw protected
        // content leaves only when the user has explicitly opted in.
        let settings = ContentProtectionSettings.current()
        let mapped = items.map { item -> ExportItemDTO in
            let protection = ContentProtector.redact(item.content, settings: settings)
            let useRaw = settings.allowRawExport || !protection.isProtected
            let content = useRaw ? item.content : protection.redactedText
            let preview = item.preview.map { raw in
                useRaw ? raw : ContentProtector.redact(raw, settings: settings).redactedText
            }
            return ExportItemDTO(
                id: item.id.uuidString,
                type: item.type,
                content: content,
                preview: preview,
                sourceApp: item.sourceApp.isEmpty ? nil : item.sourceApp,
                fileURL: item.fileURL,
                createdAt: item.createdAt,
                isFavorite: item.isFavorite,
                isPinned: item.isPinned,
                 imageDataBase64: includeImageData
                    ? ImagePayloadStore.payload(for: ImagePayloadStore.reference(for: item))?.data.base64EncodedString()
                    : nil,
                isProtected: protection.isProtected ? true : nil,
                protectedCategories: protection.isProtected
                    ? protection.categories.map(\.rawValue).sorted()
                    : nil
            )
        }
        return ExportPayload(
            exportedAt: Date(),
            count: mapped.count,
            items: mapped
        )
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func imageExportType(for item: ClipboardItem) -> UTType {
        if let payload = ImagePayloadStore.payload(for: ImagePayloadStore.reference(for: item)),
           let type = UTType(payload.uti) {
            return type
        }
        if let type = item.imageUTI.flatMap(UTType.init) {
            return type
        }
        if let sourceURL = item.resolvedFileURL,
           let type = UTType(filenameExtension: sourceURL.pathExtension) {
            return type
        }
        return .png
    }

    @discardableResult
    private func writeItem(_ item: ClipboardItem, to url: URL) -> Bool {
        do {
            switch item.itemType {
            case .text, .rtf, .url:
                // Default to the redacted rendition unless the user opted into
                // raw protected export; the stored clip itself is unchanged.
                let settings = ContentProtectionSettings.current()
                let protection = ContentProtector.redact(item.content, settings: settings)
                let output = (settings.allowRawExport || !protection.isProtected)
                    ? item.content
                    : protection.redactedText
                try output.write(to: url, atomically: true, encoding: .utf8)
             case .image:
                 if let payload = ImagePayloadStore.payload(for: ImagePayloadStore.reference(for: item)) {
                     try payload.data.write(to: url)
                 } else if let sourceURL = item.resolvedFileURL {
                     if FileManager.default.fileExists(atPath: url.path) {
                         try FileManager.default.removeItem(at: url)
                     }
                     try FileManager.default.copyItem(at: sourceURL, to: url)
                 } else {
                     return false
                 }
            case .video, .file:
                if let path = item.fileURL, let sourceURL = URL(string: path) {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                    try fileManager.copyItem(at: sourceURL, to: url)
                } else {
                    try item.content.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            return true
        } catch {
            print("Export failed: \(error)")
            return false
        }
    }
}

// MARK: - JSON DTOs

private struct ExportPayload: Encodable {
    let exportedAt: Date
    let count: Int
    let items: [ExportItemDTO]
}

private struct ExportItemDTO: Encodable {
    let id: String
    let type: String
    let content: String
    let preview: String?
    let sourceApp: String?
    let fileURL: String?
    let createdAt: Date
    let isFavorite: Bool
    let isPinned: Bool
    let imageDataBase64: String?
    /// Present (and `true`) only for protected clips, so consumers can tell a
    /// redacted value apart from a clip that simply contained asterisks.
    let isProtected: Bool?
    let protectedCategories: [String]?
}
