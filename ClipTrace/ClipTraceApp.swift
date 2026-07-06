import SwiftUI
import SwiftData
import KeyboardShortcuts

@main
struct AppLauncher {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--mcp") {
            MCPServer.run()
            return
        }
        ClipTraceApp.main()
    }
}

/// Owns clipboard capture for the lifetime of the app, independently of any
/// window. Closing the main window should leave the menu-bar utility recording;
/// only an explicit app quit tears the monitor down.
@MainActor
final class ClipboardRuntime {
    static let shared = ClipboardRuntime()

    let viewModel = ClipboardViewModel()

    private let context = AppContainer.shared.mainContext
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        viewModel.startMonitoring(context: context)
        // Seed the shared snapshot at launch so the widgets have data to show
        // before the first new clip arrives.
        WidgetBridge.shared.refreshNow(context: context)
        ImagePayloadStore.migrateStoredImagesInBackground(context: context)
    }

    func stop() {
        guard started else { return }
        started = false
        viewModel.stopMonitoring()
    }
}

struct ClipTraceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var clipboardVM = ClipboardRuntime.shared.viewModel

    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @AppStorage("dynamicIslandEnabled") private var dynamicIslandEnabled = false
    @AppStorage("hideFromCapture") private var hideFromCapture = false
    @AppStorage("appearanceTheme") private var appearanceThemeRaw = AppearanceTheme.system.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue
    // Holding this `@AppStorage` on the root scene is what makes a palette
    // change trigger a body rebuild — `Color.appAccent` reads from the same
    // key, so descendants pick up the new colour on the next render pass.
    @AppStorage("accentPalette") private var accentPaletteRaw = AccentPalette.sage.rawValue

    private var appearanceTheme: AppearanceTheme {
        AppearanceTheme(rawValue: appearanceThemeRaw) ?? .system
    }
    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .system
    }
    private var accentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .sage
    }

    var body: some Scene {
        // `Window` (not `WindowGroup`) so opening from the menu bar reuses the
        // existing window instead of stacking a new one each click.
        Window("剪迹", id: "main") {
            MainWindowView()
                .environmentObject(clipboardVM)
                .modelContainer(AppContainer.shared)
                .environment(\.locale, appLanguage.locale ?? Locale.current)
                .tint(accentPalette.color)
                .onAppear {
                    applyActivationPolicy()
                    applyCaptureProtection()
                    applyAppearance()
                }
                .onChange(of: showInDock) { _, _ in
                    applyActivationPolicy()
                }
                .onChange(of: dynamicIslandEnabled) { _, enabled in
                    DynamicIslandController.shared.setEnabled(enabled)
                }
                .onChange(of: hideFromCapture) { _, _ in
                    applyCaptureProtection()
                }
                .onChange(of: appearanceTheme) { _, _ in
                    applyAppearance()
                }
        }
        .defaultSize(width: 1000, height: 640)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("ClipBoard", image: "MenuBarIcon", isInserted: $menuBarIcon) {
            MenuBarView()
                .environmentObject(clipboardVM)
                .modelContainer(AppContainer.shared)
                .environment(\.locale, appLanguage.locale ?? Locale.current)
                .tint(accentPalette.color)
                .onAppear { applyAppearance() }
        }
        .menuBarExtraStyle(.window)
    }

    /// Pin (or release) the app-wide appearance. Driving `NSApp.appearance`
    /// directly — instead of `.preferredColorScheme` — is what lets "follow
    /// system" actually reset: setting it to `nil` clears the forced scheme,
    /// whereas SwiftUI leaves the window's `NSAppearance` stuck on the last
    /// `.light`/`.dark` value it was given.
    private func applyAppearance() {
        NSApp.appearance = appearanceTheme.nsAppearance
    }

    /// Toggle `NSWindow.sharingType` on every app window so the clipboard
    /// history doesn't leak into screen recordings or shared screens when the
    /// user enables the privacy switch.
    private func applyCaptureProtection() {
        let type: NSWindow.SharingType = hideFromCapture ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    private func applyActivationPolicy() {
        let policy = AppDelegate.desiredActivationPolicy()
        guard NSApp.activationPolicy() != policy else { return }

        // Remember the window that was focused so we can restore it after the
        // policy change (switching to .accessory makes AppKit briefly hand
        // focus to another app).
        let previousKeyWindow = NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })

        NSApp.setActivationPolicy(policy)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let confirmBeforeQuitKey = "confirmBeforeQuit"
    private var quitConfirmationPanel: NSPanel?
    private var isQuittingAfterConfirmation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        syncActivationPolicyFromDefaults()
        applyInitialAppearance()
        setupGlobalHotKeys()
        ClipboardRuntime.shared.start()
        DispatchQueue.main.async {
            QuickPasteController.shared.prewarm()
        }

        // AppKit resets the activation policy back to the bundle default
        // (`.regular`, since we ship no `LSUIElement`) when the last standard
        // window closes — which pops the Dock icon back even though the user
        // asked to hide it. Re-assert the saved policy after any window closes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        DynamicIslandController.shared.setEnabled(
            DynamicIslandController.shared.isEnabled
        )
        // Touch the singleton so the Sparkle updater starts and background
        // checks fire on schedule (per SUEnableAutomaticChecks /
        // SUScheduledCheckInterval in Info.plist). Deferred a few seconds
        // past launch so its initialisation (network probe, signature setup)
        // doesn't contend with the first window paint.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            _ = UpdaterService.shared
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardRuntime.shared.stop()
    }

    /// Keep the app alive in the menu bar after the main window is closed.
    /// Users explicitly quit via the menu-bar Quit button or the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Command-Q and every explicit terminate request are routed here. By
    /// default we ask once before fully stopping the clipboard monitor; the
    /// Settings switch can opt out for users who prefer immediate quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isQuittingAfterConfirmation { return .terminateNow }
        guard shouldConfirmBeforeQuit else { return .terminateNow }
        showQuitConfirmation()
        return .terminateCancel
    }

    /// Re-open the main window when the user clicks the Dock icon after
    /// closing it with the red traffic light. Without this AppKit doesn't
    /// know how to surface the SwiftUI `Window` scene again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppDelegate.openMainWindow()
        }
        return true
    }

    static let mainWindowTitle = "剪迹"

    /// The policy the app should hold right now: the saved Dock preference,
    /// except that a visible main window always pins `.regular`. macOS never
    /// performs its "switch to a Space with the app's windows" transition for
    /// `.accessory` apps, so honoring "hide Dock icon" while the main window
    /// is open would strand users on another app's fullscreen Space whenever
    /// they enter through the menu bar / island / hotkey — the window opens
    /// but the screen never moves there. The preference takes effect again as
    /// soon as the main window closes (`windowWillClose` re-syncs).
    static func desiredActivationPolicy() -> NSApplication.ActivationPolicy {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showInDock") == nil {
            defaults.set(true, forKey: "showInDock")
        }
        if defaults.bool(forKey: "showInDock") { return .regular }
        let mainWindowVisible = NSApp.windows.contains {
            $0.title == mainWindowTitle && $0.isVisible
        }
        return mainWindowVisible ? .regular : .accessory
    }

    /// Re-assert the desired policy. Used at launch and again whenever a
    /// window closes, since AppKit silently reverts an `.accessory` app back
    /// to `.regular` (its bundle default) once the last standard window goes
    /// away — and, in the other direction, closing the main window is when a
    /// hidden-Dock preference becomes applicable again.
    private func syncActivationPolicyFromDefaults() {
        NSApp.setActivationPolicy(Self.desiredActivationPolicy())
    }

    private var shouldConfirmBeforeQuit: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: confirmBeforeQuitKey) == nil {
            defaults.set(true, forKey: confirmBeforeQuitKey)
            return true
        }
        return defaults.bool(forKey: confirmBeforeQuitKey)
    }

    private func showQuitConfirmation() {
        if let panel = quitConfirmationPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        if let window = mainAppWindow() {
            presentQuitConfirmation(attachedTo: window)
            return
        }

        showMainWindowForQuitPrompt()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.quitConfirmationPanel == nil else { return }
            if let window = self.mainAppWindow() {
                self.presentQuitConfirmation(attachedTo: window)
            } else {
                self.presentStandaloneQuitConfirmation()
            }
        }
    }

    private func mainAppWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.title == Self.mainWindowTitle && window.isVisible
        } ?? NSApp.windows.first { window in
            window.isVisible && window.canBecomeKey && !(window is NSPanel)
        }
    }

    private func showMainWindowForQuitPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == Self.mainWindowTitle {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func presentQuitConfirmation(attachedTo window: NSWindow) {
        let panel = makeQuitConfirmationPanel(
            frame: window.frame,
            dimBackground: true
        )
        window.addChildWindow(panel, ordered: .above)
        quitConfirmationPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func presentStandaloneQuitConfirmation() {
        let size = NSSize(width: 380, height: 280)
        let frame = NSRect(origin: .zero, size: size)
        let panel = makeQuitConfirmationPanel(frame: frame, dimBackground: false)
        quitConfirmationPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeQuitConfirmationPanel(frame: NSRect, dimBackground: Bool) -> NSPanel {
        let request = ConfirmRequest(
            title: L("quit.confirm.title"),
            message: L("quit.confirm.message"),
            confirmLabel: L("quit.confirm.button"),
            cancelLabel: L("common.cancel"),
            icon: "power",
            isDestructive: true,
            action: {}
        )

        let panel = QuitConfirmationPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.transient, .ignoresCycle]

        panel.contentView = NSHostingView(
            rootView: QuitConfirmationHost(
                request: request,
                dimBackground: dimBackground,
                onConfirm: { [weak self] in
                    self?.confirmQuit()
                },
                onCancel: { [weak self] in
                    self?.dismissQuitConfirmation()
                }
            )
            .frame(width: frame.width, height: frame.height)
        )

        return panel
    }

    private func confirmQuit() {
        isQuittingAfterConfirmation = true
        dismissQuitConfirmation()
        NSApp.terminate(nil)
    }

    private func dismissQuitConfirmation() {
        guard let panel = quitConfirmationPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.close()
        quitConfirmationPanel = nil
    }

    /// Window just closed — re-apply the saved policy on the next runloop, once
    /// AppKit has finished tearing the window down (and applied its own policy
    /// reset). Without the defer we'd set the policy before AppKit clobbers it.
    @objc private func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicyFromDefaults()
        }
    }

    /// Pin the saved appearance before the first window paints, so the app
    /// launches in the right scheme rather than flashing the system default.
    private func applyInitialAppearance() {
        let raw = UserDefaults.standard.string(forKey: "appearanceTheme")
            ?? AppearanceTheme.system.rawValue
        let theme = AppearanceTheme(rawValue: raw) ?? .system
        NSApp.appearance = theme.nsAppearance
    }

    private func setupGlobalHotKeys() {
        KeyboardShortcuts.onKeyUp(for: .openMainWindow) {
            Task { @MainActor in
                AppDelegate.openMainWindow()
            }
        }
        // Open the quick panel on key-down rather than waiting for key-up.
        // This shaves the user's key-hold time off the perceived latency of
        // the global shortcut, making the popup appear as soon as the chord is
        // recognized.
        KeyboardShortcuts.onKeyDown(for: .openQuickPaste) {
            Task { @MainActor in
                QuickPasteController.shared.toggle()
            }
        }
    }

    @MainActor
    /// Bring the main window to the user from any entry point (menu bar
    /// panel, dynamic island, global hotkey, Dock re-open) — including while
    /// another app's fullscreen Space is active. Two quirks conspire there:
    /// `.accessory` apps never get the system Space switch on activation, so
    /// the policy is pinned to `.regular` up front (the main window is about
    /// to be visible, which is exactly when `desiredActivationPolicy` holds
    /// `.regular` anyway); and activating/keying in the same runloop turn as
    /// the policy flip or the panel teardown loses the switch, so both are
    /// deferred one tick.
    static func openMainWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        DispatchQueue.main.async {
            // Re-pin in case a window-close re-sync raced us in this gap
            // (closing the menu-bar panel triggers one).
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == mainWindowTitle {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }
}

private final class QuitConfirmationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct QuitConfirmationHost: View {
    let request: ConfirmRequest
    let dimBackground: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            if dimBackground {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onCancel)
            }

            ConfirmationDialogView(
                request: request,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        }
        .background(Color.clear)
    }
}
