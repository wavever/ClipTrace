import SwiftUI
import AppKit

struct FullDiskAccessOnboardingView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [.appAccent, .appAccent.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .shadow(color: .appAccent.opacity(0.3), radius: 6, y: 2)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("onboarding.title"))
                        .font(.system(size: 16, weight: .bold))
                    Text(L("onboarding.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(L("common.close"))
            }

            Text(L("onboarding.body"))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            steps

            HStack(spacing: 10) {
                Button {
                    Self.openFullDiskAccessPane()
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(L("onboarding.openPrefs"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.appAccent)
                    )
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text(L("onboarding.later"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(index: 1, text: L("onboarding.step1"))
            stepRow(index: 2, text: L("onboarding.step2"))
            stepRow(index: 3, text: L("onboarding.step3"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.secondary.opacity(0.10))
        )
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.appAccent))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    static func openFullDiskAccessPane() {
        // Probe an FDA-gated file first. macOS only adds an app to the Full
        // Disk Access list after it has actually attempted to read a protected
        // location; without this attempt the pane opens but the app isn't in
        // the list, forcing the user to click "+" and locate it themselves.
        // The read is expected to fail when permission is missing — we only
        // need the access attempt itself to register the app with TCC.
        let probe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        _ = try? Data(contentsOf: probe)

        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 首次进入的功能导览

/// One stop on the first-run tour of the main window. Steps with an on-screen
/// target get a spotlight cut out of the dimming layer; `welcome` and
/// `quickPaste` have nothing to point at and render as centered cards.
enum FeatureTourStep: Int, CaseIterable, Identifiable {
    case welcome
    case search
    case filters
    case actions
    case list
    case capture
    case quickPaste

    var id: Int { rawValue }

    /// Anchored steps are skipped when their control isn't on screen — e.g.
    /// the card list while the history is still empty on a fresh install.
    var needsAnchor: Bool {
        switch self {
        case .welcome, .quickPaste: return false
        case .search, .filters, .actions, .list, .capture: return true
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .search: return "sparkle.magnifyingglass"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .actions: return "square.and.pencil"
        case .list: return "rectangle.stack"
        case .capture: return "pause.circle"
        case .quickPaste: return "keyboard"
        }
    }

    var title: String {
        switch self {
        case .welcome: return L("tour.welcome.title")
        case .search: return L("tour.search.title")
        case .filters: return L("tour.filters.title")
        case .actions: return L("tour.actions.title")
        case .list: return L("tour.list.title")
        case .capture: return L("tour.capture.title")
        case .quickPaste: return L("tour.quickpaste.title")
        }
    }

    var body: String {
        switch self {
        case .welcome: return L("tour.welcome.body")
        case .search: return L("tour.search.body")
        case .filters: return L("tour.filters.body")
        case .actions: return L("tour.actions.body")
        case .list: return L("tour.list.body")
        case .capture: return L("tour.capture.body")
        case .quickPaste: return L("tour.quickpaste.body")
        }
    }
}

/// Anchors flow up from wherever `.featureTourAnchor` is attached, so the
/// overlay can spotlight controls that live deep inside the toolbar/header
/// without those views knowing about the tour.
struct FeatureTourAnchorKey: PreferenceKey {
    static let defaultValue: [FeatureTourStep: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [FeatureTourStep: Anchor<CGRect>],
        nextValue: () -> [FeatureTourStep: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publishes this view's bounds as the spotlight target for one tour step.
    func featureTourAnchor(_ step: FeatureTourStep) -> some View {
        anchorPreference(key: FeatureTourAnchorKey.self, value: .bounds) { [step: $0] }
    }
}

/// Full-window dim with a rounded hole over the current target. Animatable
/// over the hole's rect so the spotlight glides between steps instead of
/// jump-cutting.
private struct FeatureTourDimShape: Shape {
    var spot: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(spot.origin.x, spot.origin.y),
                AnimatablePair(spot.size.width, spot.size.height)
            )
        }
        set {
            spot = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        // A zero-size spot (welcome / quickPaste) degenerates to a plain dim;
        // animating through it makes the hole grow out of a point, which reads
        // as the spotlight "arriving" rather than popping in.
        if spot.width > 0.5, spot.height > 0.5 {
            path.addRoundedRect(
                in: spot,
                cornerSize: CGSize(width: 12, height: 12),
                style: .continuous
            )
        }
        return path
    }
}

/// The guided tour itself: one shared dim layer, a spotlight over the current
/// target, and a paper card explaining it. Tap anywhere (or "下一步") to
/// advance; skipping or finishing both hand control back via `onFinish`.
struct FeatureTourOverlay: View {
    let anchors: [FeatureTourStep: Anchor<CGRect>]
    let onFinish: () -> Void

    @State private var step: FeatureTourStep = .welcome

    /// `startAt` exists for previews/off-screen harnesses that need to pin a
    /// specific step; the app itself always starts from `.welcome`.
    init(
        anchors: [FeatureTourStep: Anchor<CGRect>],
        startAt initialStep: FeatureTourStep = .welcome,
        onFinish: @escaping () -> Void
    ) {
        self.anchors = anchors
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }
    /// Measured live because the body text wraps differently per language, and
    /// above/below placement needs the real height to avoid overlapping the
    /// spotlight.
    @State private var cardSize = CGSize(width: 330, height: 180)

    private static let stepSpring = Animation.spring(response: 0.34, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            let spot = spotRect(in: geo)

            ZStack {
                FeatureTourDimShape(spot: spot ?? zeroSpot(in: geo.size))
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    // The cutout is visual only — the whole surface stays
                    // tappable so a click inside the spotlight can't reach the
                    // control mid-tour (and still advances the tour).
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }

                if let spot {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.9), lineWidth: 1.5)
                        .frame(width: spot.width, height: spot.height)
                        .position(x: spot.midX, y: spot.midY)
                        .allowsHitTesting(false)
                }

                card
                    .position(cardPosition(spot: spot, in: geo.size))
            }
            .animation(Self.stepSpring, value: step)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.appAccent.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: step.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                Text(step.title)
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
            }

            Text(step.body)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                stepDots
                Spacer(minLength: 10)
                if !isLast {
                    Button(L("tour.skip")) { onFinish() }
                        .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
                Button(primaryLabel) { advance() }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
            }
        }
        .padding(16)
        .frame(width: 330)
        .paperCard(cornerRadius: 14)
        // Extra lift beyond the paper shadow — the card floats over the dim
        // layer, not over paper.
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { cardSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in cardSize = newSize }
            }
        )
    }

    private var stepDots: some View {
        HStack(spacing: 5) {
            ForEach(visibleSteps) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.appAccent : Color.appMetal.opacity(0.28))
                    .frame(width: candidate == step ? 16 : 5, height: 5)
            }
        }
    }

    private var primaryLabel: String {
        if isLast { return L("tour.done") }
        if step == .welcome { return L("tour.welcome.start") }
        return L("tour.next")
    }

    /// Steps actually reachable in this session — anchored steps drop out when
    /// their control isn't on screen, and the dots must agree with that.
    private var visibleSteps: [FeatureTourStep] {
        FeatureTourStep.allCases.filter { !$0.needsAnchor || anchors[$0] != nil }
    }

    private var isLast: Bool {
        nextStep(after: step) == nil
    }

    private func nextStep(after current: FeatureTourStep) -> FeatureTourStep? {
        var raw = current.rawValue + 1
        while let candidate = FeatureTourStep(rawValue: raw) {
            if !candidate.needsAnchor || anchors[candidate] != nil { return candidate }
            raw += 1
        }
        return nil
    }

    private func advance() {
        if let next = nextStep(after: step) {
            step = next
        } else {
            onFinish()
        }
    }

    private func spotRect(in geo: GeometryProxy) -> CGRect? {
        guard let anchor = anchors[step] else { return nil }
        var rect = geo[anchor].insetBy(dx: -6, dy: -6)
        // The list target is the whole scroll region; cap the spotlight to the
        // first few cards so the dim keeps framing what the card talks about.
        if step == .list {
            rect.size.height = min(rect.height, 236)
        }
        return rect
    }

    private func zeroSpot(in size: CGSize) -> CGRect {
        CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
    }

    private func cardPosition(spot: CGRect?, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 16
        guard let spot else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let half = cardSize.height / 2
        // Prefer sitting below the spotlight; flip above only when the card
        // would run off the bottom (e.g. a target near the window's foot).
        var y = spot.maxY + 14 + half
        if y + half > size.height - margin {
            y = spot.minY - 14 - half
        }
        y = min(max(y, margin + half), size.height - margin - half)
        let x = min(max(spot.midX, margin + cardSize.width / 2), size.width - margin - cardSize.width / 2)
        return CGPoint(x: x, y: y)
    }
}
