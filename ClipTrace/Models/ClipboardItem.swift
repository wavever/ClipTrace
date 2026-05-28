import Foundation
import SwiftData
import UniformTypeIdentifiers

enum ClipboardItemType: String, Codable, CaseIterable {
    case text = "text"
    case image = "image"
    case video = "video"
    case file = "file"
    case url = "url"
    case rtf = "rtf"
    
    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .video: return "video"
        case .file: return "folder"
        case .url: return "link"
        case .rtf: return "doc.richtext"
        }
    }
    
    var displayName: String {
        switch self {
        case .text: return L("type.text")
        case .image: return L("type.image")
        case .video: return L("type.video")
        case .file: return L("type.file")
        case .url: return L("type.url")
        case .rtf: return L("type.rtf")
        }
    }
}

@Model
final class ClipboardItem {
    var id: UUID
    var type: String // ClipboardItemType raw value
    var content: String // text content or file path
    var imageData: Data?
    var fileURL: String?
    var sourceApp: String
    var createdAt: Date
    var isFavorite: Bool
    var isPinned: Bool
    var preview: String?
    var embedding: Data?
    var embeddingLang: String?
    /// Soft-delete marker. Nil means the entry is alive in history; a date
    /// means the user deleted it on that date and it's currently in trash.
    var deletedAt: Date?
    /// User-defined labels. Stored as a newline-joined string for SwiftData
    /// portability — accessed via `tags` / `setTags(_:)` below.
    var tagsRaw: String?
    /// User-assigned label that overrides the auto-derived row title. Lets
    /// long URLs / tokens be made recognisable at a glance. Nil means
    /// "use the default heuristic" (see `effectiveTitle`).
    var customTitle: String?
    /// Recognised text for image items, populated by an async OCR pass after
    /// the clip is inserted. Nil for non-image clips or while recognition is
    /// still pending; an empty string means OCR ran but found nothing.
    var ocrText: String?

    init(type: ClipboardItemType, content: String, imageData: Data? = nil, fileURL: String? = nil, sourceApp: String = "", preview: String? = nil) {
        self.id = UUID()
        self.type = type.rawValue
        self.content = content
        self.imageData = imageData
        self.fileURL = fileURL
        self.sourceApp = sourceApp
        self.createdAt = Date()
        self.isFavorite = false
        self.isPinned = false
        self.preview = preview
        self.embedding = nil
        self.embeddingLang = nil
        self.deletedAt = nil
        self.tagsRaw = nil
        self.customTitle = nil
        self.ocrText = nil
    }

    /// Trimmed custom title, or nil if the user hasn't set one. Used by row
    /// views as the highest-priority title source.
    var effectiveCustomTitle: String? {
        guard let raw = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    var tags: [String] {
        guard let raw = tagsRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").map(String.init)
    }

    func setTags(_ newTags: [String]) {
        // Normalize: trim, drop empties, dedupe (case-insensitive), cap length.
        var seen = Set<String>()
        let cleaned: [String] = newTags.compactMap { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            if seen.contains(key) { return nil }
            seen.insert(key)
            return String(trimmed.prefix(32))
        }
        tagsRaw = cleaned.isEmpty ? nil : cleaned.joined(separator: "\n")
    }
    
    var itemType: ClipboardItemType {
        ClipboardItemType(rawValue: type) ?? .text
    }
    
    var resolvedFileURL: URL? {
        if let raw = fileURL, !raw.isEmpty {
            if raw.hasPrefix("file://"), let url = URL(string: raw) {
                return url
            }
            return URL(fileURLWithPath: raw)
        }
        let firstLine = content.split(separator: "\n").first.map(String.init) ?? content
        guard !firstLine.isEmpty else { return nil }
        if firstLine.hasPrefix("file://"), let url = URL(string: firstLine) {
            return url
        }
        if firstLine.hasPrefix("/") {
            return URL(fileURLWithPath: firstLine)
        }
        return nil
    }

    /// Human-friendly tag shown in the list row, e.g. "音频文件"、"软件包"、"文本".
    /// Falls back to the broad displayName when no file URL is available.
    var descriptiveTag: String {
        switch itemType {
        case .text: return L("type.text")
        case .url: return L("type.url")
        case .rtf: return L("type.rtf")
        case .image, .video, .file:
            if let url = resolvedFileURL {
                return Self.descriptiveTag(forFileURL: url)
            }
            switch itemType {
            case .image: return L("type.image")
            case .video: return L("type.video")
            default: return L("type.file")
            }
        }
    }

    private static func descriptiveTag(forFileURL url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        // Bundle/installer extensions where macOS would otherwise just label these as directories
        switch ext {
        case "app": return L("tag.application")
        case "pkg", "mpkg": return L("tag.installer")
        case "dmg": return L("tag.dmg")
        case "ipa": return L("tag.ipa")
        default: break
        }

        // Detect directory before falling back to extension lookup
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            return L("tag.folder")
        }

        guard let type = UTType(filenameExtension: ext) else { return L("type.file") }

        if type.conforms(to: .audio) { return L("tag.audio") }
        if type.conforms(to: .movie) { return L("tag.video") }
        if type.conforms(to: .image) { return L("tag.image") }
        if type.conforms(to: .pdf) { return L("tag.pdf") }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return L("tag.archive") }
        if type.conforms(to: .sourceCode) { return L("tag.sourceCode") }
        if type.conforms(to: .spreadsheet) { return L("tag.spreadsheet") }
        if type.conforms(to: .presentation) { return L("tag.presentation") }
        if type.conforms(to: .html) { return L("tag.html") }
        if type.conforms(to: .json) { return L("tag.json") }
        if type.conforms(to: .xml) { return L("tag.xml") }
        if type.conforms(to: .rtf) { return L("tag.rtfFile") }
        if type.conforms(to: .plainText) || type.conforms(to: .text) { return L("tag.plainText") }
        if type.conforms(to: .applicationBundle) { return L("tag.application") }
        if type.conforms(to: .application) { return L("tag.bundle") }
        if type.conforms(to: .folder) { return L("tag.folder") }

        return type.localizedDescription ?? L("type.file")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    var formattedDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) {
            return L("common.today") + " " + Self.timeFormatter.string(from: createdAt)
        } else if calendar.isDateInYesterday(createdAt) {
            return L("common.yesterday") + " " + Self.timeFormatter.string(from: createdAt)
        } else {
            return Self.dateTimeFormatter.string(from: createdAt)
        }
    }
}
