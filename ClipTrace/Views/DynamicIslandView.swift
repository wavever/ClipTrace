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
            background
            content
                .padding(.horizontal, state.horizontalPadding)
                .padding(.vertical, state.verticalPadding)
        }
        .frame(width: state.size.width, height: state.size.height)
        .contentShape(RoundedRectangle(cornerRadius: state.cornerRadius, style: .continuous))
        .onTapGesture { onTap() }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: state)
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .idle:
            Capsule()
                .fill(Color.black)
        case .toast:
            RoundedRectangle(cornerRadius: state.cornerRadius, style: .continuous)
                .fill(Color.appPaper.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: state.cornerRadius, style: .continuous)
                        .strokeBorder(Color.appCardBorder, lineWidth: 0.8)
                )
                .shadow(color: Color.appCardShadow.opacity(0.34), radius: 18, y: 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        case let .toast(icon, preview):
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.appAccent.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("dynamicIsland.copied"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(preview)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appMetal.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Text(L("dynamicIsland.openHint"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

extension DynamicIslandState {
    var size: CGSize {
        switch self {
        case .idle:  return CGSize(width: 60, height: 26)
        case .toast: return CGSize(width: 360, height: 70)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .idle:  return 0
        case .toast: return 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .idle:  return 0
        case .toast: return 12
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .idle:  return size.height / 2
        case .toast: return 22
        }
    }
}
