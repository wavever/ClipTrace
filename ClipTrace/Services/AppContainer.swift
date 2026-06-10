import Foundation
import SQLite3
import SwiftData

/// Shared SwiftData container used by every app entry point.
///
/// Earlier builds relied on SwiftData's default location, which can resolve to
/// different Application Support roots across launch modes and OS releases.
/// Keep the history database at a stable app-owned URL and recover the old
/// default stores before opening the container.
enum AppContainer {
    private static let folderName = "ClipTrace"
    private static let storeFileName = "default.store"
    private static let backupFolderName = "StoreBackups"
    private static let legacyProjectFolderName = "ClipBoardManager"
    private static let bundleFolderName = "com.wavever.cliptrace"
    private static let sidecarSuffixes = ["", "-wal", "-shm"]

    static let shared: ModelContainer = {
        do {
            return try makeContainer()
        } catch {
            fatalError("Failed to open ModelContainer: \(error)")
        }
    }()

    static func makeContainer() throws -> ModelContainer {
        try recoverLegacyStoreIfNeeded()

        let schema = Schema([ClipboardItem.self])
        let configuration = ModelConfiguration(
            "ClipTrace",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        mergeLegacyStoresIfNeeded(into: container)
        return container
    }

    static var storeURL: URL {
        applicationSupportDirectory.appendingPathComponent(storeFileName)
    }

    private static var applicationSupportDirectory: URL {
        applicationSupportRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    private static var applicationSupportRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static var homeApplicationSupportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func recoverLegacyStoreIfNeeded() throws {
        let fileManager = FileManager.default
        let destination = storeURL
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let destinationCount = clipboardItemCount(at: destination)
        if let destinationCount, destinationCount > 0 {
            return
        }

        guard let source = bestLegacyStore(excluding: destination) else {
            return
        }

        if source.count <= (destinationCount ?? 0) {
            return
        }

        try backupExistingStoreIfNeeded(at: destination)
        try copyStore(from: source.url, to: destination)

        NSLog(
            "ClipTrace recovered %d clipboard history rows from legacy SwiftData store %@ into %@",
            source.count,
            source.url.path,
            destination.path
        )
    }

    private static func mergeLegacyStoresIfNeeded(into container: ModelContainer) {
        let sources = legacyStoreCandidates(excluding: storeURL)
            .compactMap { url -> (url: URL, count: Int)? in
                guard let count = clipboardItemCount(at: url), count > 0 else { return nil }
                return (url, count)
            }
            .sorted { lhs, rhs in lhs.count > rhs.count }
        guard !sources.isEmpty else { return }

        do {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<ClipboardItem>()
            descriptor.propertiesToFetch = [\.id]
            var knownIDs = Set(try context.fetch(descriptor).map(\.id))
            var totalImported = 0

            for source in sources {
                totalImported += try importMissingClipboardItems(
                    from: source.url,
                    into: context,
                    knownIDs: &knownIDs
                )
            }

            if totalImported > 0 {
                try context.save()
                NSLog("ClipTrace imported %d missing clipboard history rows from legacy stores", totalImported)
            }
        } catch {
            NSLog("ClipTrace legacy history merge failed: %@", String(describing: error))
        }
    }

    private static func bestLegacyStore(excluding destination: URL) -> (url: URL, count: Int)? {
        legacyStoreCandidates(excluding: destination)
            .compactMap { url -> (URL, Int)? in
                guard let count = clipboardItemCount(at: url), count > 0 else { return nil }
                return (url, count)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }
    }

    private static func legacyStoreCandidates(excluding destination: URL) -> [URL] {
        let homeSupport = homeApplicationSupportRoot
        let sandboxSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)

        let candidates = [
            applicationSupportRoot.appendingPathComponent(storeFileName),
            homeSupport.appendingPathComponent(storeFileName),
            homeSupport
                .appendingPathComponent(legacyProjectFolderName, isDirectory: true)
                .appendingPathComponent(storeFileName),
            homeSupport
                .appendingPathComponent(bundleFolderName, isDirectory: true)
                .appendingPathComponent(storeFileName),
            sandboxSupport.appendingPathComponent(storeFileName),
            sandboxSupport
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(storeFileName),
            sandboxSupport
                .appendingPathComponent(legacyProjectFolderName, isDirectory: true)
                .appendingPathComponent(storeFileName)
        ]

        var seen = Set<String>()
        let destinationPath = destination.standardizedFileURL.path
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard path != destinationPath, !seen.contains(path) else { return nil }
            seen.insert(path)
            return url
        }
    }

    private static func clipboardItemCount(at storeURL: URL) -> Int? {
        guard regularFileSize(at: storeURL) > 0 else { return nil }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM ZCLIPBOARDITEM"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func importMissingClipboardItems(
        from storeURL: URL,
        into context: ModelContext,
        knownIDs: inout Set<UUID>
    ) throws -> Int {
        guard regularFileSize(at: storeURL) > 0 else { return 0 }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(storeURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            defer {
                if let database {
                    sqlite3_close(database)
                }
            }
            throw StoreRecoveryError.openFailed(storeURL.path)
        }
        defer { sqlite3_close(database) }

        guard let columns = clipboardItemColumns(in: database), columns.contains("ZID") else {
            return 0
        }

        let selectedColumns = [
            "ZID", "ZTYPE", "ZCONTENT", "ZIMAGEDATA", "ZFILEURL", "ZSOURCEAPP",
            "ZCREATEDAT", "ZISFAVORITE", "ZISPINNED", "ZPREVIEW", "ZEMBEDDING",
            "ZEMBEDDINGLANG", "ZDELETEDAT", "ZTAGSRAW", "ZCUSTOMTITLE", "ZOCRTEXT"
        ]
        let selectList = selectedColumns
            .map { columns.contains($0) ? $0 : "NULL AS \($0)" }
            .joined(separator: ", ")
        let sql = "SELECT \(selectList) FROM ZCLIPBOARDITEM"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreRecoveryError.queryFailed(storeURL.path)
        }
        defer { sqlite3_finalize(statement) }

        var imported = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let legacy = LegacyClipboardItem(statement: statement),
                  !knownIDs.contains(legacy.id) else {
                continue
            }

            let item = ClipboardItem(
                type: ClipboardItemType(rawValue: legacy.type) ?? .text,
                content: legacy.content,
                imageData: legacy.imageData,
                fileURL: legacy.fileURL,
                sourceApp: legacy.sourceApp,
                preview: legacy.preview
            )
            item.id = legacy.id
            item.type = legacy.type
            item.createdAt = legacy.createdAt
            item.isFavorite = legacy.isFavorite
            item.isPinned = legacy.isPinned
            item.embedding = legacy.embedding
            item.embeddingLang = legacy.embeddingLang
            item.deletedAt = legacy.deletedAt
            item.tagsRaw = legacy.tagsRaw
            item.customTitle = legacy.customTitle
            item.ocrText = legacy.ocrText

            context.insert(item)
            knownIDs.insert(legacy.id)
            imported += 1
        }

        return imported
    }

    private static func clipboardItemColumns(in database: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZCLIPBOARDITEM)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns.isEmpty ? nil : columns
    }

    private static func regularFileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return 0
        }
        if let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        return attributes[.size] as? UInt64 ?? 0
    }

    private static func backupExistingStoreIfNeeded(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let existingSidecars = sidecarURLs(for: storeURL).filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !existingSidecars.isEmpty else { return }

        let backupDirectory = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(backupFolderName, isDirectory: true)
            .appendingPathComponent(Self.timestamp(), isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        for url in existingSidecars {
            let backupURL = backupDirectory.appendingPathComponent(url.lastPathComponent)
            try fileManager.moveItem(at: url, to: backupURL)
        }
    }

    private static func copyStore(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for (sourceURL, destinationURL) in zip(
            sidecarURLs(for: source),
            sidecarURLs(for: destination)
        ) where fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func sidecarURLs(for storeURL: URL) -> [URL] {
        sidecarSuffixes.map { URL(fileURLWithPath: storeURL.path + $0) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private enum StoreRecoveryError: Error {
    case openFailed(String)
    case queryFailed(String)
}

private struct LegacyClipboardItem {
    let id: UUID
    let type: String
    let content: String
    let imageData: Data?
    let fileURL: String?
    let sourceApp: String
    let createdAt: Date
    let isFavorite: Bool
    let isPinned: Bool
    let preview: String?
    let embedding: Data?
    let embeddingLang: String?
    let deletedAt: Date?
    let tagsRaw: String?
    let customTitle: String?
    let ocrText: String?

    init?(statement: OpaquePointer) {
        guard let id = Self.uuid(at: 0, in: statement) else { return nil }

        self.id = id
        self.type = Self.string(at: 1, in: statement) ?? ClipboardItemType.text.rawValue
        self.content = Self.string(at: 2, in: statement) ?? ""
        self.imageData = Self.data(at: 3, in: statement)
        self.fileURL = Self.string(at: 4, in: statement)
        self.sourceApp = Self.string(at: 5, in: statement) ?? ""
        self.createdAt = Self.date(at: 6, in: statement) ?? Date()
        self.isFavorite = Self.bool(at: 7, in: statement)
        self.isPinned = Self.bool(at: 8, in: statement)
        self.preview = Self.string(at: 9, in: statement)
        self.embedding = Self.data(at: 10, in: statement)
        self.embeddingLang = Self.string(at: 11, in: statement)
        self.deletedAt = Self.date(at: 12, in: statement)
        self.tagsRaw = Self.string(at: 13, in: statement)
        self.customTitle = Self.string(at: 14, in: statement)
        self.ocrText = Self.string(at: 15, in: statement)
    }

    private static func uuid(at index: Int32, in statement: OpaquePointer) -> UUID? {
        guard let data = data(at: index, in: statement), data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func data(at index: Int32, in statement: OpaquePointer) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: byteCount)
    }

    private static func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private static func bool(at index: Int32, in statement: OpaquePointer) -> Bool {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return false }
        return sqlite3_column_int(statement, index) != 0
    }

    private static func date(at index: Int32, in statement: OpaquePointer) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }
}
