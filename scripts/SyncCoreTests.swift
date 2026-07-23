import Foundation

func L(_ key: String) -> String { key }
func L(_ key: String, _ args: any CVarArg...) -> String {
    String(format: key, arguments: args)
}

@main
struct SyncCoreTests {
    static func main() async throws {
        try testNewerRecordWins()
        try testFieldLevelMergePreservesIndependentEdits()
        try testObservedSetsMergeConcurrentAdds()
        try testHybridClockSurvivesWallClockRollback()
        try testDeletionWinsAndGroupMembershipConverges()
        try testCodecRejectsTampering()
        try testCodecRejectsDuplicateEntities()
        try testLegacyArchiveMigratesToV2()
        try testOperationBatchRoundTrip()
        try testTombstoneGCWaitsForEveryDevice()
        try testEncryptionRoundTrip()
        try await testFileTransportCompareAndSwap()
        try await testWebDAVProtocolFlow()
        try await testS3ProtocolFlow()
        print("SyncCoreTests: all tests passed")
    }

    private static func testNewerRecordWins() throws {
        let id = UUID()
        let deviceA = "device-a"
        let deviceB = "device-b"
        var old = item(id: id, content: "old", modifiedAt: Date(timeIntervalSince1970: 10), device: deviceA)
        var new = old
        new.content = "new"
        new.modifiedAt = Date(timeIntervalSince1970: 20)
        new.modifiedBy = deviceB
        new.refreshContentHash()

        let merged = SyncArchiveMerger.merge(
            local: archive(items: [old]),
            remote: archive(items: [new]),
            now: Date(timeIntervalSince1970: 30)
        )
        try expect(merged.items.count == 1 && merged.items[0].content == "new", "newer record should win")

        old.modifiedAt = Date(timeIntervalSince1970: 40)
        old.refreshContentHash()
        let reverse = SyncArchiveMerger.merge(local: archive(items: [old]), remote: archive(items: [new]))
        try expect(reverse.items[0].content == "old", "newer local record should win")
    }

    private static func testFieldLevelMergePreservesIndependentEdits() throws {
        let id = UUID()
        let baseVersion = timestamp(100, device: "device-a")
        var base = item(id: id, content: "original", modifiedAt: baseVersion.date, device: baseVersion.deviceID)
        base.version = baseVersion
        base.fieldVersions = Dictionary(
            uniqueKeysWithValues: SyncClipboardRecord.versionedFields.map { ($0, baseVersion) }
        )
        base.normalizeMetadata()

        var favoriteEdit = base
        let favoriteVersion = timestamp(200, device: "device-a")
        favoriteEdit.isFavorite = true
        favoriteEdit.fieldVersions?["isFavorite"] = favoriteVersion
        favoriteEdit.version = favoriteVersion
        favoriteEdit.modifiedAt = favoriteVersion.date
        favoriteEdit.modifiedBy = favoriteVersion.deviceID
        favoriteEdit.refreshContentHash()

        var contentEdit = base
        let contentVersion = timestamp(300, device: "device-b")
        contentEdit.content = "updated elsewhere"
        contentEdit.fieldVersions?["content"] = contentVersion
        contentEdit.version = contentVersion
        contentEdit.modifiedAt = contentVersion.date
        contentEdit.modifiedBy = contentVersion.deviceID
        contentEdit.refreshContentHash()

        let merged = SyncArchiveMerger.merge(
            local: archive(items: [favoriteEdit]),
            remote: archive(items: [contentEdit]),
            now: Date(timeIntervalSince1970: 400)
        )
        try expect(merged.items[0].content == "updated elsewhere", "the newer content field should win")
        try expect(merged.items[0].isFavorite, "an independent favorite edit must not be overwritten")
        try expect(
            merged.conflicts?.contains(where: { $0.entityID == id && $0.conflictingFields.contains("content") }) == true,
            "a losing content value should be retained as a conflict copy"
        )
        let roundTripped = try SyncArchiveCodec.decode(SyncArchiveCodec.encode(merged))
        try expect(roundTripped == merged, "a v2 field merge and its conflict copy should validate and round-trip")
    }

    private static func testObservedSetsMergeConcurrentAdds() throws {
        let id = UUID()
        let baseVersion = timestamp(100, device: "device-a")
        var lhs = item(id: id, content: "tagged", modifiedAt: baseVersion.date, device: baseVersion.deviceID)
        lhs.version = baseVersion
        lhs.fieldVersions = Dictionary(
            uniqueKeysWithValues: SyncClipboardRecord.versionedFields.map { ($0, baseVersion) }
        )
        let workVersion = timestamp(200, device: "device-a")
        lhs.tagSet = .seeded(with: ["Work"], version: workVersion) { $0.lowercased() }
        lhs.tagsRaw = "Work"
        lhs.fieldVersions?["tagsRaw"] = workVersion
        lhs.version = workVersion
        lhs.refreshContentHash()

        var rhs = lhs
        let homeVersion = timestamp(200, device: "device-b")
        rhs.tagSet = .seeded(with: ["Home"], version: homeVersion) { $0.lowercased() }
        rhs.tagsRaw = "Home"
        rhs.fieldVersions?["tagsRaw"] = homeVersion
        rhs.version = homeVersion
        rhs.modifiedAt = homeVersion.date
        rhs.modifiedBy = homeVersion.deviceID
        rhs.refreshContentHash()

        let merged = SyncArchiveMerger.merge(local: archive(items: [lhs]), remote: archive(items: [rhs]))
        let tags = Set(merged.items[0].tagsRaw?.split(separator: "\n").map(String.init) ?? [])
        try expect(tags == Set(["Home", "Work"]), "concurrent tag additions should be unioned")
    }

    private static func testHybridClockSurvivesWallClockRollback() throws {
        let future = timestamp(9_000, logical: 3, device: "device-a")
        let next = SyncHybridTimestamp.next(
            after: future,
            observing: nil,
            now: Date(timeIntervalSince1970: 1),
            deviceID: "device-a"
        )
        try expect(next.physicalMilliseconds == future.physicalMilliseconds, "clock rollback must not lower physical time")
        try expect(next.logical == 4, "clock rollback should advance the logical counter")
    }

    private static func testDeletionWinsAndGroupMembershipConverges() throws {
        let groupID = UUID()
        let itemID = UUID()
        var group = SyncGroupRecord(
            id: groupID,
            name: "Work",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 5),
            modifiedBy: "device-a",
            contentHash: ""
        )
        group.refreshContentHash()
        var record = item(
            id: itemID,
            content: "grouped",
            modifiedAt: Date(timeIntervalSince1970: 5),
            device: "device-a"
        )
        record.groupIDsRaw = groupID.uuidString
        record.refreshContentHash()
        let deletion = SyncTombstone(
            id: groupID,
            kind: .group,
            modifiedAt: Date(timeIntervalSince1970: 10),
            modifiedBy: "device-b"
        )

        let merged = SyncArchiveMerger.merge(
            local: archive(items: [record], groups: [group]),
            remote: archive(tombstones: [deletion])
        )
        try expect(merged.groups.isEmpty, "newer group tombstone should delete the group")
        try expect(merged.items[0].groupIDsRaw == nil, "group deletion should remove dangling membership")
        try expect(merged.items[0].hasValidContentHash, "normalized membership must refresh the item hash")

        let itemDeletion = SyncTombstone(
            id: itemID,
            kind: .clipboardItem,
            modifiedAt: record.modifiedAt,
            modifiedBy: record.modifiedBy
        )
        let deleted = SyncArchiveMerger.merge(
            local: archive(items: [record]),
            remote: archive(tombstones: [itemDeletion])
        )
        try expect(deleted.items.isEmpty, "a tombstone should win an exact record-version tie")
    }

    private static func testCodecRejectsTampering() throws {
        let original = archive(items: [
            item(id: UUID(), content: "verified", modifiedAt: Date(), device: "device-a")
        ])
        let encoded = try SyncArchiveCodec.encode(original)
        let decoded = try SyncArchiveCodec.decode(encoded)
        try expect(decoded.items[0].content == "verified", "archive should round-trip")

        var tamperedData = encoded
        guard let contentRange = tamperedData.range(of: Data("verified".utf8)) else {
            throw TestFailure("encoded fixture should contain its plaintext content")
        }
        tamperedData.replaceSubrange(contentRange, with: Data("tampered".utf8))
        do {
            _ = try SyncArchiveCodec.decode(tamperedData)
            throw TestFailure("tampered content must fail its hash check")
        } catch SyncModelError.corruptContent {
            // Expected.
        }
    }

    private static func testCodecRejectsDuplicateEntities() throws {
        let duplicate = item(id: UUID(), content: "duplicate", modifiedAt: Date(), device: "device-a")
        do {
            let data = try SyncArchiveCodec.encode(archive(items: [duplicate, duplicate]))
            _ = try SyncArchiveCodec.decode(data)
            throw TestFailure("duplicate entity identifiers must be rejected")
        } catch SyncModelError.duplicateEntity {
            // Expected.
        }
    }

    private static func testLegacyArchiveMigratesToV2() throws {
        let legacy = SyncArchive(
            formatVersion: 1,
            generatedAt: Date(),
            items: [item(id: UUID(), content: "legacy", modifiedAt: Date(), device: "old-device")],
            groups: [],
            tombstones: []
        )
        let decoded = try SyncArchiveCodec.decode(SyncArchiveCodec.encode(legacy))
        try expect(decoded.items[0].version == nil, "v1 should decode before metadata normalization")
        let migrated = SyncArchiveMerger.merge(local: decoded, remote: .empty)
        try expect(migrated.formatVersion == 2, "the next merge should upgrade a v1 archive")
        try expect(migrated.items[0].version != nil, "migration should seed a hybrid version")
        try expect(
            migrated.items[0].fieldVersions?.count == SyncClipboardRecord.versionedFields.count,
            "migration should seed every field version"
        )
    }

    private static func testOperationBatchRoundTrip() throws {
        var record = item(id: UUID(), content: "incremental", modifiedAt: Date(), device: "device-a")
        let version = timestamp(500, device: "device-a")
        record.version = version
        record.fieldVersions = Dictionary(
            uniqueKeysWithValues: SyncClipboardRecord.versionedFields.map { ($0, version) }
        )
        record.normalizeMetadata()
        guard let batch = SyncOperationBatch.make(
            deviceID: "device-a",
            createdAt: Date(timeIntervalSince1970: 1),
            items: [record],
            groups: [],
            tombstones: []
        ) else {
            throw TestFailure("a changed record should create an operation batch")
        }
        let decoded = try SyncOperationCodec.decode(SyncOperationCodec.encode(batch))
        try expect(decoded == batch, "operation batches should round-trip")

        var tampered = decoded
        tampered.items[0].content = "tampered"
        do {
            _ = try SyncOperationCodec.encode(tampered)
            throw TestFailure("operation payload tampering must fail validation")
        } catch SyncModelError.corruptContent {
            // Expected.
        }
    }

    private static func testTombstoneGCWaitsForEveryDevice() throws {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let deletionVersion = SyncHybridTimestamp(
            date: now.addingTimeInterval(-SyncArchiveGarbageCollector.tombstoneRetention - 1),
            deviceID: "device-a"
        )
        let deletion = SyncTombstone(
            id: UUID(),
            kind: .clipboardItem,
            modifiedAt: deletionVersion.date,
            modifiedBy: deletionVersion.deviceID,
            version: deletionVersion
        )
        var waiting = archive(tombstones: [deletion])
        waiting.deviceAcknowledgements = [
            "device-a": timestamp(30_000_000_000, device: "device-a"),
            "device-b": timestamp(deletionVersion.physicalMilliseconds - 1, device: "device-b")
        ]
        let retained = SyncArchiveGarbageCollector.compactTombstones(in: waiting, now: now)
        try expect(retained.tombstones.count == 1, "an unacknowledged device must retain the tombstone")

        waiting.deviceAcknowledgements?["device-b"] = timestamp(
            deletionVersion.physicalMilliseconds + 1,
            device: "device-b"
        )
        let compacted = SyncArchiveGarbageCollector.compactTombstones(in: waiting, now: now)
        try expect(compacted.tombstones.isEmpty, "an old tombstone can expire after every device acknowledges it")
    }

    private static func testEncryptionRoundTrip() throws {
        let key = try SyncCipher.generateKeyData()
        let plaintext = Data("clipboard secret".utf8)
        let ciphertext = try SyncCipher.seal(plaintext, keyData: key)
        try expect(ciphertext != plaintext, "ciphertext should not expose plaintext")
        try expect(try SyncCipher.open(ciphertext, keyData: key) == plaintext, "encrypted data should round-trip")

        let recovery = try SyncCipher.recoveryKey(from: key)
        try expect(try SyncCipher.keyData(fromRecoveryKey: recovery) == key, "recovery key should round-trip")
        let name1 = try SyncCipher.remoteAttachmentName(contentHash: "abc", keyData: key)
        let name2 = try SyncCipher.remoteAttachmentName(contentHash: "abc", keyData: key)
        let otherName = try SyncCipher.remoteAttachmentName(
            contentHash: "abc",
            keyData: SyncCipher.generateKeyData()
        )
        try expect(name1 == name2 && name1 != otherName, "remote names should be keyed and deterministic")

        do {
            _ = try SyncCipher.open(ciphertext, keyData: SyncCipher.generateKeyData())
            throw TestFailure("the wrong recovery key must not decrypt")
        } catch SyncSecurityError.decryptionFailed {
            // Expected.
        }
    }

    private static func testFileTransportCompareAndSwap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipthSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FileSyncTransport(rootURL: root, securityScoped: false)
        try await transport.prepare()
        let initial = try await transport.readManifest()
        try expect(initial == nil, "new transport should have no manifest")

        let first = Data("first".utf8)
        try await transport.writeManifest(first, replacing: nil)
        guard let revision = try await transport.readManifest() else {
            throw TestFailure("written manifest should be readable")
        }
        try expect(revision.data == first, "manifest bytes should round-trip")

        do {
            try await transport.writeManifest(Data("stale".utf8), replacing: nil)
            throw TestFailure("create-only write must reject an existing manifest")
        } catch SyncTransportError.concurrentChange {
            // Expected.
        }
        let second = Data("second".utf8)
        try await transport.writeManifest(second, replacing: revision.revision)
        let updated = try await transport.readManifest()
        try expect(updated?.data == second, "compare-and-swap update should succeed")

        try await transport.writeAttachmentIfNeeded(Data("payload".utf8), named: "aabb.bin")
        let attachment = try await transport.readAttachment(named: "aabb.bin")
        try expect(
            attachment == Data("payload".utf8),
            "attachments should round-trip"
        )
        let listedAttachments = try await transport.listAttachments()
        try expect(listedAttachments.map(\.name) == ["aabb.bin"], "attachments should be listable")
        try await transport.deleteAttachment(named: "aabb.bin")
        let remainingAttachments = try await transport.listAttachments()
        try expect(remainingAttachments.isEmpty, "attachments should be deletable")

        try await transport.writeJournalEntryIfNeeded(Data("operation".utf8), named: "ccdd.cte")
        let listedJournal = try await transport.listJournalEntries()
        try expect(listedJournal.map(\.name) == ["ccdd.cte"], "journal entries should be listable")
        let journalPayload = try await transport.readJournalEntry(named: "ccdd.cte")
        try expect(
            journalPayload == Data("operation".utf8),
            "journal entries should round-trip"
        )
        try await transport.deleteJournalEntry(named: "ccdd.cte")
        let remainingJournal = try await transport.listJournalEntries()
        try expect(remainingJournal.isEmpty, "journal entries should be compactable")
    }

    private static func testWebDAVProtocolFlow() async throws {
        MockWebDAVURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWebDAVURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = WebDAVSyncTransport(
            baseURL: URL(string: "https://dav.example.test/user/")!,
            username: "alice",
            password: "secret",
            session: session
        )

        try await transport.prepare()
        let initial = try await transport.readManifest()
        try expect(initial == nil, "empty WebDAV folder should return no manifest")
        try await transport.writeManifest(Data("one".utf8), replacing: nil)
        guard let first = try await transport.readManifest() else {
            throw TestFailure("WebDAV manifest should be readable after PUT")
        }
        try expect(first.data == Data("one".utf8), "WebDAV GET should return stored manifest bytes")
        try expect(first.revision.hasPrefix("etag:"), "WebDAV should preserve the server ETag")

        try await transport.writeManifest(Data("two".utf8), replacing: first.revision)
        do {
            try await transport.writeManifest(Data("stale".utf8), replacing: first.revision)
            throw TestFailure("stale WebDAV ETag must be rejected")
        } catch SyncTransportError.concurrentChange {
            // Expected.
        }

        try await transport.writeAttachmentIfNeeded(Data("attachment".utf8), named: "aabb.bin")
        let attachment = try await transport.readAttachment(named: "aabb.bin")
        try expect(attachment == Data("attachment".utf8), "WebDAV attachment should round-trip")
        try await transport.writeJournalEntryIfNeeded(Data("operation".utf8), named: "ccdd.cte")
        let listedJournal = try await transport.listJournalEntries()
        try expect(listedJournal.map(\.name) == ["ccdd.cte"], "WebDAV should list journals")
        let journalPayload = try await transport.readJournalEntry(named: "ccdd.cte")
        try expect(
            journalPayload == Data("operation".utf8),
            "WebDAV journal should round-trip"
        )
        try await transport.deleteJournalEntry(named: "ccdd.cte")
        let remainingJournal = try await transport.listJournalEntries()
        try expect(remainingJournal.isEmpty, "WebDAV should compact journals")
        try expect(MockWebDAVURLProtocol.sawBasicAuthentication, "WebDAV requests should carry Basic auth")
        try expect(MockWebDAVURLProtocol.sawCreateOnlyCondition, "initial manifest PUT should be create-only")
        try expect(MockWebDAVURLProtocol.sawCompareAndSwapCondition, "manifest update should use If-Match")
    }

    private static func testS3ProtocolFlow() async throws {
        MockS3URLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockS3URLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let transport = S3SyncTransport(
            configuration: S3SyncConfiguration(
                endpoint: URL(string: "https://s3.example.test")!,
                region: "us-east-1",
                bucket: "clipth-test",
                prefix: "alice",
                accessKeyID: "AKIDEXAMPLE",
                secretAccessKey: "secret",
                sessionToken: "temporary-token",
                pathStyle: true
            ),
            session: session,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        try await transport.prepare()
        let initial = try await transport.readManifest()
        try expect(initial == nil, "a new S3 prefix should have no manifest")
        try await transport.writeManifest(Data("one".utf8), replacing: nil)
        guard let first = try await transport.readManifest() else {
            throw TestFailure("S3 manifest should be readable")
        }
        try expect(first.data == Data("one".utf8), "S3 manifest bytes should round-trip")
        try await transport.writeManifest(Data("two".utf8), replacing: first.revision)
        do {
            try await transport.writeManifest(Data("stale".utf8), replacing: first.revision)
            throw TestFailure("a stale S3 ETag must be rejected")
        } catch SyncTransportError.concurrentChange {
            // Expected.
        }

        try await transport.writeAttachmentIfNeeded(Data("attachment".utf8), named: "aabb.bin")
        let attachments = try await transport.listAttachments()
        try expect(attachments.map(\.name) == ["aabb.bin"], "S3 attachments should be listable")
        let attachment = try await transport.readAttachment(named: "aabb.bin")
        try expect(
            attachment == Data("attachment".utf8),
            "S3 attachment should round-trip"
        )
        try await transport.writeJournalEntryIfNeeded(Data("operation".utf8), named: "ccdd.cte")
        let journal = try await transport.listJournalEntries()
        try expect(journal.map(\.name) == ["ccdd.cte"], "S3 journals should be listable")
        try await transport.deleteJournalEntry(named: "ccdd.cte")
        let remainingJournal = try await transport.listJournalEntries()
        try expect(remainingJournal.isEmpty, "S3 journals should be compactable")
        try expect(MockS3URLProtocol.sawSignature, "S3 requests should use SigV4 authorization")
        try expect(MockS3URLProtocol.sawSessionToken, "temporary S3 credentials should include their session token")
        try expect(MockS3URLProtocol.sawCreateOnlyCondition, "S3 immutable writes should use If-None-Match")
        try expect(MockS3URLProtocol.sawCompareAndSwapCondition, "S3 manifest updates should use If-Match")
    }

    private static func item(
        id: UUID,
        content: String,
        modifiedAt: Date,
        device: String
    ) -> SyncClipboardRecord {
        var value = SyncClipboardRecord(
            id: id,
            type: "text",
            content: content,
            sourceApp: "Tests",
            createdAt: Date(timeIntervalSince1970: 1),
            isFavorite: false,
            isPinned: false,
            preview: nil,
            deletedAt: nil,
            tagsRaw: nil,
            customTitle: nil,
            ocrText: nil,
            groupIDsRaw: nil,
            attachment: nil,
            modifiedAt: modifiedAt,
            modifiedBy: device,
            contentHash: ""
        )
        value.refreshContentHash()
        return value
    }

    private static func archive(
        items: [SyncClipboardRecord] = [],
        groups: [SyncGroupRecord] = [],
        tombstones: [SyncTombstone] = []
    ) -> SyncArchive {
        SyncArchive(
            formatVersion: SyncArchive.currentFormatVersion,
            generatedAt: Date(),
            items: items,
            groups: groups,
            tombstones: tombstones
        )
    }

    private static func timestamp(
        _ milliseconds: Int64,
        logical: Int = 0,
        device: String
    ) -> SyncHybridTimestamp {
        SyncHybridTimestamp(
            physicalMilliseconds: milliseconds,
            logical: logical,
            deviceID: device
        )
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class MockWebDAVURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var manifest: Data?
    private static var etagVersion = 0
    private static var attachments: [String: Data] = [:]
    private static var journals: [String: Data] = [:]
    private(set) static var sawBasicAuthentication = false
    private(set) static var sawCreateOnlyCondition = false
    private(set) static var sawCompareAndSwapCondition = false

    static func reset() {
        lock.lock()
        manifest = nil
        etagVersion = 0
        attachments = [:]
        journals = [:]
        sawBasicAuthentication = false
        sawCreateOnlyCondition = false
        sawCompareAndSwapCondition = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let url = request.url else { return }
        let expectedAuthentication = "Basic " + Data("alice:secret".utf8).base64EncodedString()
        if request.value(forHTTPHeaderField: "Authorization") == expectedAuthentication {
            Self.sawBasicAuthentication = true
        }

        let method = request.httpMethod ?? "GET"
        let path = url.path
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        if method == "MKCOL" {
            status = 201
        } else if path.hasSuffix("manifest.cte") {
            switch method {
            case "GET":
                if let manifest = Self.manifest {
                    body = manifest
                    headers["ETag"] = "\"v\(Self.etagVersion)\""
                } else {
                    status = 404
                }
            case "PUT":
                if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                    Self.sawCreateOnlyCondition = true
                    if Self.manifest != nil { status = 412 }
                } else if let condition = request.value(forHTTPHeaderField: "If-Match") {
                    Self.sawCompareAndSwapCondition = true
                    if condition != "\"v\(Self.etagVersion)\"" { status = 412 }
                }
                if status != 412 {
                    Self.manifest = Self.bodyData(from: request)
                    Self.etagVersion += 1
                    status = 201
                }
            default:
                status = 405
            }
        } else if method == "PROPFIND" && (
            path.hasSuffix("/attachments/") || path.hasSuffix("/attachments") ||
                path.hasSuffix("/journal/") || path.hasSuffix("/journal")
        ) {
            let isJournal = path.hasSuffix("/journal/") || path.hasSuffix("/journal")
            let values = isJournal ? Self.journals : Self.attachments
            let directory = isJournal ? "journal" : "attachments"
            let children = values.keys.sorted().map {
                "<d:response><d:href>/user/.clipth-sync-v1/\(directory)/\($0)</d:href><d:propstat><d:prop><d:getlastmodified>Tue, 14 Jul 2026 00:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>"
            }.joined()
            body = Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/user/.clipth-sync-v1/\(directory)/</d:href></d:response>\(children)</d:multistatus>".utf8)
            status = 207
        } else if path.contains("/attachments/") {
            let name = url.lastPathComponent
            switch method {
            case "HEAD":
                status = Self.attachments[name] == nil ? 404 : 200
            case "GET":
                if let stored = Self.attachments[name] {
                    body = stored
                } else {
                    status = 404
                }
            case "PUT":
                Self.attachments[name] = Self.bodyData(from: request)
                status = 201
            case "DELETE":
                Self.attachments.removeValue(forKey: name)
                status = 204
            default:
                status = 405
            }
        } else if path.contains("/journal/") {
            let name = url.lastPathComponent
            switch method {
            case "GET":
                if let stored = Self.journals[name] { body = stored }
                else { status = 404 }
            case "PUT":
                if request.value(forHTTPHeaderField: "If-None-Match") == "*", Self.journals[name] != nil {
                    status = 412
                } else {
                    Self.journals[name] = Self.bodyData(from: request)
                    status = 201
                }
            case "DELETE":
                Self.journals.removeValue(forKey: name)
                status = 204
            default:
                status = 405
            }
        } else {
            status = 404
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if method != "HEAD", !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func stopLoading() {}
}

private final class MockS3URLProtocol: URLProtocol {
    private struct StoredObject {
        var data: Data
        var etag: String
    }

    private static let lock = NSLock()
    private static var objects: [String: StoredObject] = [:]
    private static var version = 0
    private(set) static var sawSignature = false
    private(set) static var sawSessionToken = false
    private(set) static var sawCreateOnlyCondition = false
    private(set) static var sawCompareAndSwapCondition = false

    static func reset() {
        lock.lock()
        objects = [:]
        version = 0
        sawSignature = false
        sawSessionToken = false
        sawCreateOnlyCondition = false
        sawCompareAndSwapCondition = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let url = request.url else { return }
        if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") == true {
            Self.sawSignature = true
        }
        if request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "temporary-token" {
            Self.sawSessionToken = true
        }

        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        let key = url.path.removingPercentEncoding?
            .replacingOccurrences(of: "/clipth-test/", with: "", options: [.anchored]) ?? ""
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        if query["list-type"] == "2" {
            let prefix = query["prefix"] ?? ""
            let contents = Self.objects.keys.filter { $0.hasPrefix(prefix) }.sorted().map { key in
                "<Contents><Key>\(key)</Key><LastModified>2026-07-14T00:00:00Z</LastModified></Contents>"
            }.joined()
            body = Data("<?xml version=\"1.0\"?><ListBucketResult>\(contents)<IsTruncated>false</IsTruncated></ListBucketResult>".utf8)
        } else {
            switch method {
            case "GET":
                if let stored = Self.objects[key] {
                    body = stored.data
                    headers["ETag"] = stored.etag
                } else {
                    status = 404
                }
            case "PUT":
                if request.value(forHTTPHeaderField: "If-None-Match") == "*" {
                    Self.sawCreateOnlyCondition = true
                    if Self.objects[key] != nil { status = 412 }
                } else if let condition = request.value(forHTTPHeaderField: "If-Match") {
                    Self.sawCompareAndSwapCondition = true
                    if Self.objects[key]?.etag != condition { status = 412 }
                }
                if status != 412 {
                    Self.version += 1
                    let etag = "\"v\(Self.version)\""
                    Self.objects[key] = StoredObject(data: Self.bodyData(from: request), etag: etag)
                    headers["ETag"] = etag
                    status = 200
                }
            case "DELETE":
                Self.objects.removeValue(forKey: key)
                status = 204
            default:
                status = 405
            }
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func stopLoading() {}
}
