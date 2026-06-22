import SwiftUI

// MARK: - Shared notch motion

/// Centralized spring curves for the island. `close` is critically damped so the
/// surface never overshoots upward and exposes the camera cutout on collapse.
enum NotchAnimation {
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Expand: lightly under-damped for a responsive, slightly bouncy growth.
    static var open: Animation {
        reduceMotion ? .easeOut(duration: 0.18)
                     : .spring(response: 0.42, dampingFraction: 0.82)
    }

    /// Collapse: critically damped (no rebound) so the bottom edge settles
    /// cleanly without lifting above the notch height.
    static var close: Animation {
        reduceMotion ? .easeOut(duration: 0.18)
                     : .spring(response: 0.38, dampingFraction: 1.0)
    }

    /// Notification pop — a touch bouncier for the copy toast.
    static var pop: Animation {
        reduceMotion ? .easeOut(duration: 0.18)
                     : .spring(response: 0.32, dampingFraction: 0.74)
    }
}

// MARK: - Surface state

/// The single morphing surface only ever lives in one of these states. The copy
/// notification and the expanded clipboard menu are states of the *same* surface,
/// not separate windows.
enum DynamicIslandState: Equatable {
    case collapsed
    case notification(itemTypeIcon: String, preview: String)
    case expanded

    static func == (lhs: DynamicIslandState, rhs: DynamicIslandState) -> Bool {
        switch (lhs, rhs) {
        case (.collapsed, .collapsed): return true
        case (.expanded, .expanded): return true
        case let (.notification(li, lp), .notification(ri, rp)): return li == ri && lp == rp
        default: return false
        }
    }

    var isExpanded: Bool { self == .expanded }
}

/// Observable so the controller can drive transitions with `withAnimation`,
/// letting SwiftUI interpolate the surface geometry instead of swapping panels.
@MainActor
final class IslandModel: ObservableObject {
    @Published var state: DynamicIslandState = .collapsed
}

// MARK: - The island surface

struct DynamicIslandView: View {
    @ObservedObject var model: IslandModel

    /// Physical notch geometry, resolved from the target screen.
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// Width / body height the surface grows to when the menu is open.
    let expandedWidth: CGFloat
    let expandedBodyHeight: CGFloat

    /// Tapping the notch band toggles expand/collapse.
    var onBandTap: () -> Void
    /// The expanded clipboard menu, built once by the controller with its
    /// environment wired up, so its internal `@State` survives re-renders.
    let menu: AnyView

    private let notificationBodyHeight: CGFloat = 58
    private let dividerHeight: CGFloat = 1

    var body: some View {
        surface
            // Centered horizontally (panel is screen-centered ⇒ notch-centered),
            // pinned to the top edge so it grows *down* from the notch. The empty
            // surrounding area carries no view, so clicks fall through to apps below.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var surface: some View {
        VStack(spacing: 0) {
            // Camera-safe band: an empty region exactly as tall as the notch.
            // Nothing is ever drawn here, so content can never sit under the camera.
            Color.clear
                .frame(width: surfaceWidth, height: notchHeight)
                .contentShape(Rectangle())
                .onTapGesture { onBandTap() }

            bodyContent
        }
        .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
        .background(Color.black)
        // Square top (flush with the screen edge, merging into the notch),
        // rounded bottom — the Dynamic Island silhouette. Overflow during the
        // collapse animation is clipped, giving a clean "curtain" close.
        .clipShape(islandShape)
        .overlay(
            islandShape
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(model.state == .collapsed ? 0 : 0.35), radius: 16, y: 8)
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch model.state {
        case .collapsed:
            EmptyView()
        case let .notification(icon, preview):
            notificationRow(icon: icon, preview: preview)
                .frame(width: surfaceWidth, height: notificationBodyHeight)
                .contentShape(Rectangle())
                .onTapGesture { onBandTap() }
                .transition(.opacity)
        case .expanded:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: dividerHeight)
                menu
                    .frame(width: surfaceWidth, height: expandedBodyHeight, alignment: .top)
            }
            .transition(.opacity)
        }
    }

    private func notificationRow(icon: String, preview: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.appAccent.opacity(0.18)))

            VStack(alignment: .leading, spacing: 2) {
                Text(L("dynamicIsland.copied"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                Text(preview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            Text(L("dynamicIsland.openHint"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Per-state geometry (animated via the model)

    private var surfaceWidth: CGFloat {
        switch model.state {
        case .collapsed:     return min(notchWidth + 18, expandedWidth)
        case .notification:  return min(max(notchWidth + 250, 360), expandedWidth)
        case .expanded:      return expandedWidth
        }
    }

    private var surfaceHeight: CGFloat {
        switch model.state {
        case .collapsed:     return notchHeight
        case .notification:  return notchHeight + notificationBodyHeight
        case .expanded:      return notchHeight + dividerHeight + expandedBodyHeight
        }
    }

    private var bottomRadius: CGFloat {
        switch model.state {
        case .collapsed:     return 10
        case .notification:  return 18
        case .expanded:      return 22
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }
}
