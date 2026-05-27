import SwiftUI
import AppKit

/// Surface, border, and shadow tokens used by the main window's "paper" look.
/// Sourced from the app icon: warm cream paper on a muted sage frame, with
/// soft warm-olive shadows instead of the cool grey/blacks AppKit defaults to.
///
/// These are all dynamic NSColors so light/dark switch without re-rendering
/// the call sites. Sage is hard-coded (rather than read from `AccentPalette`)
/// because the surface language should stay stable when the user picks a
/// different accent — only the *content* tint should follow the accent.
extension Color {
    /// Window-level page color. Cards float on top of this.
    static var appPaper: Color { Self.dynamic(light: paperLight, dark: paperDark) }

    /// Muted sage chassis color taken from the app icon's outer frame.
    static var appFrame: Color { Self.dynamic(light: frameLight, dark: frameDark) }

    /// Softer sage wash used for broad structural bands.
    static var appFrameSoft: Color { Self.dynamic(light: frameSoftLight, dark: frameSoftDark) }

    /// Card body color. Slightly brighter than `appPaper` so cards visibly
    /// lift off the page even without a heavy shadow.
    static var appCard: Color { Self.dynamic(light: cardLight, dark: cardDark) }

    /// Subtle warmer fill used for hover/selected card states. Stays in the
    /// paper family so it doesn't read as a tinted highlight.
    static var appCardHover: Color { Self.dynamic(light: cardHoverLight, dark: cardHoverDark) }

    /// Sage stroke at a low alpha — the structural color from the icon.
    static var appCardBorder: Color { Self.dynamic(light: borderLight, dark: borderDark) }

    /// Stronger sage for hover/selected borders.
    static var appCardBorderStrong: Color { Self.dynamic(light: borderStrongLight, dark: borderStrongDark) }

    /// Warm-olive shadow color. Replaces the cool `.black.opacity(...)` so
    /// the depth cue stays in the same color family as the paper surface.
    static var appCardShadow: Color { Self.dynamic(light: shadowLight, dark: shadowDark) }

    /// Hairline highlight painted on the top edge of a card — mimics how the
    /// icon's stacked paper catches light along its top fold.
    static var appCardHighlight: Color { Self.dynamic(light: highlightLight, dark: highlightDark) }

    /// Soft "chip" fill used by type/tag pills in the row meta line. Reads as
    /// warm parchment instead of the cool `secondary.opacity(0.14)` default.
    static var appChipFill: Color { Self.dynamic(light: chipLight, dark: chipDark) }

    /// Hairline divider color tuned for the paper surface.
    static var appPaperDivider: Color { Self.dynamic(light: dividerLight, dark: dividerDark) }

    /// Warm graphite used where a metal-like neutral fits better than black.
    static var appMetal: Color { Self.dynamic(light: metalLight, dark: metalDark) }

    // MARK: - Raw values

    // Keep the page warm, but not so saturated that the whole app turns tan.
    private static let paperLight   = NSColor(srgbRed: 0.958, green: 0.940, blue: 0.902, alpha: 1)
    private static let paperDark    = NSColor(srgbRed: 0.105, green: 0.098, blue: 0.086, alpha: 1)

    private static let frameLight     = NSColor(srgbRed: 0.570, green: 0.615, blue: 0.505, alpha: 1)
    private static let frameDark      = NSColor(srgbRed: 0.385, green: 0.455, blue: 0.380, alpha: 1)
    private static let frameSoftLight = NSColor(srgbRed: 0.710, green: 0.740, blue: 0.640, alpha: 1)
    private static let frameSoftDark  = NSColor(srgbRed: 0.185, green: 0.225, blue: 0.190, alpha: 1)

    private static let cardLight    = NSColor(srgbRed: 0.995, green: 0.986, blue: 0.958, alpha: 1)
    private static let cardDark     = NSColor(srgbRed: 0.168, green: 0.154, blue: 0.134, alpha: 1)

    private static let cardHoverLight = NSColor(srgbRed: 1.000, green: 0.994, blue: 0.968, alpha: 1)
    private static let cardHoverDark  = NSColor(srgbRed: 0.192, green: 0.176, blue: 0.154, alpha: 1)

    // Sage (0.47, 0.65, 0.54) / (0.58, 0.76, 0.65) at low alpha.
    private static let borderLight       = NSColor(srgbRed: 0.47, green: 0.65, blue: 0.54, alpha: 0.18)
    private static let borderDark        = NSColor(srgbRed: 0.58, green: 0.76, blue: 0.65, alpha: 0.20)
    private static let borderStrongLight = NSColor(srgbRed: 0.47, green: 0.65, blue: 0.54, alpha: 0.42)
    private static let borderStrongDark  = NSColor(srgbRed: 0.58, green: 0.76, blue: 0.65, alpha: 0.50)

    // Warm olive for the shadow on light; near-black with a sliver of warmth on dark.
    private static let shadowLight = NSColor(srgbRed: 0.30, green: 0.25, blue: 0.12, alpha: 0.11)
    private static let shadowDark  = NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 0.48)

    private static let highlightLight = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.55)
    private static let highlightDark  = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.06)

    private static let chipLight = NSColor(srgbRed: 0.86, green: 0.82, blue: 0.72, alpha: 0.24)
    private static let chipDark  = NSColor(srgbRed: 0.55, green: 0.50, blue: 0.40, alpha: 0.22)

    private static let dividerLight = NSColor(srgbRed: 0.47, green: 0.65, blue: 0.54, alpha: 0.14)
    private static let dividerDark  = NSColor(srgbRed: 0.58, green: 0.76, blue: 0.65, alpha: 0.16)

    private static let metalLight = NSColor(srgbRed: 0.355, green: 0.330, blue: 0.285, alpha: 1)
    private static let metalDark  = NSColor(srgbRed: 0.760, green: 0.720, blue: 0.650, alpha: 1)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }
}

/// A reusable card surface modifier so the row and the pinned-section header
/// pick up identical paper styling.
struct PaperCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 14
    var isHovered: Bool = false
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(isHovered || isSelected ? Color.appCardHover : Color.appCard)
                    // Top-edge highlight: just enough to keep the paper from
                    // reading as a flat beige rectangle.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isHovered || isSelected ? Color.appCardBorderStrong : Color.appCardBorder,
                        lineWidth: isHovered || isSelected ? 1 : 0.75
                    )
            )
            .shadow(color: Color.appCardShadow, radius: isHovered ? 9 : 5, x: 0, y: isHovered ? 4 : 2)
    }
}

extension View {
    func paperCard(
        cornerRadius: CGFloat = 14,
        isHovered: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        modifier(PaperCardBackground(
            cornerRadius: cornerRadius,
            isHovered: isHovered,
            isSelected: isSelected
        ))
    }
}

struct AppLogoMark: View {
    var size: CGFloat
    var shadowRadius: CGFloat = 0
    var shadowOpacity: CGFloat = 0

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .compositingGroup()
            .shadow(color: Color.appCardShadow.opacity(shadowOpacity), radius: shadowRadius, y: shadowRadius > 0 ? shadowRadius * 0.35 : 0)
    }
}

struct PaperActionButtonStyle: ButtonStyle {
    enum Role {
        case plain
        case primary
        case destructive
    }

    var role: Role = .plain

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: role == .plain ? 0.75 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .plain: return Color.appMetal
        case .primary, .destructive: return .white
        }
    }

    private var background: Color {
        switch role {
        case .plain: return Color.appChipFill
        case .primary: return Color.appAccent
        case .destructive: return .red
        }
    }

    private var border: Color {
        switch role {
        case .plain: return Color.appCardBorder
        case .primary, .destructive: return .clear
        }
    }
}

struct PaperIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.appMetal)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appChipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct PaperTextFieldBackground: ViewModifier {
    var cornerRadius: CGFloat = 7
    var focused: Bool = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appCard.opacity(focused ? 1 : 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        focused ? Color.appAccent.opacity(0.55) : Color.appCardBorder,
                        lineWidth: focused ? 1 : 0.75
                    )
            )
    }
}

extension View {
    func paperTextField(cornerRadius: CGFloat = 7, focused: Bool = false) -> some View {
        modifier(PaperTextFieldBackground(cornerRadius: cornerRadius, focused: focused))
    }
}
