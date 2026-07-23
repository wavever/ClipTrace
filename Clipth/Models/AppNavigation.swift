import SwiftUI

enum MainScreen: String {
    case list
    case settings
    case stats
    case trash
}

@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    @Published var screen: MainScreen = .list

    /// One-shot deep link consumed by `SettingsPanelView` so entry points like
    /// the badged menu-bar gear can land on a specific tab (e.g. About when an
    /// update is waiting). `nil` leaves the panel on its default tab.
    @Published var pendingSettingsSection: SettingsPanelView.Section?

    /// One-shot request consumed by `MainWindowView` to replay the main feature
    /// tour from Settings. Kept separate from the persisted first-run flag so
    /// replaying the tour does not resurrect permission onboarding cards.
    @Published var featureTourReplayRequest: UUID?

    private init() {}

    func showSettings(section: SettingsPanelView.Section? = nil) {
        if let section { pendingSettingsSection = section }
        screen = .settings
    }
    func showList() { screen = .list }
    func showStats() { screen = .stats }
    func showTrash() { screen = .trash }
    func replayFeatureTour() {
        featureTourReplayRequest = UUID()
        screen = .list
    }
}
