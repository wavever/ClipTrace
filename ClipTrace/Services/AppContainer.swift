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
        return try ModelContainer(for: schema, configurations: [configuration])
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
