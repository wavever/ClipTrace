import Foundation
import SwiftUI
import SwiftData
import AppKit

/// Combinator for the tag filter chips in the search bar.
///
/// - `any` — item passes if *any* of its tags matches one of the selected
///   keys (set union / boolean OR). The common case.
/// - `all` — item passes only if it carries *every* selected key
///   (intersection / boolean AND). Useful for narrowing into a single
///   conceptual bucket.
enum TagFilterMode: String, CaseIterable, Identifiable {
    case any
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return L("search.tagMode.any")
        case .all: return L("search.tagMode.all")
        }
    }
}

/// Which engine drives the search bar. Mutually exclusive — the toolbar shows
/// these as three segmented buttons.
enum SearchMode: String, CaseIterable, Identifiable {
    case fullText
    case semantic
    case tag

    var id: String { rawValue }
}

enum ListScope: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return L("scope.all")
        case .favorites: return L("scope.favorites")
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .favorites: return "star.fill"
        }
    }
}

/// Sort order for the favorites scope. The "all" scope keeps its natural
/// reverse-chronological order, so this only applies inside 收藏.
enum FavoritesSortOrder: String, CaseIterable, Identifiable {
    case dateNewest
    case dateOldest
    case name
    case type

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateNewest: return L("favorites.sort.dateNewest")
        case .dateOldest: return L("favorites.sort.dateOldest")
        case .name:       return L("favorites.sort.name")
        case .type:       return L("favorites.sort.type")
        }
    }

    var icon: String {
        switch self {
        case .dateNewest: return "arrow.down"
        case .dateOldest: return "arrow.up"
        case .name:       return "textformat"
        case .type:       return "doc.text.image"
        }
    }
}

@MainActor
class ClipboardViewModel: ObservableObject {
    /// UserDefaults key for the master semantic-search feature toggle. When
    /// false, the toolbar hides the semantic mode segment and all queries
    /// fall back to keyword search.
    static let semanticFeatureEnabledKey = "semanticSearchFeatureEnabled"
    static let tagFilterModeKey = "tagFilterMode"

    @Published var searchText = ""
    /// Lowercased tag keys narrowing the visible list. Matching is
    /// case-insensitive; how the keys combine (union vs intersection) is
    /// driven by `tagFilterMode`.
    @Published var activeTags: Set<String> = []
    /// Combinator for `activeTags`. Persisted to UserDefaults so the choice
    /// survives relaunches and stays in sync with the Settings panel.
    var tagFilterMode: TagFilterMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.tagFilterModeKey)
                ?? TagFilterMode.any.rawValue
            return TagFilterMode(rawValue: raw) ?? .any
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.tagFilterModeKey)
        }
    }
    @Published var selectedType: ClipboardItemType? = nil
    @Published var selectedSourceApp: String? = nil
    @Published var selectedGroupFilter: ClipboardGroupFilter = .all
    @Published var selectedScope: ListScope = .all
    /// Sort order for the favorites scope. Persisted so the choice survives
    /// relaunches.
    @Published var favoritesSortOrder: FavoritesSortOrder = {
        let raw = UserDefaults.standard.string(forKey: "favoritesSortOrder")
            ?? FavoritesSortOrder.dateNewest.rawValue
        return FavoritesSortOrder(rawValue: raw) ?? .dateNewest
    }() {
        didSet {
            UserDefaults.standard.set(favoritesSortOrder.rawValue, forKey: "favoritesSortOrder")
        }
    }
    @Published private(set) var isMonitoring = false

    /// User-facing "pause capture" switch surfaced in the main window header
    /// and the menu-bar panel. Persisted so a paused session stays paused
    /// across relaunches; the visible toggles make that state obvious. While
    /// paused the poll timer is suspended — the history stays browsable but no
    /// new clips are recorded.
    static let pausedKey = "monitoringPaused"
    @Published var isCapturePaused: Bool = UserDefaults.standard.bool(forKey: ClipboardViewModel.pausedKey) {
        didSet {
            guard oldValue != isCapturePaused else { return }
            UserDefaults.standard.set(isCapturePaused, forKey: Self.pausedKey)
            monitor.setPaused(isCapturePaused, interval: Self.resolvedPollInterval())
        }
    }

    @Published var showExportPanel = false
    /// Active search engine for the toolbar. Persisted only in-memory — defaults
    /// back to full-text on relaunch, matching the previous behavior.
    @Published var searchMode: SearchMode = .fullText
    @Published var isSelectionMode = false
    @Published var selectedItemIDs: Set<UUID> = []
    @Published var showSnippetEditor = false
    /// Single-row keyboard focus — used by arrow keys and the Space-to-preview
    /// shortcut. Distinct from the multi-selection used by bulk actions. Nil
    /// means "no row focused"; consumers can fall back to the first visible row
    /// in that case.
    @Published var focusedItemID: UUID? = nil

    /// True while `backfillEmbeddings` is actively recomputing vectors. The
    /// toolbar uses this to disable the semantic segment, and the settings
    /// panel surfaces progress.
    @Published var isBackfillingEmbeddings: Bool = false
    @Published var backfillTotal: Int = 0
    @Published var backfillCompleted: Int = 0
    /// True while `backfillOCR` is walking image clips and running Vision on
    /// any that don't yet have recognized text. Independent from the embedding
    /// backfill so users can search by image text even while embeddings are
    /// still re-indexing.
    @Published var isBackfillingOCR: Bool = false

    /// Reflects the persisted master toggle. Published so SwiftUI views that
    /// observe the VM update when it flips. Updated by the settings panel via
    /// `setSemanticFeatureEnabled(_:)` so the in-memory mirror stays in sync.
    @Published var semanticFeatureEnabled: Bool = UserDefaults.standard.object(
        forKey: ClipboardViewModel.semanticFeatureEnabledKey
    ) as? Bool ?? true

    /// Monotonic bump counters published so views can rebuild O(n) derived
    /// state (allKnownTags, favorites count, pinned ordering) lazily — only
    /// when the relevant mutation actually happens, instead of scanning every
    /// row on every body re-run. Bumped from `addTag/removeTag/toggleFavorite/...`.
    @Published var tagCatalogVersion: Int = 0
    @Published var favoritesVersion: Int = 0
    @Published var pinsVersion: Int = 0
    @Published var groupsVersion: Int = 0

    func setSemanticFeatureEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.semanticFeatureEnabledKey)
        semanticFeatureEnabled = enabled
        // Turning the feature off should also drop the per-search toggle so
        // the next time it's re-enabled the user starts in plain text mode.
        if !enabled, searchMode == .semantic {
            searchMode = .fullText
        }
    }

    /// Absolute cosine similarity floor — anything below this is usually noise.
    private let semanticThreshold: Float = 0.35
    /// High-confidence semantic hits stay visible even when the top result is
    /// much stronger; this avoids a single perfect match hiding useful peers.
    private let semanticStrongThreshold: Float = 0.55
    /// Relative cutoff: drop any result that scores more than this far below
    /// the top hit. Short Chinese queries produce a long tail of weakly
    /// related vectors (e.g. "代码" pulling in "斤斤计较"); this keeps results
    /// clustered around the best match.
    private let semanticTopDelta: Float = 0.16
    /// Bonus added to items whose content literally contains the query — a
    /// substring hit is a strong relevance signal that pure cosine misses on
    /// very short queries.
    private let semanticKeywordBoost: Float = 0.35
    /// Smaller boost for source-app matches, useful when users remember where
    /// a clip came from but not the exact content.
    private let semanticSourceBoost: Float = 0.12

    let monitor = ClipboardMonitor()
    private var retentionTimer: Timer?
    private static let embeddingBackfillBatchSize = 12
    private static let ocrBackfillBatchSize = 2
    
    var filteredTypeDisplayName: String {
        selectedType?.displayName ?? L("common.all")
    }
    
    /// Drop entries that are older than the per-type retention setting and
    /// hard-delete trashed items past their grace period. Pinned and favorited
    /// items are exempt from per-type retention — users marked them on purpose.
    func applyRetentionCleanup(context: ModelContext) {
        let filters = FilterSettingsStore.shared
        let now = Date()
        var didMutate = false

        // 1) Purge expired trash.
        let trashDays = filters.trashRetentionDays
        if trashDays > 0 {
            let trashCutoff = now.addingTimeInterval(-Double(trashDays) * 86_400)
            var trashDescriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate { $0.deletedAt != nil }
            )
            trashDescriptor.propertiesToFetch = [\.deletedAt]
            for item in (try? context.fetch(trashDescriptor)) ?? [] {
                guard let deletedAt = item.deletedAt else { continue }
                if deletedAt < trashCutoff {
                    context.delete(item)
                    didMutate = true
                }
            }
        }

        // 2) Per-type retention on live history.
        for type in ClipboardItemType.allCases {
            let days = filters.retentionDays(for: type)
            guard days > 0 else { continue }
            let rawType = type.rawValue
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            var liveDescriptor = FetchDescriptor<ClipboardItem>(
                predicate: #Predicate {
                    $0.deletedAt == nil &&
                    !$0.isPinned &&
                    !$0.isFavorite &&
                    $0.type == rawType &&
                    $0.createdAt < cutoff
                }
            )
            liveDescriptor.propertiesToFetch = [\.deletedAt]
            for item in (try? context.fetch(liveDescriptor)) ?? [] {
                if filters.trashEnabled {
                    // Move into trash so user has a chance to recover.
                    item.deletedAt = now
                } else {
                    context.delete(item)
                }
                didMutate = true
            }
        }

        if didMutate {
            try? context.save()
            // History shrank — let the widgets re-read the new counts.
            WidgetBridge.shared.requestRefresh(context: context)
        }
    }

    /// All trashed items, newest deletion first.
    func trashedItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { $0.deletedAt != nil }
             .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private func scheduleRetentionTimer(context: ModelContext) {
        retentionTimer?.invalidate()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.applyRetentionCleanup(context: context)
            }
        }
    }

    // MARK: - User-configurable limits (read from the same UserDefaults keys
    // the settings UI writes via @AppStorage).

    /// History cap; falls back to the settings default of 500 and is clamped to
    /// the field's allowed range.
    static func resolvedMaxRecords() -> Int {
        let raw = UserDefaults.standard.integer(forKey: "maxRecords")
        return raw > 0 ? min(max(raw, 50), 100_000) : 500
    }

    /// Clipboard poll interval in seconds; falls back to 0.5s.
    static func resolvedPollInterval() -> TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "pollInterval")
        return raw > 0 ? raw : 0.5
    }

    /// Push the current poll-interval preference to the running monitor so a
    /// change in settings takes effect without relaunching.
    func updatePollInterval() {
        monitor.updateInterval(Self.resolvedPollInterval())
    }

    /// Trim live history down to the configured cap, deleting the oldest rows.
    /// Safe to call repeatedly; runs after every capture and whenever the user
    /// lowers the limit.
    func enforceMaxRecords(context: ModelContext) {
        // Cheap headcount first; only materialise the tail when over the cap so
        // we don't fault every image blob into memory on each paste.
        let limit = Self.resolvedMaxRecords()
        let countAll = FetchDescriptor<ClipboardItem>()
        guard let total = try? context.fetchCount(countAll), total > limit else { return }
        var tailDescriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        tailDescriptor.fetchOffset = limit
        tailDescriptor.fetchLimit = total - limit
        if let tail = try? context.fetch(tailDescriptor) {
            for oldItem in tail { context.delete(oldItem) }
            try? context.save()
        }
    }

    func startMonitoring(context: ModelContext) {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Retention sweep used to run synchronously on the very first frame,
        // which fetched every clipboard item (including embedded image data)
        // before the window could draw. Push it past the first paint so the
        // app feels snappy on launch — clips that are seconds-over the
        // retention boundary surviving for ~2s is harmless.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.applyRetentionCleanup(context: context)
        }
        scheduleRetentionTimer(context: context)

        monitor.startMonitoring(interval: Self.resolvedPollInterval()) { [weak self] type, rawContent, imageData, fileURL, sourceApp, bundleId in
            guard let self else { return }
            ClipboardMonitor.debugLog("[VM] onNewContent type=\(type) src=\(sourceApp) bundle=\(bundleId) hasImageData=\(imageData != nil) fileURL=\(fileURL ?? "nil") content=\(rawContent.prefix(80))")

            // Drop utm_*/fbclid/etc. before the URL ever lands in history.
            let content: String = {
                guard type == .url, FilterSettingsStore.shared.stripURLTracking else {
                    return rawContent
                }
                return URLSanitizer.clean(rawContent)
            }()

            // Apply user filter rules first.
            if FilterSettingsStore.shared.shouldExclude(
                type: type,
                content: content,
                sourceBundleId: bundleId
            ) {
                ClipboardMonitor.debugLog("[VM] excluded by filter")
                return
            }

            // Pre-insert tier of the scripting rules: a code-free `.drop` rule
            // excludes the clip entirely (no flash-in/out), same as the filter.
            if self.preInsertDropMatches(type: type, content: content, bundleId: bundleId) {
                ClipboardMonitor.debugLog("[VM] excluded by drop rule")
                return
            }

            // Re-copying the same content shouldn't grow a wall of duplicates
            // — refresh the existing entry's timestamp so it bubbles back to
            // the top, and still count the copy in stats. We only dedup
            // text-like clips: image/file/video share a content placeholder
            // ("[图片 12KB]") so equality would collapse unrelated clips.
            let isTextLike = (type == .text || type == .url || type == .rtf)
            if isTextLike {
                var recentDescriptor = FetchDescriptor<ClipboardItem>(
                    predicate: #Predicate { $0.content == content },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
                // We only ever read `existing.first`; capping the fetch keeps
                // the dedup probe O(1) instead of materialising every prior
                // copy of a hot string (URLs, tokens, repeated snippets).
                recentDescriptor.fetchLimit = 1
                if let existing = try? context.fetch(recentDescriptor),
                   let mostRecent = existing.first {
                    mostRecent.createdAt = Date()
                    try? context.save()
                    CopyStatsStore.shared.recordCopy()
                    WidgetBridge.shared.requestRefresh(context: context)
                    DynamicIslandController.shared.flash(
                        itemIcon: type.icon,
                        preview: String(ContentProtector.redact(content).redactedText.prefix(60))
                    )
                    return
                }
            }
            
            let item = ClipboardItem(
                type: type,
                content: content,
                imageData: imageData,
                fileURL: fileURL,
                sourceApp: sourceApp,
                preview: String(content.prefix(200))
            )
            context.insert(item)
            do {
                try context.save()
                ClipboardMonitor.debugLog("[VM] inserted id=\(item.id)")
            } catch {
                ClipboardMonitor.debugLog("[VM] insert FAILED: \(error)")
            }

            // Bump today's copy counter (guarded by user's toggle).
            CopyStatsStore.shared.recordCopy()

            // Refresh the widget snapshot (debounced) so the data/activity
            // widgets reflect the new clip.
            WidgetBridge.shared.requestRefresh(context: context)

            // Notify the Dynamic Island so it can briefly toast the new clip.
            DynamicIslandController.shared.flash(
                itemIcon: type.icon,
                preview: String(content.prefix(60))
            )

            // Run the user's scripting rules against the freshly-stored clip,
            // asynchronously and off-main — never blocks capture (mirrors the
            // OCR/embedding backfill below). A rule may transform, tag, rename,
            // or drop the clip a beat later.
            self.runRulesOnCapture(for: item, bundleId: bundleId, context: context)

            // Compute embedding off the main thread, then write back. For
            // image clips we also kick off an OCR pass so the recognized
            // text feeds both keyword search and the embedding vector.
            if type == .image {
                Task { @MainActor [item] in
                    let recognized = await OCRService.shared.recognize(item: item)
                    item.ocrText = recognized
                    try? context.save()
                    guard !recognized.isEmpty else { return }
                    let emb = await EmbeddingService.shared.embedAsync(recognized)
                    guard let emb else { return }
                    item.embedding = emb.data
                    item.embeddingLang = emb.language
                    try? context.save()
                }
            } else {
                let embedContent = content
                Task { @MainActor in
                    let emb = await EmbeddingService.shared.embedAsync(embedContent)
                    guard let emb else { return }
                    item.embedding = emb.data
                    item.embeddingLang = emb.language
                    try? context.save()
                }
            }

            // Trim old items down to the user-configured cap.
            self.enforceMaxRecords(context: context)
        }

        // Respect a pause that was persisted from a previous session — the
        // monitor just spun its timer up, so suspend it right back if needed.
        if isCapturePaused {
            monitor.setPaused(true, interval: Self.resolvedPollInterval())
        }
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.stopMonitoring()
        retentionTimer?.invalidate()
        retentionTimer = nil
    }
    
    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.itemType {
        case .text, .rtf, .url:
            // Optional cleanup: drop trailing whitespace/newlines that almost
            // never matter but commonly leak in from triple-click or
            // select-all in editors.
            var output = item.content
            if UserDefaults.standard.bool(forKey: "trimTrailingWhitespaceOnCopy") {
                output = output.replacingOccurrences(
                    of: "\\s+$",
                    with: "",
                    options: .regularExpression
                )
            }
            pasteboard.setString(output, forType: .string)
        case .image:
            if let data = item.imageData {
                pasteboard.setData(data, forType: .tiff)
            } else if let url = item.resolvedFileURL {
                pasteboard.writeObjects([url as NSURL])
            }
        case .video, .file:
            if let url = item.resolvedFileURL {
                pasteboard.writeObjects([url as NSURL])
            }
        }

        ClipboardMonitor.markInternalWrite()
    }

    /// Force-write `item` to the pasteboard as `.string` only — stripping rich
    /// formatting (RTF, file URLs) so the next paste lands as plain text.
    /// Image clips fall back to their localized preview tag because they have
    /// no meaningful plain-text representation.
    func copyAsPlainText(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let output: String
        switch item.itemType {
        case .text, .url:
            output = item.content
        case .rtf:
            output = Self.rtfPlainText(from: item.content) ?? item.content
        case .file, .video:
            output = item.resolvedFileURL?.path ?? item.content
        case .image:
            // No useful text rendition — fall back to OCR text when present,
            // otherwise the preview tag (e.g. "[Image 12KB]").
            if let ocr = item.ocrText, !ocr.isEmpty {
                output = ocr
            } else {
                output = item.preview ?? item.content
            }
        }
        pasteboard.setString(output, forType: .string)
        ClipboardMonitor.markInternalWrite()
    }

    /// Decode the stored RTF blob back to plain text. Returns nil if the
    /// content isn't valid RTF, in which case callers should fall back to
    /// the raw content.
    private static func rtfPlainText(from content: String) -> String? {
        guard let data = content.data(using: .utf8) ?? content.data(using: .ascii) else {
            return nil
        }
        let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attributed?.string
    }

    /// Hand-authored entry created via the snippet editor. Lives alongside
    /// captured clips but tagged with the localized snippet source label so
    /// it's distinguishable from real copies.
    @discardableResult
    func createSnippet(
        content: String,
        type: ClipboardItemType,
        pinned: Bool,
        context: ModelContext
    ) -> ClipboardItem {
        let item = ClipboardItem(
            type: type,
            content: content,
            sourceApp: L("snippet.sourceApp"),
            preview: String(content.prefix(200))
        )
        item.isPinned = pinned
        context.insert(item)
        try? context.save()
        if pinned { pinsVersion &+= 1 }

        // Embed off-thread so the snippet shows up in semantic search.
        Task { @MainActor in
            let emb = await EmbeddingService.shared.embedAsync(content)
            guard let emb else { return }
            item.embedding = emb.data
            item.embeddingLang = emb.language
            try? context.save()
        }
        return item
    }

    func deleteItem(_ item: ClipboardItem, context: ModelContext) {
        if FilterSettingsStore.shared.trashEnabled {
            // Soft-delete: keep the row around until trash retention expires.
            item.deletedAt = Date()
            try? context.save()
        } else {
            context.delete(item)
            try? context.save()
        }
    }

    /// Move an item back out of the trash. No-op for items that aren't trashed.
    func restoreItem(_ item: ClipboardItem, context: ModelContext) {
        guard item.deletedAt != nil else { return }
        item.deletedAt = nil
        item.createdAt = Date()
        try? context.save()
    }

    /// Hard-delete a single trashed item.
    func purgeItem(_ item: ClipboardItem, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    /// Drop every trashed entry. The active history is untouched.
    func emptyTrash(context: ModelContext) {
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        if let trashed = try? context.fetch(descriptor) {
            for item in trashed { context.delete(item) }
            try? context.save()
        }
    }

    func deleteAll(context: ModelContext) {
        let descriptor = FetchDescriptor<ClipboardItem>()
        if let all = try? context.fetch(descriptor) {
            for item in all {
                context.delete(item)
            }
            try? context.save()
        }
    }

    func toggleFavorite(_ item: ClipboardItem) {
        item.isFavorite.toggle()
        favoritesVersion &+= 1
    }

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        pinsVersion &+= 1
        if let context = item.modelContext {
            try? context.save()
        }
    }

    /// Apply a user-typed title to `item`. Empty / whitespace input clears
    /// the custom title and reverts the row to its default heuristic title.
    func rename(_ item: ClipboardItem, to newTitle: String, context: ModelContext) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        item.customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
        try? context.save()
    }

    @discardableResult
    func createGroup(named name: String, groups: [ClipboardGroup], context: ModelContext) -> ClipboardGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? L("group.untitled") : String(trimmed.prefix(40))
        let nextOrder = (groups.map(\.sortOrder).max() ?? -1) + 1
        let group = ClipboardGroup(name: resolvedName, sortOrder: nextOrder)
        context.insert(group)
        do {
            try context.save()
            groupsVersion &+= 1
            return group
        } catch {
            context.delete(group)
            return nil
        }
    }

    func renameGroup(_ group: ClipboardGroup, to newName: String, context: ModelContext) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        group.name = trimmed.isEmpty ? L("group.untitled") : String(trimmed.prefix(40))
        try? context.save()
        groupsVersion &+= 1
    }

    func moveGroup(_ group: ClipboardGroup, direction: Int, groups: [ClipboardGroup], context: ModelContext) {
        let sorted = groups.sortedForDisplay()
        guard let index = sorted.firstIndex(where: { $0.id == group.id }) else { return }
        let destination = index + direction
        guard sorted.indices.contains(destination) else { return }

        var reordered = sorted
        reordered.swapAt(index, destination)
        for (idx, item) in reordered.enumerated() {
            item.sortOrder = idx
        }
        try? context.save()
        groupsVersion &+= 1
    }

    func deleteGroup(_ group: ClipboardGroup, context: ModelContext) {
        let groupID = group.id
        if let items = try? context.fetch(FetchDescriptor<ClipboardItem>()) {
            for item in items where item.isInGroup(groupID) {
                item.removeFromGroup(groupID)
            }
        }
        context.delete(group)
        if selectedGroupFilter == .group(groupID) {
            selectedGroupFilter = .all
        }
        try? context.save()
        groupsVersion &+= 1
    }

    /// Toggle a single group's membership for one item. An item can belong to
    /// several groups, so this adds the group when absent and removes it when
    /// already present rather than replacing the whole assignment.
    func toggleGroup(_ item: ClipboardItem, group: ClipboardGroup, context: ModelContext) {
        if item.isInGroup(group.id) {
            item.removeFromGroup(group.id)
        } else {
            item.addToGroup(group.id)
        }
        try? context.save()
        groupsVersion &+= 1
    }

    /// Drop an item from every group it belongs to.
    func clearGroups(_ item: ClipboardItem, context: ModelContext) {
        item.setGroupIDs([])
        try? context.save()
        groupsVersion &+= 1
    }

    /// Batch group edit for the selection bar. A non-nil group is *added* to
    /// every selected item (existing memberships are kept); nil clears all
    /// group membership.
    func assign(_ items: [ClipboardItem], to group: ClipboardGroup?, context: ModelContext) {
        guard !items.isEmpty else { return }
        for item in items {
            if let group {
                item.addToGroup(group.id)
            } else {
                item.setGroupIDs([])
            }
        }
        try? context.save()
        groupsVersion &+= 1
        exitSelectionMode()
    }

    /// Soft- (or hard-) delete every active clip created in the last
    /// `minutes` minutes. Pinned and favorited entries are preserved on the
    /// theory that the user marked them on purpose; returns the affected count.
    @discardableResult
    func clearLastMinutes(_ minutes: Int, context: ModelContext) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= cutoff }
        )
        guard let items = try? context.fetch(descriptor) else { return 0 }
        let candidates = items.filter { !$0.isPinned && !$0.isFavorite }
        guard !candidates.isEmpty else { return 0 }

        let now = Date()
        if FilterSettingsStore.shared.trashEnabled {
            for item in candidates { item.deletedAt = now }
        } else {
            for item in candidates { context.delete(item) }
        }
        try? context.save()
        return candidates.count
    }

    /// Soft- (or hard-) delete every active clip created today (since the
    /// local-time start of day). Same favorite/pin exemption as `clearLastMinutes`.
    @discardableResult
    func clearToday(context: ModelContext) -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.createdAt >= startOfDay }
        )
        guard let items = try? context.fetch(descriptor) else { return 0 }
        let candidates = items.filter { !$0.isPinned && !$0.isFavorite }
        guard !candidates.isEmpty else { return 0 }

        let now = Date()
        if FilterSettingsStore.shared.trashEnabled {
            for item in candidates { item.deletedAt = now }
        } else {
            for item in candidates { context.delete(item) }
        }
        try? context.save()
        return candidates.count
    }

    /// Clears active clips whose capture time falls within `[from, to]`.
    /// Soft-deletes into trash when the trash is enabled, hard-deletes
    /// otherwise. Pinned/favorited rows are preserved. Returns the count moved.
    func clearRange(from: Date, to: Date, context: ModelContext) -> Int {
        let lower = min(from, to)
        let upper = max(from, to)
        let descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.createdAt >= lower && $0.createdAt <= upper
            }
        )
        guard let items = try? context.fetch(descriptor) else { return 0 }
        let candidates = items.filter { !$0.isPinned && !$0.isFavorite }
        guard !candidates.isEmpty else { return 0 }

        let now = Date()
        if FilterSettingsStore.shared.trashEnabled {
            for item in candidates { item.deletedAt = now }
        } else {
            for item in candidates { context.delete(item) }
        }
        try? context.save()
        return candidates.count
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        item.setTags(item.tags + [tag])
        tagCatalogVersion &+= 1
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        let key = tag.lowercased()
        item.setTags(item.tags.filter { $0.lowercased() != key })
        tagCatalogVersion &+= 1
    }

    // MARK: - Scripting rule effects

    /// Apply one `ScriptEffect` produced by a rule action to `item`, reusing the
    /// same verbs as manual user actions so there is a single mutation path.
    /// Returns true when the clip was dropped, letting the engine short-circuit
    /// the rest of the rule chain.
    ///
    /// Loop-safety: every case here mutates SwiftData (which the clipboard
    /// monitor does not observe) or, for the one pasteboard-writing case, marks
    /// an internal write — so applying an effect never re-enters capture or
    /// re-triggers rule evaluation, and is never counted as a user copy
    /// (`recordCopy` lives only on the capture path).
    @discardableResult
    func applyScriptEffect(_ effect: ScriptEffect, to item: ClipboardItem, context: ModelContext) -> Bool {
        switch effect {
        case .none:
            return false
        case .replaceText(let text):
            item.content = text
            item.preview = String(text.prefix(200))
            try? context.save()
        case .newClip(let text):
            let new = ClipboardItem(
                type: .text,
                content: text,
                sourceApp: L("rule.sourceApp"),
                preview: String(text.prefix(200))
            )
            context.insert(new)
            try? context.save()
        case .setTags(let tags):
            item.setTags(item.tags + tags)
            tagCatalogVersion &+= 1
            try? context.save()
        case .rename(let title):
            rename(item, to: title, context: context)
        case .copyToPasteboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Treat as our own write so the monitor doesn't re-capture it.
            ClipboardMonitor.markInternalWrite()
        case .drop:
            // Soft-delete (or hard, per trash setting) — mirrors the GUI and the
            // spec's "remove it if already stored" for a post-insert drop.
            deleteItem(item, context: context)
            return true
        }
        return false
    }

    /// Apply a sequence of effects in order, stopping early if one drops the
    /// clip. Used by both automatic (capture) and manual rule invocation so the
    /// chain semantics are identical.
    @discardableResult
    func applyScriptEffects(_ effects: [ScriptEffect], to item: ClipboardItem, context: ModelContext) -> Bool {
        for effect in effects {
            if applyScriptEffect(effect, to: item, context: context) {
                return true // dropped — short-circuit
            }
        }
        return false
    }

    // MARK: - Scripting rule execution

    /// Immutable input snapshot for runners. Reads the model on the main actor so
    /// the (value-typed, Sendable) result can cross to a background executor.
    private func makeScriptInput(_ item: ClipboardItem, bundleId: String) -> ScriptClipInput {
        ScriptClipInput(
            text: item.content,
            type: item.type,
            sourceApp: item.sourceApp,
            bundleId: bundleId,
            tags: item.tags,
            imageData: item.imageData
        )
    }

    /// Synchronous pre-insert tier: true when an enabled, code-free `.drop` rule
    /// matches, so the clip is excluded before it is ever stored (preserving the
    /// legacy filter's clean exclusion, no flash-in/flash-out).
    func preInsertDropMatches(type: ClipboardItemType, content: String, bundleId: String) -> Bool {
        for rule in FilterSettingsStore.shared.scriptingRules where rule.isEnabled {
            if case .drop = rule.action,
               rule.matches(type: type, content: content, sourceBundleId: bundleId) {
                return true
            }
        }
        return false
    }

    /// Run the enabled rule chain against a freshly-stored clip. The script body
    /// runs off the main actor; effects apply back on the main actor. Rules run
    /// in order; a `drop` short-circuits the rest. Never blocks capture.
    func runRulesOnCapture(for item: ClipboardItem, bundleId: String, context: ModelContext) {
        let rules = FilterSettingsStore.shared.scriptingRules.filter(\.isEnabled)
        guard !rules.isEmpty else { return }
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            for rule in rules {
                // Source app is immutable for a clip, so the capture-time bundleId
                // stays valid; content may have changed via an earlier rule.
                guard rule.matches(type: item.itemType, content: item.content, sourceBundleId: bundleId) else { continue }
                if await self.runOneRule(rule, on: item, bundleId: bundleId, context: context) {
                    break // dropped
                }
            }
        }
    }

    /// Run a single rule on demand (context menu), ignoring its match conditions
    /// per the manual-invocation contract.
    func runRuleManually(_ rule: ScriptingRule, on item: ClipboardItem, context: ModelContext) {
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            _ = await self.runOneRule(rule, on: item, bundleId: "", context: context)
            ToastCenter.shared.show(
                L("rule.toast.ran") + " " + rule.displayName,
                systemImage: "wand.and.stars",
                tint: .appAccent
            )
        }
    }

    /// Execute one rule's action off-main, apply its effects on-main, and record
    /// the run. Returns true when the clip was dropped.
    @discardableResult
    private func runOneRule(_ rule: ScriptingRule, on item: ClipboardItem, bundleId: String, context: ModelContext) async -> Bool {
        let input = makeScriptInput(item, bundleId: bundleId)
        let timeout = rule.timeoutSeconds ?? ScriptRuleEngine.defaultTimeout
        let action = rule.action
        let caps = rule.grantedCapabilities
        do {
            let effects = try await Task.detached(priority: .utility) {
                try ScriptRuleEngine.runAction(action, input: input, timeout: timeout, capabilities: caps)
            }.value
            let dropped = applyScriptEffects(effects, to: item, context: context)
            ScriptRunLog.shared.record(rule: rule.displayName, outcome: effects.isEmpty ? .skipped : .applied)
            return dropped
        } catch {
            ScriptRunLog.shared.record(rule: rule.displayName, outcome: .error, detail: String(describing: error))
            ToastCenter.shared.show(
                L("rule.toast.failed") + " " + rule.displayName,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
            return false
        }
    }

    // MARK: - Selection / Merge

    func enterSelectionMode() {
        isSelectionMode = true
        selectedItemIDs.removeAll()
    }

    func exitSelectionMode() {
        isSelectionMode = false
        selectedItemIDs.removeAll()
    }

    func toggleSelection(_ item: ClipboardItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func isSelected(_ item: ClipboardItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    /// Items currently selected, in chronological order (oldest first).
    func orderedSelectedItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { selectedItemIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Merging requires ≥2 entries of the same type. Images are allowed only
    /// when the user has explicitly enabled image stitching in settings.
    func canMerge(selectedItems: [ClipboardItem]) -> Bool {
        mergeBlockReason(selectedItems: selectedItems) == nil
    }

    /// Inspect the selection and report why merge is blocked (or nil if it's OK).
    func mergeBlockReason(selectedItems: [ClipboardItem]) -> String? {
        if selectedItems.count < 2 { return L("selection.requireTwo") }
        let types = Set(selectedItems.map { $0.itemType })
        if types.count > 1 { return L("selection.requireSameType") }
        if types.first == .image, !MergeSettingsStore.shared.enableImageMerge {
            return L("selection.imageMergeDisabled")
        }
        return nil
    }

    /// Concatenate (or stitch, for images) the selected items into a new
    /// ClipboardItem using user-configured separators / direction. Original
    /// entries are deleted when the "delete originals" preference is on.
    @discardableResult
    func mergeSelected(_ selectedItems: [ClipboardItem], context: ModelContext) -> ClipboardItem? {
        guard canMerge(selectedItems: selectedItems) else { return nil }
        let sorted = selectedItems.sorted { $0.createdAt < $1.createdAt }
        guard let type = sorted.first?.itemType else { return nil }

        let settings = MergeSettingsStore.shared
        let sourceApps = Array(NSOrderedSet(array: sorted.map { $0.sourceApp }.filter { !$0.isEmpty }))
            as? [String] ?? []
        let sourceApp = sourceApps.count == 1
            ? sourceApps[0]
            : L("merge.sourceLabelFormat", sorted.count)

        let merged: ClipboardItem
        switch type {
        case .text, .rtf, .url:
            let sep = settings.resolvedTextSeparator()
            let mergedContent = sorted.map { $0.content }.joined(separator: sep)
            // Build a one-line summary so the row title clearly reads as a
            // merged entry instead of looking identical to the first source
            // item (which is what naive `prefix(200)` produces).
            let inline = sorted
                .map { $0.content.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " · ")
            let preview = L("merge.previewTextFormat", sorted.count) + String(inline.prefix(180))
            merged = ClipboardItem(
                type: type,
                content: mergedContent,
                sourceApp: sourceApp,
                preview: preview
            )
        case .file, .video:
            // File paths are always merged one-per-line so they paste back as
            // an ordered list of paths; we don't expose a separator setting.
            let mergedContent = sorted.map { $0.content }.joined(separator: "\n")
            let names = sorted
                .map { $0.resolvedFileURL?.lastPathComponent ?? $0.content }
                .joined(separator: " · ")
            let preview = L("merge.previewFileFormat", sorted.count) + String(names.prefix(180))
            merged = ClipboardItem(
                type: type,
                content: mergedContent,
                sourceApp: sourceApp,
                preview: preview
            )
        case .image:
            let images = sorted.compactMap { ImageStitcher.imageFromItem($0) }
            guard images.count == sorted.count,
                  let stitched = ImageStitcher.stitch(
                    images,
                    direction: settings.imageDirection,
                    spacing: CGFloat(settings.imageSpacing),
                    background: settings.imageBackground.nsColor
                  )
            else { return nil }
            let content = L("merge.imageContentFormat", sorted.count, stitched.count / 1024)
            merged = ClipboardItem(
                type: .image,
                content: content,
                imageData: stitched,
                sourceApp: sourceApp,
                preview: content
            )
        }

        context.insert(merged)

        if settings.deleteOriginals {
            for item in sorted { context.delete(item) }
        }
        try? context.save()

        // Compute embedding asynchronously for text-like merges.
        if type != .image {
            let embedContent = merged.content
            Task { @MainActor in
                let emb = await EmbeddingService.shared.embedAsync(embedContent)
                guard let emb else { return }
                merged.embedding = emb.data
                merged.embeddingLang = emb.language
                try? context.save()
            }
        }

        exitSelectionMode()
        return merged
    }

    /// Soft- or hard-delete every selected entry in a single save pass
    /// (honoring the trash setting, exactly like `deleteItem`), then leave
    /// selection mode.
    func deleteSelected(_ items: [ClipboardItem], context: ModelContext) {
        guard !items.isEmpty else { return }
        let toTrash = FilterSettingsStore.shared.trashEnabled
        let now = Date()
        for item in items {
            if toTrash {
                item.deletedAt = now
            } else {
                context.delete(item)
            }
        }
        try? context.save()
        exitSelectionMode()
    }

    // MARK: - Bulk selection helpers

    func selectAll(_ items: [ClipboardItem]) {
        selectedItemIDs = Set(items.map(\.id))
    }

    func invertSelection(_ items: [ClipboardItem]) {
        let allIDs = Set(items.map(\.id))
        selectedItemIDs = allIDs.subtracting(selectedItemIDs)
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    // MARK: - Embedding backfill

    /// One-shot pass for historical clips that have never had an embedding
    /// attempt. The query is intentionally narrow and paged: fetching every
    /// model here also faults large image blobs into the main actor on launch.
    func backfillEmbeddings(context: ModelContext) async {
        guard semanticFeatureEnabled, !isBackfillingEmbeddings else { return }

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate {
                $0.deletedAt == nil &&
                $0.embeddingLang == nil
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let total = try? context.fetchCount(descriptor), total > 0 else { return }

        let service = EmbeddingService.shared
        backfillTotal = total
        backfillCompleted = 0
        isBackfillingEmbeddings = true
        defer {
            isBackfillingEmbeddings = false
            backfillTotal = 0
            backfillCompleted = 0
        }

        descriptor.fetchLimit = Self.embeddingBackfillBatchSize
        descriptor.propertiesToFetch = [\.type, \.content, \.ocrText, \.embeddingLang]

        while !Task.isCancelled {
            guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { break }
            for item in pending {
                guard !Task.isCancelled else { break }
                let source = item.itemType == .image ? (item.ocrText ?? "") : item.content
                if let vec = await service.embedAsync(source) {
                    item.embedding = vec.data
                    item.embeddingLang = vec.language
                } else {
                    // Empty marks a completed attempt for unsupported content,
                    // preventing the same row from being retried every launch.
                    item.embeddingLang = ""
                }
                backfillCompleted += 1
            }
            try? context.save()
            await Task.yield()
        }
    }

    // MARK: - Filtering

    /// Searches the live history for every distinct tag the user has applied
    /// (case-insensitive). Returns display strings in their first-seen casing,
    /// sorted alphabetically — the search bar's `#` picker reads this list.
    func allKnownTags(in items: [ClipboardItem]) -> [String] {
        var seen: [String: String] = [:]
        for item in items where item.deletedAt == nil {
            for tag in item.tags {
                let key = tag.lowercased()
                if seen[key] == nil { seen[key] = tag }
            }
        }
        return seen.values.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func allKnownSourceApps(in items: [ClipboardItem]) -> [String] {
        var seen: [String: String] = [:]
        for item in items where item.deletedAt == nil {
            let app = item.sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !app.isEmpty else { continue }
            let key = app.lowercased()
            if seen[key] == nil { seen[key] = app }
        }
        return seen.values.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func filteredItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        // Active history never shows soft-deleted entries — those live in
        // the trash screen until they're restored or expire.
        var result = items.filter { $0.deletedAt == nil }

        switch selectedScope {
        case .all: break
        case .favorites: result = result.filter { $0.isFavorite }
        }

        if let type = selectedType {
            result = result.filter { $0.itemType == type }
        }

        if let app = selectedSourceApp {
            result = result.filter { $0.sourceApp == app }
        }

        switch selectedGroupFilter {
        case .all:
            break
        case .ungrouped:
            result = result.filter { !$0.isGrouped && !$0.isPinned }
        case .group(let groupID):
            result = result.filter { $0.isInGroup(groupID) && !$0.isPinned }
        }

        if !activeTags.isEmpty {
            switch tagFilterMode {
            case .any:
                result = result.filter { item in
                    for tag in item.tags where activeTags.contains(tag.lowercased()) {
                        return true
                    }
                    return false
                }
            case .all:
                result = result.filter { item in
                    let itemKeys = Set(item.tags.map { $0.lowercased() })
                    return activeTags.isSubset(of: itemKeys)
                }
            }
        }

        // In tag mode the search field is a local tag-picker buffer (never
        // written to `searchText`), so only `activeTags` matters for filtering.
        if searchMode != .tag {
            let raw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                // Strip out app:/since:/before: token modifiers before they
                // ever reach the keyword/semantic engines.
                let tokens = ClipboardSearchTokens.parse(raw)
                if let appQuery = tokens.appQuery, !appQuery.isEmpty {
                    result = result.filter { item in
                        item.sourceApp.localizedCaseInsensitiveContains(appQuery)
                    }
                }
                if let since = tokens.since {
                    result = result.filter { $0.createdAt >= since }
                }
                if let before = tokens.before {
                    result = result.filter { $0.createdAt < before }
                }

                let query = tokens.keywords
                if !query.isEmpty {
                    let useSemantic = searchMode == .semantic
                        && semanticFeatureEnabled
                        && !isBackfillingEmbeddings
                    if useSemantic {
                        result = semanticFilter(result, query: query)
                    } else {
                        result = keywordFilter(result, query: query)
                    }
                }
            }
        }

        // Favorites is user-sortable; the "all" scope keeps its natural
        // reverse-chronological order from the @Query. Pinned items still
        // float to the top — splitItems() partitions the (already sorted)
        // result, so each group keeps the chosen order.
        if selectedScope == .favorites {
            result = sortFavorites(result)
        }

        // Pin-ordering is the caller's job — MainWindowView splits pinned vs
        // others for the section header, and a duplicate sort here would be a
        // wasted pass over the list on every scope/filter change.
        return result
    }

    private func sortFavorites(_ items: [ClipboardItem]) -> [ClipboardItem] {
        switch favoritesSortOrder {
        case .dateNewest:
            return items.sorted { $0.createdAt > $1.createdAt }
        case .dateOldest:
            return items.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return items.sorted {
                favoriteSortKey($0).localizedCaseInsensitiveCompare(favoriteSortKey($1)) == .orderedAscending
            }
        case .type:
            return items.sorted {
                if $0.itemType != $1.itemType {
                    return $0.itemType.rawValue < $1.itemType.rawValue
                }
                return $0.createdAt > $1.createdAt
            }
        }
    }

    private func favoriteSortKey(_ item: ClipboardItem) -> String {
        if let title = item.effectiveCustomTitle { return title }
        return (item.preview ?? item.content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rank items by keyword and cosine similarity. Each language (`zh` /
    /// `en`) has its own model with its own dimension, so search builds query
    /// vectors for both and only compares compatible vector families.
    private func semanticFilter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let service = EmbeddingService.shared
        let queryVectors = service.embeddingsForSearch(query)
        guard !queryVectors.isEmpty else {
            return keywordFilter(items, query: query)
        }

        struct Scored {
            let item: ClipboardItem
            let semanticScore: Float
            let keywordScore: Float
            let originalIndex: Int

            var score: Float { semanticScore + keywordScore }
            var hasKeywordMatch: Bool { keywordScore > 0 }
        }

        var scored: [Scored] = []
        for (index, item) in items.enumerated() {
            let semanticScore = service.bestSimilarity(
                queryVectors: queryVectors,
                itemEmbedding: item.embedding,
                itemLanguage: item.embeddingLang
            ) ?? 0
            let keywordScore = keywordMatchScore(for: item, query: query)

            if semanticScore >= semanticThreshold || keywordScore > 0 {
                scored.append(
                    Scored(
                        item: item,
                        semanticScore: semanticScore,
                        keywordScore: keywordScore,
                        originalIndex: index
                    )
                )
            }
        }

        if let topSemantic = scored.map(\.semanticScore).max(), topSemantic >= semanticThreshold {
            let cutoff = max(semanticThreshold, topSemantic - semanticTopDelta)
            scored = scored.filter {
                $0.hasKeywordMatch ||
                $0.semanticScore >= semanticStrongThreshold ||
                $0.semanticScore >= cutoff
            }
        }

        if scored.isEmpty {
            return keywordFilter(items, query: query)
        }
        scored.sort {
            if $0.hasKeywordMatch != $1.hasKeywordMatch {
                return $0.hasKeywordMatch
            }
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.originalIndex < $1.originalIndex
        }
        return scored.map { $0.item }
    }

    private func keywordFilter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        return items.filter {
            keywordMatchScore(for: $0, query: query) > 0
        }
    }

    private func keywordMatchScore(for item: ClipboardItem, query: String) -> Float {
        var score: Float = 0
        if item.content.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if let title = item.effectiveCustomTitle,
           title.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if let ocr = item.ocrText, !ocr.isEmpty,
           ocr.localizedCaseInsensitiveContains(query) {
            score += semanticKeywordBoost
        }
        if item.sourceApp.localizedCaseInsensitiveContains(query) {
            score += semanticSourceBoost
        }
        return score
    }

    // MARK: - OCR backfill

    /// One-shot pass over historical image clips that don't yet have OCR
    /// text. Vision is run on a detached task per item; recognized text is
    /// stored on `ClipboardItem.ocrText` and the embedding is recomputed so
    /// the same image is searchable in both keyword and semantic modes.
    func backfillOCR(context: ModelContext) async {
        guard !isBackfillingOCR else { return }

        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.type == "image" && $0.ocrText == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.ocrBackfillBatchSize
        descriptor.propertiesToFetch = [\.type, \.content, \.imageData, \.fileURL, \.ocrText]

        guard let firstBatch = try? context.fetch(descriptor), !firstBatch.isEmpty else { return }

        isBackfillingOCR = true
        defer { isBackfillingOCR = false }

        var images = firstBatch
        while !images.isEmpty, !Task.isCancelled {
            for item in images {
                guard !Task.isCancelled else { break }
                let recognized = await OCRService.shared.recognize(item: item)
                item.ocrText = recognized
                if semanticFeatureEnabled,
                   !recognized.isEmpty,
                   let emb = await EmbeddingService.shared.embedAsync(recognized) {
                    item.embedding = emb.data
                    item.embeddingLang = emb.language
                }
            }
            try? context.save()
            await Task.yield()
            images = (try? context.fetch(descriptor)) ?? []
        }
    }
}

// MARK: - Search query tokens

/// Lightweight parser for the search bar's `app:`, `since:`, and `before:`
/// modifiers. Tokens are consumed up-front by `filteredItems`, leaving the
/// remaining text to drive the keyword / semantic engine.
///
/// Recognised forms:
///   - `app:VSCode`       — sourceApp / sourceBundleId contains "VSCode" (case-insensitive)
///   - `since:2d`         — relative window; suffixes m / h / d / w supported
///   - `before:2026-05-01` — ISO date upper bound (exclusive of next day)
///   - `before:2d`        — relative; "before two days ago", i.e. older than 2d
struct ClipboardSearchTokens {
    var keywords: String
    var appQuery: String?
    var since: Date?
    var before: Date?

    static func parse(_ raw: String) -> ClipboardSearchTokens {
        var keywords: [String] = []
        var appQuery: String?
        var since: Date?
        var before: Date?

        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in words {
            if let value = tokenValue("app:", in: word) {
                if appQuery == nil { appQuery = value }
                continue
            }
            if let value = tokenValue("since:", in: word) {
                if let date = resolveDate(value, isUpperBound: false) {
                    since = date
                    continue
                }
            }
            if let value = tokenValue("before:", in: word) {
                if let date = resolveDate(value, isUpperBound: true) {
                    before = date
                    continue
                }
            }
            keywords.append(word)
        }

        return ClipboardSearchTokens(
            keywords: keywords.joined(separator: " "),
            appQuery: appQuery,
            since: since,
            before: before
        )
    }

    private static func tokenValue(_ prefix: String, in word: String) -> String? {
        guard word.count > prefix.count,
              word.lowercased().hasPrefix(prefix) else { return nil }
        let value = word.dropFirst(prefix.count)
        return value.isEmpty ? nil : String(value)
    }

    /// Accept either a relative duration (`2d`, `90m`, `1w`) or an ISO-8601
    /// calendar date. For relative tokens the result is "now minus duration";
    /// for absolute dates `isUpperBound` treats the date as 00:00 of the *next*
    /// day so `before:2026-05-01` excludes May 1st itself.
    private static func resolveDate(_ raw: String, isUpperBound: Bool) -> Date? {
        if let interval = relativeInterval(raw) {
            return Date().addingTimeInterval(-interval)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: raw) else { return nil }
        if isUpperBound {
            return Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private static func relativeInterval(_ raw: String) -> TimeInterval? {
        guard let suffix = raw.last, "mhdw".contains(suffix) else { return nil }
        let numberPart = raw.dropLast()
        guard let value = Double(numberPart), value > 0 else { return nil }
        switch suffix {
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        case "w": return value * 86_400 * 7
        default:  return nil
        }
    }
}
