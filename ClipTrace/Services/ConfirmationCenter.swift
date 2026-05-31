import SwiftUI

/// One pending confirmation request. `action` runs only if the user taps the
/// prominently colored confirm button in the dialog.
struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String?
    let confirmLabel: String
    let cancelLabel: String
    let icon: String
    /// Drives the confirm button's accent. `true` paints it solid red (for
    /// destructive deletes); `false` uses the app accent. Either way it is the
    /// filled, eye-catching button in the dialog.
    let isDestructive: Bool
    let action: () -> Void
}

/// Centralized confirm-before-delete dialog. Any delete site routes through
/// `ConfirmationCenter.shared.confirm(...)` instead of mutating directly, and
/// `MainWindowContent` hosts the single overlay that renders the request. This
/// keeps every delete in the app behind one consistent, app-styled dialog.
@MainActor
final class ConfirmationCenter: ObservableObject {
    static let shared = ConfirmationCenter()

    @Published var request: ConfirmRequest?

    private init() {}

    func confirm(
        title: String,
        message: String? = nil,
        confirmLabel: String,
        cancelLabel: String = L("common.cancel"),
        icon: String = "trash",
        isDestructive: Bool = true,
        action: @escaping () -> Void
    ) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            request = ConfirmRequest(
                title: title,
                message: message,
                confirmLabel: confirmLabel,
                cancelLabel: cancelLabel,
                icon: icon,
                isDestructive: isDestructive,
                action: action
            )
        }
    }

    /// Dismiss without running the action (cancel / backdrop tap / Esc).
    func dismiss() {
        withAnimation(.easeIn(duration: 0.18)) { request = nil }
    }

    /// Run the pending action, then dismiss. The action is captured first so it
    /// still fires after the request is cleared.
    func runAndDismiss() {
        let action = request?.action
        withAnimation(.easeIn(duration: 0.18)) { request = nil }
        action?()
    }
}
