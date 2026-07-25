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

    /// Small alert accents such as non-blocking update reminders.
    static var appWarning: Color { Self.dynamic(light: warningLight, dark: warningDark) }

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

    private static let warningLight = NSColor(srgbRed: 0.855, green: 0.505, blue: 0.245, alpha: 1)
    private static let warningDark  = NSColor(srgbRed: 0.940, green: 0.620, blue: 0.330, alpha: 1)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }

    /// AppKit handle for the page color, for the rare spots that must paint an
    /// `NSWindow` directly (SwiftUI backgrounds can't reach the window chrome
    /// the system draws around the menu-bar panel on macOS 26).
    static var appPaperNSColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? paperDark : paperLight
        }
    }
}

/// Non-modal update reminder shown beside `CaptureToggle` in the main window
/// header and the menu-bar panel. Mirrors the toggle's anatomy (tinted glyph
/// bubble on a paper chip) so the two read as siblings; the warm amber tint is
/// what marks it as a prompt. Clicking hands off to Sparkle's user-initiated
/// flow, which focuses the already-deferred update immediately.
struct UpdateReminderPill: View {
    /// Drops the version label for tight layouts (keeps the glyph bubble).
    var showsLabel: Bool = true

    @ObservedObject private var updater = UpdaterService.shared
    @State private var hovering = false

    private var cornerRadius: CGFloat { showsLabel ? 7 : 8 }
    private var horizontalPadding: CGFloat { showsLabel ? 10 : 7 }
    private var verticalPadding: CGFloat { showsLabel ? 6 : 5 }
    private var glyphSize: CGFloat { showsLabel ? 18 : 17 }

    var body: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.system(size: showsLabel ? 10 : 9, weight: .semibold))
                    .foregroundStyle(Color.appWarning)
                    .frame(width: glyphSize, height: glyphSize)
                    .background(
                        Circle()
                            .fill(Color.appWarning.opacity(0.13))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.appWarning.opacity(0.22), lineWidth: 0.5)
                    )
                if showsLabel {
                    Text(updater.latestVersionLabel ?? L("settings.about.update.available"))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.appMetal)
                        .fixedSize()
                }
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
                        hovering ? Color.appWarning.opacity(0.42) : Color.appCardBorder,
                        lineWidth: hovering ? 1 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .accessibilityLabel(tip)
        .hoverTip(tip)
    }

    private var tip: String {
        if let label = updater.latestVersionLabel {
            return L("toolbar.update.tipFormat", label)
        }
        return L("toolbar.update.tip")
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
    var displayTitle: String?
    var onSelect: ((Value) -> Void)?

    init(
        options: [PaperMenuOption<Value>],
        selection: Binding<Value>,
        width: CGFloat? = nil,
        help: String? = nil,
        displayTitle: String? = nil,
        onSelect: ((Value) -> Void)? = nil
    ) {
        self.options = options
        self._selection = selection
        self.width = width
        self.help = help
        self.displayTitle = displayTitle
        self.onSelect = onSelect
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
                Text(displayTitle ?? selected?.title ?? "")
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
                    onSelect?(value)
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

extension View {
    /// Place on the content *inside* a horizontal `ScrollView`. SwiftUI's
    /// horizontal scroller only reacts to horizontal wheel deltas, which
    /// leaves mouse wheels (and vertical trackpad swipes) unable to move it;
    /// this bridges the dominant vertical delta into horizontal travel.
    func redirectsVerticalWheelToHorizontal() -> some View {
        background(WheelToHorizontalBridge())
    }
}

/// Probe view that resolves the AppKit `NSScrollView` backing the enclosing
/// SwiftUI `ScrollView` and redirects vertical wheel events over it into
/// horizontal scrolling. Uses a local event monitor because the scroll view
/// instance belongs to SwiftUI and can't have its `scrollWheel` overridden.
private struct WheelToHorizontalBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeView { BridgeView() }

    func updateNSView(_ nsView: BridgeView, context: Context) {}

    final class BridgeView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.redirect(event) else { return event }
                return nil   // consumed — don't let the outer vertical list scroll too
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Returns true when the event was translated into horizontal travel:
        /// cursor over the strip, vertical delta dominant, and the strip
        /// actually overflows. Everything else keeps native behavior.
        private func redirect(_ event: NSEvent) -> Bool {
            guard event.window === window,
                  let scrollView = enclosingScrollView,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            else { return false }
            let locationInScroll = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(locationInScroll) else { return false }

            let clip = scrollView.contentView
            let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
            guard maxX > 0 else { return false }

            // Notched mice report coarse line deltas; scale them so one notch
            // moves roughly a chip's width.
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
            var origin = clip.bounds.origin
            origin.x = min(max(0, origin.x - delta), maxX)
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
            return true
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

// MARK: - Paper context menu

/// Keeps the shared context-menu interaction consistent while allowing a host
/// surface to supply the tone that belongs beside it. Quick Paste floats on a
/// translucent AppKit popover, whereas the main window and menu-bar panel use
/// the warmer paper palette.
enum PaperContextMenuSurfaceStyle {
    case paper
    case popover

    var foreground: Color {
        switch self {
        case .paper: Color.appMetal
        case .popover: Color.primary.opacity(0.84)
        }
    }

    var hoverFill: Color {
        switch self {
        case .paper: Color.appAccent.opacity(0.14)
        case .popover: Color.secondary.opacity(0.10)
        }
    }

    var selectedFill: Color {
        switch self {
        case .paper: Color.appAccent.opacity(0.10)
        case .popover: Color.appAccent.opacity(0.11)
        }
    }

    var selectedHoverFill: Color {
        switch self {
        case .paper: Color.appAccent.opacity(0.18)
        case .popover: Color.appAccent.opacity(0.16)
        }
    }

    var divider: Color {
        switch self {
        case .paper: Color.appPaperDivider
        case .popover: Color(nsColor: .separatorColor).opacity(0.42)
        }
    }

    var border: Color {
        switch self {
        case .paper: Color.appCardBorder
        case .popover: Color(nsColor: .separatorColor).opacity(0.4)
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .paper: 0.75
        case .popover: 0.5
        }
    }
}

private struct PaperContextMenuSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = PaperContextMenuSurfaceStyle.paper
}

extension EnvironmentValues {
    var paperContextMenuSurfaceStyle: PaperContextMenuSurfaceStyle {
        get { self[PaperContextMenuSurfaceStyleKey.self] }
        set { self[PaperContextMenuSurfaceStyleKey.self] = newValue }
    }
}

extension View {
    func paperContextMenuSurfaceStyle(_ style: PaperContextMenuSurfaceStyle) -> some View {
        environment(\.paperContextMenuSurfaceStyle, style)
    }
}

/// Hosts a borderless child `NSPanel` for a right-click menu, opened *at the
/// cursor* rather than below a fixed trigger. Mirrors `PaperDropdownController`,
/// but the menu drives its own dismissal (outside click, Esc, window resign)
/// since a context menu has no persistent toggle button to bounce off of.
///
/// The native `.contextMenu` renders a cold AppKit `NSMenu` that clashes with
/// the warm paper UI and can't show a custom selected state; this lets the row
/// menu be drawn entirely in SwiftUI with paper tokens.
@MainActor
final class PaperContextMenuController: ObservableObject {
    @Published private(set) var isOpen = false

    private var panel: NSPanel?
    private var submenuPanel: NSPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var closeHandler: (() -> Void)?

    func open<Content: View>(
        at screenPoint: CGPoint,
        in parentWindow: NSWindow,
        width: CGFloat,
        keyboardHandler: ((NSEvent) -> Bool)? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        close()
        closeHandler = onClose

        let hosting = NSHostingView(rootView: content())
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]

        // The menu's top-left should sit at the cursor (AppKit is y-up, so the
        // panel's bottom-left origin is the cursor minus the menu height).
        var originX = screenPoint.x
        var originY = screenPoint.y - height
        if let screen = parentWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            originX = min(max(originX, visible.minX + 4), visible.maxX - width - 4)
            // Flip above the cursor if it would spill off the bottom edge.
            if originY < visible.minY + 4 { originY = min(screenPoint.y, visible.maxY - height - 4) }
            originY = min(max(originY, visible.minY + 4), visible.maxY - height - 4)
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

        parentWindow.addChildWindow(panel, ordered: .above)
        self.panel = panel
        isOpen = true

        // Dismiss on any click outside the menu, and on Esc.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown || event.type == .keyUp {
                if keyboardHandler?(event) == true { return nil }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.close()
                    return nil
                }
                return event
            }
            // Clicks inside the root menu or its open submenu keep the menu up.
            if event.window == panel || event.window == self.submenuPanel { return event }
            self.close()
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// Open a second-level menu flying out beside `rowFrame` (in screen
    /// coordinates). Hosted as a child of the root menu panel so it layers
    /// above and tears down with it.
    func openSubmenu<Content: View>(
        besideRowAt rowFrame: CGRect,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        guard let rootPanel = panel else { return }
        closeSubmenu()

        let hosting = NSHostingView(rootView: content())
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]

        // Tuck under the root panel's edge so there's no dead gap for the
        // cursor to cross on its way into the submenu.
        let overlap: CGFloat = 6
        var originX = rowFrame.maxX - overlap
        var originY = rowFrame.maxY - height        // align submenu top with the row top
        if let screen = rootPanel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if originX + width > visible.maxX - 4 {
                originX = rowFrame.minX - width + overlap    // flip to the left
            }
            originX = min(max(originX, visible.minX + 4), visible.maxX - width - 4)
            originY = min(max(originY, visible.minY + 4), visible.maxY - height - 4)
        }

        let sub = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        sub.isOpaque = false
        sub.backgroundColor = .clear
        sub.hasShadow = true
        sub.level = .popUpMenu
        sub.animationBehavior = .none
        sub.contentView = hosting
        rootPanel.addChildWindow(sub, ordered: .above)
        self.submenuPanel = sub
    }

    func closeSubmenu() {
        if let submenuPanel {
            submenuPanel.parent?.removeChildWindow(submenuPanel)
            submenuPanel.orderOut(nil)
        }
        submenuPanel = nil
    }

    func close() {
        let closeHandler = closeHandler
        self.closeHandler = nil
        closeSubmenu()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        isOpen = false
        closeHandler?()
    }
}

/// Transparent AppKit overlay that reports right-clicks (and control-clicks)
/// with the cursor's screen location, while letting every other event fall
/// through to the SwiftUI content beneath it — so hover, single- and
/// double-tap on the row keep working untouched. Passthrough is achieved by
/// only returning `self` from `hitTest` when the live event is a right/control
/// click; otherwise the hit lands on the view below.
struct RightClickCatcher: NSViewRepresentable {
    /// A changing token asks the backing row view to open the same menu from
    /// its live screen frame. This keeps keyboard invocation anchored to the
    /// focused lazy row instead of wherever the mouse happened to be.
    var keyboardRequestSequence: Int? = nil
    var onKeyboardRequest: ((CGPoint, NSWindow) -> Void)? = nil
    let onRightClick: (CGPoint, NSWindow) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.keyboardRequestSequence = keyboardRequestSequence
        view.onKeyboardRequest = onKeyboardRequest
        view.onRightClick = onRightClick
        view.scheduleKeyboardRequestIfNeeded()
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.keyboardRequestSequence = keyboardRequestSequence
        nsView.onKeyboardRequest = onKeyboardRequest
        nsView.onRightClick = onRightClick
        nsView.scheduleKeyboardRequestIfNeeded()
    }

    final class CatcherView: NSView {
        var keyboardRequestSequence: Int?
        var onKeyboardRequest: ((CGPoint, NSWindow) -> Void)?
        var onRightClick: ((CGPoint, NSWindow) -> Void)?
        private var handledKeyboardRequestSequence: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleKeyboardRequestIfNeeded()
        }

        func scheduleKeyboardRequestIfNeeded() {
            guard let sequence = keyboardRequestSequence,
                  sequence != handledKeyboardRequestSequence else { return }
            DispatchQueue.main.async { [weak self] in
                self?.fulfillKeyboardRequestIfNeeded()
            }
        }

        private func fulfillKeyboardRequestIfNeeded() {
            guard let sequence = keyboardRequestSequence,
                  sequence != handledKeyboardRequestSequence,
                  let window else { return }
            handledKeyboardRequestSequence = sequence
            let frame = window.convertToScreen(convert(bounds, to: nil))
            let point = CGPoint(x: frame.minX + 12, y: frame.maxY - 4)
            onKeyboardRequest?(point, window)
        }

        private func isContextClick(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return true
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            isContextClick(NSApp.currentEvent) ? self : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { nil }

        override func rightMouseDown(with event: NSEvent) {
            report(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                report(event)
            } else {
                super.mouseDown(with: event)
            }
        }

        private func report(_ event: NSEvent) {
            guard let window else { return }
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            onRightClick?(screenPoint, window)
        }
    }
}

/// Drives the open/close timing of a paper flyout submenu with native-feeling
/// hover intent: a short delay before opening, a longer grace before closing so
/// the cursor can travel from the parent row into the submenu without it
/// vanishing. The parent row and the submenu panel both report their hover
/// state here; the submenu stays up while either is hovered.
@MainActor
final class PaperSubmenuCoordinator: ObservableObject {
    @Published private(set) var isOpen = false
    weak var anchorView: NSView?
    /// Set by the menu view: actually present / dismiss the submenu panel.
    var present: (() -> Void)?
    var dismiss: (() -> Void)?

    private var rowHovered = false
    private var submenuHovered = false
    private var task: Task<Void, Never>?

    /// The parent row's frame in screen coordinates, for positioning the flyout.
    func rowScreenFrame() -> CGRect? {
        guard let view = anchorView, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func rowHover(_ hovered: Bool) { rowHovered = hovered; reconcile() }
    func submenuHover(_ hovered: Bool) { submenuHovered = hovered; reconcile() }

    /// Click-to-open: bypass the hover delay entirely.
    func openNow() {
        task?.cancel()
        if !isOpen { isOpen = true; present?() }
    }

    /// Keyboard navigation must update the coordinator as well as removing
    /// the child panel; otherwise a subsequent Right-arrow sees `isOpen` and
    /// refuses to recreate the submenu that Left-arrow just dismissed.
    func closeNow() {
        task?.cancel()
        rowHovered = false
        submenuHovered = false
        if isOpen {
            isOpen = false
            dismiss?()
        }
    }

    private func reconcile() {
        task?.cancel()
        let shouldOpen = rowHovered || submenuHovered
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: shouldOpen ? 110_000_000 : 230_000_000)
            guard !Task.isCancelled else { return }
            if shouldOpen, !isOpen {
                isOpen = true; present?()
            } else if !shouldOpen, isOpen {
                isOpen = false; dismiss?()
            }
        }
    }
}

/// Zero-size companion that hands the coordinator the parent row's backing
/// `NSView`, so the flyout can be positioned next to it.
struct PaperSubmenuAnchor: NSViewRepresentable {
    let coordinator: PaperSubmenuCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        MainActor.assumeIsolated { coordinator.anchorView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated { coordinator.anchorView = nsView }
    }
}

/// Parent row that reveals a second-level paper menu: hover (or click) opens
/// the flyout, with a trailing chevron and an active highlight while open.
struct PaperSubmenuRow: View {
    let icon: String
    let title: String
    @ObservedObject var coordinator: PaperSubmenuCoordinator
    var isKeyboardFocused = false

    @State private var hovering = false
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    private var active: Bool { coordinator.isOpen }

    var body: some View {
        Button(action: { coordinator.openNow() }) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.appAccent : surfaceStyle.foreground)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.appAccent : surfaceStyle.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(active ? Color.appAccent : .secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active
                          ? Color.appAccent.opacity(0.14)
                          : (hovering || isKeyboardFocused ? surfaceStyle.hoverFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(PaperSubmenuAnchor(coordinator: coordinator))
        .onHover { h in
            hovering = h
            coordinator.rowHover(h)
        }
    }
}

/// One row of a paper context menu: leading icon, title, optional trailing
/// accessory. `role: .destructive` tints it terracotta. Matches the row metrics
/// of `PaperMenuItem` / `FilterListOption` so every paper menu reads the same.
struct PaperMenuActionRow: View {
    enum Role { case normal, destructive }

    let icon: String
    let title: String
    var role: Role = .normal
    var isKeyboardFocused = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    private var tint: Color {
        role == .destructive ? Color.appDanger : surfaceStyle.foreground
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering || isKeyboardFocused
                          ? (role == .destructive ? Color.appDanger.opacity(0.14) : surfaceStyle.hoverFill)
                          : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Group-membership row: a leading check slot makes current membership legible
/// at a glance (the whole reason this menu exists), with a hover wash to read
/// as actionable.
struct PaperMenuCheckRow: View {
    let title: String
    let isMember: Bool
    var isKeyboardFocused = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isMember ? Color.appAccent : Color.secondary.opacity(0.5))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isMember ? .semibold : .regular))
                    .foregroundStyle(isMember ? Color.appAccent : surfaceStyle.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isMember
                          ? (hovering || isKeyboardFocused
                             ? surfaceStyle.selectedHoverFill
                             : surfaceStyle.selectedFill)
                          : (hovering || isKeyboardFocused ? surfaceStyle.hoverFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small uppercase section caption inside a paper menu.
struct PaperMenuSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 1)
    }
}

/// Hairline divider tuned for the paper menu surface.
struct PaperMenuDivider: View {
    @Environment(\.paperContextMenuSurfaceStyle) private var surfaceStyle

    var body: some View {
        Rectangle()
            .fill(surfaceStyle.divider)
            .frame(height: 1)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
    }
}
