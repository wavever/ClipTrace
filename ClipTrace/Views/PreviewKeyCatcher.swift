import SwiftUI
import AppKit

/// Invisible view that hooks the main window's `keyDown` so that:
///
/// - `Space` opens the QuickLook preview panel for the currently focused row
///   (or the first row if nothing is focused yet).
/// - Arrow keys move through the current list or adaptive grid geometry.
///
/// Lives behind the card list. The list itself is hit-tested first by SwiftUI,
/// so this only fires when no editable control (search field, tag picker, …)
/// owns the responder chain — exactly the behavior we want.
struct PreviewKeyCatcher: NSViewRepresentable {
    /// Resolved at key-press time so we always act on the current filtered
    /// list, not a snapshot taken at view-construction time.
    var items: () -> [ClipboardItem]
    var focusedID: () -> UUID?
    var setFocused: (UUID?) -> Void
    /// One for list mode; the measured adaptive column count for grid mode.
    var navigationColumns: () -> Int = { 1 }
    /// Visible section lengths (pinned and normal). Grid sections each restart
    /// at column zero, so navigation must not flatten across their headers.
    var navigationSectionCounts: () -> [Int] = { [] }
    var copyAction: ((ClipboardItem) -> Void)?
    var deleteAction: ((ClipboardItem) -> Void)? = nil

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.itemsProvider = items
        view.focusedIDProvider = focusedID
        view.setFocused = setFocused
        view.navigationColumnsProvider = navigationColumns
        view.navigationSectionCountsProvider = navigationSectionCounts
        view.copyAction = copyAction
        view.deleteAction = deleteAction
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.itemsProvider = items
        nsView.focusedIDProvider = focusedID
        nsView.setFocused = setFocused
        nsView.navigationColumnsProvider = navigationColumns
        nsView.navigationSectionCountsProvider = navigationSectionCounts
        nsView.copyAction = copyAction
        nsView.deleteAction = deleteAction
    }

    final class KeyCatcherView: NSView {
        var itemsProvider: (() -> [ClipboardItem])?
        var focusedIDProvider: (() -> UUID?)?
        var setFocused: ((UUID?) -> Void)?
        var navigationColumnsProvider: (() -> Int)?
        var navigationSectionCountsProvider: (() -> [Int])?
        var copyAction: ((ClipboardItem) -> Void)?
        var deleteAction: ((ClipboardItem) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Become first responder once we have a window, so Space lands on
            // us instead of beeping. We yield to text fields by checking the
            // current responder before consuming the key in `keyDown`.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if window.firstResponder === window {
                    window.makeFirstResponder(self)
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            // If anything text-y already owns focus, defer — typing space into
            // the search field should produce a space, not open a preview.
            if let responder = window?.firstResponder,
               responder !== self,
               isEditableResponder(responder) {
                super.keyDown(with: event)
                return
            }

            guard let itemsProvider, let focusedIDProvider, let setFocused else {
                super.keyDown(with: event)
                return
            }

            let items = itemsProvider()
            guard !items.isEmpty else {
                super.keyDown(with: event)
                return
            }

            let currentIndex = items.firstIndex(where: { $0.id == focusedIDProvider() }) ?? -1

            // Only arrow navigation should fire on OS key-repeat (held key →
            // continuous scroll). The one-shot actions — preview, copy, and
            // especially delete — must ignore repeats: a held ⌫ would otherwise
            // walk the whole list deleting row after row.
            switch event.keyCode {
            case 49:  // Space
                if event.isARepeat { return }
                let targetIndex = currentIndex >= 0 ? currentIndex : 0
                setFocused(items[targetIndex].id)
                QuickLookCoordinator.shared.preview(items: items, startingAt: targetIndex)
                return
            case 123, 124, 125, 126: // ← / → / ↓ / ↑
                let next = directionalIndex(
                    from: currentIndex,
                    keyCode: event.keyCode,
                    itemCount: items.count
                )
                setFocused(items[next].id)
                return
            case 36, 76: // Return / numpad Enter → copy the focused row
                if event.isARepeat { return }
                let targetIndex = currentIndex >= 0 ? currentIndex : 0
                setFocused(items[targetIndex].id)
                copyAction?(items[targetIndex])
                return
            case 51, 117: // Delete (⌫) / forward-delete (⌦) → remove the focused row
                if event.isARepeat { return }
                if currentIndex >= 0 {
                    deleteAction?(items[currentIndex])
                }
                return
            default:
                break
            }
            super.keyDown(with: event)
        }

        /// Resolve a physical neighbor without wrapping left/right across row
        /// edges. Up/down preserve the current column where possible and clamp
        /// to the closest card in an incomplete final row.
        private func directionalIndex(from current: Int, keyCode: UInt16, itemCount: Int) -> Int {
            guard current >= 0 else { return 0 }

            let columns = max(1, navigationColumnsProvider?() ?? 1)
            let proposedSections = navigationSectionCountsProvider?() ?? []
            let sections = proposedSections.allSatisfy({ $0 > 0 })
                && proposedSections.reduce(0, +) == itemCount
                ? proposedSections
                : [itemCount]

            var sectionStart = 0
            var sectionIndex = 0
            for (index, count) in sections.enumerated() {
                if current < sectionStart + count {
                    sectionIndex = index
                    break
                }
                sectionStart += count
            }

            let sectionCount = sections[sectionIndex]
            let local = current - sectionStart
            let column = local % columns
            let row = local / columns

            switch keyCode {
            case 123: // ←
                return column > 0 ? current - 1 : current

            case 124: // →
                let candidate = local + 1
                return candidate < sectionCount && candidate / columns == row
                    ? current + 1
                    : current

            case 126: // ↑
                if local >= columns { return current - columns }
                guard sectionIndex > 0 else { return current }

                let previousCount = sections[sectionIndex - 1]
                let previousStart = sectionStart - previousCount
                let previousLastRowStart = ((previousCount - 1) / columns) * columns
                return previousStart + min(previousLastRowStart + column, previousCount - 1)

            case 125: // ↓
                let lastRow = (sectionCount - 1) / columns
                if row < lastRow {
                    let nextRowStart = (row + 1) * columns
                    return sectionStart + min(nextRowStart + column, sectionCount - 1)
                }
                guard sectionIndex + 1 < sections.count else { return current }

                let nextCount = sections[sectionIndex + 1]
                let nextStart = sectionStart + sectionCount
                return nextStart + min(column, nextCount - 1)

            default:
                return current
            }
        }

        private func isEditableResponder(_ responder: NSResponder) -> Bool {
            if responder is NSTextView { return true }
            if let view = responder as? NSView,
               view.className.contains("NSTextField") || view.className.contains("TextField") {
                return true
            }
            return false
        }
    }
}
