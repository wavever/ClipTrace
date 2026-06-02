import SwiftUI

/// App-styled confirmation dialog rendered by `MainWindowContent` whenever
/// `ConfirmationCenter` has a pending request. Matches the paper-card look of
/// the rest of the app; the confirm button is the filled, eye-catching one
/// (solid red for destructive deletes, accent otherwise) so the dangerous
/// choice always reads loudest.
struct ConfirmationDialogView: View {
    let request: ConfirmRequest
    var onConfirm: () -> Void
    var onCancel: () -> Void

    private var tint: Color { request.isDestructive ? .appDanger : .appAccent }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: request.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 54, height: 54)
            .padding(.top, 24)
            .padding(.bottom, 14)

            Text(request.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appMetal)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            if let message = request.message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(request.cancelLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut(.cancelAction)

                Button(action: onConfirm) {
                    Text(request.confirmLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PaperActionButtonStyle(role: request.isDestructive ? .destructive : .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow, radius: 30, y: 12)
    }
}
