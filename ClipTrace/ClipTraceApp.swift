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
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
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

    /// Re-open the main window when the user clicks the Dock icon after
    /// closing it with the red traffic light. Without this AppKit doesn't
    /// know how to surface the SwiftUI `Window` scene again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppDelegate.openMainWindow()
        }
        return true
    }

    /// Re-assert the user's chosen Dock visibility from the saved preference.
    /// Used at launch and again whenever a window closes, since AppKit silently
    /// reverts an `.accessory` app back to `.regular` (its bundle default) once
    /// the last standard window goes away.
    private func syncActivationPolicyFromDefaults() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showInDock") == nil {
            defaults.set(true, forKey: "showInDock")
        }
        let showInDock = defaults.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
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
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "剪迹" {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
