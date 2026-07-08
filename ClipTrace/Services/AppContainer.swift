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
    private static let scannedStoreExtensions = ["store", "sqlite"]

    /// Set to `true` when `shared` had to discard an unopenable store and start
    /// fresh. The app reads it once at launch to tell the user their history was
    /// reset (a backup is kept under `StoreBackups/`), then clears it.
    static let didResetStoreDefaultsKey = "didResetClipboardStore"

    static let shared: ModelContainer = {
        do {
            return try makeContainer()
        } catch {
            // The store can't be opened by this build — usually a schema *newer*
            // than ours (an older binary launched after a newer one migrated the
            // shared store) or on-disk corruption. The old `fatalError` here made
            // that an unrecoverable launch crash on every start; instead move the
            // unopenable store aside (data preserved, not deleted) and rebuild a
            // clean one so the app still launches.
            NSLog(
                "ClipTrace: opening ModelContainer failed (%@) — quarantining store and rebuilding",
                String(describing: error)
            )
            quarantineUnopenableStore()
            UserDefaults.standard.set(true, forKey: didResetStoreDefaultsKey)
            do {
                // Skip legacy recovery on the rebuild: the environment is already
                // degraded, and re-scanning could pull another incompatible store
                // straight back into a crash loop. A clean empty store is enough
                // to get the user back in — the quarantined data stays on disk.
                return try makeContainer(recoverLegacy: false)
            } catch {
                // Even a fresh store won't open — the environment is broken (no
                // write access, disk full). Nothing left to try.
                fatalError("Failed to open ModelContainer after resetting the store: \(error)")
            }
        }
    }()

    static func makeContainer(recoverLegacy: Bool = true) throws -> ModelContainer {
        if recoverLegacy {
            try recoverLegacyStoreIfNeeded()
        }

        let schema = Schema([ClipboardItem.self, ClipboardGroup.self])
        let configuration = ModelConfiguration(
            "ClipTrace",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        if recoverLegacy {
            mergeLegacyStoresIfNeeded(into: container)
            migrateLegacyGroupAssignments(in: container)
        }
        return container
    }

    /// Move an unopenable store (plus its `-wal`/`-shm` sidecars and the Core
    /// Data external-storage `_SUPPORT` folders) into a timestamped
    /// `StoreBackups/` subfolder so the next `makeContainer()` can create a clean
    /// database. Files are *moved*, never deleted, so the user can recover their
    /// history manually. The backed-up store file gets a non-`.store` extension
    /// so `recoverLegacyStoreIfNeeded` can't re-adopt the very file we just
    /// quarantined.
    private static func quarantineUnopenableStore() {
        let fileManager = FileManager.default
        let store = storeURL
        let directory = store.deletingLastPathComponent()
        let backupDirectory = directory
            .appendingPathComponent(backupFolderName, isDirectory: true)
            .appendingPathComponent("unopenable-\(timestamp())", isDirectory: true)

        // Every on-disk artifact belonging to the store. Core Data names the
        // external-storage folder after the store's *stem* (".default_SUPPORT"),
        // so cover that plus the full-name variants defensively.
        let name = store.lastPathComponent            // "default.store"
        let stem = store.deletingPathExtension().lastPathComponent  // "default"
        let artifacts: [(source: URL, backupName: String)] = [
            (store, name + ".quarantine"),
            (URL(fileURLWithPath: store.path + "-wal"), name + "-wal"),
            (URL(fileURLWithPath: store.path + "-shm"), name + "-shm"),
            (directory.appendingPathComponent(".\(stem)_SUPPORT", isDirectory: true), ".\(stem)_SUPPORT"),
            (directory.appendingPathComponent("\(name)_SUPPORT", isDirectory: true), "\(name)_SUPPORT"),
            (directory.appendingPathComponent(".\(name)_SUPPORT", isDirectory: true), ".\(name)_SUPPORT")
        ]

        let present = artifacts.filter { fileManager.fileExists(atPath: $0.source.path) }
        guard !present.isEmpty else { return }

        let haveBackupDir = (try? fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )) != nil

        for artifact in present {
            let destination = backupDirectory.appendingPathComponent(artifact.backupName)
            if haveBackupDir, (try? fileManager.moveItem(at: artifact.source, to: destination)) != nil {
                continue
            }
            // Couldn't back it up (e.g. backup dir creation failed) — delete so
            // the same unreadable file doesn't block the rebuild.
            NSLog("ClipTrace: could not back up %@ — deleting so the store can rebuild", artifact.source.lastPathComponent)
            try? fileManager.removeItem(at: artifact.source)
        }
    }

    /// One-time fold of the pre-multi-group `groupID` field into the
    /// newline-joined `groupIDsRaw`. Runs on every launch but matches only
    /// rows that still carry a legacy single-group id, so it's a no-op once
    /// the store has been converted.
    private static func migrateLegacyGroupAssignments(in container: ModelContainer) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.groupID != nil && $0.groupIDsRaw == nil }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }
        for item in pending {
            if let gid = item.groupID {
                item.setGroupIDs([gid])
            }
            item.groupID = nil
        }
        try? context.save()
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

    /// Escape hatch (`defaults write com.wavever.cliptrace skipLegacyStoreScan
    /// -bool true`): legacy-store recovery probes other bundles' sandbox
    /// containers, and on machines where that consent was never granted macOS
    /// parks the `open()` behind a TCC prompt — turning an unattended
    /// (agent/CI) rebuild-and-relaunch loop into a launch that never reaches
    /// its first window. Machines whose store already migrated lose nothing
    /// by skipping the scan.
    private static var legacyScanDisabled: Bool {
        UserDefaults.standard.bool(forKey: "skipLegacyStoreScan")
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

        if legacyScanDisabled { return }

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
        if legacyScanDisabled { return }
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

        let knownCandidates = [
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
        let candidates = knownCandidates + scannedLegacyStoreCandidates()

        var seen = Set<String>()
        let destinationPath = destination.standardizedFileURL.path
        return candidates.compactMap { url in
            let path = url.standardizedFileURL.path
            guard path != destinationPath, !seen.contains(path) else { return nil }
            seen.insert(path)
            return url
        }
    }

    private static func scannedLegacyStoreCandidates() -> [URL] {
        let homeSupport = homeApplicationSupportRoot
        var roots: [(url: URL, depth: Int)] = [(homeSupport, 4)]

        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        if let containerURLs = try? FileManager.default.contentsOfDirectory(
            at: containerRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in containerURLs where isRelevantContainer(url) {
                roots.append((url, 8))
            }
        }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(contentsOf: storeCandidates(under: root.url, maxDepth: root.depth))
        }
        return candidates
    }

    private static func isRelevantContainer(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.contains("clip") || name.contains("clipboard") || name.contains("wavever")
    }

    private static func storeCandidates(under root: URL, maxDepth: Int) -> [URL] {
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            return []
        }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            if depth > maxDepth {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard isPotentialStoreURL(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    private static func isPotentialStoreURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard !name.hasSuffix("-wal"), !name.hasSuffix("-shm") else { return false }
        guard scannedStoreExtensions.contains(url.pathExtension.lowercased()) else { return false }
        guard regularFileSize(at: url) > 0 else { return false }
        return true
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
            "ZEMBEDDINGLANG", "ZDELETEDAT", "ZTAGSRAW", "ZCUSTOMTITLE", "ZOCRTEXT", "ZGROUPID"
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

            let imagePayload = legacy.imageData.flatMap {
                ImagePayloadStore.normalizedPayload(from: $0)
            }

            let item = ClipboardItem(
                type: ClipboardItemType(rawValue: legacy.type) ?? .text,
                content: legacy.content,
                imageData: imagePayload?.data,
                fileURL: legacy.fileURL,
                sourceApp: legacy.sourceApp,
                preview: legacy.preview
            )
            if let imagePayload {
                ImagePayloadStore.applyMetadata(from: imagePayload, to: item)
            }
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
            // Old stores carry a single group id; fold it into the new
            // multi-group field directly so it needs no later backfill.
            if let gid = legacy.groupID { item.setGroupIDs([gid]) }

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
        var urls = sidecarSuffixes.map { URL(fileURLWithPath: storeURL.path + $0) }
        urls.append(URL(fileURLWithPath: storeURL.path + "_SUPPORT", isDirectory: true))
        urls.append(
            storeURL
                .deletingLastPathComponent()
                .appendingPathComponent(".\(storeURL.lastPathComponent)_SUPPORT", isDirectory: true)
        )
        return urls
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
    let groupID: UUID?

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
        self.groupID = Self.uuid(at: 16, in: statement)
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
