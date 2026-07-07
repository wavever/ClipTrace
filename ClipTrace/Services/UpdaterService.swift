import AppKit
import Foundation
import Sparkle

/// SwiftUI-friendly wrapper around Sparkle's updater.
///
/// Sparkle handles the entire update lifecycle — appcast fetch, EdDSA signature
/// verification, DMG download, app replacement, and relaunch — and ships a
/// polished standard UI for each step. We just expose two things to the rest
/// of the app:
///
/// 1. `checkForUpdates()` — fire a user-initiated check; Sparkle takes over from there.
/// 2. `canCheck` — a `@Published` mirror of the updater's busy state so the UI
///    can disable the button while a check is already in flight.
/// 3. `updateAvailable` / `latestVersion` — delegate-driven state used for
///    non-modal in-app reminders when a scheduled background check finds an update.
///
/// `SPUUpdater.start()` boots the updater on init, which also kicks off the
/// configured background check schedule (controlled by `SUEnableAutomaticChecks`
/// / `SUScheduledCheckInterval` in Info.plist). Keep the singleton alive for
/// the app's lifetime so background checks keep running even when the Settings
/// window is closed.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    @Published private(set) var canCheck: Bool = true
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var latestVersion: String?

    /// `latestVersion` normalized for display ("0.9.14" → "v0.9.14").
    var latestVersionLabel: String? {
        guard let latestVersion, !latestVersion.isEmpty else { return nil }
        return latestVersion.lowercased().hasPrefix("v") ? latestVersion : "v\(latestVersion)"
    }

    let updater: SPUUpdater
    private let userDriver: ClipTraceUpdaterUserDriver
    private let delegate = ClipTraceUpdaterDelegate()
    private var observation: NSKeyValueObservation?
    private var keyWindowObserver: NSObjectProtocol?
    private var lastSilentProbeAt: Date?

    /// Minimum spacing between the silent open-triggered probes below. Keeps
    /// rapid panel open/close cycles from hammering the appcast while still
    /// catching a fresh release on the next meaningful open.
    private static let silentProbeInterval: TimeInterval = 5 * 60

    private init() {
        userDriver = ClipTraceUpdaterUserDriver(
            hostBundle: .main,
            delegate: delegate
        )
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: delegate
        )
        delegate.service = self

        do {
            try updater.start()
        } catch {
            NSLog("Sparkle updater failed to start: \(error.localizedDescription)")
        }

        observation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            guard let self else { return }
            Task { @MainActor in
                self.canCheck = value
            }
        }

        // The daily Sparkle schedule alone leaves the reminder pill dark for
        // up to a day after a release. Any app surface becoming key (main
        // window, menu-bar panel, quick paste) re-probes silently so the pill
        // lights up on the open that follows a release, not the next morning.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.probeForUpdatesInBackground()
            }
        }
        probeForUpdatesInBackground()
    }

    /// Silent appcast probe: drives `updateAvailable` through the delegate
    /// without any Sparkle UI. Non-user-initiated, so Sparkle still honors a
    /// version the user chose to skip.
    func probeForUpdatesInBackground() {
        guard !updater.sessionInProgress else { return }
        if let lastSilentProbeAt,
           Date().timeIntervalSince(lastSilentProbeAt) < Self.silentProbeInterval {
            return
        }
        lastSilentProbeAt = Date()
        updater.checkForUpdateInformation()
    }

    /// User-initiated update check. Sparkle drives the dialogs from here:
    /// "Checking…" → "Up to date" / "Update available" with release notes →
    /// "Downloading" → "Install and Relaunch".
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    fileprivate func markUpdateAvailable(_ item: SUAppcastItem) {
        let displayVersion = item.displayVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = displayVersion.isEmpty ? item.versionString : displayVersion
        latestVersion = version
        updateAvailable = true
    }

    fileprivate func clearUpdateAvailability() {
        updateAvailable = false
        latestVersion = nil
    }
}

private final class ClipTraceUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    weak var service: UpdaterService?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        markUpdateAvailable(update)
        return false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !state.userInitiated {
            markUpdateAvailable(update)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markUpdateAvailable(item)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            // The user explicitly skipped this version; Sparkle won't offer it
            // again on scheduled checks, so keeping the reminder lit would nag
            // about an update the user just opted out of.
            clearUpdateAvailability()
        case .dismiss:
            markUpdateAvailable(updateItem)
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        clearUpdateAvailability()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        clearUpdateAvailability()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Sparkle terminates the app right after this to hand off to the
        // installer; the quit-confirmation dialog would cancel the relaunch,
        // so flag the termination as update-driven before it arrives.
        AppDelegate.isTerminatingForUpdate = true
        clearUpdateAvailability()
    }

    private func markUpdateAvailable(_ item: SUAppcastItem) {
        Task { @MainActor [weak service] in
            service?.markUpdateAvailable(item)
        }
    }

    private func clearUpdateAvailability() {
        Task { @MainActor [weak service] in
            service?.clearUpdateAvailability()
        }
    }
}

@MainActor
private final class ClipTraceUpdaterUserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        guard let simplifiedError = simplifiedNoUpdateError(from: error as NSError) else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        super.showUpdateNotFoundWithError(
            simplifiedError,
            acknowledgement: acknowledgement
        )
    }

    private func simplifiedNoUpdateError(from error: NSError) -> NSError? {
        guard
            let reasonNumber = error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber,
            let reason = SPUNoUpdateFoundReason(rawValue: reasonNumber.int32Value),
            Self.shouldUseSimplifiedMessage(for: reason)
        else {
            return nil
        }

        var userInfo = error.userInfo
        userInfo[NSLocalizedDescriptionKey] = L(
            "settings.about.update.noUpdateFound",
            runningVersionLabel()
        )
        userInfo.removeValue(forKey: NSLocalizedRecoverySuggestionErrorKey)
        userInfo.removeValue(forKey: NSLocalizedFailureReasonErrorKey)
        return NSError(domain: error.domain, code: error.code, userInfo: userInfo)
    }

    private static func shouldUseSimplifiedMessage(for reason: SPUNoUpdateFoundReason) -> Bool {
        switch reason {
        case .unknown, .onLatestVersion, .onNewerThanLatestVersion:
            return true
        case .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64:
            return false
        @unknown default:
            return false
        }
    }

    private func runningVersionLabel() -> String {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmedVersion = rawVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayVersion: String
        if let trimmedVersion, !trimmedVersion.isEmpty {
            displayVersion = trimmedVersion
        } else {
            displayVersion = "0"
        }

        if displayVersion.lowercased().hasPrefix("v") {
            return displayVersion
        }
        return "v\(displayVersion)"
    }
}
