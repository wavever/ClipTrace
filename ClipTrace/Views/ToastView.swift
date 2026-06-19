import SwiftUI

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // The semantic tint lives only in this small badge — green for
            // success, red for destructive, accent for neutral — so the toast
            // still reads its meaning at a glance without washing the whole
            // surface in a color that fights the warm paper language.
            Image(systemName: toast.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(toast.tint.opacity(0.16)))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        // Paper card surface + top-edge highlight, identical to the row/header
        // cards so the toast reads as the same material floating overhead.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.appCard)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .trim(from: 0.0, to: 0.5)
                    .stroke(Color.appCardHighlight, lineWidth: 1)
                    .blendMode(.plusLighter)
                    .mask(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        // Warm-olive lift instead of the cool default black, with a touch more
        // radius than a resting card so the toast clearly floats above content.
        .shadow(color: Color.appCardShadow, radius: 10, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onDismiss)
    }
}
