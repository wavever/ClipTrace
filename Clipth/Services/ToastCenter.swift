import SwiftUI
import AppKit
import QuartzCore

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String
    let tint: Color
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(
        _ message: String,
        systemImage: String = "checkmark.circle.fill",
        tint: Color = .green,
        duration: TimeInterval = 2.2
    ) {
        dismissTask?.cancel()
        let toast = Toast(message: message, systemImage: systemImage, tint: tint)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            current = toast
        }
        ToastWindowPresenter.shared.show(toast)
        let id = toast.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.current?.id == id else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    self.current = nil
                }
                ToastWindowPresenter.shared.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeIn(duration: 0.18)) {
            current = nil
        }
        ToastWindowPresenter.shared.dismiss()
    }
}

/// Presents toasts in their own non-activating panel instead of as a view
/// overlay inside `MainWindowView`. SwiftUI sheets / alerts are separate AppKit
/// windows; a normal in-window overlay is therefore painted *under* them. This
/// panel floats above in-app sheet, confirmation dialog, and custom popover
/// while still being positioned inside the app window and not taking focus from
/// the current control.
@MainActor
private final class ToastWindowPresenter {
    static let shared = ToastWindowPresenter()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    private init() {}

    func show(_ toast: Toast) {
        let root = AnyView(
            ToastView(toast: toast) {
                ToastCenter.shared.dismiss()
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        )

        let hosting: NSHostingView<AnyView>
        if let existing = hostingView {
            existing.rootView = root
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: root)
            hostingView = hosting
        }

        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = CGSize(
            width: max(fitting.width, 180),
            height: max(fitting.height, 52)
        )
        hosting.frame = CGRect(origin: .zero, size: size)

        let panel = ensurePanel(size: size)
        panel.contentView = hosting
        panel.setFrame(positionedFrame(for: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func ensurePanel(size: CGSize) -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func positionedFrame(for size: CGSize) -> CGRect {
        let anchorWindow = appAnchorWindow()
        let anchorFrame = anchorWindow?.frame
        let fallbackFrame = anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let targetFrame = anchorFrame ?? fallbackFrame
        let horizontalInset: CGFloat = 14
        let minX = targetFrame.minX + horizontalInset
        let maxX = max(minX, targetFrame.maxX - size.width - horizontalInset)
        let x = min(max(targetFrame.midX - size.width / 2, minX), maxX)

        return CGRect(
            x: x,
            y: targetFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func appAnchorWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key !== panel {
            return key
        }
        if let main = NSApp.mainWindow, main !== panel {
            return main
        }
        return NSApp.windows.first { window in
            window.isVisible && window !== panel
        }
    }
}
