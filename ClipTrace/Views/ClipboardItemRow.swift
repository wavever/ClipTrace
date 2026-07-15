import SwiftUI
import AppKit

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem
    var groupNames: [String] = []
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    /// Bumped by `ContentProtectionStore` when the master toggle or a category
    /// changes. Carried purely so the `Equatable` gate below invalidates the row
    /// after a protection setting flips and the masked title/badge recompute.
    var protectionVersion: Int = 0
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRevealInFinder: () -> Void = {}
    var onOpenFile: () -> Void = {}
    var onOpenURL: () -> Void = {}
    var onSaveImage: () -> Void = {}
    var onPreview: () -> Void = {}
    var onAddTag: (String) -> Void = { _ in }
    var onRemoveTag: (String) -> Void = { _ in }
    var onBase64Encode: () -> Void = {}
    var onBase64Decode: () -> Void = {}

    @State private var isHovered = false
    @State private var showTagEditor = false
    @State private var showOCR = false
    @State private var showBarcodeScan = false
    @State private var showQRCodePreview = false
    /// Result of the `FileManager.fileExists` probe for this item's URL,
    /// populated once asynchronously after the row appears. Keeping this out
    /// of the synchronous body avoids a disk hit on every scroll/hover frame.
    @State private var fileExistsCache: Bool = false
    /// Cached color-literal detection. SwiftUI calls `body` on every hover /
    /// scroll tick; parsing the color string every time is wasted work.
    @State private var detectedColorCache: Color? = nil
    @State private var detectedColorComputed = false

    // Lets the parent `LazyVStack` skip re-evaluating this row's (heavy)
    // body when only some *other* row's selection changed — the common case
    // while arrow-keying through the list. We compare just the value inputs
    // the parent feeds in; everything drawn from `item` (pin/favorite/tags/…)
    // is observed through SwiftData's `@Model`, so those edits still re-render
    // the row live, independent of this gate. Without it, every keystroke
    // rebuilt all ~12 visible rows and stole frames from the scroll animation.
    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.groupNames == rhs.groupNames
            && lhs.isSelected == rhs.isSelected
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.protectionVersion == rhs.protectionVersion
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if let detectedColor = detectedColorCache {
                ColorSwatchThumbnail(color: detectedColor, size: 44)
            } else {
                ThumbnailView(item: item, size: 44, cornerRadius: 9)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                    if rowProtection.isProtected {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.appAccent)
                            .help(L("protection.badge.tooltip"))
                    }
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        if item.sourceApp == L("remote.universalClipboard") {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                        Text(item.sourceApp)
                            .lineLimit(1)
                    }
                    rowDot
                    Text(item.formattedDate)
                        .monospacedDigit()
                    rowDot
                    HStack(spacing: 3) {
                        Image(systemName: item.itemType.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(item.descriptiveTag)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.secondary.opacity(0.14))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                    ForEach(groupNames, id: \.self) { name in
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(name)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appAccent.opacity(0.12))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.appAccent.opacity(0.30), lineWidth: 0.5)
                        )
                    }
                    ForEach(item.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.appAccent.opacity(0.14))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isHovered && !isSelectionMode {
                actionBar
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single solid fill + conditional accent tint instead of the previous
        // ZStack-with-material + always-on shadow. Each row was paying for a
        // backdrop blur and a soft shadow on every paint — at ~10 visible rows
        // that's 10 GPU passes per frame for visuals that read identically
        // against the warm paper background.
        //
        // Both the base fill *and* the accent tint live inside `.background`
        // so neither layer intercepts hit-testing for the action-bar buttons
        // sitting on top of the row.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered || staticSelected ? Color.appCardHover : Color.appCard)
                // Hover wash, skipped under the static selected tint to avoid
                // doubling. The browse-mode keyboard-focus highlight is *not*
                // drawn here — the list parks a single sliding overlay on the
                // focused row (see `focusHighlight`) so it can glide with scroll.
                if isHovered && !staticSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.appAccent.opacity(0.04))
                }
                // Selection/merge mode keeps a static per-row tint, since
                // several rows can be checked at once.
                if staticSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.appAccent.opacity(0.10))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: (isHovered || staticSelected) ? 1 : 0.5)
        )
        // Only paint a shadow on the row the user is actively interacting
        // with — idle rows used to each get their own blur pass, which adds
        // up fast in a long list.
        .shadow(
            color: isHovered ? Color.appAccent.opacity(0.12) : .clear,
            radius: isHovered ? 6 : 0,
            y: isHovered ? 2 : 0
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: item.id) {
            // Color-literal detection: cheap but does string trim + parse on
            // every body otherwise. Compute once per row identity.
            if !detectedColorComputed {
                detectedColorComputed = true
                if item.itemType == .text {
                    detectedColorCache = ColorValueParser.color(from: item.content)
                }
            }
            // File existence probe: do the disk hit off the render path. Only
            // run for items that actually have a path to check; the cache
            // stays `false` for text/URL/RTF clips.
            await refreshFileExistsCache()
        }
        .onChange(of: item.fileURL) { _, _ in
            Task { await refreshFileExistsCache() }
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorPopover(
                item: item,
                onAdd: onAddTag,
                onRemove: onRemoveTag
            )
        }
        .sheet(isPresented: $showOCR) {
            // No `.interactiveDismissDisabled` needed — macOS sheets don't
            // dismiss on outside taps, and we deliberately omit any cancel-
            // role button so Esc has nothing to bind to. Only the close
            // button in the footer can close this.
            OCRResultView(item: item, onClose: { showOCR = false })
        }
        .sheet(isPresented: $showBarcodeScan) {
            BarcodeResultView(item: item, onClose: { showBarcodeScan = false })
        }
        .sheet(isPresented: $showQRCodePreview) {
            TextQRCodePreviewView(item: item, onClose: { showQRCodePreview = false })
        }
    }

    /// Selected *and* painted in place. Only selection/merge mode does this —
    /// in browse mode the keyboard-focus highlight is the list's sliding overlay
    /// (`focusHighlight`), so the row itself draws no selected styling.
    private var staticSelected: Bool {
        isSelected && isSelectionMode
    }

    private var borderColor: Color {
        // The browse-mode focus border rides along with the sliding overlay, so
        // the row's own border only reflects selection mode / hover / idle.
        if staticSelected { return Color.appAccent }
        if isHovered  { return Color.appAccent.opacity(0.55) }
        return Color.secondary.opacity(0.15)
    }

    private var rowDot: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 2.5, height: 2.5)
            .opacity(0.7)
    }

    /// Redaction over the row's text source, reused by the masked title and the
    /// protected-state badge so the scan runs against the (≤200 char) preview
    /// rather than the full clip.
    private var rowProtection: ContentProtectionResult {
        ContentProtector.redact(item.preview ?? item.content)
    }

    private var displayTitle: String {
        // User-assigned label wins outright — that's the whole point of
        // letting people rename rows. Custom titles and file names are not
        // redacted (they aren't the sensitive value).
        if let custom = item.effectiveCustomTitle { return custom }
        // Merged entries set a preview prefixed with a localized "[Merged ..."
        // (or "[合并 ...") tag — keep that as the title so the row visually
        // reads as a merge result instead of mirroring the first source item.
        if let preview = item.preview,
           preview.hasPrefix("[合并 ") || preview.hasPrefix("[Merged ") {
            return preview.components(separatedBy: .newlines).first ?? preview
        }
        if let url = item.resolvedFileURL { return url.lastPathComponent }
        // Sensitive spans are masked before the title is rendered.
        let firstLine = rowProtection.redactedText
            .components(separatedBy: .newlines)
            .first ?? ""
        return firstLine.isEmpty ? item.itemType.displayName : firstLine
    }

    private var actionBar: some View {
        ClipboardItemActionBar(
            item: item,
            layout: .list,
            fileExists: fileExistsCache,
            onCopy: onCopy,
            onPreview: onPreview,
            onShowQRCode: { showQRCodePreview = true },
            onBase64Encode: onBase64Encode,
            onBase64Decode: onBase64Decode,
            onTogglePin: onTogglePin,
            onToggleFavorite: onToggleFavorite,
            onEditTags: { showTagEditor = true },
            onOpenURL: onOpenURL,
            onShowOCR: { showOCR = true },
            onShowBarcodeScan: { showBarcodeScan = true },
            onSaveImage: onSaveImage,
            onRevealInFinder: onRevealInFinder,
            onOpenFile: onOpenFile,
            onDelete: onDelete
        )
    }

    /// Probe the resolved file URL off the main render path. Falls back to
    /// `false` for clips that aren't backed by a file (text / URL / RTF) so
    /// the action bar's file-only buttons stay hidden.
    private func refreshFileExistsCache() async {
        guard let url = item.resolvedFileURL else {
            if fileExistsCache { fileExistsCache = false }
            return
        }
        let path = url.path
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
        if fileExistsCache != exists { fileExistsCache = exists }
    }
}

/// A denser, image-forward counterpart to `ClipboardItemRow` for the main
/// window's adaptive grid. Copy lives in the top corner; the footer stays
/// deliberately compact while the context menu keeps the complete command
/// set available.
struct ClipboardItemGridCard: View, Equatable {
    let item: ClipboardItem
    var groupNames: [String] = []
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var protectionVersion: Int = 0
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRevealInFinder: () -> Void = {}
    var onOpenURL: () -> Void = {}
    var onPreview: () -> Void = {}
    var onAddTag: (String) -> Void = { _ in }
    var onRemoveTag: (String) -> Void = { _ in }

    @State private var isHovered = false
    @State private var showTagEditor = false
    @State private var showOCR = false
    @State private var detectedColorCache: Color?
    @State private var detectedColorComputed = false
    @State private var fileExistsCache = false

    static func == (lhs: ClipboardItemGridCard, rhs: ClipboardItemGridCard) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.groupNames == rhs.groupNames
            && lhs.isSelected == rhs.isSelected
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.protectionVersion == rhs.protectionVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewSurface

            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    if let firstGroup = groupNames.first {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                        Text(firstGroup)
                            .foregroundStyle(Color.appAccent)
                            .lineLimit(1)
                        rowDot
                    }
                    Text(item.sourceApp)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.formattedDate)
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .opacity(isHovered && !isSelectionMode ? 0 : 1)

                if !isSelectionMode {
                    actionBar
                        .opacity(isHovered ? 1 : 0)
                        .disabled(!isHovered)
                        .allowsHitTesting(isHovered)
                        .accessibilityHidden(!isHovered)
                }
            }
            .frame(height: 28)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 242, maxHeight: 242, alignment: .topLeading)
        .background {
            if staticSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appAccent.opacity(0.10))
            }
        }
        .paperCard(cornerRadius: 14, isHovered: isHovered, isSelected: staticSelected)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .task(id: item.id) {
            if !detectedColorComputed {
                detectedColorComputed = true
                if item.itemType == .text {
                    detectedColorCache = ColorValueParser.color(from: item.content)
                }
            }
            await refreshFileExistsCache()
        }
        .onChange(of: item.fileURL) { _, _ in
            Task { await refreshFileExistsCache() }
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorPopover(
                item: item,
                onAdd: onAddTag,
                onRemove: onRemoveTag
            )
        }
        .sheet(isPresented: $showOCR) {
            OCRResultView(item: item, onClose: { showOCR = false })
        }
    }

    private var actionBar: some View {
        ClipboardItemActionBar(
            item: item,
            layout: .grid,
            fileExists: fileExistsCache,
            onPreview: onPreview,
            onTogglePin: onTogglePin,
            onToggleFavorite: onToggleFavorite,
            onEditTags: { showTagEditor = true },
            onOpenURL: onOpenURL,
            onShowOCR: { showOCR = true },
            onRevealInFinder: onRevealInFinder,
            onDelete: onDelete
        )
    }

    private var previewSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appChipFill)

            if let detectedColor = detectedColorCache {
                ZStack {
                    Color.white
                    Checkerboard(squareSize: 9)
                        .fill(Color.secondary.opacity(0.25))
                    detectedColor
                }
            } else if showsLargeThumbnail {
                GeometryReader { proxy in
                    ThumbnailView(
                        item: item,
                        width: proxy.size.width,
                        height: proxy.size.height,
                        cornerRadius: 10,
                        contentMode: item.itemType == .image ? .fit : .fill
                    )
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: item.itemType.icon)
                        .font(.system(size: 56, weight: .ultraLight))
                        .foregroundStyle(Color.appAccent.opacity(0.08))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)

                    Text(previewText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.76))
                        .lineLimit(9)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 12)
                        .padding(.top, 39)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 184)
        .overlay(alignment: .top) {
            previewBadges
                .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            if item.itemType == .image {
                imageTitleOverlay
                    .padding(8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appCardBorder.opacity(0.8), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var previewBadges: some View {
        HStack(spacing: 6) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.secondary.opacity(0.7))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(4)
                    .background(Circle().fill(Color.appPaper.opacity(0.92)))
            }

            Label(item.descriptiveTag, systemImage: item.itemType.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.appPaper.opacity(0.92))
                )

            Spacer(minLength: 4)

            previewTrailingControls
        }
    }

    /// The protection badge shares a fixed trailing footprint with copy.
    /// Pin and favorite live exclusively in the footer, keeping the preview
    /// corner light while the type badge avoids a sideways jump on hover.
    private var previewTrailingControls: some View {
        ZStack(alignment: .trailing) {
            if rowProtection.isProtected {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .help(L("protection.badge.tooltip"))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.appPaper.opacity(0.92))
                    )
                    .opacity(isHovered && !isSelectionMode ? 0 : 1)
                    .accessibilityHidden(isHovered && !isSelectionMode)
            }

            if !isSelectionMode {
                HoverIconButton(
                    systemName: "doc.on.doc",
                    help: L("action.copy"),
                    action: onCopy
                )
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.appPaper.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.appCardBorder.opacity(0.8), lineWidth: 0.5)
                )
                .opacity(isHovered ? 1 : 0)
                .disabled(!isHovered)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var staticSelected: Bool {
        isSelected && isSelectionMode
    }

    private var showsLargeThumbnail: Bool {
        switch item.itemType {
        case .image, .video, .file: return true
        case .text, .url, .rtf: return false
        }
    }

    private var rowProtection: ContentProtectionResult {
        ContentProtector.redact(item.preview ?? item.content)
    }

    private var previewText: String {
        item.gridPreviewContent
    }

    private var rowDot: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 2.5, height: 2.5)
            .opacity(0.7)
    }

    private var imageTitleOverlay: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
            Text(item.gridImageTitle)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appMetal.opacity(0.82))
        )
    }

    /// Match the list row's asynchronous file capability check without doing
    /// synchronous disk I/O during hover-driven card redraws.
    private func refreshFileExistsCache() async {
        guard let url = item.resolvedFileURL else {
            if fileExistsCache { fileExistsCache = false }
            return
        }
        let path = url.path
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value
        if fileExistsCache != exists { fileExistsCache = exists }
    }
}

private enum ClipboardItemActionBarLayout {
    case list
    case grid
}

/// Main-window action definitions. List rows expose the complete inline set;
/// grid cards deliberately keep only primary commands in their single-line
/// footer, with secondary transforms available from the shared context menu.
private struct ClipboardItemActionBar: View {
    let item: ClipboardItem
    let layout: ClipboardItemActionBarLayout
    let fileExists: Bool
    var onCopy: () -> Void = {}
    var onPreview: () -> Void = {}
    var onShowQRCode: () -> Void = {}
    var onBase64Encode: () -> Void = {}
    var onBase64Decode: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onEditTags: () -> Void = {}
    var onOpenURL: () -> Void = {}
    var onShowOCR: () -> Void = {}
    var onShowBarcodeScan: () -> Void = {}
    var onSaveImage: () -> Void = {}
    var onRevealInFinder: () -> Void = {}
    var onOpenFile: () -> Void = {}
    var onDelete: () -> Void = {}

    @ViewBuilder
    var body: some View {
        switch layout {
        case .list:
            HStack(spacing: 4) {
                buttons
            }
        case .grid:
            HStack(spacing: 0) {
                gridButtons
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HoverIconButton(
            systemName: "doc.on.doc",
            help: L("action.copy"),
            action: onCopy
        )
        HoverIconButton(
            systemName: "eye",
            help: L("action.preview"),
            action: onPreview
        )
        if canPreviewQRCode {
            HoverIconButton(
                systemName: "qrcode",
                help: L("action.qrPreview"),
                action: onShowQRCode
            )
        }
        if hasEncodableText {
            EncodingMenuButton(
                item: item,
                onEncode: onBase64Encode,
                onDecode: onBase64Decode
            )
        }
        HoverIconButton(
            systemName: item.isPinned ? "pin.fill" : "pin",
            help: item.isPinned ? L("action.unpin") : L("action.pin"),
            tint: item.isPinned ? .orange : nil,
            action: onTogglePin
        )
        HoverIconButton(
            systemName: item.isFavorite ? "star.fill" : "star",
            help: item.isFavorite ? L("action.unfavorite") : L("action.favorite"),
            tint: item.isFavorite ? .yellow : nil,
            action: onToggleFavorite
        )
        HoverIconButton(
            systemName: item.tags.isEmpty ? "tag" : "tag.fill",
            help: L("action.editTags"),
            tint: item.tags.isEmpty ? nil : .appAccent,
            action: onEditTags
        )
        if item.itemType == .url {
            HoverIconButton(
                systemName: "safari",
                help: L("action.openInBrowser"),
                action: onOpenURL
            )
        }
        if item.hasImagePayload {
            HoverIconButton(
                systemName: "text.viewfinder",
                help: L("action.ocr"),
                action: onShowOCR
            )
            HoverIconButton(
                systemName: "qrcode.viewfinder",
                help: L("action.scanCodes"),
                action: onShowBarcodeScan
            )
        }
        if item.hasStoredImageData {
            HoverIconButton(
                systemName: "square.and.arrow.down",
                help: L("action.saveImage"),
                action: onSaveImage
            )
        }
        if fileExists {
            HoverIconButton(
                systemName: "folder",
                help: L("action.revealInFinder"),
                action: onRevealInFinder
            )
            HoverIconButton(
                systemName: "arrow.up.forward.app",
                help: L("action.openFile"),
                action: onOpenFile
            )
        }
        HoverIconButton(
            systemName: "trash",
            help: L("action.delete"),
            tint: .red,
            action: onDelete
        )
    }

    /// The compact card footer is capped at six 28pt buttons, fitting the
    /// narrowest card's 190pt content width. Flexible gaps absorb the remaining
    /// space, so both five- and six-command rows feel intentionally full.
    @ViewBuilder
    private var gridButtons: some View {
        HoverIconButton(
            systemName: "eye",
            help: L("action.preview"),
            action: onPreview
        )
        Spacer(minLength: 0)
        HoverIconButton(
            systemName: item.isPinned ? "pin.fill" : "pin",
            help: item.isPinned ? L("action.unpin") : L("action.pin"),
            tint: item.isPinned ? .orange : nil,
            action: onTogglePin
        )
        Spacer(minLength: 0)
        HoverIconButton(
            systemName: item.isFavorite ? "star.fill" : "star",
            help: item.isFavorite ? L("action.unfavorite") : L("action.favorite"),
            tint: item.isFavorite ? .yellow : nil,
            action: onToggleFavorite
        )
        Spacer(minLength: 0)
        HoverIconButton(
            systemName: item.tags.isEmpty ? "tag" : "tag.fill",
            help: L("action.editTags"),
            tint: item.tags.isEmpty ? nil : .appAccent,
            action: onEditTags
        )
        if item.itemType == .url {
            Spacer(minLength: 0)
            HoverIconButton(
                systemName: "safari",
                help: L("action.openInBrowser"),
                action: onOpenURL
            )
        } else if fileExists {
            Spacer(minLength: 0)
            HoverIconButton(
                systemName: "folder",
                help: L("action.revealInFinder"),
                action: onRevealInFinder
            )
        } else if item.hasImagePayload {
            Spacer(minLength: 0)
            HoverIconButton(
                systemName: "text.viewfinder",
                help: L("action.ocr"),
                action: onShowOCR
            )
        }
        Spacer(minLength: 0)
        HoverIconButton(
            systemName: "trash",
            help: L("action.delete"),
            tint: .red,
            action: onDelete
        )
    }

    private var canPreviewQRCode: Bool {
        item.itemType == .text &&
        !item.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keep the expensive Base64 validity check inside `EncodingMenuButton`;
    /// this gate only decides whether an encoding command applies at all.
    private var hasEncodableText: Bool {
        switch item.itemType {
        case .text, .url, .rtf: return !item.content.isEmpty
        default: return false
        }
    }
}

struct HoverIconButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(background)
                )
                .scaleEffect(isPressed ? 0.92 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .hoverTip(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.12)) { isPressed = false }
                }
        )
    }

    private var foreground: Color {
        let base = tint ?? .secondary
        return isHovered ? (tint ?? .primary) : base
    }

    private var background: Color {
        if !isHovered { return .clear }
        if let tint { return tint.opacity(0.18) }
        return Color.secondary.opacity(0.2)
    }
}

// MARK: - Color value detection

/// Detects whether a clip's text is a single CSS-style color literal and
/// resolves it to a `Color` for the row swatch. Recognizes hex
/// (`#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA`) and the functional
/// notations `rgb()/rgba()`, `hsl()/hsla()` and `hsb()/hsv()`.
enum ColorValueParser {
    static func color(from raw: String) -> Color? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Color literals are short — bail fast on anything that obviously isn't.
        guard !s.isEmpty, s.count <= 48 else { return nil }
        return hexColor(s) ?? functionalColor(s)
    }

    private static func hexColor(_ s: String) -> Color? {
        guard s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        guard [3, 4, 6, 8].contains(hex.count),
              hex.allSatisfy(\.isHexDigit) else { return nil }

        // #RGB / #RGBA use one nibble per channel — duplicate to full bytes.
        let full = hex.count <= 4 ? hex.map { "\($0)\($0)" }.joined() : String(hex)
        guard let value = UInt64(full, radix: 16) else { return nil }

        if full.count == 8 {
            return Color(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Functional notation: `rgb()/rgba()`, `hsl()/hsla()`, `hsb()/hsv()`.
    /// Components accept comma, slash (modern alpha) or whitespace separators.
    private static func functionalColor(_ s: String) -> Color? {
        let lower = s.lowercased()
        guard let open = lower.firstIndex(of: "("),
              let close = lower.lastIndex(of: ")"),
              open < close else { return nil }
        let name = lower[..<open].trimmingCharacters(in: .whitespaces)
        let parts = lower[lower.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let opacity = parts.count == 4 ? (alpha(parts[3]) ?? 1) : 1

        switch name {
        case "rgb", "rgba":
            guard let r = channel(parts[0]),
                  let g = channel(parts[1]),
                  let b = channel(parts[2]) else { return nil }
            return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
        case "hsl", "hsla":
            guard let h = hue(parts[0]),
                  let s = unit(parts[1]),
                  let l = unit(parts[2]) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: s, l: l)
            return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
        case "hsb", "hsv":
            guard let h = hue(parts[0]),
                  let s = unit(parts[1]),
                  let brightness = unit(parts[2]) else { return nil }
            return Color(hue: h / 360, saturation: s, brightness: brightness, opacity: opacity)
        default:
            return nil
        }
    }

    /// Hue in degrees, normalized to `0..<360`. Accepts an optional `deg` suffix.
    private static func hue(_ str: String) -> Double? {
        let t = str.hasSuffix("deg") ? String(str.dropLast(3)) : str
        guard let v = Double(t) else { return nil }
        let mod = v.truncatingRemainder(dividingBy: 360)
        return mod < 0 ? mod + 360 : mod
    }

    /// Saturation / lightness / brightness as `0...1`. Accepts `50%`, `0.5`,
    /// or a bare `0...100` value (design tools often drop the percent sign).
    private static func unit(_ str: String) -> Double? {
        if str.hasSuffix("%") {
            guard let pct = Double(str.dropLast()) else { return nil }
            return clamp(pct / 100)
        }
        guard let v = Double(str) else { return nil }
        return clamp(v > 1 ? v / 100 : v)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default:    (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return (clamp(r + m), clamp(g + m), clamp(b + m))
    }

    /// One RGB channel — `0...255` or a `0%...100%` percentage — as `0...1`.
    private static func channel(_ str: String) -> Double? {
        if str.hasSuffix("%") {
            guard let pct = Double(str.dropLast()) else { return nil }
            return clamp(pct / 100)
        }
        guard let v = Double(str) else { return nil }
        return clamp(v / 255)
    }

    /// Alpha — already `0...1`, or a percentage.
    private static func alpha(_ str: String) -> Double? {
        if str.hasSuffix("%") {
            guard let pct = Double(str.dropLast()) else { return nil }
            return clamp(pct / 100)
        }
        guard let v = Double(str) else { return nil }
        return clamp(v)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Swatch shown in place of the text thumbnail for color-literal clips. A
/// checkerboard sits behind the fill so semi-transparent colors read correctly.
private struct ColorSwatchThumbnail: View {
    let color: Color
    let size: CGFloat
    private let corner: CGFloat = 9

    var body: some View {
        ZStack {
            Color.white
            Checkerboard(squareSize: 6)
                .fill(Color.secondary.opacity(0.30))
            color
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// Classic transparency checkerboard — fills every other cell.
private struct Checkerboard: Shape {
    var squareSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cols = Int(ceil(rect.width / squareSize))
        let rows = Int(ceil(rect.height / squareSize))
        for row in 0..<rows {
            for col in 0..<cols where (row + col).isMultiple(of: 2) {
                path.addRect(CGRect(
                    x: CGFloat(col) * squareSize,
                    y: CGFloat(row) * squareSize,
                    width: squareSize,
                    height: squareSize
                ))
            }
        }
        return path
    }
}

// MARK: - Encoding menu

/// Hover-bar entry for text transforms (Base64 today). One glyph opening a
/// paper dropdown keeps the crowded action bar at a single icon while leaving
/// room for more encodings later.
private struct EncodingMenuButton: View {
    let item: ClipboardItem
    let onEncode: () -> Void
    let onDecode: () -> Void

    @StateObject private var controller = PaperDropdownController()

    var body: some View {
        HoverIconButton(
            systemName: "chevron.left.forwardslash.chevron.right",
            help: L("action.encoding")
        ) {
            // Decode legality costs a full-content scan — probe it only when
            // the menu actually opens, never on row render.
            let canDecode = ClipboardViewModel.transformableText(of: item)
                .flatMap(ClipboardViewModel.base64Decoded) != nil
            controller.toggle(width: 180) {
                EncodingMenuPanel(
                    canDecode: canDecode,
                    onEncode: { controller.close(); onEncode() },
                    onDecode: { controller.close(); onDecode() }
                )
            }
        }
        .background(EncodingDropdownAnchor(controller: controller))
    }
}

private struct EncodingMenuPanel: View {
    let canDecode: Bool
    let onEncode: () -> Void
    let onDecode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PaperMenuActionRow(
                icon: "chevron.left.forwardslash.chevron.right",
                title: L("action.base64Encode"),
                action: onEncode
            )
            if canDecode {
                PaperMenuActionRow(
                    icon: "abc",
                    title: L("action.base64Decode"),
                    action: onDecode
                )
            }
        }
        .padding(5)
        .frame(width: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Zero-size companion handing the dropdown controller its anchor `NSView`
/// (same pattern as the filter dropdowns in the main window toolbar).
private struct EncodingDropdownAnchor: NSViewRepresentable {
    let controller: PaperDropdownController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        MainActor.assumeIsolated { controller.anchorView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated { controller.anchorView = nsView }
    }
}
