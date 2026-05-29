import SwiftUI

enum DynamicIslandState: Equatable {
    case idle
    case toast(itemTypeIcon: String, preview: String)

    static func == (lhs: DynamicIslandState, rhs: DynamicIslandState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case let (.toast(li, lp), .toast(ri, rp)): return li == ri && lp == rp
        default: return false
        }
    }
}

struct DynamicIslandView: View {
    let state: DynamicIslandState
    var onTap: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.black)
            content
                .padding(.horizontal, state.horizontalPadding)
        }
        .frame(width: state.size.width, height: state.size.height)
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case let .toast(icon, preview):
            HStack(spacing: 8) {
                // Tint the leading glyph with the app accent so the pill, even
                // sitting on the hardware-black notch, still nods to the
                // current theme color; the label stays white for legibility.
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                Text(preview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

extension DynamicIslandState {
    var size: CGSize {
        switch self {
        case .idle:  return CGSize(width: 60, height: 26)
        case .toast: return CGSize(width: 280, height: 32)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .idle:  return 0
        case .toast: return 14
        }
    }
}
