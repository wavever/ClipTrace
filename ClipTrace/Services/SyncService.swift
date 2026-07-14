import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum SyncPreferenceKeys {
    static let provider = "sync.provider"
    static let automatic = "sync.automatic"
    static let intervalMinutes = "sync.intervalMinutes"
    static let webDAVURL = "sync.webdav.url"
    static let webDAVUsername = "sync.webdav.username"
    static let s3Endpoint = "sync.s3.endpoint"
    static let s3Region = "sync.s3.region"
    static let s3Bucket = "sync.s3.bucket"
    static let s3Prefix = "sync.s3.prefix"
    static let s3AccessKeyID = "sync.s3.accessKeyID"
    static let s3PathStyle = "sync.s3.pathStyle"
    static let localFolderBookmark = "sync.folder.bookmark"
    static let localFolderPath = "sync.folder.path"
    static let lastSuccess = "sync.lastSuccess"
    static let deviceID = "sync.deviceID"
}

enum SyncActivityState: Equatable {
    case idle
    case syncing
    case succeeded
    case failed(String)
}

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    static let defaultIntervalMinutes = 15
    static let maximumAttachmentBytes = 25 * 1024 * 1024

    @Published private(set) var activity: SyncActivityState = .idle
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var activeLocation: String?

    private let defaults = UserDefaults.standard
    private let context = AppContainer.shared.mainContext
    private var scheduler: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var started = false

    private init() {
        lastSuccess = defaults.object(forKey: SyncPreferenceKeys.lastSuccess) as? Date
    }

    var provider: SyncProvider {
        SyncProvider(rawValue: defaults.string(forKey: SyncPreferenceKeys.provider) ?? "") ?? .off
    }

    var isConfigured: Bool {
        switch provider {
        case .off:
            return false
        case .iCloudDrive:
            return iCloudDriveRootURL != nil
        case .webDAV:
            return normalizedWebDAVURL != nil
        case .localFolder:
            return localFolderURL != nil
        case .s3:
            return s3Configuration?.isValid == true
        }
    }

    var iCloudDriveLocation: String? {
        iCloudDriveRootURL?.path
    }

    var localFolderLocation: String? {
        localFolderURL?.path
    }

    var hasEncryptionKey: Bool {
        SyncKeychain.data(for: .encryptionKey)?.count == SyncCipher.keyByteCount
    }

    func start() {
        guard !started else { return }
        started = true
        reschedule()
        syncIfDue()
    }

    func stop() {
        started = false
        scheduler?.cancel()
        scheduler = nil
        syncTask?.cancel()
        syncTask = nil
    }

    func settingsDidChange(syncImmediately: Bool = false) {
        activeLocation = nil
        activity = .idle
        reschedule()
        if syncImmediately { syncNow() }
    }

    func syncIfDue() {
        guard provider != .off,
              defaults.object(forKey: SyncPreferenceKeys.automatic) as? Bool ?? true else { return }
        let interval = TimeInterval(max(1, configuredIntervalMinutes) * 60)
        guard lastSuccess == nil || Date().timeIntervalSince(lastSuccess ?? .distantPast) >= interval else {
            return
        }
        syncNow()
    }

    func syncNow() {
        guard syncTask == nil, provider != .off else { return }
        activity = .syncing
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Let AppKit commit the spinner's first frame before snapshot
                // creation touches SwiftData on the main actor. Its subsequent
                // rotation runs on Core Animation's render side.
                try await Task.sleep(nanoseconds: 16_000_000)
                try Task.checkCancellation()
                let result = try await performSync()
                try Task.checkCancellation()
                let completedAt = Date()
                lastSuccess = completedAt
                defaults.set(completedAt, forKey: SyncPreferenceKeys.lastSuccess)
                activeLocation = result.location
                activity = .succeeded
                NotificationCenter.default.post(name: .clipTraceSyncDidComplete, object: nil)
            } catch is CancellationError {
                activity = .idle
            } catch {
                let message = error.localizedDescription
                activity = .failed(message)
                NotificationCenter.default.post(name: .clipTraceSyncDidFail, object: message)
            }
            syncTask = nil
        }
    }

    func saveWebDAVPassword(_ password: String) throws {
        try SyncKeychain.set(Data(password.utf8), for: .webDAVPassword)
    }

    func webDAVPassword() -> String {
        guard let data = SyncKeychain.data(for: .webDAVPassword) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveS3Credentials(secretAccessKey: String, sessionToken: String) throws {
        try SyncKeychain.set(Data(secretAccessKey.utf8), for: .s3SecretAccessKey)
        if sessionToken.isEmpty {
            try SyncKeychain.remove(.s3SessionToken)
        } else {
            try SyncKeychain.set(Data(sessionToken.utf8), for: .s3SessionToken)
        }
    }

    func s3SecretAccessKey() -> String {
        stringFromKeychain(.s3SecretAccessKey)
    }

    func s3SessionToken() -> String {
        stringFromKeychain(.s3SessionToken)
    }

    @discardableResult
    func ensureEncryptionKey() throws -> Data {
        if let existing = SyncKeychain.data(for: .encryptionKey),
           existing.count == SyncCipher.keyByteCount {
            return existing
        }
        let generated = try SyncCipher.generateKeyData()
        try SyncKeychain.set(generated, for: .encryptionKey)
        return generated
    }

    func currentRecoveryKey() throws -> String {
        try SyncCipher.recoveryKey(from: ensureEncryptionKey())
    }

    func installRecoveryKey(_ value: String) throws {
        let data = try SyncCipher.keyData(fromRecoveryKey: value)
        try SyncKeychain.set(data, for: .encryptionKey)
        activity = .idle
    }

    func chooseLocalFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: SyncPreferenceKeys.localFolderBookmark)
        defaults.set(url.path, forKey: SyncPreferenceKeys.localFolderPath)
        settingsDidChange()
    }

    private var configuredIntervalMinutes: Int {
        let value = defaults.integer(forKey: SyncPreferenceKeys.intervalMinutes)
        return value > 0 ? value : Self.defaultIntervalMinutes
    }

    private func reschedule() {
        scheduler?.cancel()
        scheduler = nil
        guard started,
              provider != .off,
              defaults.object(forKey: SyncPreferenceKeys.automatic) as? Bool ?? true else { return }

        let minutes = configuredIntervalMinutes
        scheduler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(max(60, minutes * 60)))
                } catch {
                    return
                }
                self?.syncIfDue()
            }
        }
    }

    private func performSync() async throws -> (location: String, itemCount: Int) {
        let keyData = try ensureEncryptionKey()
        let transport = try makeTransport()
        activeLocation = transport.displayLocation
        try await transport.prepare()

        for attempt in 0..<3 {
            do {
                return try await performSyncAttempt(transport: transport, keyData: keyData)
            } catch SyncTransportError.concurrentChange where attempt < 2 {
                try Task.checkCancellation()
                continue
            }
        }
        throw SyncTransportError.concurrentChange
    }

    private func performSyncAttempt(
        transport: any SyncTransport,
        keyData: Data
    ) async throws -> (location: String, itemCount: Int) {
        let remoteFile = try await transport.readManifest()
        var remote: SyncArchive
        if let remoteFile {
            let manifest = try SyncCipher.open(remoteFile.data, keyData: keyData)
            remote = try SyncArchiveCodec.decode(manifest)
        } else {
            remote = .empty
        }
        let journalObjects = try await transport.listJournalEntries()
        var journalBatches: [String: SyncOperationBatch] = [:]
        for object in journalObjects {
            try Task.checkCancellation()
            let encrypted = try await transport.readJournalEntry(named: object.name)
            let plaintext = try SyncCipher.open(encrypted, keyData: keyData)
            let batch = try SyncOperationCodec.decode(plaintext)
            guard object.name == batch.remoteName else { throw SyncServiceError.corruptJournal }
            journalBatches[object.name] = batch
        }
        for batch in journalBatches.values.sorted(by: {
            $0.version == $1.version ? $0.id < $1.id : $0.version < $1.version
        }) {
            let watermark = remote.journalWatermarks?[batch.deviceID]
            guard watermark == nil || watermark! < batch.version else { continue }
            remote = SyncArchiveMerger.merge(local: remote, remote: batch.archive)
            var watermarks = remote.journalWatermarks ?? [:]
            watermarks[batch.deviceID] = max(watermarks[batch.deviceID] ?? batch.version, batch.version)
            remote.journalWatermarks = watermarks
        }

        var stateIndex = try SyncStateStore.load()
        var attachmentGarbageCandidates = stateIndex.attachmentGarbageCandidates ?? [:]
        stateIndex.observe(remote.greatestVersion)
        let local = try await makeLocalSnapshot(remote: remote, stateIndex: &stateIndex)
        try SyncStateStore.save(stateIndex)
        var merged = SyncArchiveMerger.merge(local: local.archive, remote: remote)
        let pendingBatch = stateIndex.pendingBatch
        if let pendingBatch {
            var watermarks = merged.journalWatermarks ?? [:]
            watermarks[pendingBatch.deviceID] = max(
                watermarks[pendingBatch.deviceID] ?? pendingBatch.version,
                pendingBatch.version
            )
            merged.journalWatermarks = watermarks
        }
        if let greatest = merged.greatestVersion {
            var acknowledgements = merged.deviceAcknowledgements ?? [:]
            acknowledgements[syncDeviceID] = max(acknowledgements[syncDeviceID] ?? greatest, greatest)
            merged.deviceAcknowledgements = acknowledgements
        }

        let remotePayloads = try await downloadPayloadsNeededToApply(
            merged: merged,
            local: local.archive,
            transport: transport,
            keyData: keyData
        )
        try await uploadMissingLocalPayloads(
            merged: merged,
            remote: remote,
            snapshotPayloads: local.payloads,
            downloadedPayloads: remotePayloads,
            transport: transport,
            keyData: keyData
        )
        try await apply(merged, downloadedPayloads: remotePayloads)
        merged = SyncArchiveGarbageCollector.compactTombstones(in: merged)

        // Save version knowledge as soon as local application succeeds. If a
        // later network upload fails, the retry preserves the remote versions
        // instead of stamping those just-applied rows as fresh local edits.
        stateIndex = makeStateIndex(for: merged)
        stateIndex.pendingBatch = pendingBatch
        stateIndex.attachmentGarbageCandidates = attachmentGarbageCandidates
        try SyncStateStore.save(stateIndex)
        if let pendingBatch {
            let encoded = try SyncOperationCodec.encode(pendingBatch)
            let encrypted = try SyncCipher.seal(encoded, keyData: keyData)
            try await transport.writeJournalEntryIfNeeded(encrypted, named: pendingBatch.remoteName)
            journalBatches[pendingBatch.remoteName] = pendingBatch
        }
        let manifest = try SyncArchiveCodec.encode(merged)
        let encryptedManifest = try SyncCipher.seal(manifest, keyData: keyData)
        try await transport.writeManifest(encryptedManifest, replacing: remoteFile?.revision)

        // Once the compare-and-swap snapshot includes a device watermark, its
        // older immutable operations are redundant. Deletion is best-effort:
        // leaving an encrypted entry behind is harmless and a later sync will
        // compact it again.
        for (name, batch) in journalBatches {
            guard let watermark = merged.journalWatermarks?[batch.deviceID],
                  batch.version <= watermark else { continue }
            try? await transport.deleteJournalEntry(named: name)
        }
        if let updatedCandidates = try? await compactRemoteAttachments(
            in: merged,
            previousCandidates: attachmentGarbageCandidates,
            transport: transport,
            keyData: keyData
        ) {
            attachmentGarbageCandidates = updatedCandidates
        }
        stateIndex = makeStateIndex(for: merged)
        stateIndex.pendingBatch = nil
        stateIndex.attachmentGarbageCandidates = attachmentGarbageCandidates
        try SyncStateStore.save(stateIndex)

        WidgetBridge.shared.refreshNow(context: context)
        return (transport.displayLocation, merged.items.count)
    }

    private func makeTransport() throws -> any SyncTransport {
        switch provider {
        case .off:
            throw SyncServiceError.providerDisabled
        case .iCloudDrive:
            guard let url = iCloudDriveRootURL else { throw SyncServiceError.iCloudUnavailable }
            return FileSyncTransport(rootURL: url, securityScoped: false)
        case .webDAV:
            guard let url = normalizedWebDAVURL else { throw WebDAVSyncError.invalidURL }
            let username = defaults.string(forKey: SyncPreferenceKeys.webDAVUsername) ?? ""
            return WebDAVSyncTransport(baseURL: url, username: username, password: webDAVPassword())
        case .localFolder:
            guard let url = localFolderURL else { throw SyncServiceError.folderUnavailable }
            return FileSyncTransport(
                rootURL: url.appendingPathComponent("ClipTrace Sync", isDirectory: true),
                securityScoped: true
            )
        case .s3:
            guard let configuration = s3Configuration else {
                throw S3SyncError.invalidConfiguration
            }
            return S3SyncTransport(configuration: configuration)
        }
    }

    private var iCloudDriveRootURL: URL? {
        let cloudDrive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDrive.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return cloudDrive
            .appendingPathComponent("ClipTrace", isDirectory: true)
            .appendingPathComponent("Sync", isDirectory: true)
    }

    private var normalizedWebDAVURL: URL? {
        guard let raw = defaults.string(forKey: SyncPreferenceKeys.webDAVURL)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    private var s3Configuration: S3SyncConfiguration? {
        guard let rawEndpoint = defaults.string(forKey: SyncPreferenceKeys.s3Endpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            var endpointComponents = URLComponents(string: rawEndpoint),
            let scheme = endpointComponents.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            endpointComponents.host != nil else { return nil }
        endpointComponents.user = nil
        endpointComponents.password = nil
        endpointComponents.query = nil
        endpointComponents.fragment = nil
        guard let endpoint = endpointComponents.url else { return nil }
        let region = defaults.string(forKey: SyncPreferenceKeys.s3Region)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bucket = defaults.string(forKey: SyncPreferenceKeys.s3Bucket)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = defaults.string(forKey: SyncPreferenceKeys.s3Prefix)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accessKeyID = defaults.string(forKey: SyncPreferenceKeys.s3AccessKeyID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pathStyle = defaults.object(forKey: SyncPreferenceKeys.s3PathStyle) as? Bool ?? true
        let configuration = S3SyncConfiguration(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            prefix: prefix,
            accessKeyID: accessKeyID,
            secretAccessKey: s3SecretAccessKey(),
            sessionToken: s3SessionToken(),
            pathStyle: pathStyle
        )
        return configuration.isValid ? configuration : nil
    }

    private var localFolderURL: URL? {
        guard let bookmark = defaults.data(forKey: SyncPreferenceKeys.localFolderBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale, let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(refreshed, forKey: SyncPreferenceKeys.localFolderBookmark)
        }
        return url
    }

    private func makeLocalSnapshot(
        remote: SyncArchive,
        stateIndex: inout SyncStateIndex
    ) async throws -> LocalSyncSnapshot {
        var remote = remote
        remote.normalizeMetadata()
        let items = try context.fetch(FetchDescriptor<ClipboardItem>())
        let groups = try context.fetch(FetchDescriptor<ClipboardGroup>())
        let now = Date()
        let deviceID = syncDeviceID
        let remoteItems = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.id, $0) })
        let remoteGroups = Dictionary(uniqueKeysWithValues: remote.groups.map { ($0.id, $0) })
        var records: [SyncClipboardRecord] = []
        var groupRecords: [SyncGroupRecord] = []
        var changedRecords: [SyncClipboardRecord] = []
        var changedGroupRecords: [SyncGroupRecord] = []
        var payloads: [String: Data] = [:]
        let liveItemIDs = Set(items.map(\.id))
        let liveGroupIDs = Set(groups.map(\.id))

        for item in items {
            try Task.checkCancellation()
            var isLocalChange = false
            let existingState = stateIndex.items[item.id.uuidString]
            let cheapSignature = attachmentSourceSignature(for: item)
            let portableContent = portableContent(for: item)
            let sourceFingerprint = sourceFingerprint(
                for: item,
                portableContent: portableContent,
                attachmentSignature: cheapSignature
            )

            let attachment: SyncAttachment?
            if let existingState,
               !existingState.deleted,
               existingState.sourceFingerprint == sourceFingerprint {
                attachment = existingState.attachment
            } else if let payload = try await attachmentPayload(for: item) {
                attachment = payload.attachment
                payloads[payload.attachment.sha256] = payload.data
            } else {
                attachment = nil
            }

            var record = SyncClipboardRecord(
                id: item.id,
                type: item.type,
                content: portableContent,
                sourceApp: item.sourceApp,
                createdAt: item.createdAt,
                isFavorite: item.isFavorite,
                isPinned: item.isPinned,
                preview: item.preview,
                deletedAt: item.deletedAt,
                tagsRaw: item.tagsRaw,
                customTitle: item.customTitle,
                ocrText: item.ocrText,
                groupIDsRaw: item.groupIDsRaw,
                attachment: attachment,
                modifiedAt: now,
                modifiedBy: deviceID,
                contentHash: ""
            )
            record.refreshContentHash()

            if let existingState, !existingState.deleted, existingState.contentHash == record.contentHash {
                record.modifiedAt = existingState.modifiedAt
                record.modifiedBy = existingState.modifiedBy
                record.version = existingState.version
                record.fieldVersions = existingState.fieldVersions
                record.tagSet = existingState.tagSet
                record.groupSet = existingState.groupSet
                record.normalizeMetadata()
            } else if existingState == nil,
                      let remoteRecord = remoteItems[item.id],
                      remoteRecord.contentHash == record.contentHash {
                record.modifiedAt = remoteRecord.modifiedAt
                record.modifiedBy = remoteRecord.modifiedBy
                record.version = remoteRecord.version
                record.fieldVersions = remoteRecord.fieldVersions
                record.tagSet = remoteRecord.tagSet
                record.groupSet = remoteRecord.groupSet
                record.normalizeMetadata()
            } else if existingState == nil, let remoteRecord = remoteItems[item.id] {
                // A missing state index cannot prove which fields changed
                // locally. Treat the database row as an older recovery branch
                // so known remote edits are not overwritten; protected losing
                // content is still retained by the conflict-copy policy.
                let recoveryVersion = versionImmediatelyBefore(
                    remoteRecord.effectiveVersion,
                    deviceID: deviceID
                )
                record.modifiedAt = recoveryVersion.date
                record.modifiedBy = recoveryVersion.deviceID
                record.stampLocalChanges(
                    previousHashes: nil,
                    previousVersions: nil,
                    previousTagSet: nil,
                    previousGroupSet: nil,
                    at: recoveryVersion
                )
            } else {
                let timestamp = stateIndex.nextTimestamp(now: now, deviceID: deviceID)
                record.stampLocalChanges(
                    previousHashes: existingState?.fieldHashes,
                    previousVersions: existingState?.fieldVersions,
                    previousTagSet: existingState?.tagSet,
                    previousGroupSet: existingState?.groupSet,
                    at: timestamp
                )
                isLocalChange = true
            }

            stateIndex.items[item.id.uuidString] = SyncStateEntry(
                sourceFingerprint: sourceFingerprint,
                contentHash: record.contentHash,
                modifiedAt: record.modifiedAt,
                modifiedBy: record.modifiedBy,
                deleted: false,
                attachment: attachment,
                version: record.effectiveVersion,
                fieldHashes: record.syncFieldHashes,
                fieldVersions: record.fieldVersions,
                tagSet: record.tagSet,
                groupSet: record.groupSet
            )
            records.append(record)
            if isLocalChange { changedRecords.append(record) }
        }

        for group in groups {
            var isLocalChange = false
            var record = SyncGroupRecord(
                id: group.id,
                name: group.name,
                sortOrder: group.sortOrder,
                createdAt: group.createdAt,
                modifiedAt: now,
                modifiedBy: deviceID,
                contentHash: ""
            )
            record.refreshContentHash()
            let sourceFingerprint = record.contentHash
            if let existing = stateIndex.groups[group.id.uuidString],
               !existing.deleted,
               existing.contentHash == record.contentHash {
                record.modifiedAt = existing.modifiedAt
                record.modifiedBy = existing.modifiedBy
                record.version = existing.version
                record.fieldVersions = existing.fieldVersions
                record.normalizeMetadata()
            } else if stateIndex.groups[group.id.uuidString] == nil,
                      let remoteRecord = remoteGroups[group.id],
                      remoteRecord.contentHash == record.contentHash {
                record.modifiedAt = remoteRecord.modifiedAt
                record.modifiedBy = remoteRecord.modifiedBy
                record.version = remoteRecord.version
                record.fieldVersions = remoteRecord.fieldVersions
                record.normalizeMetadata()
            } else if stateIndex.groups[group.id.uuidString] == nil,
                      let remoteRecord = remoteGroups[group.id] {
                let recoveryVersion = versionImmediatelyBefore(
                    remoteRecord.effectiveVersion,
                    deviceID: deviceID
                )
                record.modifiedAt = recoveryVersion.date
                record.modifiedBy = recoveryVersion.deviceID
                record.stampLocalChanges(
                    previousHashes: nil,
                    previousVersions: nil,
                    at: recoveryVersion
                )
            } else {
                let timestamp = stateIndex.nextTimestamp(now: now, deviceID: deviceID)
                record.stampLocalChanges(
                    previousHashes: stateIndex.groups[group.id.uuidString]?.fieldHashes,
                    previousVersions: stateIndex.groups[group.id.uuidString]?.fieldVersions,
                    at: timestamp
                )
                isLocalChange = true
            }
            stateIndex.groups[group.id.uuidString] = SyncStateEntry(
                sourceFingerprint: sourceFingerprint,
                contentHash: record.contentHash,
                modifiedAt: record.modifiedAt,
                modifiedBy: record.modifiedBy,
                deleted: false,
                attachment: nil,
                version: record.effectiveVersion,
                fieldHashes: record.syncFieldHashes,
                fieldVersions: record.fieldVersions
            )
            groupRecords.append(record)
            if isLocalChange { changedGroupRecords.append(record) }
        }

        let newItemTombstones = markMissingEntitiesAsDeleted(
            liveIDs: liveItemIDs,
            kind: .clipboardItem,
            now: now,
            deviceID: deviceID,
            stateIndex: &stateIndex
        )
        let newGroupTombstones = markMissingEntitiesAsDeleted(
            liveIDs: liveGroupIDs,
            kind: .group,
            now: now,
            deviceID: deviceID,
            stateIndex: &stateIndex
        )

        let itemTombstones = tombstones(from: stateIndex.items, kind: .clipboardItem)
        let groupTombstones = tombstones(from: stateIndex.groups, kind: .group)
        if let batch = SyncOperationBatch.make(
            deviceID: deviceID,
            createdAt: now,
            items: changedRecords,
            groups: changedGroupRecords,
            tombstones: newItemTombstones + newGroupTombstones
        ) {
            stateIndex.pendingBatch = stateIndex.pendingBatch.map {
                $0.coalescing(with: batch, now: now)
            } ?? batch
        }
        var archive = SyncArchive(
                formatVersion: SyncArchive.currentFormatVersion,
                generatedAt: now,
                items: records,
                groups: groupRecords,
                tombstones: itemTombstones + groupTombstones,
                conflicts: remote.conflicts,
                deviceAcknowledgements: remote.deviceAcknowledgements,
                journalWatermarks: remote.journalWatermarks
            )
        if let acknowledgement = [archive.greatestVersion, remote.greatestVersion].compactMap({ $0 }).max() {
            var acknowledgements = archive.deviceAcknowledgements ?? [:]
            acknowledgements[deviceID] = max(acknowledgements[deviceID] ?? acknowledgement, acknowledgement)
            archive.deviceAcknowledgements = acknowledgements
            stateIndex.observe(acknowledgement)
        }
        return LocalSyncSnapshot(
            archive: archive,
            payloads: payloads
        )
    }

    private func markMissingEntitiesAsDeleted(
        liveIDs: Set<UUID>,
        kind: SyncEntityKind,
        now: Date,
        deviceID: String,
        stateIndex: inout SyncStateIndex
    ) -> [SyncTombstone] {
        var entries = kind == .clipboardItem ? stateIndex.items : stateIndex.groups
        var created: [SyncTombstone] = []
        for (rawID, entry) in entries {
            guard let id = UUID(uuidString: rawID), !liveIDs.contains(id), !entry.deleted else { continue }
            let timestamp = stateIndex.nextTimestamp(now: now, deviceID: deviceID)
            entries[rawID] = SyncStateEntry(
                sourceFingerprint: "",
                contentHash: "",
                modifiedAt: timestamp.date,
                modifiedBy: timestamp.deviceID,
                deleted: true,
                attachment: nil,
                version: timestamp
            )
            created.append(SyncTombstone(
                id: id,
                kind: kind,
                modifiedAt: timestamp.date,
                modifiedBy: timestamp.deviceID,
                version: timestamp
            ))
        }
        if kind == .clipboardItem { stateIndex.items = entries }
        else { stateIndex.groups = entries }
        return created
    }

    private func tombstones(
        from entries: [String: SyncStateEntry],
        kind: SyncEntityKind
    ) -> [SyncTombstone] {
        entries.compactMap { rawID, entry in
            guard entry.deleted, let id = UUID(uuidString: rawID) else { return nil }
            return SyncTombstone(
                id: id,
                kind: kind,
                modifiedAt: entry.modifiedAt,
                modifiedBy: entry.modifiedBy,
                version: entry.version
            )
        }
    }

    private func downloadPayloadsNeededToApply(
        merged: SyncArchive,
        local: SyncArchive,
        transport: any SyncTransport,
        keyData: Data
    ) async throws -> [String: Data] {
        let localRecords = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        var result: [String: Data] = [:]
        for record in merged.items {
            guard let attachment = record.attachment else { continue }
            if let localRecord = localRecords[record.id],
               localRecord.contentHash == record.contentHash ||
               localRecord.attachment?.sha256 == attachment.sha256 {
                continue
            }
            if result[attachment.sha256] != nil { continue }
            let remoteName = try SyncCipher.remoteAttachmentName(
                contentHash: attachment.sha256,
                keyData: keyData
            )
            let encrypted = try await transport.readAttachment(named: remoteName)
            let payload = try SyncCipher.open(encrypted, keyData: keyData)
            guard payload.count == attachment.byteCount,
                  SyncDigest.hash(payload) == attachment.sha256 else {
                throw SyncServiceError.corruptAttachment
            }
            result[attachment.sha256] = payload
        }
        return result
    }

    private func apply(
        _ archive: SyncArchive,
        downloadedPayloads: [String: Data]
    ) async throws {
        let existingItems = try context.fetch(FetchDescriptor<ClipboardItem>())
        let existingGroups = try context.fetch(FetchDescriptor<ClipboardGroup>())
        var itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        var groupsByID = Dictionary(uniqueKeysWithValues: existingGroups.map { ($0.id, $0) })
        let itemTombstones = archive.tombstones.filter { $0.kind == .clipboardItem }
        let groupTombstones = archive.tombstones.filter { $0.kind == .group }

        for tombstone in itemTombstones {
            if let item = itemsByID.removeValue(forKey: tombstone.id) {
                context.delete(item)
            }
        }
        for tombstone in groupTombstones {
            if let group = groupsByID.removeValue(forKey: tombstone.id) {
                context.delete(group)
            }
        }

        for record in archive.groups {
            let group: ClipboardGroup
            if let existing = groupsByID[record.id] {
                group = existing
            } else {
                group = ClipboardGroup(name: record.name, sortOrder: record.sortOrder)
                group.id = record.id
                context.insert(group)
                groupsByID[record.id] = group
            }
            group.name = record.name
            group.sortOrder = record.sortOrder
            group.createdAt = record.createdAt
        }

        var preparedFileURLs: [String: URL] = [:]
        for record in archive.items {
            guard let attachment = record.attachment,
                  attachment.kind == .file,
                  let payload = downloadedPayloads[attachment.sha256] else { continue }
            preparedFileURLs[attachment.sha256] = try await writeSyncedFile(
                payload,
                itemID: record.id,
                suggestedName: attachment.fileName
            )
        }

        for record in archive.items {
            let item: ClipboardItem
            if let existing = itemsByID[record.id] {
                item = existing
            } else {
                let type = ClipboardItemType(rawValue: record.type) ?? .text
                item = ClipboardItem(type: type, content: record.content, sourceApp: record.sourceApp)
                item.id = record.id
                context.insert(item)
                itemsByID[record.id] = item
            }

            let semanticContentChanged = item.type != record.type ||
                item.content != record.content || item.ocrText != record.ocrText
            item.type = record.type
            item.sourceApp = record.sourceApp
            item.createdAt = record.createdAt
            item.isFavorite = record.isFavorite
            item.isPinned = record.isPinned
            item.preview = record.preview
            item.deletedAt = record.deletedAt
            item.tagsRaw = record.tagsRaw
            item.customTitle = record.customTitle
            item.ocrText = record.ocrText
            item.groupIDsRaw = record.groupIDsRaw
            item.groupID = nil
            if semanticContentChanged {
                item.embedding = nil
                item.embeddingLang = nil
            }

            if let attachment = record.attachment {
                switch attachment.kind {
                case .image:
                    if let data = downloadedPayloads[attachment.sha256] {
                        item.imageData = data
                    }
                    item.imageUTI = attachment.uti
                    item.imageByteCount = attachment.byteCount
                    item.imagePixelWidth = attachment.pixelWidth
                    item.imagePixelHeight = attachment.pixelHeight
                    item.imageStorageVersion = ImagePayloadStore.storageVersion
                    item.fileURL = nil
                    item.content = record.content
                case .file:
                    item.imageData = nil
                    item.imageUTI = nil
                    item.imageByteCount = nil
                    item.imagePixelWidth = nil
                    item.imagePixelHeight = nil
                    item.imageStorageVersion = nil
                    if let url = preparedFileURLs[attachment.sha256] {
                        item.fileURL = url.path
                        item.content = url.path
                    } else if item.resolvedFileURL == nil {
                        item.fileURL = nil
                        item.content = record.content
                    }
                }
            } else {
                item.imageData = nil
                item.imageUTI = nil
                item.imageByteCount = nil
                item.imagePixelWidth = nil
                item.imagePixelHeight = nil
                item.imageStorageVersion = nil
                item.fileURL = nil
                item.content = record.content
            }
        }
        try context.save()
    }

    private func uploadMissingLocalPayloads(
        merged: SyncArchive,
        remote: SyncArchive,
        snapshotPayloads: [String: Data],
        downloadedPayloads: [String: Data],
        transport: any SyncTransport,
        keyData: Data
    ) async throws {
        let alreadyRemote = Set(recordsWithAttachments(in: remote).compactMap { $0.attachment?.sha256 })
        let itemsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ClipboardItem>()).map { ($0.id, $0) })
        var uploaded = Set<String>()

        for record in recordsWithAttachments(in: merged) {
            guard let attachment = record.attachment,
                  !alreadyRemote.contains(attachment.sha256),
                  uploaded.insert(attachment.sha256).inserted else { continue }

            let payload: Data
            if let cached = snapshotPayloads[attachment.sha256] ?? downloadedPayloads[attachment.sha256] {
                payload = cached
            } else if let item = itemsByID[record.id],
                      let loaded = try await attachmentPayload(for: item)?.data {
                payload = loaded
            } else {
                throw SyncServiceError.missingAttachment
            }
            guard payload.count == attachment.byteCount,
                  SyncDigest.hash(payload) == attachment.sha256 else {
                throw SyncServiceError.corruptAttachment
            }
            let encrypted = try SyncCipher.seal(payload, keyData: keyData)
            let remoteName = try SyncCipher.remoteAttachmentName(
                contentHash: attachment.sha256,
                keyData: keyData
            )
            try await transport.writeAttachmentIfNeeded(encrypted, named: remoteName)
        }
    }

    private func recordsWithAttachments(in archive: SyncArchive) -> [SyncClipboardRecord] {
        archive.items + (archive.conflicts ?? []).compactMap(\.item)
    }

    private func compactRemoteAttachments(
        in archive: SyncArchive,
        previousCandidates: [String: Date],
        transport: any SyncTransport,
        keyData: Data,
        now: Date = Date()
    ) async throws -> [String: Date] {
        var liveNames = Set<String>()
        for attachment in recordsWithAttachments(in: archive).compactMap(\.attachment) {
            let name = try SyncCipher.remoteAttachmentName(
                contentHash: attachment.sha256,
                keyData: keyData
            )
            liveNames.insert(name)
            // Builds before sync format v2 accidentally stripped non-hex
            // suffix letters, producing `.b`; keep that alias live until the
            // corresponding record or conflict copy really expires.
            liveNames.insert(name.filter { $0.isHexDigit || $0 == "." })
        }

        let remoteObjects = try await transport.listAttachments()
        let remoteNames = Set(remoteObjects.map(\.name))
        var candidates = previousCandidates.filter {
            remoteNames.contains($0.key) && !liveNames.contains($0.key)
        }
        let gracePeriod: TimeInterval = 7 * 24 * 60 * 60
        for object in remoteObjects where !liveNames.contains(object.name) {
            guard let firstSeen = candidates[object.name] else {
                candidates[object.name] = now
                continue
            }
            if let modifiedAt = object.modifiedAt, modifiedAt > firstSeen {
                candidates[object.name] = now
                continue
            }
            guard now.timeIntervalSince(firstSeen) >= gracePeriod else { continue }
            try await transport.deleteAttachment(named: object.name)
            candidates.removeValue(forKey: object.name)
        }
        return candidates
    }

    private func attachmentPayload(for item: ClipboardItem) async throws -> LocalAttachmentPayload? {
        if item.hasStoredImageData, let data = item.imageData {
            let hash = await Task.detached(priority: .utility) { SyncDigest.hash(data) }.value
            return LocalAttachmentPayload(
                attachment: SyncAttachment(
                    kind: .image,
                    sha256: hash,
                    byteCount: data.count,
                    uti: item.imageUTI,
                    fileName: nil,
                    pixelWidth: item.imagePixelWidth,
                    pixelHeight: item.imagePixelHeight
                ),
                data: data
            )
        }

        guard let url = item.resolvedFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              let byteCount = values?.fileSize,
              byteCount <= Self.maximumAttachmentBytes else { return nil }
        let data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
        let hash = await Task.detached(priority: .utility) { SyncDigest.hash(data) }.value
        let kind: SyncAttachmentKind = item.itemType == .image ? .image : .file
        return LocalAttachmentPayload(
            attachment: SyncAttachment(
                kind: kind,
                sha256: hash,
                byteCount: data.count,
                uti: UTType(filenameExtension: url.pathExtension)?.identifier,
                fileName: url.lastPathComponent,
                pixelWidth: item.imagePixelWidth,
                pixelHeight: item.imagePixelHeight
            ),
            data: data
        )
    }

    private func portableContent(for item: ClipboardItem) -> String {
        switch item.itemType {
        case .file, .video:
            return item.resolvedFileURL?.lastPathComponent ?? item.content
        case .image where !item.hasStoredImageData:
            return item.resolvedFileURL?.lastPathComponent ?? item.content
        default:
            return item.content
        }
    }

    private func attachmentSourceSignature(for item: ClipboardItem) -> String {
        if item.hasStoredImageData {
            return [
                "embedded", String(item.imageByteCount ?? -1), item.imageUTI ?? "",
                String(item.imagePixelWidth ?? -1), String(item.imagePixelHeight ?? -1),
                String(item.imageStorageVersion ?? -1)
            ].joined(separator: "|")
        }
        guard let url = item.resolvedFileURL,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
              ]), values.isRegularFile == true else {
            return "none"
        }
        return [
            "file", url.path, String(values.fileSize ?? -1),
            values.contentModificationDate.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }

    private func writeSyncedFile(_ data: Data, itemID: UUID, suggestedName: String?) async throws -> URL {
        let safeName = sanitizedFileName(suggestedName ?? "attachment")
        let directory = AppContainer.storeURL.deletingLastPathComponent()
            .appendingPathComponent("SyncedFiles", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(safeName)
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        }.value
    }

    private func sanitizedFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0").union(.newlines)
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let result = parts.joined(separator: "-")
        return result.isEmpty ? "attachment" : String(result.prefix(180))
    }

    private func makeStateIndex(for archive: SyncArchive) -> SyncStateIndex {
        let itemsByID = Dictionary(uniqueKeysWithValues: (try? context.fetch(FetchDescriptor<ClipboardItem>()))?.map { ($0.id, $0) } ?? [])
        var result = SyncStateIndex(clock: archive.greatestVersion)
        for record in archive.items {
            guard let item = itemsByID[record.id] else { continue }
            result.items[record.id.uuidString] = SyncStateEntry(
                sourceFingerprint: sourceFingerprint(for: item),
                contentHash: record.contentHash,
                modifiedAt: record.modifiedAt,
                modifiedBy: record.modifiedBy,
                deleted: false,
                attachment: record.attachment,
                version: record.effectiveVersion,
                fieldHashes: record.syncFieldHashes,
                fieldVersions: record.fieldVersions,
                tagSet: record.tagSet,
                groupSet: record.groupSet
            )
        }
        for group in archive.groups {
            result.groups[group.id.uuidString] = SyncStateEntry(
                sourceFingerprint: group.contentHash,
                contentHash: group.contentHash,
                modifiedAt: group.modifiedAt,
                modifiedBy: group.modifiedBy,
                deleted: false,
                attachment: nil,
                version: group.effectiveVersion,
                fieldHashes: group.syncFieldHashes,
                fieldVersions: group.fieldVersions
            )
        }
        for tombstone in archive.tombstones {
            let entry = SyncStateEntry(
                sourceFingerprint: "",
                contentHash: "",
                modifiedAt: tombstone.modifiedAt,
                modifiedBy: tombstone.modifiedBy,
                deleted: true,
                attachment: nil,
                version: tombstone.effectiveVersion
            )
            switch tombstone.kind {
            case .clipboardItem: result.items[tombstone.id.uuidString] = entry
            case .group: result.groups[tombstone.id.uuidString] = entry
            }
        }
        return result
    }

    private func sourceFingerprint(for item: ClipboardItem) -> String {
        sourceFingerprint(
            for: item,
            portableContent: portableContent(for: item),
            attachmentSignature: attachmentSourceSignature(for: item)
        )
    }

    private func sourceFingerprint(
        for item: ClipboardItem,
        portableContent: String,
        attachmentSignature: String
    ) -> String {
        var components = [item.id.uuidString, item.type, portableContent, item.sourceApp]
        components.append(String(item.createdAt.timeIntervalSince1970))
        components.append(String(item.isFavorite))
        components.append(String(item.isPinned))
        components.append(item.preview ?? "")
        components.append(item.deletedAt.map { String($0.timeIntervalSince1970) } ?? "")
        components.append(item.tagsRaw ?? "")
        components.append(item.customTitle ?? "")
        components.append(item.ocrText ?? "")
        components.append(item.groupIDsRaw ?? "")
        components.append(attachmentSignature)
        return SyncDigest.hash(components)
    }

    private var syncDeviceID: String {
        if let existing = defaults.string(forKey: SyncPreferenceKeys.deviceID), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: SyncPreferenceKeys.deviceID)
        return generated
    }

    private func versionImmediatelyBefore(
        _ version: SyncHybridTimestamp,
        deviceID: String
    ) -> SyncHybridTimestamp {
        if version.logical > 0 {
            return SyncHybridTimestamp(
                physicalMilliseconds: version.physicalMilliseconds,
                logical: version.logical - 1,
                deviceID: deviceID
            )
        }
        return SyncHybridTimestamp(
            physicalMilliseconds: version.physicalMilliseconds == Int64.min
                ? Int64.min
                : version.physicalMilliseconds - 1,
            logical: 0,
            deviceID: deviceID
        )
    }

    private func stringFromKeychain(_ account: SyncKeychain.Account) -> String {
        guard let data = SyncKeychain.data(for: account) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct LocalSyncSnapshot {
    let archive: SyncArchive
    let payloads: [String: Data]
}

private struct LocalAttachmentPayload {
    let attachment: SyncAttachment
    let data: Data
}

private struct SyncStateEntry: Codable {
    var sourceFingerprint: String
    var contentHash: String
    var modifiedAt: Date
    var modifiedBy: String
    var deleted: Bool
    var attachment: SyncAttachment?
    var version: SyncHybridTimestamp? = nil
    var fieldHashes: [String: String]? = nil
    var fieldVersions: [String: SyncHybridTimestamp]? = nil
    var tagSet: SyncObservedSet? = nil
    var groupSet: SyncObservedSet? = nil
}

private struct SyncStateIndex: Codable {
    static let currentFormatVersion = 2

    var formatVersion = currentFormatVersion
    var items: [String: SyncStateEntry] = [:]
    var groups: [String: SyncStateEntry] = [:]
    var clock: SyncHybridTimestamp? = nil
    var pendingBatch: SyncOperationBatch? = nil
    var attachmentGarbageCandidates: [String: Date]? = nil

    init(
        formatVersion: Int = currentFormatVersion,
        items: [String: SyncStateEntry] = [:],
        groups: [String: SyncStateEntry] = [:],
        clock: SyncHybridTimestamp? = nil,
        pendingBatch: SyncOperationBatch? = nil,
        attachmentGarbageCandidates: [String: Date]? = nil
    ) {
        self.formatVersion = formatVersion
        self.items = items
        self.groups = groups
        self.clock = clock
        self.pendingBatch = pendingBatch
        self.attachmentGarbageCandidates = attachmentGarbageCandidates
    }

    mutating func observe(_ timestamp: SyncHybridTimestamp?) {
        guard let timestamp else { return }
        clock = max(clock ?? timestamp, timestamp)
    }

    mutating func nextTimestamp(now: Date, deviceID: String) -> SyncHybridTimestamp {
        let next = SyncHybridTimestamp.next(after: clock, observing: nil, now: now, deviceID: deviceID)
        clock = next
        return next
    }

    func validate() throws {
        guard (1...Self.currentFormatVersion).contains(formatVersion),
              clock?.isValid ?? true,
              items.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              groups.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw SyncServiceError.corruptLocalState
        }
        try pendingBatch?.validate()
        guard attachmentGarbageCandidates?.keys.allSatisfy({ !$0.isEmpty }) ?? true else {
            throw SyncServiceError.corruptLocalState
        }
        let entries = Array(items.values) + Array(groups.values)
        guard entries.allSatisfy({ entry in
            !entry.modifiedBy.isEmpty &&
                (entry.version?.isValid ?? true) &&
                (entry.fieldVersions?.values.allSatisfy(\.isValid) ?? true) &&
                (entry.tagSet?.isValid ?? true) &&
                (entry.groupSet?.isValid ?? true) &&
                (!entry.deleted || (entry.contentHash.isEmpty && entry.attachment == nil))
        }) else {
            throw SyncServiceError.corruptLocalState
        }
    }
}

private enum SyncStateStore {
    private static var url: URL {
        AppContainer.storeURL.deletingLastPathComponent().appendingPathComponent("sync-state.json")
    }

    static func load() throws -> SyncStateIndex {
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncStateIndex() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SyncServiceError.localStateUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            var result = try decoder.decode(SyncStateIndex.self, from: data)
            try result.validate()
            result.formatVersion = SyncStateIndex.currentFormatVersion
            return result
        } catch {
            quarantineCorruptState()
            throw SyncServiceError.corruptLocalState
        }
    }

    static func save(_ index: SyncStateIndex) throws {
        try index.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SyncServiceError.localStateUnavailable
        }
    }

    private static func quarantineCorruptState() {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("sync-state.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: destination)
    }
}

enum SyncServiceError: LocalizedError {
    case providerDisabled
    case iCloudUnavailable
    case folderUnavailable
    case missingAttachment
    case corruptAttachment
    case corruptLocalState
    case localStateUnavailable
    case corruptJournal

    var errorDescription: String? {
        switch self {
        case .providerDisabled: return L("settings.sync.error.disabled")
        case .iCloudUnavailable: return L("settings.sync.error.icloudUnavailable")
        case .folderUnavailable: return L("settings.sync.error.folderUnavailable")
        case .missingAttachment: return L("settings.sync.error.missingAttachment")
        case .corruptAttachment: return L("settings.sync.error.corruptAttachment")
        case .corruptLocalState: return L("settings.sync.error.localStateCorrupt")
        case .localStateUnavailable: return L("settings.sync.error.localStateUnavailable")
        case .corruptJournal: return L("settings.sync.error.corruptJournal")
        }
    }
}

extension Notification.Name {
    static let clipTraceSyncDidComplete = Notification.Name("ClipTraceSyncDidComplete")
    static let clipTraceSyncDidFail = Notification.Name("ClipTraceSyncDidFail")
}
