import SwiftUI
import AppKit

/// Invisible view that hooks the main window's `keyDown` so that:
///
/// - `Space` opens the QuickLook preview panel for the currently focused row
///   (or the first row if nothing is focused yet).
/// - `↑` / `↓` move the focused row, just like Finder's list view.
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
    var copyAction: ((ClipboardItem) -> Void)?

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.itemsProvider = items
        view.focusedIDProvider = focusedID
        view.setFocused = setFocused
        view.copyAction = copyAction
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.itemsProvider = items
        nsView.focusedIDProvider = focusedID
        nsView.setFocused = setFocused
        nsView.copyAction = copyAction
    }

    final class KeyCatcherView: NSView {
        var itemsProvider: (() -> [ClipboardItem])?
        var focusedIDProvider: (() -> UUID?)?
        var setFocused: ((UUID?) -> Void)?
        var copyAction: ((ClipboardItem) -> Void)?

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

            switch event.keyCode {
            case 49:  // Space
                let targetIndex = currentIndex >= 0 ? currentIndex : 0
                setFocused(items[targetIndex].id)
                QuickLookCoordinator.shared.preview(items: items, startingAt: targetIndex)
                return
            case 125: // ↓
                let next = min(items.count - 1, max(0, currentIndex) + (currentIndex < 0 ? 0 : 1))
                setFocused(items[next].id)
                return
            case 126: // ↑
                let prev = max(0, (currentIndex < 0 ? 0 : currentIndex) - 1)
                setFocused(items[prev].id)
                return
            default:
                break
            }
            super.keyDown(with: event)
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
