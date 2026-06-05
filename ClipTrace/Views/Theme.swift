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

    /// Muted, warm-leaning red for destructive actions (delete / clear). The
    /// system `.red` reads as too saturated next to the earth-tone palette, so
    /// this terracotta red keeps "danger" legible without screaming.
    static var appDanger: Color { Self.dynamic(light: dangerLight, dark: dangerDark) }

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

    // Softened terracotta — kept close to system red's brightness so white
    // text stays legible, but desaturated and warmed so it sits in the palette.
    private static let dangerLight = NSColor(srgbRed: 0.760, green: 0.330, blue: 0.300, alpha: 1)
    private static let dangerDark  = NSColor(srgbRed: 0.815, green: 0.420, blue: 0.385, alpha: 1)

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
    // Custom button styles don't inherit the system's disabled dimming, so read
    // it ourselves and fade the whole control — otherwise a disabled primary
    // (e.g. an empty "保存") would look fully active.
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? 1 : 0.4)
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
        case .destructive: return Color.appDanger
        }
    }

    private var border: Color {
        switch role {
        case .plain: return Color.appCardBorder
        case .primary, .destructive: return .clear
        }
    }
}

/// A quiet switch graphic in the paper palette. It avoids the bright system-like
/// thumb so the monitor control reads as a status chip instead of an isolated
/// form control.
struct PaperSwitchTrack: View {
    var isOn: Bool
    var isCompact: Bool = false

    private var tint: Color { isOn ? .appAccent : .appDanger }
    private var width: CGFloat { isCompact ? 24 : 28 }
    private var height: CGFloat { isCompact ? 14 : 16 }
    private var dotSize: CGFloat { isCompact ? 5 : 6 }
    private var horizontalInset: CGFloat { isCompact ? 5 : 6 }

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(tint.opacity(0.11))
            Capsule()
                .strokeBorder(tint.opacity(0.26), lineWidth: 0.65)
            Circle()
                .fill(tint)
                .frame(width: dotSize, height: dotSize)
                .padding(.horizontal, horizontalInset)
        }
        .frame(width: width, height: height)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isOn)
    }
}

/// Paper-styled "pause capture" control used in both the main window header and
/// the menu-bar panel. The whole pill toggles `isPaused`; the leading glyph,
/// label, and switch indicator all reflect the current state so it's obvious at
/// a glance whether the clipboard is being recorded.
struct CaptureToggle: View {
    @Binding var isPaused: Bool
    /// Drops the text label for tight layouts (keeps the glyph + switch).
    var showsLabel: Bool = true

    @State private var hovering = false

    private var stateTint: Color { isPaused ? .appDanger : .appAccent }
    private var iconName: String { isPaused ? "pause.fill" : "dot.radiowaves.up.forward" }
    private var cornerRadius: CGFloat { showsLabel ? 7 : 8 }
    private var horizontalPadding: CGFloat { showsLabel ? 10 : 7 }
    private var verticalPadding: CGFloat { showsLabel ? 6 : 5 }
    private var glyphSize: CGFloat { showsLabel ? 18 : 17 }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                isPaused.toggle()
            }
        } label: {
            HStack(spacing: showsLabel ? 7 : 6) {
                Image(systemName: iconName)
                    .font(.system(size: showsLabel ? 10 : 9, weight: .semibold))
                    .foregroundStyle(stateTint)
                    .frame(width: glyphSize, height: glyphSize)
                    .background(
                        Circle()
                            .fill(stateTint.opacity(isPaused ? 0.13 : 0.11))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(stateTint.opacity(0.22), lineWidth: 0.5)
                    )
                if showsLabel {
                    Text(isPaused ? L("monitor.paused") : L("monitor.active"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appMetal)
                        .fixedSize()
                }
                PaperSwitchTrack(isOn: !isPaused, isCompact: !showsLabel)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appChipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        hovering ? stateTint.opacity(0.42) : Color.appCardBorder,
                        lineWidth: hovering ? 1 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .help(isPaused ? L("monitor.resume.tooltip") : L("monitor.pause.tooltip"))
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

// MARK: - Paper dropdown

/// One choice in a `PaperMenuPicker`.
struct PaperMenuOption<Value: Hashable> {
    let value: Value
    let title: String
    var icon: String?

    init(_ value: Value, _ title: String, icon: String? = nil) {
        self.value = value
        self.title = title
        self.icon = icon
    }
}

/// Drop-in replacement for `Picker(.menu)`. The system pop-up button opens a
/// cold AppKit menu that clashes with the warm paper UI, so this renders the
/// trigger as a paper chip and the choices as a rectangular paper menu with
/// fully custom rows (hover wash + accent check on the active option). Generic
/// over any `Hashable` value — including optionals — so it covers every
/// dropdown in the app (type filter, poll interval, retention, …).
///
/// The menu is hosted in a borderless child `NSPanel` rather than a `.popover`
/// so it reads as a plain rectangle (no bubble arrow) and is never clipped by
/// an enclosing `ScrollView` such as the settings pane.
struct PaperMenuPicker<Value: Hashable>: View {
    let options: [PaperMenuOption<Value>]
    @Binding var selection: Value
    var width: CGFloat?
    var help: String?

    init(
        options: [PaperMenuOption<Value>],
        selection: Binding<Value>,
        width: CGFloat? = nil,
        help: String? = nil
    ) {
        self.options = options
        self._selection = selection
        self.width = width
        self.help = help
    }

    @State private var hovering = false
    @StateObject private var controller = PaperDropdownController()

    private var selected: PaperMenuOption<Value>? {
        options.first { $0.value == selection }
    }

    var body: some View {
        Button {
            toggleMenu()
        } label: {
            HStack(spacing: 6) {
                if let icon = selected?.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                Text(selected?.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appMetal)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering || controller.isOpen ? Color.appCardHover : Color.appChipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        controller.isOpen ? Color.appAccent.opacity(0.55) : Color.appCardBorder,
                        lineWidth: controller.isOpen ? 1 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(PaperDropdownAnchor(controller: controller))
        .help(help ?? "")
    }

    private func toggleMenu() {
        let menuWidth = max(width ?? 0, 160)
        controller.toggle(width: menuWidth) {
            PaperMenuList(
                options: options,
                selected: selection,
                width: menuWidth,
                onSelect: { value in
                    if selection != value { selection = value }
                    controller.close()
                }
            )
        }
    }
}

/// Owns the borderless child `NSPanel` that hosts an open menu. Kept as an
/// `ObservableObject` so the trigger can reflect the open state, and so the
/// panel + its event monitors are torn down deterministically.
@MainActor
final class PaperDropdownController: ObservableObject {
    weak var anchorView: NSView?
    @Published private(set) var isOpen = false

    private var panel: NSPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    func toggle<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) {
        if isOpen { close() } else { open(width: width, content: content()) }
    }

    private func open<Content: View>(width: CGFloat, content: Content) {
        guard let anchorView, let parent = anchorView.window else { return }

        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]

        // Anchor rect → screen coordinates (AppKit's y-up space).
        let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorOnScreen = parent.convertToScreen(rectInWindow)

        let gap: CGFloat = 4
        var originX = anchorOnScreen.minX
        var originY = anchorOnScreen.minY - gap - height        // hang below the trigger
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if originY < visible.minY { originY = anchorOnScreen.maxY + gap }   // flip above
            originX = min(max(originX, visible.minX + 4), visible.maxX - width - 4)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.animationBehavior = .utilityWindow
        panel.contentView = hosting

        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        isOpen = true

        // Dismiss on any click that isn't inside the menu. Clicks on the
        // trigger itself are passed through so the button's own toggle closes
        // it (otherwise the monitor would close it, then the button reopens).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window == panel { return event }
            if let anchorView = self.anchorView, event.window == anchorView.window {
                let point = anchorView.convert(event.locationInWindow, from: nil)
                if anchorView.bounds.contains(point) { return event }
            }
            self.close()
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        isOpen = false
    }
}

/// Zero-size companion view that hands the controller the backing `NSView`, so
/// it can resolve the trigger's window and on-screen frame when opening.
private struct PaperDropdownAnchor: NSViewRepresentable {
    let controller: PaperDropdownController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        MainActor.assumeIsolated { controller.anchorView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated { controller.anchorView = nsView }
    }
}

private struct PaperMenuList<Value: Hashable>: View {
    let options: [PaperMenuOption<Value>]
    let selected: Value
    let width: CGFloat
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { idx in
                let option = options[idx]
                PaperMenuItem(
                    title: option.title,
                    icon: option.icon,
                    isSelected: option.value == selected,
                    action: { onSelect(option.value) }
                )
            }
        }
        .padding(5)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appPaper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PaperMenuItem: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.appAccent : Color.appMetal)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appMetal)
                    .lineLimit(1)
                Spacer(minLength: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.appAccent.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
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
