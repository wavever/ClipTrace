import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import SwiftData

// MARK: - Notch geometry

/// Resolves the physical notch geometry of the built-in display. The island is
/// only ever shown on the built-in notched screen; external displays that own
/// the menu bar must not pull it onto themselves.
enum NotchGeometry {
    /// The built-in display that currently reports a notch, if any.
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first { isBuiltIn($0) && hasNotch($0) }
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
    }

    /// Notch width = screen width minus the two menu-bar areas flanking the
    /// cutout. Falls back to a bounded simulated width when the display reports
    /// no auxiliary areas (e.g. a non-notched built-in panel under existing gating).
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        if left > 0 || right > 0 {
            return screen.frame.width - left - right
        }
        return min(max(screen.frame.width * 0.14, 160), 220)
    }

    /// Notch height from the top safe-area inset, falling back to the menu-bar
    /// height so geometry is always well-defined.
    static func notchHeight(for screen: NSScreen) -> CGFloat {
        let inset = screen.safeAreaInsets.top
        if inset > 0 { return inset }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 5 ? menuBar : 32
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(for: screen) else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

// MARK: - Controller

@MainActor
final class DynamicIslandController: NSObject {
    static let shared = DynamicIslandController()

    private let model = IslandModel()
    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<DynamicIslandView>?
    private var toastTimer: Timer?

    // Outside-interaction dismissal, installed only while expanded.
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var appResignObserver: NSObjectProtocol?
    private var contextMenuPresentationActive = false

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

    /// True when the built-in display has a notch. Anchoring to the physical
    /// built-in notched screen keeps the island off external displays.
    static var hasNotchedDisplay: Bool {
        NotchGeometry.preferredScreen != nil
    }

    /// Called on app launch and whenever the setting toggles.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            show()
        } else {
            hide()
        }
    }

    /// Call after a new clipboard item has been recorded. Briefly grows the
    /// surface into a copy notification, then collapses back to the pill. Skipped
    /// while the menu is open so a copy doesn't interrupt browsing.
    func flash(itemIcon: String, preview: String) {
        guard isEnabled else { return }
        if panel == nil { show() }
        guard panel != nil else { return }
        guard model.state != .expanded else { return }

        toastTimer?.invalidate()
        withAnimation(NotchAnimation.pop) {
            model.state = .notification(itemTypeIcon: itemIcon, preview: preview)
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.model.state != .expanded else { return }
                withAnimation(NotchAnimation.close) {
                    self.model.state = .collapsed
                }
            }
        }
    }

    // MARK: - Panel lifecycle

    private func show() {
        guard let screen = NotchGeometry.preferredScreen else {
            hide()
            return
        }
        guard panel == nil else {
            reposition(on: screen)
            panel?.orderFrontRegardless()
            return
        }

        model.state = .collapsed
        let metrics = Metrics(screen: screen)
        let hosting = NotchHostingView(rootView: makeRootView(metrics: metrics))
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: metrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        // Above the menu-bar window so the surface visually merges with the notch.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = UserDefaults.standard.bool(forKey: "hideFromCapture") ? .none : .readOnly
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting

        panel.setFrame(metrics.panelFrame, display: true)
        panel.orderFrontRegardless()
    }

    private func hide() {
        toastTimer?.invalidate()
        toastTimer = nil
        removeDismissHandlers()
        contextMenuPresentationActive = false
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        model.state = .collapsed
    }

    private func makeRootView(metrics: Metrics) -> DynamicIslandView {
        DynamicIslandView(
            model: model,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight,
            expandedWidth: metrics.expandedWidth,
            expandedBodyHeight: metrics.expandedBodyHeight,
            onBandTap: { [weak self] in self?.handleBandTap() },
            menu: makeMenu()
        )
    }

    private func reposition(on screen: NSScreen) {
        guard let panel, let hostingView else { return }
        let metrics = Metrics(screen: screen)
        hostingView.rootView = makeRootView(metrics: metrics)
        panel.setFrame(metrics.panelFrame, display: true)
    }

    // MARK: - Interaction

    private func handleBandTap() {
        if model.state == .expanded {
            collapse()
        } else {
            expand()
        }
    }

    private func expand() {
        toastTimer?.invalidate()
        toastTimer = nil
        withAnimation(NotchAnimation.open) {
            model.state = .expanded
        }
        panel?.makeKey()
        installDismissHandlers()
    }

    private func collapse() {
        removeDismissHandlers()
        contextMenuPresentationActive = false
        withAnimation(NotchAnimation.close) {
            model.state = .collapsed
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard isEnabled else {
            hide()
            return
        }
        guard let screen = NotchGeometry.preferredScreen else {
            hide()
            return
        }
        if panel == nil {
            show()
        } else {
            reposition(on: screen)
        }
    }

    // MARK: - Dismiss handlers (expanded only)

    private func installDismissHandlers() {
        guard localMonitor == nil else { return }
        let hosted = panel

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1b}" {
                // Let an active child menu or sheet consume Esc first. Without
                // this, the island monitor would collapse the entire surface
                // before the menu can close or a sheet can run its cancel path.
                if self?.contextMenuPresentationActive == true ||
                    hosted?.attachedSheet != nil ||
                    hosted?.childWindows?.contains(where: { $0.isVisible }) == true {
                    return event
                }
                Task { @MainActor in self?.collapse() }
                return nil
            }
            // Context menus, flyout submenus and SwiftUI sheets are separate
            // AppKit windows parented to the island panel. They are still part
            // of the expanded interaction, so only clicks outside the entire
            // hierarchy should collapse it.
            if Self.belongsToHostedHierarchy(event.window, hosted: hosted) {
                return event
            }
            Task { @MainActor in self?.collapse() }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }

        if let panel {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // Sheet attachment and key-window transfer settle one turn
                    // after the resign notification. Waiting prevents rename,
                    // preview and delete sheets from dismissing their host.
                    await Task.yield()
                    guard let self, let panel = self.panel,
                          !self.contextMenuPresentationActive,
                          panel.attachedSheet == nil,
                          !Self.belongsToHostedHierarchy(NSApp.keyWindow, hosted: panel) else {
                        return
                    }
                    self.collapse()
                }
            }
        }
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
    }

    /// True for the hosted island panel, any context-menu child panel, nested
    /// submenu, or attached sheet. Walking both parent relationships keeps the
    /// check generic instead of coupling the island to a specific menu type.
    private static func belongsToHostedHierarchy(_ candidate: NSWindow?, hosted: NSWindow?) -> Bool {
        guard let hosted else { return false }
        var current = candidate
        var visited: Set<ObjectIdentifier> = []

        while let window = current {
            if window === hosted { return true }
            let identifier = ObjectIdentifier(window)
            guard visited.insert(identifier).inserted else { return false }
            current = window.sheetParent ?? window.parent
        }
        return false
    }

    private func removeDismissHandlers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
    }

    // MARK: - Expanded menu

    private func makeMenu() -> AnyView {
        let language = Self.currentAppLanguage
        let accent = Self.currentAccentPalette

        return AnyView(
            MenuBarView(
                surfaceStyle: .dynamicIsland,
                onRequestClose: { [weak self] in
                    self?.collapse()
                },
                onOpenMain: {
                    AppNavigation.shared.showList()
                    AppDelegate.openMainWindow()
                },
                onOpenSettings: {
                    AppNavigation.shared.showSettings()
                    AppDelegate.openMainWindow()
                },
                onContextMenuPresentationChange: { [weak self] presenting in
                    self?.contextMenuPresentationActive = presenting
                }
            )
            .environmentObject(ClipboardRuntime.shared.viewModel)
            .modelContainer(AppContainer.shared)
            .environment(\.locale, language.locale ?? Locale.current)
            .tint(accent.color)
        )
    }

    private static var currentAppLanguage: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    private static var currentAccentPalette: AccentPalette {
        let raw = UserDefaults.standard.string(forKey: "accentPalette") ?? AccentPalette.sage.rawValue
        return AccentPalette(rawValue: raw) ?? .sage
    }
}

// MARK: - Panel sizing

private struct Metrics {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedBodyHeight: CGFloat
    let panelFrame: NSRect

    var panelSize: NSSize { panelFrame.size }

    init(screen: NSScreen) {
        let nw = NotchGeometry.notchWidth(for: screen)
        let nh = NotchGeometry.notchHeight(for: screen)
        let bodyH = min(720, max(380, screen.visibleFrame.height - nh - 80))
        let expW: CGFloat = 380

        notchWidth = nw
        notchHeight = nh
        expandedWidth = expW
        expandedBodyHeight = bodyH

        let panelWidth = expW + 24
        let panelHeight = nh + 1 + bodyH + 16
        let originX = screen.frame.midX - panelWidth / 2
        let originY = screen.frame.maxY - panelHeight
        panelFrame = NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight)
    }
}

// MARK: - AppKit hosting

/// Non-activating panel that can still become key so the expanded menu's controls
/// (search field, buttons) respond.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that (a) takes key on first click so a single click on the
/// non-activating panel reaches SwiftUI actions, and (b) defers AppKit
/// constraint/layout invalidation to the next run-loop turn — calling it
/// synchronously during the display cycle re-enters AppKit and crashes.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred { super.needsUpdateConstraints = newValue; return }
            DispatchQueue.main.async { [weak self] in self?.applyDeferred { $0.needsUpdateConstraints = newValue } }
        }
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred { super.needsLayout = newValue; return }
            DispatchQueue.main.async { [weak self] in self?.applyDeferred { $0.needsLayout = newValue } }
        }
    }

    private func applyDeferred(_ body: (NotchHostingView) -> Void) {
        applyingDeferred = true
        body(self)
        applyingDeferred = false
    }
}
