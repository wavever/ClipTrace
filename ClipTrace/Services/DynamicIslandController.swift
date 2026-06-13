import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import SwiftData

@MainActor
final class DynamicIslandController: NSObject {
    static let shared = DynamicIslandController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<DynamicIslandView>?
    private var menuPanel: NSPanel?
    private var menuHostingController: NSHostingController<AnyView>?
    private var menuLocalMonitor: Any?
    private var menuGlobalMonitor: Any?
    private var menuResignObserver: NSObjectProtocol?
    private var state: DynamicIslandState = .idle
    private var toastTimer: Timer?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// True when the user has enabled the feature in Settings.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dynamicIslandEnabled")
    }

    /// True when the built-in display has a notch. External displays can become
    /// `NSScreen.main` when they own the menu bar; anchoring to the physical
    /// built-in notched panel keeps the island off those displays.
    static var hasNotchedDisplay: Bool {
        notchedBuiltInScreen != nil
    }

    /// Called on app launch and whenever the setting toggles.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            show()
        } else {
            hide()
        }
    }

    /// Call after a new clipboard item has been recorded. Briefly expands the
    /// pill into a toast that shows the item's type + preview, then collapses.
    func flash(itemIcon: String, preview: String) {
        guard isEnabled else { return }
        if panel == nil { show() }
        guard panel != nil else { return }
        toastTimer?.invalidate()
        applyState(.toast(itemTypeIcon: itemIcon, preview: preview))
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.applyState(.idle)
            }
        }
    }

    // MARK: - Panel lifecycle

    private func show() {
        guard Self.notchedBuiltInScreen != nil else {
            hide()
            return
        }
        guard panel == nil else {
            positionPanel(for: state, animated: false)
            panel?.orderFrontRegardless()
            return
        }

        let initialState: DynamicIslandState = .idle
        let view = DynamicIslandView(state: initialState) { [weak self] in
            self?.handleClick()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialState.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // statusBar level keeps the pill above ordinary windows but below
        // system overlays; we live alongside the menu bar.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // Travel to all spaces (including fullscreen apps) so the pill is
        // always reachable without switching desktops.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentViewController = hosting

        self.panel = panel
        self.hostingController = hosting
        self.state = initialState

        positionPanel(for: initialState, animated: false)
        panel.orderFrontRegardless()
    }

    private func hide() {
        toastTimer?.invalidate()
        toastTimer = nil
        closeMenuPanel()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        state = .idle
    }

    private func applyState(_ newState: DynamicIslandState) {
        guard newState != state else { return }
        state = newState
        hostingController?.rootView = DynamicIslandView(state: newState) { [weak self] in
            self?.handleClick()
        }
        positionPanel(for: newState, animated: true)
    }

    /// Anchor every visible state below the menu-bar / camera safe area. Keeping
    /// the same top edge lets the toast feel like it expands downward from the
    /// compact island instead of rendering text behind the hardware cutout.
    private func positionPanel(for state: DynamicIslandState, animated: Bool) {
        guard let panel else { return }
        let screen = Self.notchedBuiltInScreen
        guard let screen else { return }

        let frame = islandFrame(for: state, on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Click handling

    private func handleClick() {
        if menuPanel?.isVisible == true {
            closeMenuPanel()
            return
        }

        toastTimer?.invalidate()
        toastTimer = nil
        applyState(.idle)
        showMenuPanel()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard isEnabled else {
            hide()
            return
        }
        if Self.notchedBuiltInScreen == nil {
            hide()
        } else if panel == nil {
            show()
        } else {
            positionPanel(for: state, animated: false)
            positionMenuPanel(animated: false)
        }
    }

    // MARK: - Menu replacement panel

    private func showMenuPanel() {
        guard menuPanel == nil else {
            positionMenuPanel(animated: false)
            menuPanel?.orderFrontRegardless()
            return
        }
        guard let screen = Self.notchedBuiltInScreen else { return }

        let size = menuPanelSize(on: screen)
        let root = menuPanelRootView(size: size)
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: size)
        hosting.view.autoresizingMask = [.width, .height]

        let panel = DynamicIslandMenuPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.sharingType = UserDefaults.standard.bool(forKey: "hideFromCapture") ? .none : .readOnly
        panel.contentViewController = hosting

        menuPanel = panel
        menuHostingController = hosting
        installMenuPanelDismissHandlers()
        positionMenuPanel(animated: false)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func closeMenuPanel() {
        if let menuLocalMonitor {
            NSEvent.removeMonitor(menuLocalMonitor)
            self.menuLocalMonitor = nil
        }
        if let menuGlobalMonitor {
            NSEvent.removeMonitor(menuGlobalMonitor)
            self.menuGlobalMonitor = nil
        }
        if let menuResignObserver {
            NotificationCenter.default.removeObserver(menuResignObserver)
            self.menuResignObserver = nil
        }
        menuPanel?.orderOut(nil)
        menuPanel = nil
        menuHostingController = nil
    }

    private func positionMenuPanel(animated: Bool) {
        guard let menuPanel, let screen = Self.notchedBuiltInScreen else { return }
        let size = menuPanel.frame.size
        let anchor = islandFrame(for: .idle, on: screen)
        let visible = screen.visibleFrame
        let gap: CGFloat = 8

        var originX = anchor.midX - size.width / 2
        var originY = anchor.minY - gap - size.height
        originX = min(max(originX, visible.minX + 8), visible.maxX - size.width - 8)
        originY = max(originY, visible.minY + 8)

        let frame = NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                menuPanel.animator().setFrame(frame, display: true)
            }
        } else {
            menuPanel.setFrame(frame, display: true)
        }
    }

    private func menuPanelSize(on screen: NSScreen) -> NSSize {
        NSSize(
            width: 340,
            height: min(780, max(630, screen.visibleFrame.height - 48))
        )
    }

    private func menuPanelRootView(size: NSSize) -> AnyView {
        let language = Self.currentAppLanguage
        let accent = Self.currentAccentPalette

        return AnyView(
            MenuBarView(
                surfaceStyle: .dynamicIsland,
                onRequestClose: { [weak self] in
                    self?.closeMenuPanel()
                },
                onOpenMain: {
                    AppNavigation.shared.showList()
                    AppDelegate.openMainWindow()
                },
                onOpenSettings: {
                    AppNavigation.shared.showSettings()
                    AppDelegate.openMainWindow()
                }
            )
            .environmentObject(ClipboardRuntime.shared.viewModel)
            .modelContainer(AppContainer.shared)
            .environment(\.locale, language.locale ?? Locale.current)
            .tint(accent.color)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.9)
            )
        )
    }

    private func installMenuPanelDismissHandlers() {
        let hostedMenuPanel = menuPanel
        let hostedIslandPanel = panel

        menuLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown,
               event.charactersIgnoringModifiers == "\u{1b}" {
                Task { @MainActor in self?.closeMenuPanel() }
                return nil
            }
            if event.window == hostedMenuPanel || event.window == hostedIslandPanel {
                return event
            }
            Task { @MainActor in self?.closeMenuPanel() }
            return event
        }

        menuGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closeMenuPanel() }
        }

        if let menuPanel {
            menuResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: menuPanel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.closeMenuPanel() }
            }
        }
    }

    private static var currentAppLanguage: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "appLanguage")
            ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    private static var currentAccentPalette: AccentPalette {
        let raw = UserDefaults.standard.string(forKey: "accentPalette")
            ?? AccentPalette.sage.rawValue
        return AccentPalette(rawValue: raw) ?? .sage
    }

    private static var notchedBuiltInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            isBuiltIn(screen) && screen.safeAreaInsets.top > 0
        }
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(for: screen) else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func safeTopY(on screen: NSScreen) -> CGFloat {
        // `visibleFrame.maxY` sits below the menu bar; `safeAreaInsets.top`
        // accounts for the notch/camera housing. Use the lower of both top
        // edges so the expanded toast never renders under either region.
        let safeAreaTopY = screen.frame.maxY - screen.safeAreaInsets.top
        return min(screen.visibleFrame.maxY, safeAreaTopY)
    }

    private func islandFrame(for state: DynamicIslandState, on screen: NSScreen) -> NSRect {
        let size = state.size
        let originX = screen.frame.midX - size.width / 2
        let topGap: CGFloat = state == .idle ? 4 : 8
        let originY = safeTopY(on: screen) - size.height - topGap
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}

private final class DynamicIslandMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
