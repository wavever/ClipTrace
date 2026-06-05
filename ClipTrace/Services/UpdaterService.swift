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

    let updater: SPUUpdater
    private let userDriver: ClipTraceUpdaterUserDriver
    private var observation: NSKeyValueObservation?

    private init() {
        userDriver = ClipTraceUpdaterUserDriver(
            hostBundle: .main,
            delegate: nil
        )
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )
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
    }

    /// User-initiated update check. Sparkle drives the dialogs from here:
    /// "Checking…" → "Up to date" / "Update available" with release notes →
    /// "Downloading" → "Install and Relaunch".
    func checkForUpdates() {
        updater.checkForUpdates()
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
