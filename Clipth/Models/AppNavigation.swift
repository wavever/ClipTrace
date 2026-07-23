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

    private init() {}

    func showSettings(section: SettingsPanelView.Section? = nil) {
        if let section { pendingSettingsSection = section }
        screen = .settings
    }
    func showList() { screen = .list }
    func showStats() { screen = .stats }
    func showTrash() { screen = .trash }
}
