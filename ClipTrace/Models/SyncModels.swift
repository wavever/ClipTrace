import CryptoKit
import Foundation

enum SyncProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case iCloudDrive
    case webDAV
    case localFolder
    case s3

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .off: return L("settings.sync.provider.off")
        case .iCloudDrive: return L("settings.sync.provider.icloud")
        case .webDAV: return L("settings.sync.provider.webdav")
        case .localFolder: return L("settings.sync.provider.folder")
        case .s3: return L("settings.sync.provider.s3")
        }
    }
}

enum SyncEntityKind: String, Codable, Sendable {
    case clipboardItem
    case group
}

enum SyncAttachmentKind: String, Codable, Sendable {
    case image
    case file
}

struct SyncAttachment: Codable, Equatable, Sendable {
    var kind: SyncAttachmentKind
    var sha256: String
    var byteCount: Int
    var uti: String?
    var fileName: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

/// A hybrid logical clock keeps causality monotonic even when a device clock
/// moves backwards. The device identifier is part of the total ordering so
/// independently-created timestamps still converge deterministically.
struct SyncHybridTimestamp: Codable, Equatable, Hashable, Comparable, Sendable {
    var physicalMilliseconds: Int64
    var logical: Int
    var deviceID: String

    init(physicalMilliseconds: Int64, logical: Int = 0, deviceID: String) {
        self.physicalMilliseconds = physicalMilliseconds
        self.logical = logical
        self.deviceID = deviceID
    }

    init(date: Date, deviceID: String) {
        self.init(
            physicalMilliseconds: Int64((date.timeIntervalSince1970 * 1_000).rounded()),
            deviceID: deviceID
        )
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(physicalMilliseconds) / 1_000)
    }

    var isValid: Bool { logical >= 0 && !deviceID.isEmpty }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logical != rhs.logical { return lhs.logical < rhs.logical }
        return lhs.deviceID < rhs.deviceID
    }

    static func next(after previous: Self?, observing remote: Self?, now: Date, deviceID: String) -> Self {
        let wall = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let greatest = [previous, remote].compactMap { $0 }.max()
        guard let greatest else {
            return Self(physicalMilliseconds: wall, deviceID: deviceID)
        }
        if wall > greatest.physicalMilliseconds {
            return Self(physicalMilliseconds: wall, deviceID: deviceID)
        }
        return Self(
            physicalMilliseconds: greatest.physicalMilliseconds,
            logical: greatest.logical + 1,
            deviceID: deviceID
        )
    }
}

struct SyncObservedSet: Codable, Equatable, Sendable {
    struct Addition: Codable, Equatable, Sendable {
        var value: String
        var version: SyncHybridTimestamp
    }

    var additions: [String: Addition]
    var removals: [String: SyncHybridTimestamp]

    init(additions: [String: Addition] = [:], removals: [String: SyncHybridTimestamp] = [:]) {
        self.additions = additions
        self.removals = removals
    }

    static func seeded(
        with values: [String],
        version: SyncHybridTimestamp,
        key: (String) -> String
    ) -> Self {
        var result = Self()
        for value in values {
            let canonical = key(value)
            guard !canonical.isEmpty else { continue }
            result.additions[canonical] = Addition(value: value, version: version)
        }
        return result
    }

    func reconciling(
        with values: [String],
        at version: SyncHybridTimestamp,
        key: (String) -> String
    ) -> Self {
        var result = self
        let incoming = Dictionary(
            values.compactMap { value -> (String, String)? in
                let canonical = key(value)
                return canonical.isEmpty ? nil : (canonical, value)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        for (canonical, value) in incoming {
            let current = result.additions[canonical]
            let isVisible = current.map { addition in
                guard let removal = result.removals[canonical] else { return true }
                return removal < addition.version
            } ?? false
            if !isVisible || current?.value != value {
                result.additions[canonical] = Addition(value: value, version: version)
            }
        }
        for canonical in result.visibleKeys where incoming[canonical] == nil {
            if let existing = result.removals[canonical] {
                result.removals[canonical] = max(existing, version)
            } else {
                result.removals[canonical] = version
            }
        }
        return result
    }

    func merging(_ other: Self) -> Self {
        var result = self
        for (key, candidate) in other.additions {
            guard let current = result.additions[key] else {
                result.additions[key] = candidate
                continue
            }
            if current.version < candidate.version ||
                (current.version == candidate.version && current.value < candidate.value) {
                result.additions[key] = candidate
            }
        }
        for (key, candidate) in other.removals {
            if let current = result.removals[key] {
                result.removals[key] = max(current, candidate)
            } else {
                result.removals[key] = candidate
            }
        }
        return result
    }

    var visibleKeys: Set<String> {
        Set(additions.compactMap { key, addition in
            guard let removal = removals[key] else { return key }
            return removal < addition.version ? key : nil
        })
    }

    var visibleValues: [String] {
        visibleKeys.compactMap { additions[$0]?.value }.sorted {
            let lhs = $0.lowercased()
            let rhs = $1.lowercased()
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    var latestVersion: SyncHybridTimestamp? {
        (additions.values.map(\.version) + Array(removals.values)).max()
    }

    var isValid: Bool {
        !additions.keys.contains(where: \.isEmpty) &&
            !removals.keys.contains(where: \.isEmpty) &&
            additions.values.allSatisfy { !$0.value.isEmpty && $0.version.isValid } &&
            removals.values.allSatisfy(\.isValid)
    }
}

struct SyncClipboardRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var type: String
    var content: String
    var sourceApp: String
    var createdAt: Date
    var isFavorite: Bool
    var isPinned: Bool
    var preview: String?
    var deletedAt: Date?
    var tagsRaw: String?
    var customTitle: String?
    var ocrText: String?
    var groupIDsRaw: String?
    var attachment: SyncAttachment?
    var modifiedAt: Date
    var modifiedBy: String
    var contentHash: String
    var version: SyncHybridTimestamp? = nil
    var fieldVersions: [String: SyncHybridTimestamp]? = nil
    var tagSet: SyncObservedSet? = nil
    var groupSet: SyncObservedSet? = nil

    static let versionedFields = [
        "type", "content", "sourceApp", "createdAt", "isFavorite", "isPinned",
        "preview", "deletedAt", "tagsRaw", "customTitle", "ocrText", "groupIDsRaw",
        "attachment"
    ]

    var syncFieldHashes: [String: String] {
        [
            "type": SyncDigest.hash(type),
            "content": SyncDigest.hash(content),
            "sourceApp": SyncDigest.hash(sourceApp),
            "createdAt": SyncDigest.hash(createdAt),
            "isFavorite": SyncDigest.hash(isFavorite),
            "isPinned": SyncDigest.hash(isPinned),
            "preview": SyncDigest.hash(OptionalPayload(preview)),
            "deletedAt": SyncDigest.hash(OptionalPayload(deletedAt)),
            "tagsRaw": SyncDigest.hash(OptionalPayload(tagsRaw)),
            "customTitle": SyncDigest.hash(OptionalPayload(customTitle)),
            "ocrText": SyncDigest.hash(OptionalPayload(ocrText)),
            "groupIDsRaw": SyncDigest.hash(OptionalPayload(groupIDsRaw)),
            "attachment": SyncDigest.hash(OptionalPayload(attachment))
        ]
    }

    var effectiveVersion: SyncHybridTimestamp {
        ([legacyVersion, version, fieldVersions?.values.max(), tagSet?.latestVersion, groupSet?.latestVersion]
            .compactMap { $0 }).max() ?? legacyVersion
    }

    var legacyVersion: SyncHybridTimestamp {
        SyncHybridTimestamp(date: modifiedAt, deviceID: modifiedBy)
    }

    mutating func normalizeMetadata() {
        let fallback = effectiveVersion
        var versions = fieldVersions ?? [:]
        for field in Self.versionedFields where versions[field] == nil {
            versions[field] = fallback
        }
        fieldVersions = versions
        tagSet = tagSet ?? .seeded(with: parsedTags, version: versions["tagsRaw"] ?? fallback, key: Self.tagKey)
        groupSet = groupSet ?? .seeded(
            with: parsedGroupIDs,
            version: versions["groupIDsRaw"] ?? fallback,
            key: Self.groupKey
        )
        tagsRaw = Self.rawValue(tagSet?.visibleValues ?? [])
        groupIDsRaw = Self.rawValue(groupSet?.visibleValues ?? [])
        version = (Array(versions.values) + [fallback] +
            [tagSet?.latestVersion, groupSet?.latestVersion].compactMap { $0 }).max() ?? fallback
        modifiedAt = version?.date ?? modifiedAt
        modifiedBy = version?.deviceID ?? modifiedBy
        refreshContentHash()
    }

    mutating func stampLocalChanges(
        previousHashes: [String: String]?,
        previousVersions: [String: SyncHybridTimestamp]?,
        previousTagSet: SyncObservedSet?,
        previousGroupSet: SyncObservedSet?,
        at changeVersion: SyncHybridTimestamp
    ) {
        let hashes = syncFieldHashes
        var versions = previousVersions ?? [:]
        for field in Self.versionedFields {
            if previousHashes?[field] != hashes[field] || versions[field] == nil {
                versions[field] = changeVersion
            }
        }
        fieldVersions = versions
        tagSet = (previousTagSet ?? SyncObservedSet()).reconciling(
            with: parsedTags,
            at: changeVersion,
            key: Self.tagKey
        )
        groupSet = (previousGroupSet ?? SyncObservedSet()).reconciling(
            with: parsedGroupIDs,
            at: changeVersion,
            key: Self.groupKey
        )
        version = changeVersion
        modifiedAt = changeVersion.date
        modifiedBy = changeVersion.deviceID
        normalizeMetadata()
    }

    private var parsedTags: [String] {
        tagsRaw?.split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
    }

    private var parsedGroupIDs: [String] {
        groupIDsRaw?.split(separator: "\n").compactMap {
            UUID(uuidString: String($0))?.uuidString
        } ?? []
    }

    fileprivate static func tagKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate static func groupKey(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? ""
    }

    fileprivate static func rawValue(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: "\n")
    }

    mutating func refreshContentHash() {
        contentHash = Self.contentHash(
            id: id,
            type: type,
            content: content,
            sourceApp: sourceApp,
            createdAt: createdAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            preview: preview,
            deletedAt: deletedAt,
            tagsRaw: tagsRaw,
            customTitle: customTitle,
            ocrText: ocrText,
            groupIDsRaw: groupIDsRaw,
            attachment: attachment
        )
    }

    var hasValidContentHash: Bool {
        contentHash == Self.contentHash(
            id: id,
            type: type,
            content: content,
            sourceApp: sourceApp,
            createdAt: createdAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            preview: preview,
            deletedAt: deletedAt,
            tagsRaw: tagsRaw,
            customTitle: customTitle,
            ocrText: ocrText,
            groupIDsRaw: groupIDsRaw,
            attachment: attachment
        )
    }

    private static func contentHash(
        id: UUID,
        type: String,
        content: String,
        sourceApp: String,
        createdAt: Date,
        isFavorite: Bool,
        isPinned: Bool,
        preview: String?,
        deletedAt: Date?,
        tagsRaw: String?,
        customTitle: String?,
        ocrText: String?,
        groupIDsRaw: String?,
        attachment: SyncAttachment?
    ) -> String {
        let payload = ContentPayload(
            id: id,
            type: type,
            content: content,
            sourceApp: sourceApp,
            createdAt: createdAt,
            isFavorite: isFavorite,
            isPinned: isPinned,
            preview: preview,
            deletedAt: deletedAt,
            tagsRaw: tagsRaw,
            customTitle: customTitle,
            ocrText: ocrText,
            groupIDsRaw: groupIDsRaw,
            attachment: attachment
        )
        return SyncDigest.hash(payload)
    }

    private struct ContentPayload: Encodable {
        let id: UUID
        let type: String
        let content: String
        let sourceApp: String
        let createdAt: Date
        let isFavorite: Bool
        let isPinned: Bool
        let preview: String?
        let deletedAt: Date?
        let tagsRaw: String?
        let customTitle: String?
        let ocrText: String?
        let groupIDsRaw: String?
        let attachment: SyncAttachment?
    }

    private struct OptionalPayload<Value: Encodable>: Encodable {
        let value: Value?
        init(_ value: Value?) { self.value = value }
    }
}

struct SyncGroupRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var modifiedAt: Date
    var modifiedBy: String
    var contentHash: String
    var version: SyncHybridTimestamp? = nil
    var fieldVersions: [String: SyncHybridTimestamp]? = nil

    static let versionedFields = ["name", "sortOrder", "createdAt"]

    var syncFieldHashes: [String: String] {
        [
            "name": SyncDigest.hash(name),
            "sortOrder": SyncDigest.hash(sortOrder),
            "createdAt": SyncDigest.hash(createdAt)
        ]
    }

    var effectiveVersion: SyncHybridTimestamp {
        ([legacyVersion, version, fieldVersions?.values.max()].compactMap { $0 }).max() ?? legacyVersion
    }

    var legacyVersion: SyncHybridTimestamp {
        SyncHybridTimestamp(date: modifiedAt, deviceID: modifiedBy)
    }

    mutating func normalizeMetadata() {
        let fallback = effectiveVersion
        var versions = fieldVersions ?? [:]
        for field in Self.versionedFields where versions[field] == nil {
            versions[field] = fallback
        }
        fieldVersions = versions
        version = max(versions.values.max() ?? fallback, fallback)
        modifiedAt = version?.date ?? modifiedAt
        modifiedBy = version?.deviceID ?? modifiedBy
        refreshContentHash()
    }

    mutating func stampLocalChanges(
        previousHashes: [String: String]?,
        previousVersions: [String: SyncHybridTimestamp]?,
        at changeVersion: SyncHybridTimestamp
    ) {
        let hashes = syncFieldHashes
        var versions = previousVersions ?? [:]
        for field in Self.versionedFields {
            if previousHashes?[field] != hashes[field] || versions[field] == nil {
                versions[field] = changeVersion
            }
        }
        fieldVersions = versions
        version = changeVersion
        modifiedAt = changeVersion.date
        modifiedBy = changeVersion.deviceID
        normalizeMetadata()
    }

    mutating func refreshContentHash() {
        contentHash = Self.contentHash(
            id: id,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt
        )
    }

    var hasValidContentHash: Bool {
        contentHash == Self.contentHash(
            id: id,
            name: name,
            sortOrder: sortOrder,
            createdAt: createdAt
        )
    }

    private static func contentHash(id: UUID, name: String, sortOrder: Int, createdAt: Date) -> String {
        SyncDigest.hash(ContentPayload(id: id, name: name, sortOrder: sortOrder, createdAt: createdAt))
    }

    private struct ContentPayload: Encodable {
        let id: UUID
        let name: String
        let sortOrder: Int
        let createdAt: Date
    }
}

struct SyncTombstone: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: SyncEntityKind
    var modifiedAt: Date
    var modifiedBy: String
    var version: SyncHybridTimestamp? = nil

    var effectiveVersion: SyncHybridTimestamp {
        max(version ?? SyncHybridTimestamp(date: modifiedAt, deviceID: modifiedBy),
            SyncHybridTimestamp(date: modifiedAt, deviceID: modifiedBy))
    }

    mutating func normalizeMetadata() {
        version = effectiveVersion
        modifiedAt = effectiveVersion.date
        modifiedBy = effectiveVersion.deviceID
    }
}

struct SyncConflictCopy: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var entityID: UUID
    var kind: SyncEntityKind
    var detectedAt: Date
    var conflictingFields: [String]
    var item: SyncClipboardRecord?
    var group: SyncGroupRecord?
}

struct SyncOperationBatch: Codable, Equatable, Identifiable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: String
    var deviceID: String
    var version: SyncHybridTimestamp
    var createdAt: Date
    var items: [SyncClipboardRecord]
    var groups: [SyncGroupRecord]
    var tombstones: [SyncTombstone]

    var remoteName: String { "\(id).cte" }

    var archive: SyncArchive {
        SyncArchive(
            formatVersion: SyncArchive.currentFormatVersion,
            generatedAt: createdAt,
            items: items,
            groups: groups,
            tombstones: tombstones
        )
    }

    static func make(
        deviceID: String,
        createdAt: Date,
        items: [SyncClipboardRecord],
        groups: [SyncGroupRecord],
        tombstones: [SyncTombstone]
    ) -> Self? {
        let versions = items.map(\.effectiveVersion) + groups.map(\.effectiveVersion) +
            tombstones.map(\.effectiveVersion)
        guard let version = versions.max(), !deviceID.isEmpty else { return nil }
        let payloadID = SyncDigest.hash(OperationIdentity(
            deviceID: deviceID,
            version: version,
            itemHashes: items.map { "\($0.id.uuidString):\($0.contentHash)" }.sorted(),
            groupHashes: groups.map { "\($0.id.uuidString):\($0.contentHash)" }.sorted(),
            tombstones: tombstones.map {
                "\($0.kind.rawValue):\($0.id.uuidString):\($0.effectiveVersion.physicalMilliseconds):\($0.effectiveVersion.logical):\($0.effectiveVersion.deviceID)"
            }.sorted()
        ))
        return Self(
            formatVersion: currentFormatVersion,
            id: payloadID,
            deviceID: deviceID,
            version: version,
            createdAt: createdAt,
            items: items,
            groups: groups,
            tombstones: tombstones
        )
    }

    func coalescing(with newer: Self, now: Date) -> Self {
        let merged = SyncArchiveMerger.merge(local: archive, remote: newer.archive, now: now)
        return Self.make(
            deviceID: newer.deviceID,
            createdAt: now,
            items: merged.items,
            groups: merged.groups,
            tombstones: merged.tombstones
        ) ?? newer
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              !id.isEmpty,
              !deviceID.isEmpty,
              version.isValid,
              version.deviceID == deviceID else {
            throw SyncModelError.invalidMetadata
        }
        let rebuilt = Self.make(
            deviceID: deviceID,
            createdAt: createdAt,
            items: items,
            groups: groups,
            tombstones: tombstones
        )
        guard rebuilt?.id == id, rebuilt?.version == version else {
            throw SyncModelError.corruptContent
        }
        try archive.validate()
    }

    private struct OperationIdentity: Encodable {
        let deviceID: String
        let version: SyncHybridTimestamp
        let itemHashes: [String]
        let groupHashes: [String]
        let tombstones: [String]
    }
}

enum SyncOperationCodec {
    static func encode(_ batch: SyncOperationBatch) throws -> Data {
        try batch.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(batch)
    }

    static func decode(_ data: Data) throws -> SyncOperationBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let batch = try decoder.decode(SyncOperationBatch.self, from: data)
        try batch.validate()
        return batch
    }
}

struct SyncArchive: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var generatedAt: Date
    var items: [SyncClipboardRecord]
    var groups: [SyncGroupRecord]
    var tombstones: [SyncTombstone]
    var conflicts: [SyncConflictCopy]? = nil
    var deviceAcknowledgements: [String: SyncHybridTimestamp]? = nil
    var journalWatermarks: [String: SyncHybridTimestamp]? = nil

    static var empty: SyncArchive {
        SyncArchive(
            formatVersion: currentFormatVersion,
            generatedAt: .distantPast,
            items: [],
            groups: [],
            tombstones: [],
            conflicts: [],
            deviceAcknowledgements: [:],
            journalWatermarks: [:]
        )
    }

    func validate() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw SyncModelError.newerFormat(formatVersion)
        }
        guard formatVersion > 0 else {
            throw SyncModelError.invalidFormat
        }
        guard items.allSatisfy(\.hasValidContentHash),
              groups.allSatisfy(\.hasValidContentHash) else {
            throw SyncModelError.corruptContent
        }
        guard Set(items.map(\.id)).count == items.count,
              Set(groups.map(\.id)).count == groups.count,
              Set(tombstones.map { "\($0.kind.rawValue):\($0.id.uuidString)" }).count == tombstones.count,
              Set((conflicts ?? []).map(\.id)).count == (conflicts ?? []).count else {
            throw SyncModelError.duplicateEntity
        }
        let liveKeys = Set(items.map { "\(SyncEntityKind.clipboardItem.rawValue):\($0.id.uuidString)" })
            .union(groups.map { "\(SyncEntityKind.group.rawValue):\($0.id.uuidString)" })
        let deletedKeys = Set(tombstones.map { "\($0.kind.rawValue):\($0.id.uuidString)" })
        guard liveKeys.isDisjoint(with: deletedKeys) else {
            throw SyncModelError.duplicateEntity
        }
        guard items.allSatisfy({ record in
            (record.version?.isValid ?? true) &&
                (record.fieldVersions?.keys.allSatisfy { SyncClipboardRecord.versionedFields.contains($0) } ?? true) &&
                (record.fieldVersions?.values.allSatisfy(\.isValid) ?? true) &&
                (record.tagSet?.isValid ?? true) &&
                (record.groupSet?.isValid ?? true) &&
                (record.tagSet?.additions.allSatisfy {
                    $0.key == SyncClipboardRecord.tagKey($0.value.value)
                } ?? true) &&
                (record.groupSet?.additions.allSatisfy {
                    $0.key == SyncClipboardRecord.groupKey($0.value.value)
                } ?? true)
        }), groups.allSatisfy({ record in
            (record.version?.isValid ?? true) &&
                (record.fieldVersions?.keys.allSatisfy { SyncGroupRecord.versionedFields.contains($0) } ?? true) &&
                (record.fieldVersions?.values.allSatisfy(\.isValid) ?? true)
        }), tombstones.allSatisfy({ $0.version?.isValid ?? true }),
        (deviceAcknowledgements?.values.allSatisfy(\.isValid) ?? true) else {
            throw SyncModelError.invalidMetadata
        }
        guard journalWatermarks?.values.allSatisfy(\.isValid) ?? true else {
            throw SyncModelError.invalidMetadata
        }
        guard journalWatermarks?.allSatisfy({ $0.key == $0.value.deviceID }) ?? true,
              (conflicts ?? []).allSatisfy({ conflict in
                  guard !conflict.id.isEmpty,
                        !conflict.conflictingFields.isEmpty,
                        Set(conflict.conflictingFields).count == conflict.conflictingFields.count else {
                      return false
                  }
                  switch conflict.kind {
                  case .clipboardItem:
                      return conflict.group == nil &&
                          conflict.item?.id == conflict.entityID &&
                          conflict.item?.hasValidContentHash == true
                  case .group:
                      return conflict.item == nil &&
                          conflict.group?.id == conflict.entityID &&
                          conflict.group?.hasValidContentHash == true
                  }
              }) else {
            throw SyncModelError.invalidMetadata
        }
    }

    mutating func normalizeMetadata() {
        for index in items.indices { items[index].normalizeMetadata() }
        for index in groups.indices { groups[index].normalizeMetadata() }
        for index in tombstones.indices { tombstones[index].normalizeMetadata() }
        formatVersion = Self.currentFormatVersion
    }

    var greatestVersion: SyncHybridTimestamp? {
        let values = items.map(\.effectiveVersion) + groups.map(\.effectiveVersion) +
            tombstones.map(\.effectiveVersion) + Array(deviceAcknowledgements?.values ?? [:].values) +
            Array(journalWatermarks?.values ?? [:].values)
        return values.max()
    }
}

enum SyncModelError: LocalizedError {
    case invalidFormat
    case newerFormat(Int)
    case corruptContent
    case duplicateEntity
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return L("settings.sync.error.invalidFormat")
        case .newerFormat:
            return L("settings.sync.error.newerFormat")
        case .corruptContent:
            return L("settings.sync.error.corrupt")
        case .duplicateEntity:
            return L("settings.sync.error.duplicate")
        case .invalidMetadata:
            return L("settings.sync.error.metadata")
        }
    }
}

enum SyncArchiveCodec {
    static func encode(_ archive: SyncArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> SyncArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(SyncArchive.self, from: data)
        try archive.validate()
        return archive
    }
}

enum SyncArchiveMerger {
    private static let conflictRetention: TimeInterval = 30 * 24 * 60 * 60

    static func merge(local: SyncArchive, remote: SyncArchive, now: Date = Date()) -> SyncArchive {
        var local = local
        var remote = remote
        local.normalizeMetadata()
        remote.normalizeMetadata()

        let localItems = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        let remoteItems = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.id, $0) })
        let localGroups = Dictionary(uniqueKeysWithValues: local.groups.map { ($0.id, $0) })
        let remoteGroups = Dictionary(uniqueKeysWithValues: remote.groups.map { ($0.id, $0) })
        let localItemTombstones = tombstones(in: local, kind: .clipboardItem)
        let remoteItemTombstones = tombstones(in: remote, kind: .clipboardItem)
        let localGroupTombstones = tombstones(in: local, kind: .group)
        let remoteGroupTombstones = tombstones(in: remote, kind: .group)

        var items: [SyncClipboardRecord] = []
        var groups: [SyncGroupRecord] = []
        var deleted: [SyncTombstone] = []
        var newConflicts: [SyncConflictCopy] = []

        let itemIDs = Set(localItems.keys).union(remoteItems.keys)
            .union(localItemTombstones.keys).union(remoteItemTombstones.keys)
        for id in itemIDs {
            let record: SyncClipboardRecord?
            switch (localItems[id], remoteItems[id]) {
            case let (lhs?, rhs?):
                let result = mergeItem(lhs, rhs, now: now)
                record = result.record
                newConflicts.append(contentsOf: result.conflicts)
            case let (lhs?, nil): record = lhs
            case let (nil, rhs?): record = rhs
            case (nil, nil): record = nil
            }
            let tombstone = newerTombstone(localItemTombstones[id], remoteItemTombstones[id])
            if let tombstone, record == nil || record!.effectiveVersion <= tombstone.effectiveVersion {
                deleted.append(tombstone)
            } else if let record {
                items.append(record)
            }
        }

        let groupIDs = Set(localGroups.keys).union(remoteGroups.keys)
            .union(localGroupTombstones.keys).union(remoteGroupTombstones.keys)
        for id in groupIDs {
            let record: SyncGroupRecord?
            switch (localGroups[id], remoteGroups[id]) {
            case let (lhs?, rhs?):
                let result = mergeGroup(lhs, rhs, now: now)
                record = result.record
                newConflicts.append(contentsOf: result.conflicts)
            case let (lhs?, nil): record = lhs
            case let (nil, rhs?): record = rhs
            case (nil, nil): record = nil
            }
            let tombstone = newerTombstone(localGroupTombstones[id], remoteGroupTombstones[id])
            if let tombstone, record == nil || record!.effectiveVersion <= tombstone.effectiveVersion {
                deleted.append(tombstone)
            } else if let record {
                groups.append(record)
            }
        }

        // Group membership is an observed set. Recording a removal at least as
        // new as the deleted group's tombstone prevents stale membership adds
        // from recreating a dangling relationship on another device.
        let liveGroupIDs = Set(groups.map(\.id))
        let deletedGroups = Dictionary(uniqueKeysWithValues: deleted
            .filter { $0.kind == .group }
            .map { ($0.id, $0) })
        for index in items.indices {
            items[index].normalizeMetadata()
            guard var memberships = items[index].groupSet else { continue }
            var changed = false
            for (key, addition) in memberships.additions {
                guard let id = UUID(uuidString: addition.value), !liveGroupIDs.contains(id) else { continue }
                let deletionVersion = deletedGroups[id]?.effectiveVersion ?? items[index].effectiveVersion
                let removalVersion = max(addition.version, deletionVersion)
                if memberships.removals[key].map({ $0 < removalVersion }) ?? true {
                    memberships.removals[key] = removalVersion
                    changed = true
                }
            }
            guard changed else { continue }
            items[index].groupSet = memberships
            items[index].groupIDsRaw = SyncClipboardRecord.rawValue(memberships.visibleValues)
            var versions = items[index].fieldVersions ?? [:]
            versions["groupIDsRaw"] = max(
                versions["groupIDsRaw"] ?? items[index].effectiveVersion,
                memberships.latestVersion ?? items[index].effectiveVersion
            )
            items[index].fieldVersions = versions
            items[index].version = max(items[index].effectiveVersion, versions["groupIDsRaw"]!)
            items[index].modifiedAt = items[index].effectiveVersion.date
            items[index].modifiedBy = items[index].effectiveVersion.deviceID
            items[index].refreshContentHash()
        }

        var conflicts: [String: SyncConflictCopy] = [:]
        for conflict in (local.conflicts ?? []) + (remote.conflicts ?? []) + newConflicts {
            if let existing = conflicts[conflict.id], existing.detectedAt >= conflict.detectedAt { continue }
            conflicts[conflict.id] = conflict
        }
        let oldestConflict = now.addingTimeInterval(-conflictRetention)
        let retainedConflicts = conflicts.values.filter { $0.detectedAt >= oldestConflict }.sorted { $0.id < $1.id }

        var acknowledgements = local.deviceAcknowledgements ?? [:]
        for (device, timestamp) in remote.deviceAcknowledgements ?? [:] {
            acknowledgements[device] = max(acknowledgements[device] ?? timestamp, timestamp)
        }
        var journalWatermarks = local.journalWatermarks ?? [:]
        for (device, timestamp) in remote.journalWatermarks ?? [:] {
            journalWatermarks[device] = max(journalWatermarks[device] ?? timestamp, timestamp)
        }

        return SyncArchive(
            formatVersion: SyncArchive.currentFormatVersion,
            generatedAt: now,
            items: items.sorted { $0.id.uuidString < $1.id.uuidString },
            groups: groups.sorted { $0.id.uuidString < $1.id.uuidString },
            tombstones: deleted.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.id.uuidString < $1.id.uuidString
            },
            conflicts: retainedConflicts,
            deviceAcknowledgements: acknowledgements,
            journalWatermarks: journalWatermarks
        )
    }

    private static func tombstones(in archive: SyncArchive, kind: SyncEntityKind) -> [UUID: SyncTombstone] {
        Dictionary(uniqueKeysWithValues: archive.tombstones.filter { $0.kind == kind }.map { ($0.id, $0) })
    }

    private static func newerTombstone(_ lhs: SyncTombstone?, _ rhs: SyncTombstone?) -> SyncTombstone? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        if lhs.effectiveVersion != rhs.effectiveVersion {
            return lhs.effectiveVersion < rhs.effectiveVersion ? rhs : lhs
        }
        return lhs.modifiedBy < rhs.modifiedBy ? rhs : lhs
    }

    private static func mergeItem(
        _ lhs: SyncClipboardRecord,
        _ rhs: SyncClipboardRecord,
        now: Date
    ) -> (record: SyncClipboardRecord, conflicts: [SyncConflictCopy]) {
        var result = lhs
        var versions: [String: SyncHybridTimestamp] = [:]
        var lhsLostProtectedFields: [String] = []
        var rhsLostProtectedFields: [String] = []

        func choose<Value: Encodable & Equatable>(
            _ field: String,
            _ left: Value,
            _ right: Value,
            protected: Bool = false
        ) -> Value {
            let leftVersion = lhs.fieldVersions?[field] ?? lhs.effectiveVersion
            let rightVersion = rhs.fieldVersions?[field] ?? rhs.effectiveVersion
            versions[field] = max(leftVersion, rightVersion)
            guard left != right else { return left }
            let leftWins = fieldWinner(
                lhsValue: left,
                lhsVersion: leftVersion,
                rhsValue: right,
                rhsVersion: rightVersion
            )
            if protected {
                if leftWins { rhsLostProtectedFields.append(field) }
                else { lhsLostProtectedFields.append(field) }
            }
            return leftWins ? left : right
        }

        result.type = choose("type", lhs.type, rhs.type, protected: true)
        result.content = choose("content", lhs.content, rhs.content, protected: true)
        result.sourceApp = choose("sourceApp", lhs.sourceApp, rhs.sourceApp)
        result.createdAt = choose("createdAt", lhs.createdAt, rhs.createdAt)
        result.isFavorite = choose("isFavorite", lhs.isFavorite, rhs.isFavorite)
        result.isPinned = choose("isPinned", lhs.isPinned, rhs.isPinned)
        result.preview = choose("preview", lhs.preview, rhs.preview, protected: true)
        result.deletedAt = choose("deletedAt", lhs.deletedAt, rhs.deletedAt)
        result.customTitle = choose("customTitle", lhs.customTitle, rhs.customTitle, protected: true)
        result.ocrText = choose("ocrText", lhs.ocrText, rhs.ocrText, protected: true)
        result.attachment = choose("attachment", lhs.attachment, rhs.attachment, protected: true)

        let tags = (lhs.tagSet ?? SyncObservedSet()).merging(rhs.tagSet ?? SyncObservedSet())
        let memberships = (lhs.groupSet ?? SyncObservedSet()).merging(rhs.groupSet ?? SyncObservedSet())
        result.tagSet = tags
        result.groupSet = memberships
        result.tagsRaw = SyncClipboardRecord.rawValue(tags.visibleValues)
        result.groupIDsRaw = SyncClipboardRecord.rawValue(memberships.visibleValues)
        versions["tagsRaw"] = max(
            lhs.fieldVersions?["tagsRaw"] ?? lhs.effectiveVersion,
            rhs.fieldVersions?["tagsRaw"] ?? rhs.effectiveVersion
        )
        versions["groupIDsRaw"] = max(
            lhs.fieldVersions?["groupIDsRaw"] ?? lhs.effectiveVersion,
            rhs.fieldVersions?["groupIDsRaw"] ?? rhs.effectiveVersion
        )
        result.fieldVersions = versions
        result.version = (Array(versions.values) + [tags.latestVersion, memberships.latestVersion].compactMap { $0 }).max()
        result.modifiedAt = result.effectiveVersion.date
        result.modifiedBy = result.effectiveVersion.deviceID
        result.refreshContentHash()

        var conflicts: [SyncConflictCopy] = []
        if !lhsLostProtectedFields.isEmpty {
            conflicts.append(conflictCopy(item: lhs, merged: result, fields: lhsLostProtectedFields, now: now))
        }
        if !rhsLostProtectedFields.isEmpty {
            conflicts.append(conflictCopy(item: rhs, merged: result, fields: rhsLostProtectedFields, now: now))
        }
        return (result, conflicts)
    }

    private static func mergeGroup(
        _ lhs: SyncGroupRecord,
        _ rhs: SyncGroupRecord,
        now: Date
    ) -> (record: SyncGroupRecord, conflicts: [SyncConflictCopy]) {
        var result = lhs
        var versions: [String: SyncHybridTimestamp] = [:]
        var lhsLost: [String] = []
        var rhsLost: [String] = []

        func choose<Value: Encodable & Equatable>(_ field: String, _ left: Value, _ right: Value) -> Value {
            let leftVersion = lhs.fieldVersions?[field] ?? lhs.effectiveVersion
            let rightVersion = rhs.fieldVersions?[field] ?? rhs.effectiveVersion
            versions[field] = max(leftVersion, rightVersion)
            guard left != right else { return left }
            let leftWins = fieldWinner(
                lhsValue: left,
                lhsVersion: leftVersion,
                rhsValue: right,
                rhsVersion: rightVersion
            )
            if field == "name" {
                if leftWins { rhsLost.append(field) } else { lhsLost.append(field) }
            }
            return leftWins ? left : right
        }

        result.name = choose("name", lhs.name, rhs.name)
        result.sortOrder = choose("sortOrder", lhs.sortOrder, rhs.sortOrder)
        result.createdAt = choose("createdAt", lhs.createdAt, rhs.createdAt)
        result.fieldVersions = versions
        result.version = versions.values.max()
        result.modifiedAt = result.effectiveVersion.date
        result.modifiedBy = result.effectiveVersion.deviceID
        result.refreshContentHash()

        var conflicts: [SyncConflictCopy] = []
        if !lhsLost.isEmpty {
            conflicts.append(conflictCopy(group: lhs, merged: result, fields: lhsLost, now: now))
        }
        if !rhsLost.isEmpty {
            conflicts.append(conflictCopy(group: rhs, merged: result, fields: rhsLost, now: now))
        }
        return (result, conflicts)
    }

    private static func fieldWinner<Value: Encodable>(
        lhsValue: Value,
        lhsVersion: SyncHybridTimestamp,
        rhsValue: Value,
        rhsVersion: SyncHybridTimestamp
    ) -> Bool {
        if lhsVersion != rhsVersion { return rhsVersion < lhsVersion }
        return SyncDigest.hash(lhsValue) >= SyncDigest.hash(rhsValue)
    }

    private static func conflictCopy(
        item: SyncClipboardRecord,
        merged: SyncClipboardRecord,
        fields: [String],
        now: Date
    ) -> SyncConflictCopy {
        let sortedFields = fields.sorted()
        let id = SyncDigest.hash(
            "clipboardItem|\(item.id.uuidString)|\(item.contentHash)|\(merged.contentHash)|\(sortedFields.joined(separator: ","))"
        )
        return SyncConflictCopy(
            id: id,
            entityID: item.id,
            kind: .clipboardItem,
            detectedAt: now,
            conflictingFields: sortedFields,
            item: item,
            group: nil
        )
    }

    private static func conflictCopy(
        group: SyncGroupRecord,
        merged: SyncGroupRecord,
        fields: [String],
        now: Date
    ) -> SyncConflictCopy {
        let sortedFields = fields.sorted()
        let id = SyncDigest.hash(
            "group|\(group.id.uuidString)|\(group.contentHash)|\(merged.contentHash)|\(sortedFields.joined(separator: ","))"
        )
        return SyncConflictCopy(
            id: id,
            entityID: group.id,
            kind: .group,
            detectedAt: now,
            conflictingFields: sortedFields,
            item: nil,
            group: group
        )
    }
}

enum SyncArchiveGarbageCollector {
    static let tombstoneRetention: TimeInterval = 90 * 24 * 60 * 60

    static func compactTombstones(in archive: SyncArchive, now: Date = Date()) -> SyncArchive {
        var result = archive
        let acknowledgements = Array((archive.deviceAcknowledgements ?? [:]).values)
        guard !acknowledgements.isEmpty else { return result }
        let retentionCutoff = now.addingTimeInterval(-tombstoneRetention)
        result.tombstones.removeAll { tombstone in
            tombstone.effectiveVersion.date <= retentionCutoff &&
                acknowledgements.allSatisfy { tombstone.effectiveVersion <= $0 }
        }
        return result
    }
}

enum SyncDigest {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return hash(data)
    }
}
