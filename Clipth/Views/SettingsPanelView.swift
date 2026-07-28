import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts
import ServiceManagement

struct SettingsPanelView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @State private var section: Section = .general

    // Zero is the persisted sentinel for unlimited history. Existing users who
    // explicitly chose a numeric cap keep that value; fresh installs stay open-ended.
    @AppStorage("maxRecords") private var maxRecords = 0
    @AppStorage("pollInterval") private var pollInterval = 0.5
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @AppStorage("hideFromCapture") private var hideFromCapture = false
    @AppStorage("confirmBeforeQuit") private var confirmBeforeQuit = true
    @AppStorage("trimTrailingWhitespaceOnCopy") private var trimTrailing = false
    @AppStorage("dynamicIslandEnabled") private var dynamicIslandEnabled = false
    @AppStorage("appearanceTheme") private var appearanceThemeRaw = AppearanceTheme.system.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue

    enum Section: String, CaseIterable, Identifiable {
        case general
        case shortcut
        case filter
        case rules
        case privacy
        case merge
        case ai
        case data
        case about
        var id: Self { self }
        var localizedTitle: String {
            switch self {
            case .general:  return L("settings.tab.general")
            case .shortcut: return L("settings.tab.shortcut")
            case .filter:   return L("settings.tab.filter")
            case .rules:    return L("settings.tab.rules")
            case .privacy:  return L("settings.tab.privacy")
            case .merge:    return L("settings.tab.merge")
            case .ai:       return L("settings.tab.ai")
            case .data:     return L("settings.tab.data")
            case .about:    return L("settings.tab.about")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            tabs
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .onAppear { consumePendingSection() }
        .onChange(of: nav.pendingSettingsSection) { _, _ in
            consumePendingSection()
        }
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.appAccent.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
            // Match Stats/Trash: just a thin top tint over the shared
            // VisualEffect + accent halo from MainWindowView — no opaque base,
            // so the window background tone stays consistent across screens.
            .ignoresSafeArea(edges: .top)
        )
    }

    private func consumePendingSection() {
        guard let pending = nav.pendingSettingsSection else { return }
        withAnimation(.easeOut(duration: 0.18)) { section = pending }
        // Clear outside the view-update cycle; the resulting onChange re-entry
        // exits on the nil guard above.
        Task { @MainActor in
            nav.pendingSettingsSection = nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: { nav.showList() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(PaperIconButtonStyle(size: 34))
            .help(L("common.back"))
            .keyboardShortcut(.escape, modifiers: [])

            Text(L("settings.title"))
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.appMetal)

            Spacer()
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { sec in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { section = sec }
                } label: {
                    Text(sec.localizedTitle)
                        .font(.system(size: 12.5, weight: section == sec ? .semibold : .medium))
                        .foregroundStyle(section == sec ? Color.white : Color.appMetal.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                if section == sec {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.appAccent)
                                        .shadow(color: Color.appCardShadow.opacity(0.55), radius: 5, y: 2)
                                }
                            }
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.appChipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general:
            GeneralSection(
                maxRecords: $maxRecords,
                pollInterval: $pollInterval,
                launchAtLogin: $launchAtLogin,
                showInDock: $showInDock,
                menuBarIcon: $menuBarIcon,
                hideFromCapture: $hideFromCapture,
                confirmBeforeQuit: $confirmBeforeQuit,
                trimTrailing: $trimTrailing,
                dynamicIslandEnabled: $dynamicIslandEnabled,
                appearanceThemeRaw: $appearanceThemeRaw,
                appLanguageRaw: $appLanguageRaw
            )
        case .shortcut:
            ShortcutSection()
        case .filter:
            FilterSection()
        case .rules:
            RulesSection()
        case .privacy:
            PrivacySection()
        case .merge:
            MergeSection()
        case .ai:
            AISection()
        case .data:
            DataSection()
        case .about:
            AboutSection()
        }
    }
}

// MARK: - AI

private struct AISection: View {
    var body: some View {
        VStack(spacing: 18) {
            MCPSettings()
        }
    }
}

// MARK: - Reusable building blocks
//
// New row/group pattern (icon + title + subtitle on the left, control flush
// right) shared across every settings section so toggles, pickers and
// buttons line up consistently.

/// One row inside a `SettingsGroup` card — colored icon, title, optional
/// secondary subtitle, and a trailing control (Toggle / Picker / Button …).
struct SettingsRow<Trailing: View>: View {
    let icon: String?
    let iconTint: Color
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String? = nil,
        iconTint: Color = .appAccent,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconTint.opacity(0.13))
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.appMetal)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Card container that groups related rows under an optional section header.
/// Children must be `SettingsRow` (or any view) and are automatically
/// separated by a thin divider, matching the design mockup.
struct SettingsGroup<Content: View>: View {
    let headerIcon: String?
    let headerTitle: String?
    let headerTint: Color
    @ViewBuilder var content: () -> Content

    init(
        icon: String? = nil,
        title: String? = nil,
        tint: Color = .appAccent,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.headerIcon = icon
        self.headerTitle = title
        self.headerTint = tint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let headerTitle {
                HStack(spacing: 8) {
                    if let headerIcon {
                        Image(systemName: headerIcon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(headerTint)
                    }
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                }
                .padding(.leading, 4)
            }

            _VariadicView.Tree(SettingsGroupLayout()) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
            )
            .shadow(color: Color.appCardShadow.opacity(0.55), radius: 7, y: 2)
        }
    }
}

private struct SettingsGroupLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let items = Array(children)
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { idx in
                items[idx]
                if idx < items.count - 1 {
                    Divider()
                        .padding(.leading, 62)
                        .overlay(Color.appPaperDivider.opacity(0.7))
                }
            }
        }
    }
}

/// Pill-style segmented selector used for language / theme pickers. Mirrors
/// the design mockup: a tinted rounded pill for the active option, plain
/// hover background for inactive ones.
struct SettingsSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        let icon: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    var tint: Color = .appAccent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { opt in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = opt.value }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = opt.icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(opt.title)
                            .font(.system(size: 12.5, weight: selection == opt.value ? .semibold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == opt.value ? Color.white : Color.appMetal.opacity(0.82))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == opt.value ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.appChipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
    }
}

/// Inline variant of `SettingCard` — title/subtitle on the left, a single
/// control vertically centered on the right. Prefer this over `SettingCard`
/// when the trailing control is a single button or compact widget; falling
/// back to the stacked card for that case puts the button on its own line
/// which reads awkwardly.
struct SettingInlineCard<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var control: () -> Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appMetal)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow.opacity(0.55), radius: 7, y: 2)
    }
}

/// Standalone titled card — used for sections that don't fit the row layout
/// (free-form button clusters, full-width pickers, lists with add/remove).
struct SettingCard<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var control: () -> Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appMetal)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow.opacity(0.55), radius: 7, y: 2)
    }
}

// MARK: - General

private enum MaxRecordsMode: String, Hashable {
    case unlimited
    case manual
}

private struct GeneralSection: View {
    @Binding var maxRecords: Int
    @Binding var pollInterval: Double
    @Binding var launchAtLogin: Bool
    @Binding var showInDock: Bool
    @Binding var menuBarIcon: Bool
    @Binding var hideFromCapture: Bool
    @Binding var confirmBeforeQuit: Bool
    @Binding var trimTrailing: Bool
    @Binding var dynamicIslandEnabled: Bool
    @Binding var appearanceThemeRaw: String
    @Binding var appLanguageRaw: String

    @AppStorage("fdaOnboardingDismissed") private var fdaOnboardingDismissed = false
    @AppStorage("videoPreviewMode") private var videoPreviewModeRaw = VideoPreviewMode.video.rawValue
    @AppStorage("videoPreviewMuted") private var videoPreviewMuted = true
    @AppStorage("menuBarContentLayout") private var menuBarContentLayoutRaw = PanelContentLayout.list.rawValue
    @AppStorage("quickPasteContentLayout") private var quickPasteContentLayoutRaw = PanelContentLayout.list.rawValue
    @AppStorage("maxRecordsManualValue") private var manualMaxRecords = 500
    @State private var maxRecordsMenuSelection = MaxRecordsMode.unlimited
    @State private var manualMaxRecordsDraft = 500
    @State private var isEditingMaxRecords = false
    @ObservedObject private var hoverPreview = HoverPreviewSettings.shared
    @ObservedObject private var nav = AppNavigation.shared
    @EnvironmentObject private var vm: ClipboardViewModel
    @Environment(\.modelContext) private var modelContext

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { appLanguageRaw = $0.rawValue }
        )
    }
    private var themeBinding: Binding<AppearanceTheme> {
        Binding(
            get: { AppearanceTheme(rawValue: appearanceThemeRaw) ?? .system },
            set: { appearanceThemeRaw = $0.rawValue }
        )
    }
    private var videoPreviewModeBinding: Binding<VideoPreviewMode> {
        Binding(
            get: { VideoPreviewMode(rawValue: videoPreviewModeRaw) ?? .video },
            set: { videoPreviewModeRaw = $0.rawValue }
        )
    }
    private var menuBarContentLayoutBinding: Binding<PanelContentLayout> {
        Binding(
            get: { PanelContentLayout(rawValue: menuBarContentLayoutRaw) ?? .list },
            set: { menuBarContentLayoutRaw = $0.rawValue }
        )
    }
    private var quickPasteContentLayoutBinding: Binding<PanelContentLayout> {
        Binding(
            get: { PanelContentLayout(rawValue: quickPasteContentLayoutRaw) ?? .list },
            set: { quickPasteContentLayoutRaw = $0.rawValue }
        )
    }
    private var hoverDelayOptions: [PaperMenuOption<Double>] {
        [
            PaperMenuOption(0.5, L("settings.preview.delay.halfSecond")),
            PaperMenuOption(1.0, L("settings.preview.delay.oneSecond")),
            PaperMenuOption(1.5, L("settings.preview.delay.oneAndHalfSeconds")),
            PaperMenuOption(2.0, L("settings.preview.delay.twoSeconds")),
            PaperMenuOption(3.0, L("settings.preview.delay.threeSeconds")),
            PaperMenuOption(5.0, L("settings.preview.delay.fiveSeconds"))
        ]
    }
    // Read/write the @Observable singleton directly so the swatch ring also
    // re-evaluates on selection, and external writes (e.g. CLI / tests) flow
    // back into the UI.
    private var accentBinding: Binding<AccentPalette> {
        Binding(
            get: { AccentThemeStore.shared.palette },
            set: { AccentThemeStore.shared.palette = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            // Language picker — keep first so users can recover from accidental switches.
            SettingsGroup(icon: "globe", title: L("settings.language.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "character.bubble",
                    iconTint: .appAccent,
                    title: L("settings.language.title"),
                    subtitle: L("settings.language.subtitle")
                ) {
                    SettingsSegmented(
                        selection: languageBinding,
                        options: [
                            .init(value: .zh,     title: "中文",    icon: nil),
                            .init(value: .en,     title: "English", icon: nil),
                            .init(value: .system, title: L("settings.language.system"), icon: nil),
                        ],
                        tint: .appAccent
                    )
                    .frame(width: 320)
                }
            }

            // Appearance theme.
            SettingsGroup(icon: "paintpalette", title: L("settings.theme.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "moon.stars",
                    iconTint: .appAccent,
                    title: L("settings.theme.title"),
                    subtitle: L("settings.theme.subtitle")
                ) {
                    SettingsSegmented(
                        selection: themeBinding,
                        options: [
                            .init(value: .light,  title: L("settings.theme.light"),  icon: "sun.max"),
                            .init(value: .dark,   title: L("settings.theme.dark"),   icon: "moon"),
                            .init(value: .system, title: L("settings.theme.system"), icon: "desktopcomputer"),
                        ],
                        tint: .appAccent
                    )
                    .frame(width: 320)
                }
                SettingsRow(
                    icon: "drop.fill",
                    iconTint: .appAccent,
                    title: L("settings.accent.title"),
                    subtitle: L("settings.accent.subtitle")
                ) {
                    AccentSwatches(selection: accentBinding)
                }
            }

            // Window behaviour.
            SettingsGroup(icon: "macwindow", title: L("settings.window.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "power",
                    iconTint: .appAccent,
                    title: L("settings.window.launchAtLogin"),
                    subtitle: L("settings.window.launchAtLogin.subtitle")
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                        // Reflect the real registration state when the panel
                        // opens (the toggle used to be a dead bool).
                        .onAppear { launchAtLogin = LoginItemService.isEnabled }
                        .onChange(of: launchAtLogin) { _, newValue in
                            LoginItemService.setEnabled(newValue)
                            launchAtLogin = LoginItemService.isEnabled
                        }
                }
                SettingsRow(
                    icon: "dock.rectangle",
                    iconTint: .appAccent,
                    title: L("settings.window.showInDock"),
                    subtitle: L("settings.window.showInDock.subtitle")
                ) {
                    Toggle("", isOn: $showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                SettingsRow(
                    icon: "menubar.rectangle",
                    iconTint: .appAccent,
                    title: L("settings.window.menuBarIcon"),
                    subtitle: L("settings.window.menuBarIcon.subtitle")
                ) {
                    Toggle("", isOn: $menuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                SettingsRow(
                    icon: "eye.slash",
                    iconTint: .appAccent,
                    title: L("settings.window.hideFromCapture"),
                    subtitle: L("settings.window.hideFromCapture.subtitle")
                ) {
                    Toggle("", isOn: $hideFromCapture)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                SettingsRow(
                    icon: "questionmark.circle",
                    iconTint: .appAccent,
                    title: L("settings.window.confirmBeforeQuit"),
                    subtitle: L("settings.window.confirmBeforeQuit.subtitle")
                ) {
                    Toggle("", isOn: $confirmBeforeQuit)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                if DynamicIslandController.hasNotchedDisplay {
                    SettingsRow(
                        icon: "capsule.portrait",
                        iconTint: .appAccent,
                        title: L("settings.window.dynamicIsland"),
                        subtitle: L("settings.window.dynamicIsland.subtitle")
                    ) {
                        Toggle("", isOn: $dynamicIslandEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.appAccent)
                            .onChange(of: dynamicIslandEnabled) { _, newValue in
                                DynamicIslandController.shared.setEnabled(newValue)
                            }
                    }
                }
                SettingsRow(
                    icon: "scissors",
                    iconTint: .appAccent,
                    title: L("settings.window.trimTrailing"),
                    subtitle: L("settings.window.trimTrailing.subtitle")
                ) {
                    Toggle("", isOn: $trimTrailing)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
            }

            SettingInlineCard(
                title: L("settings.guide.title"),
                subtitle: L("settings.guide.subtitle")
            ) {
                Button {
                    nav.replayFeatureTour()
                } label: {
                    Label(L("settings.guide.viewTour"), systemImage: "sparkles")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
            }

            SettingsGroup(
                icon: "rectangle.grid.2x2",
                title: L("settings.panelLayout.title"),
                tint: .appAccent
            ) {
                SettingsRow(
                    icon: "menubar.rectangle",
                    iconTint: .appAccent,
                    title: L("settings.panelLayout.menuBar"),
                    subtitle: L("settings.panelLayout.menuBar.subtitle")
                ) {
                    SettingsSegmented(
                        selection: menuBarContentLayoutBinding,
                        options: PanelContentLayout.allCases.map {
                            .init(value: $0, title: $0.displayName, icon: $0.icon)
                        },
                        tint: .appAccent
                    )
                    .frame(width: 220)
                }

                SettingsRow(
                    icon: "keyboard",
                    iconTint: .appAccent,
                    title: L("settings.panelLayout.quickPaste"),
                    subtitle: L("settings.panelLayout.quickPaste.subtitle")
                ) {
                    SettingsSegmented(
                        selection: quickPasteContentLayoutBinding,
                        options: PanelContentLayout.allCases.map {
                            .init(value: $0, title: $0.displayName, icon: $0.icon)
                        },
                        tint: .appAccent
                    )
                    .frame(width: 220)
                }
            }

            SettingsGroup(icon: "play.rectangle", title: L("settings.preview.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "film",
                    iconTint: .appAccent,
                    title: L("settings.preview.videoMode.title"),
                    subtitle: L("settings.preview.videoMode.subtitle")
                ) {
                    SettingsSegmented(
                        selection: videoPreviewModeBinding,
                        options: VideoPreviewMode.allCases.map {
                            .init(value: $0, title: $0.displayName, icon: $0.icon)
                        },
                        tint: .appAccent
                    )
                    .frame(width: 260)
                }
                SettingsRow(
                    icon: videoPreviewMuted ? "speaker.slash" : "speaker.wave.2",
                    iconTint: .appAccent,
                    title: L("settings.preview.videoMuted"),
                    subtitle: L("settings.preview.videoMuted.subtitle")
                ) {
                    Toggle("", isOn: $videoPreviewMuted)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                // Delay picker lives inside its toggle's row (and hides when
                // the toggle is off): a separate "trigger delay" row under
                // each switch read as an accidental duplicate.
                SettingsRow(
                    icon: "menubar.rectangle",
                    iconTint: .appAccent,
                    title: L("settings.preview.menuBarHover"),
                    subtitle: L("settings.preview.menuBarHover.subtitle")
                ) {
                    HStack(spacing: 10) {
                        if hoverPreview.menuBarEnabled {
                            PaperMenuPicker(
                                options: hoverDelayOptions,
                                selection: $hoverPreview.menuBarDelay,
                                width: 110
                            )
                            .transition(.opacity)
                        }
                        Toggle("", isOn: $hoverPreview.menuBarEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.appAccent)
                    }
                    .animation(.easeOut(duration: 0.15), value: hoverPreview.menuBarEnabled)
                }
                SettingsRow(
                    icon: "bolt.fill",
                    iconTint: .appAccent,
                    title: L("settings.preview.quickPasteHover"),
                    subtitle: L("settings.preview.quickPasteHover.subtitle")
                ) {
                    HStack(spacing: 10) {
                        if hoverPreview.quickPasteEnabled {
                            PaperMenuPicker(
                                options: hoverDelayOptions,
                                selection: $hoverPreview.quickPasteDelay,
                                width: 110
                            )
                            .transition(.opacity)
                        }
                        Toggle("", isOn: $hoverPreview.quickPasteEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.appAccent)
                    }
                    .animation(.easeOut(duration: 0.15), value: hoverPreview.quickPasteEnabled)
                }
            }

            // Storage.
            SettingsGroup(icon: "internaldrive", title: L("settings.storage.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "tray.full",
                    iconTint: .appAccent,
                    title: L("settings.storage.maxRecords"),
                    subtitle: L("settings.storage.maxRecords.subtitle")
                ) {
                    PaperMenuPicker(
                        options: [
                            PaperMenuOption(
                                MaxRecordsMode.unlimited,
                                L("settings.storage.maxRecords.unlimited"),
                                icon: "infinity"
                            ),
                            PaperMenuOption(
                                MaxRecordsMode.manual,
                                L("settings.storage.maxRecords.manual"),
                                icon: "number"
                            )
                        ],
                        selection: $maxRecordsMenuSelection,
                        width: 176,
                        displayTitle: maxRecords > 0
                            ? L("settings.storage.maxRecordsFormat", maxRecords)
                            : L("settings.storage.maxRecords.unlimited"),
                        onSelect: handleMaxRecordsSelection
                    )
                    .onAppear {
                        if maxRecords > 0 {
                            manualMaxRecords = maxRecords
                            manualMaxRecordsDraft = maxRecords
                            maxRecordsMenuSelection = .manual
                        } else {
                            manualMaxRecordsDraft = manualMaxRecords
                            maxRecordsMenuSelection = .unlimited
                        }
                    }
                    .sheet(
                        isPresented: $isEditingMaxRecords,
                        onDismiss: syncMaxRecordsMenuSelection
                    ) {
                        ManualMaxRecordsEditor(
                            initialValue: manualMaxRecordsDraft,
                            onCancel: {
                                isEditingMaxRecords = false
                            },
                            onSave: { limit in
                                manualMaxRecords = limit
                                manualMaxRecordsDraft = limit
                                maxRecords = limit
                                maxRecordsMenuSelection = .manual
                                isEditingMaxRecords = false
                                vm.enforceMaxRecords(context: modelContext)
                            }
                        )
                    }
                }
                SettingsRow(
                    icon: "timer",
                    iconTint: .appAccent,
                    title: L("settings.storage.pollInterval"),
                    subtitle: L("settings.storage.pollInterval.subtitle")
                ) {
                    PaperMenuPicker(
                        options: [
                            PaperMenuOption(0.5, L("settings.poll.halfSecond")),
                            PaperMenuOption(1.0, L("settings.poll.oneSecond")),
                            PaperMenuOption(2.0, L("settings.poll.twoSeconds")),
                            PaperMenuOption(5.0, L("settings.poll.fiveSeconds")),
                        ],
                        selection: $pollInterval,
                        width: 110
                    )
                    .onChange(of: pollInterval) { _, _ in
                        vm.updatePollInterval()
                    }
                }
            }

            SettingInlineCard(
                title: L("settings.fda.title"),
                subtitle: L("settings.fda.subtitle")
            ) {
                HStack(spacing: 8) {
                    Button {
                        FullDiskAccessOnboardingView.openFullDiskAccessPane()
                    } label: {
                        Label(L("settings.fda.openPrefs"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    Button {
                        fdaOnboardingDismissed = false
                        nav.showList()
                    } label: {
                        Label(L("settings.fda.viewOnboarding"), systemImage: "questionmark.circle")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
        }
    }

    private func handleMaxRecordsSelection(_ mode: MaxRecordsMode) {
        switch mode {
        case .unlimited:
            if maxRecords > 0 {
                manualMaxRecords = maxRecords
            }
            maxRecords = 0
            maxRecordsMenuSelection = .unlimited
        case .manual:
            manualMaxRecordsDraft = max(
                50,
                min(maxRecords > 0 ? maxRecords : manualMaxRecords, 100_000)
            )
            isEditingMaxRecords = true
        }
    }

    private func syncMaxRecordsMenuSelection() {
        maxRecordsMenuSelection = maxRecords > 0 ? .manual : .unlimited
    }
}

// MARK: - Shortcut

private struct ShortcutSection: View {
    @State private var accessibilityTrusted: Bool = AutoPasteService.isTrusted
    @State private var showDiagnostics = false
    @ObservedObject private var quickPasteKeys = QuickPasteKeyStore.shared

    private var bundlePath: String { Bundle.main.bundlePath }
    private var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "—" }

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "command", title: L("settings.shortcut.group.title"), tint: .appAccent) {
                ForEach(AppShortcut.allCases) { shortcut in
                    SettingsRow(
                        icon: shortcut.icon,
                        iconTint: .appAccent,
                        title: shortcut.displayName,
                        subtitle: shortcut.subtitle
                    ) {
                        HStack(spacing: 8) {
                            GlobalShortcutRecorder(name: shortcut.name)
                            Button {
                                KeyboardShortcuts.reset(shortcut.name)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(PaperIconButtonStyle(size: 28))
                            .help(L("settings.shortcut.resetTooltip"))
                        }
                    }
                }
                SettingsRow(
                    icon: "return",
                    iconTint: .appAccent,
                    title: L("settings.shortcut.quickPasteCommit"),
                    subtitle: L("settings.shortcut.quickPasteCommit.subtitle")
                ) {
                    HStack(spacing: 8) {
                        QuickPasteKeyRecorder(action: .commit, store: quickPasteKeys)
                        Button {
                            showQuickPasteShortcutIssue(quickPasteKeys.reset(.commit))
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(PaperIconButtonStyle(size: 28))
                        .help(L("settings.shortcut.resetTooltip"))
                    }
                }
                SettingsRow(
                    icon: "checklist",
                    iconTint: .appAccent,
                    title: L("settings.shortcut.quickPasteToggleSelect"),
                    subtitle: L("settings.shortcut.quickPasteToggleSelect.subtitle")
                ) {
                    HStack(spacing: 8) {
                        QuickPasteKeyRecorder(action: .toggleSelect, store: quickPasteKeys)
                        Button {
                            showQuickPasteShortcutIssue(quickPasteKeys.reset(.toggleSelect))
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(PaperIconButtonStyle(size: 28))
                        .help(L("settings.shortcut.resetTooltip"))
                    }
                }
                SettingsRow(
                    icon: "list.bullet.rectangle",
                    iconTint: .appAccent,
                    title: L("settings.shortcut.quickPasteMenu"),
                    subtitle: L("settings.shortcut.quickPasteMenu.subtitle")
                ) {
                    HStack(spacing: 8) {
                        QuickPasteKeyRecorder(action: .openMenu, store: quickPasteKeys)
                        Button {
                            showQuickPasteShortcutIssue(quickPasteKeys.reset(.openMenu))
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(PaperIconButtonStyle(size: 28))
                        .help(L("settings.shortcut.resetTooltip"))
                    }
                }
            }

            SettingsGroup(icon: "lock.shield", title: L("settings.shortcut.permission.title"), tint: .orange) {
                SettingsRow(
                    icon: accessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    iconTint: accessibilityTrusted ? .green : .orange,
                    title: L("settings.shortcut.permission.accessibility"),
                    subtitle: L("settings.shortcut.permission.accessibility.subtitle")
                ) {
                    HStack(spacing: 8) {
                        Text(accessibilityTrusted
                             ? L("settings.shortcut.permission.granted")
                             : L("settings.shortcut.permission.notGranted"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button {
                            // Initial grant: just fire the AX trust prompt.
                            // The system dialog is enough on first run, and
                            // also opening the Accessibility pane causes two
                            // windows to fight for focus. Users who need to
                            // recover from a stale TCC entry have the
                            // "Open Accessibility settings" button in the
                            // recovery hint below.
                            if accessibilityTrusted {
                                // Already trusted: this becomes a re-check
                                // (the label flips to "Re-check" below).
                                accessibilityTrusted = AutoPasteService.isTrusted
                            } else {
                                AutoPasteService.requestTrust()
                            }
                            // Re-check on next runloop tick — the user typically
                            // toggles in System Settings then returns to the app.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                accessibilityTrusted = AutoPasteService.isTrusted
                            }
                        } label: {
                            Label(
                                accessibilityTrusted
                                    ? L("settings.shortcut.permission.recheck")
                                    : L("settings.shortcut.permission.grant"),
                                systemImage: accessibilityTrusted
                                    ? "arrow.clockwise"
                                    : "arrow.up.right.square"
                            )
                        }
                        .buttonStyle(PaperActionButtonStyle(role: accessibilityTrusted ? .plain : .primary))
                    }
                }

                // Recovery hint + diagnostics. Shown only when permission is
                // missing — the common cause is a stale TCC entry (old build
                // path / different signature) that still appears "granted" in
                // System Settings but doesn't match the running binary.
                if !accessibilityTrusted {
                    AccessibilityRecoveryHelp(
                        bundlePath: bundlePath,
                        bundleIdentifier: bundleIdentifier,
                        showDiagnostics: $showDiagnostics
                    )
                }
            }
        }
        // Refresh whenever the app comes back to the foreground — the typical
        // flow is "click Grant → flip the toggle in System Settings → return
        // here", which without this listener leaves the row stuck on "Not
        // granted" until the user manually re-checks.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AutoPasteService.isTrusted
        }
        // Re-read on appear in case the user switched tabs within Settings
        // (no app activation event) after granting in System Settings.
        .onAppear {
            accessibilityTrusted = AutoPasteService.isTrusted
        }
    }
}

/// Recovery hint shown under the Accessibility row when permission isn't
/// detected. The most common cause is a stale TCC entry — macOS keys
/// Accessibility to the binary's path + signature, so a Debug build at
/// `build/.../Clipth.app` is a *different* entry from a Release install
/// at `/Applications/Clipth.app` even though both share the bundle ID.
private struct AccessibilityRecoveryHelp: View {
    let bundlePath: String
    let bundleIdentifier: String
    @Binding var showDiagnostics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("settings.shortcut.permission.recovery.hint"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            HStack(spacing: 8) {
                Button {
                    AutoPasteService.openAccessibilityPane()
                } label: {
                    Label(L("settings.shortcut.permission.openPane"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showDiagnostics.toggle() }
                } label: {
                    Label(
                        showDiagnostics
                            ? L("settings.shortcut.permission.hideDiagnostics")
                            : L("settings.shortcut.permission.showDiagnostics"),
                        systemImage: showDiagnostics ? "chevron.up" : "info.circle"
                    )
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
            }

            if showDiagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticsRow(
                        label: L("settings.shortcut.permission.diag.bundlePath"),
                        value: bundlePath
                    )
                    diagnosticsRow(
                        label: L("settings.shortcut.permission.diag.bundleId"),
                        value: bundleIdentifier
                    )
                    Text(L("settings.shortcut.permission.diag.note"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.appChipFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.appCardBorder, lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosticsRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension AppShortcut {
    var icon: String {
        switch self {
        case .openMainWindow: return "rectangle.inset.filled.on.rectangle"
        case .openQuickPaste: return "bolt.fill"
        }
    }
}

@MainActor
private func showQuickPasteShortcutIssue(_ issue: QuickPasteKeyAssignmentIssue?) {
    guard let issue else { return }
    let messageKey: String
    switch issue {
    case .conflict:
        messageKey = "settings.shortcut.quickPasteConflict"
    case .reservedPanelCommand:
        messageKey = "settings.shortcut.quickPasteReservedCommand"
    case .menuFallbackReserved:
        messageKey = "settings.shortcut.quickPasteMenuFallbackReserved"
    }
    ToastCenter.shared.show(
        L(messageKey),
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
    )
}

/// Records one of the QuickPaste panel's keyboard-flow keys. Click to arm,
/// then press any key (with or without modifiers); Esc cancels without
/// changing the stored command. Conflicting or reserved input keeps the
/// recorder armed so another key can be tried immediately.
///
/// Capture goes through an embedded AppKit probe rather than
/// `KeyboardShortcuts.Recorder`: that component installs a *global* hotkey for
/// whatever it records, which would hijack the key system-wide. These
/// shortcuts must stay panel-local.
private struct QuickPasteKeyRecorder: View {
    let action: QuickPasteKeyAction
    @ObservedObject var store: QuickPasteKeyStore
    @State private var isRecording = false

    private var shortcut: KeyboardShortcuts.Shortcut {
        store.shortcut(for: action)
    }

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording
                 ? L("settings.shortcut.quickPasteCommit.recording")
                 : shortcut.description)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isRecording ? Color.appAccent : Color.appMetal)
                .frame(minWidth: 64)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.appAccent.opacity(0.14) : Color.appChipFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.appAccent : Color.appCardBorder,
                            lineWidth: isRecording ? 1.2 : 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .overlay {
            if isRecording {
                QuickPasteKeyProbe(isRecording: $isRecording) { event in
                    if QuickPasteMenuShortcut.isHardwareContextMenuEvent(event) {
                        showQuickPasteShortcutIssue(.menuFallbackReserved)
                        return false
                    }
                    guard let recorded = KeyboardShortcuts.Shortcut(event: event) else {
                        return false
                    }
                    if let issue = store.assign(recorded, from: event, to: action) {
                        showQuickPasteShortcutIssue(issue)
                        return false
                    }
                    return true
                }
            }
        }
    }
}

/// Invisible AppKit probe inserted while `QuickPasteKeyRecorder` is armed.
/// Grabs keystrokes and delegates validation to the store-backed recorder.
/// `hitTest` returns `nil` so a click still falls through to the button.
private struct QuickPasteKeyProbe: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (NSEvent) -> Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isRecording = $isRecording
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.isRecording = $isRecording
        nsView.onCapture = onCapture
    }

    final class ProbeView: NSView {
        var isRecording: Binding<Bool>?
        var onCapture: ((NSEvent) -> Bool)?
        private var finished = false

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        /// Esc cancels. Valid input disarms; rejected input stays armed so the
        /// user can immediately try another key. Every event is swallowed.
        @discardableResult
        private func capture(_ event: NSEvent) -> Bool {
            guard !finished else { return true }
            if event.keyCode == 53 {
                finish()
                return true
            }
            if onCapture?(event) == true {
                finish()
            }
            return true
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            isRecording?.wrappedValue = false
        }

        override func keyDown(with event: NSEvent) {
            capture(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            capture(event)
        }

        override func resignFirstResponder() -> Bool {
            if !finished {
                finished = true
                let recording = isRecording
                DispatchQueue.main.async { recording?.wrappedValue = false }
            }
            return super.resignFirstResponder()
        }
    }
}

/// App-styled replacement for `KeyboardShortcuts.Recorder`. Unlike
/// `QuickPasteKeyRecorder` (which stays panel-local), this drives the global
/// `KeyboardShortcuts.Name` registry, so the recorded combo really does become
/// a system-wide hotkey — it just renders as a paper chip to match the rest of
/// the settings UI. While armed it pauses the existing binding via
/// `disable(_:)` so the old hotkey can't fire mid-capture, and always restores
/// or replaces it when recording ends.
private struct GlobalShortcutRecorder: View {
    let name: KeyboardShortcuts.Name

    @State private var isRecording = false
    @State private var current: KeyboardShortcuts.Shortcut?
    @State private var hovering = false

    /// The package posts this (internally named) notification whenever a
    /// binding changes — including via the sibling reset button — so we listen
    /// to keep the displayed combo in sync.
    private static let didChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    var body: some View {
        Button {
            toggle()
        } label: {
            Text(labelText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .frame(minWidth: 86)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.appAccent : Color.appCardBorder,
                            lineWidth: isRecording ? 1.2 : 0.75
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) {
            if current != nil, !isRecording {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help(L("settings.shortcut.clearTooltip"))
            }
        }
        .overlay {
            if isRecording {
                GlobalShortcutProbe(onResult: finishRecording)
            }
        }
        .onAppear { current = KeyboardShortcuts.getShortcut(for: name) }
        .onReceive(NotificationCenter.default.publisher(for: Self.didChange)) { note in
            if (note.userInfo?["name"] as? KeyboardShortcuts.Name) == name {
                current = KeyboardShortcuts.getShortcut(for: name)
            }
        }
    }

    private var labelText: String {
        if isRecording { return L("settings.shortcut.recording") }
        return current?.description ?? L("settings.shortcut.empty")
    }

    private var labelColor: Color {
        if isRecording { return Color.appAccent }
        return current == nil ? Color.secondary : Color.appMetal
    }

    private var backgroundColor: Color {
        if isRecording { return Color.appAccent.opacity(0.14) }
        return hovering ? Color.appCardHover : Color.appChipFill
    }

    private func toggle() {
        if isRecording {
            // Tearing down the probe resigns first responder, which funnels
            // through `finishRecording(nil)` and re-enables the old binding.
            isRecording = false
        } else {
            AppShortcutActivation.suspend(name)
            isRecording = true
        }
    }

    /// Single exit point for a recording session (the probe guarantees it runs
    /// exactly once — via a captured key or via resigning first responder).
    private func finishRecording(_ event: NSEvent?) {
        isRecording = false
        if let event, event.keyCode != 53, let recorded = KeyboardShortcuts.Shortcut(event: event) {
            AppShortcutActivation.setShortcut(recorded, for: name)   // registers the new global hotkey
            current = recorded
        } else {
            AppShortcutActivation.restore(name)   // Esc / click-away / invalid → restore the paused binding
        }
    }

    private func clear() {
        AppShortcutActivation.setShortcut(nil, for: name)
        current = nil
    }
}

/// Invisible probe armed while `GlobalShortcutRecorder` is recording. Reports
/// the first keystroke (or `nil` when it loses first responder) back exactly
/// once. `hitTest` returns `nil` so a click still falls through to the chip
/// beneath, letting a second click cancel.
private struct GlobalShortcutProbe: NSViewRepresentable {
    let onResult: (NSEvent?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResult = onResult
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onResult = onResult
    }

    final class ProbeView: NSView {
        var onResult: ((NSEvent?) -> Void)?
        private var finished = false

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        @discardableResult
        private func report(_ event: NSEvent?) -> Bool {
            guard !finished else { return true }
            finished = true
            onResult?(event)
            return true
        }

        override func keyDown(with event: NSEvent) { report(event) }

        override func performKeyEquivalent(with event: NSEvent) -> Bool { report(event) }

        override func resignFirstResponder() -> Bool {
            if !finished {
                finished = true
                let callback = onResult
                DispatchQueue.main.async { callback?(nil) }
            }
            return super.resignFirstResponder()
        }
    }
}

// MARK: - Filter

/// `ForEach($array)` hands each row a positional binding; when a row is
/// deleted, its still-focused TextField flushes one last read through the
/// stale index and traps on Array bounds (crashed in the wild on the
/// custom-rule editor). Keying the binding on the element id turns that
/// late access into a no-op instead.
private func elementBinding<Element: Identifiable>(
    _ array: Binding<[Element]>,
    id: Element.ID,
    fallback: Element
) -> Binding<Element> {
    Binding(
        get: { array.wrappedValue.first { $0.id == id } ?? fallback },
        set: { updated in
            guard let index = array.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            array.wrappedValue[index] = updated
        }
    )
}

private struct FilterSection: View {
    @ObservedObject private var store = FilterSettingsStore.shared
    @AppStorage("tagFilterMode") private var tagFilterModeRaw: String = TagFilterMode.any.rawValue
    @EnvironmentObject private var vm: ClipboardViewModel

    private var tagFilterModeBinding: Binding<TagFilterMode> {
        Binding(
            get: { TagFilterMode(rawValue: tagFilterModeRaw) ?? .any },
            set: { tagFilterModeRaw = $0.rawValue }
        )
    }

    private var semanticFeatureBinding: Binding<Bool> {
        Binding(
            get: { vm.semanticFeatureEnabled },
            set: { vm.setSemanticFeatureEnabled($0) }
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "link.badge.plus", title: L("settings.filter.link.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "link",
                    iconTint: .appAccent,
                    title: L("settings.filter.stripTracking"),
                    subtitle: L("settings.filter.stripTracking.subtitle")
                ) {
                    Toggle("", isOn: $store.stripURLTracking)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
            }

            SettingsGroup(icon: "tag", title: L("settings.filter.tagMode.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "tag.fill",
                    iconTint: .appAccent,
                    title: L("settings.filter.tagMode.row"),
                    subtitle: L("settings.filter.tagMode.subtitle")
                ) {
                    SettingsSegmented(
                        selection: tagFilterModeBinding,
                        options: [
                            .init(value: .any, title: L("search.tagMode.any"), icon: nil),
                            .init(value: .all, title: L("search.tagMode.all"), icon: nil),
                        ],
                        tint: .appAccent
                    )
                    .frame(width: 200)
                }
            }

            // Semantic search — controls the embedding-based search engine.
            // Moved here from "General" because conceptually it's about how
            // search filters the list.
            SettingsGroup(icon: "sparkle", title: L("settings.semantic.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "wand.and.sparkles",
                    iconTint: .appAccent,
                    title: L("settings.semantic.toggle"),
                    subtitle: L("settings.semantic.subtitle")
                ) {
                    Toggle("", isOn: semanticFeatureBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                if vm.isBackfillingEmbeddings {
                    SettingsRow(
                        icon: "arrow.triangle.2.circlepath",
                        iconTint: .appAccent,
                        title: L("settings.semantic.indexing.title"),
                        subtitle: String(
                            format: L("settings.semantic.indexing.subtitle.format"),
                            vm.backfillCompleted,
                            vm.backfillTotal
                        )
                    ) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                }
            }

            appsCard
            typesCard
            textRulesCard
        }
    }

    private var appsCard: some View {
        SettingCard(title: L("settings.filter.apps.title"), subtitle: L("settings.filter.apps.subtitle")) {
            VStack(alignment: .leading, spacing: 8) {
                if store.excludedApps.isEmpty {
                    Text(L("common.notSet"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.excludedApps) { app in
                        HStack(spacing: 10) {
                            if let icon = appIcon(for: app.bundleId) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "app")
                                    .font(.system(size: 18))
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(app.bundleId)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                store.excludedApps.removeAll { $0.bundleId == app.bundleId }
                                ToastCenter.shared.show(
                                    L("settings.filter.apps.removedFormat", app.name),
                                    systemImage: "minus.circle.fill",
                                    tint: .orange
                                )
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(PaperIconButtonStyle(size: 28))
                            .foregroundStyle(Color.appDanger)
                            .help(L("common.remove"))
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.appChipFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.appCardBorder, lineWidth: 0.5)
                        )
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        addApp()
                    } label: {
                        Label(L("settings.filter.apps.addButton"), systemImage: "plus")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
        }
    }

    private var typesCard: some View {
        SettingsGroup(icon: "square.grid.2x2", title: L("settings.filter.types.title"), tint: .appAccent) {
            ForEach(ClipboardItemType.allCases, id: \.self) { type in
                SettingsRow(
                    icon: type.icon,
                    iconTint: .appAccent,
                    title: type.displayName,
                    subtitle: nil
                ) {
                    Toggle("", isOn: Binding(
                        get: { store.excludedTypes.contains(type) },
                        set: { isOn in
                            if isOn { store.excludedTypes.insert(type) }
                            else { store.excludedTypes.remove(type) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.appAccent)
                }
            }
        }
    }

    private var textRulesCard: some View {
        SettingCard(title: L("settings.filter.textRules.title"), subtitle: L("settings.filter.textRules.subtitle")) {
            VStack(spacing: 8) {
                if store.textFilters.isEmpty {
                    Text(L("common.notSet"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(store.textFilters) { rule in
                        let binding = elementBinding($store.textFilters, id: rule.id, fallback: rule)
                        HStack(spacing: 8) {
                            PaperMenuPicker(
                                options: TextFilterRule.Mode.allCases.map {
                                    PaperMenuOption($0, $0.displayName)
                                },
                                selection: binding.mode,
                                width: 130
                            )

                            TextField(L("settings.filter.textRules.placeholder"), text: binding.text)
                                .paperTextField()

                            Button {
                                store.textFilters.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(PaperIconButtonStyle(size: 28))
                            .foregroundStyle(Color.appDanger)
                            .help(L("common.remove"))
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        store.textFilters.append(TextFilterRule(mode: .contains, text: ""))
                    } label: {
                        Label(L("settings.filter.textRules.add"), systemImage: "plus")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
        }
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = L("settings.filter.apps.chooserTitle")
        panel.prompt = L("settings.filter.apps.chooserPrompt")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        var added = 0
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let bundleId = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
            let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if !store.excludedApps.contains(where: { $0.bundleId == bundleId }) {
                store.excludedApps.append(AppFilterEntry(bundleId: bundleId, name: name))
                added += 1
            }
        }
        if added > 0 {
            ToastCenter.shared.show(L("settings.filter.apps.addedFormat", added))
        }
    }
}

// MARK: - Privacy / Content Protection

private struct PrivacySection: View {
    @ObservedObject private var store = ContentProtectionStore.shared

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "lock.shield", title: L("settings.privacy.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "lock.shield.fill",
                    iconTint: .appAccent,
                    title: L("settings.privacy.master"),
                    subtitle: L("settings.privacy.master.subtitle")
                ) {
                    Toggle("", isOn: $store.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
            }

            rulesCard
                .opacity(store.isEnabled ? 1 : 0.6)

            SettingsGroup(icon: "arrow.up.forward.square", title: L("settings.privacy.egress.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "square.and.arrow.up",
                    iconTint: .appAccent,
                    title: L("settings.privacy.rawExport"),
                    subtitle: L("settings.privacy.rawExport.subtitle")
                ) {
                    Toggle("", isOn: $store.allowRawExport)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                        .disabled(!store.isEnabled)
                }
                SettingsRow(
                    icon: "terminal",
                    iconTint: .appAccent,
                    title: L("settings.privacy.rawMCP"),
                    subtitle: L("settings.privacy.rawMCP.subtitle")
                ) {
                    Toggle("", isOn: $store.allowRawMCP)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                        .disabled(!store.isEnabled)
                }
            }
            .opacity(store.isEnabled ? 1 : 0.6)

            SettingCard(
                title: L("settings.privacy.note.title"),
                subtitle: L("settings.privacy.note.body")
            ) {
                EmptyView()
            }
        }
    }

    private var rulesCard: some View {
        SettingCard(
            title: L("settings.privacy.rules.title"),
            subtitle: L("settings.privacy.rules.subtitle")
        ) {
            // The list is never empty: the two built-ins are always seeded
            // (normalized on load), so no empty-state branch is needed.
            VStack(spacing: 8) {
                ForEach(store.rules) { rule in
                    let binding = elementBinding($store.rules, id: rule.id, fallback: rule)
                    HStack(spacing: 8) {
                        Toggle("", isOn: binding.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(.appAccent)

                        Group {
                            if let kind = rule.builtin {
                                // Built-ins keep a fixed name in the picker's
                                // column so rows align; their pattern is regex
                                // by construction.
                                HStack(spacing: 6) {
                                    Image(systemName: kind.icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.appAccent)
                                    Text(kind.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 0)
                                }
                                .frame(width: 130, alignment: .leading)
                            } else {
                                PaperMenuPicker(
                                    options: ProtectionRule.Mode.allCases.map {
                                        PaperMenuOption($0, $0.displayName)
                                    },
                                    selection: binding.mode,
                                    width: 130
                                )
                            }

                            TextField(rule.mode.placeholder, text: binding.pattern)
                                .paperTextField()

                            // Surface a dead rule (bad regex) instead of
                            // silently matching nothing.
                            if !rule.pattern.isEmpty, !rule.isValid {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.appWarning)
                                    .help(L("settings.privacy.customRules.invalidRegex"))
                            }

                            if let kind = rule.builtin {
                                if rule.pattern != ProtectionRule.defaultPattern(for: kind) {
                                    Button {
                                        binding.wrappedValue.pattern = ProtectionRule.defaultPattern(for: kind)
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(PaperIconButtonStyle(size: 28))
                                    .help(L("settings.privacy.rules.reset"))
                                }
                            } else {
                                Button {
                                    store.rules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(PaperIconButtonStyle(size: 28))
                                .foregroundStyle(Color.appDanger)
                                .help(L("common.remove"))
                            }
                        }
                        .opacity(rule.isEnabled ? 1 : 0.55)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        store.rules.append(ProtectionRule())
                    } label: {
                        Label(L("settings.privacy.customRules.add"), systemImage: "plus")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }
            .disabled(!store.isEnabled)
        }
    }
}

/// Display strings live here (not in ContentProtection.swift) so the pure
/// detector file stays standalone-compilable for the test harness.
private extension ProtectionRule.Mode {
    var displayName: String {
        switch self {
        case .contains: return L("settings.privacy.customRules.mode.contains")
        case .regex:    return L("settings.privacy.customRules.mode.regex")
        }
    }

    var placeholder: String {
        switch self {
        case .contains: return L("settings.privacy.customRules.placeholder.contains")
        case .regex:    return L("settings.privacy.customRules.placeholder.regex")
        }
    }
}

private extension ProtectionRule.BuiltinKind {
    var displayName: String {
        switch self {
        case .phone: return L("settings.privacy.rule.builtin.phone")
        case .key:   return L("settings.privacy.rule.builtin.key")
        }
    }
}

// MARK: - Merge

private struct MergeSection: View {
    @ObservedObject private var store = MergeSettingsStore.shared

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "square.stack.3d.up", title: L("settings.merge.behavior.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "trash",
                    iconTint: .appAccent,
                    title: L("settings.merge.deleteOriginals"),
                    subtitle: L("settings.merge.deleteOriginals.subtitle")
                ) {
                    Toggle("", isOn: $store.deleteOriginals)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                SettingsRow(
                    icon: "photo.on.rectangle.angled",
                    iconTint: .appAccent,
                    title: L("settings.merge.enableImageMerge"),
                    subtitle: L("settings.merge.enableImageMerge.subtitle")
                ) {
                    Toggle("", isOn: $store.enableImageMerge)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
            }

            if store.enableImageMerge {
                SettingCard(
                    title: L("settings.merge.imageParams.title"),
                    subtitle: L("settings.merge.imageParams.subtitle")
                ) {
                    VStack(spacing: 8) {
                        imageParamRow(
                            icon: "rectangle.split.1x2",
                            title: L("settings.merge.imageParams.direction")
                        ) {
                            SettingsSegmented(
                                selection: $store.imageDirection,
                                options: imageDirectionOptions,
                                tint: .appAccent
                            )
                            .frame(width: 260)
                        }

                        imageParamRow(
                            icon: "paintpalette",
                            title: L("settings.merge.imageParams.background")
                        ) {
                            SettingsSegmented(
                                selection: $store.imageBackground,
                                options: imageBackgroundOptions,
                                tint: .appAccent
                            )
                            .frame(width: 260)
                        }

                        imageParamRow(
                            icon: "arrow.left.and.right",
                            title: L("settings.merge.imageParams.spacing")
                        ) {
                            imageSpacingControl
                        }
                    }
                }
            }

            separatorCard(
                title: L("settings.merge.textSep.title"),
                subtitle: L("settings.merge.textSep.subtitle"),
                selection: $store.textSeparator,
                custom: $store.textCustomSeparator,
                placeholder: L("settings.merge.textSep.placeholder")
            )
        }
    }

    private var imageDirectionOptions: [SettingsSegmented<ImageMergeDirection>.Option] {
        ImageMergeDirection.allCases.map {
            .init(value: $0, title: $0.displayName, icon: $0.icon)
        }
    }

    private var imageBackgroundOptions: [SettingsSegmented<ImageMergeBackground>.Option] {
        ImageMergeBackground.allCases.map {
            .init(value: $0, title: $0.displayName, icon: imageBackgroundIcon(for: $0))
        }
    }

    private var imageSpacingControl: some View {
        HStack(spacing: 10) {
            Text("\(Int(store.imageSpacing)) px")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.appAccent)
                .frame(width: 58)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.appAccent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.22), lineWidth: 0.75)
                )

            Slider(value: $store.imageSpacing, in: 0...64, step: 1)
                .tint(.appAccent)
                .frame(width: 170)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.appChipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
    }

    private func imageParamRow<Control: View>(
        icon: String,
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appAccent.opacity(0.13))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 30, height: 30)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appMetal)

            Spacer(minLength: 12)

            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appChipFill.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appCardBorder.opacity(0.9), lineWidth: 0.65)
        )
    }

    private func imageBackgroundIcon(for background: ImageMergeBackground) -> String {
        switch background {
        case .transparent: return "circle.dotted"
        case .white:       return "sun.max"
        case .black:       return "moon.fill"
        }
    }

    // Inline separator card: title/subtitle on the left, preset picker
    // vertically centered on the right. When `.custom` is selected, the
    // text field drops onto a second row so it gets full width to type into.
    @ViewBuilder
    private func separatorCard(
        title: String,
        subtitle: String,
        selection: Binding<MergeSeparatorPreset>,
        custom: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                PaperMenuPicker(
                    options: MergeSeparatorPreset.allCases.map {
                        PaperMenuOption($0, $0.displayName)
                    },
                    selection: selection,
                    width: 160
                )
            }
            if selection.wrappedValue == .custom {
                TextField(placeholder, text: custom)
                    .paperTextField()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow.opacity(0.55), radius: 7, y: 2)
    }
}

// MARK: - MCP (composes into AISection)

private struct MCPSettings: View {
    @AppStorage("mcpEnabled") private var mcpEnabled = false
    @StateObject private var clients = MCPClientStore()
    @State private var manualFormat: MCPClientFormat = .mcpServers
    @State private var previewEntry: MCPClientStore.Entry?

    private var executablePath: String { MCPClientConfigurator.executablePath }

    private var configSnippet: String {
        manualFormat.fileSnippet(executablePath: executablePath)
    }

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "network", title: L("settings.mcp.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "switch.2",
                    iconTint: .appAccent,
                    title: L("settings.mcp.enable"),
                    subtitle: L("settings.mcp.enable.subtitle")
                ) {
                    Toggle("", isOn: $mcpEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
            }

            SettingCard(
                title: L("settings.mcp.config.title"),
                subtitle: L("settings.mcp.config.subtitle")
            ) {
                Text(configSnippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appMetal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    // Clear the controls floating over the top of the block.
                    .padding(.top, 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.appChipFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.appCardBorder, lineWidth: 0.5)
                    )
                    .overlay(alignment: .topLeading) {
                        CodeFormatPicker(
                            selection: $manualFormat,
                            options: [
                                .init(value: .mcpServers, title: L("settings.mcp.format.json")),
                                .init(value: .codexTOML, title: L("settings.mcp.format.toml")),
                            ]
                        )
                        .padding(6)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            copyToPasteboard(configSnippet)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(PaperIconButtonStyle(size: 26))
                        .help(L("settings.mcp.copyButton"))
                        .padding(6)
                    }
                    // Swapping JSON ↔ TOML changes the block's height, so
                    // animate it instead of letting the card snap.
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manualFormat)
            }

            clientsSection

            SettingsGroup(icon: "wrench.and.screwdriver", title: L("settings.mcp.tools.title"), tint: .appAccent) {
                ForEach(MCPServer.publicTools, id: \.name) { tool in
                    MCPToolToggleRow(tool: tool)
                        .disabled(!mcpEnabled)
                }
            }
        }
        .opacity(mcpEnabled ? 1 : 0.6)
        .onAppear { clients.refresh() }
        .sheet(item: $previewEntry) { entry in
            MCPConfigPreviewSheet(
                entry: entry,
                onClose: { previewEntry = nil },
                onInstall: {
                    previewEntry = nil
                    install(entry)
                }
            )
        }
    }

    // MARK: One-click client setup

    @ViewBuilder
    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(
                icon: "square.and.arrow.down.on.square",
                title: L("settings.mcp.clients.title"),
                tint: .appAccent
            ) {
                if clients.entries.isEmpty {
                    SettingsRow(
                        icon: "questionmark.circle",
                        iconTint: .secondary,
                        title: L("settings.mcp.clients.empty"),
                        subtitle: L("settings.mcp.clients.empty.subtitle")
                    ) {
                        EmptyView()
                    }
                }

                // Only clients actually installed on this Mac — listing the
                // other dozen would be noise for everyone.
                ForEach(clients.entries) { entry in
                    row(for: entry)
                }
            }

            Text(L("settings.mcp.clients.footnote"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .disabled(!mcpEnabled)
    }

    @ViewBuilder
    private func row(for entry: MCPClientStore.Entry) -> some View {
        MCPClientRow(
            entry: entry,
            // Import doesn't write straight away: it opens the preview so the
            // user confirms the exact edit to their own config file first.
            install: { previewEntry = entry },
            remove: { remove(entry) },
            copy: { copyToPasteboard(entry.target.format.fileSnippet(executablePath: executablePath)) },
            quickLook: {
                QuickLookCoordinator.shared.preview(
                    fileURL: URL(fileURLWithPath: entry.target.configPath)
                )
            },
            openFile: { openConfigFile(entry) }
        )
    }

    private func openConfigFile(_ entry: MCPClientStore.Entry) {
        let url = URL(fileURLWithPath: entry.target.configPath)
        // `.toml` and dotfiles often have no default app; falling back to Finder
        // beats a button that silently does nothing.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func install(_ entry: MCPClientStore.Entry) {
        do {
            try MCPClientConfigurator.install(into: entry.target)
            clients.refresh()
            ToastCenter.shared.show(
                L("settings.mcp.clients.importedFormat", entry.target.name),
                systemImage: "checkmark.circle.fill",
                tint: .appAccent
            )
        } catch {
            showFailure(entry, error)
        }
    }

    private func remove(_ entry: MCPClientStore.Entry) {
        ConfirmationCenter.shared.confirm(
            title: L("settings.mcp.clients.removeConfirm.title", entry.target.name),
            message: L("settings.mcp.clients.removeConfirm.message", entry.target.displayPath),
            confirmLabel: L("settings.mcp.clients.remove"),
            icon: "trash"
        ) {
            do {
                try MCPClientConfigurator.remove(from: entry.target)
                clients.refresh()
                ToastCenter.shared.show(
                    L("settings.mcp.clients.removedFormat", entry.target.name),
                    systemImage: "trash.fill",
                    tint: .appDanger
                )
            } catch {
                showFailure(entry, error)
            }
        }
    }

    private func showFailure(_ entry: MCPClientStore.Entry, _ error: Error) {
        let detail = (error as? MCPClientInstallError)?.errorDescription ?? error.localizedDescription
        ToastCenter.shared.show(
            "\(entry.target.name) — \(detail)",
            systemImage: "exclamationmark.triangle.fill",
            tint: .appDanger,
            duration: 4
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ToastCenter.shared.show(
            L("settings.mcp.copied"),
            systemImage: "doc.on.clipboard.fill",
            tint: .appAccent
        )
    }
}

/// Detected agent apps and whether each already knows about Clipth. Recomputed
/// on appear and after every write, so the rows always reflect the files on
/// disk rather than what we believe we wrote.
@MainActor
private final class MCPClientStore: ObservableObject {
    struct Entry: Identifiable {
        let target: MCPClientTarget
        let state: MCPClientConfigState
        let icon: NSImage?
        var id: String { target.id }
    }

    @Published private(set) var entries: [Entry] = []

    /// Installed clients only — CLI agents count too, so this covers config
    /// files, marker directories, binaries on disk and app bundles.
    func refresh() {
        entries = MCPClientCatalog.all.compactMap { target in
            guard MCPClientCatalog.isInstalled(target, appLookup: { self.appURL(for: $0) != nil }) else {
                return nil
            }
            return Entry(
                target: target,
                state: MCPClientConfigurator.state(for: target),
                icon: target.bundleIDs.lazy.compactMap { self.appIcon(for: $0) }.first
            )
        }
    }

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = appURL(for: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// One agent app: its real icon when we can find the bundle, the config file we
/// would touch, and a single action button whose meaning follows the state.
private struct MCPClientRow: View {
    let entry: MCPClientStore.Entry
    let install: () -> Void
    let remove: () -> Void
    let copy: () -> Void
    let quickLook: () -> Void
    let openFile: () -> Void

    /// Remove only turns red under the cursor — a permanently red button in an
    /// otherwise muted row pulls the eye to the least important control.
    @State private var hoveringRemove = false

    /// Quick Look and "open" need something on disk; a client that has never
    /// written a config yet has nothing to show.
    private var configExists: Bool {
        FileManager.default.fileExists(atPath: entry.target.configPath)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.target.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.appMetal)
                    Text(entry.target.format.badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.appChipFill))
                        .overlay(Capsule().strokeBorder(Color.appCardBorder, lineWidth: 0.5))
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.target.displayPath)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch entry.state {
        case .outdated: return L("settings.mcp.clients.outdated")
        case .unreadable: return L("settings.mcp.error.unreadable")
        case .current, .notConfigured: return entry.target.displayPath
        }
    }

    private var icon: some View {
        MCPClientIcon(entry: entry, size: 30)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 5) {
            Button(action: quickLook) {
                Image(systemName: "eye")
            }
            .buttonStyle(PaperIconButtonStyle(size: 26))
            .disabled(!configExists)
            .help(L("settings.mcp.clients.quickLook"))

            Button(action: openFile) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(PaperIconButtonStyle(size: 26))
            .disabled(!configExists)
            .help(L("settings.mcp.clients.openFile"))

            Button(action: copy) {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(PaperIconButtonStyle(size: 26))
            .help(L("settings.mcp.clients.copy"))

            // Fixed-width slot: without it the icon buttons zig-zag down the
            // list, because "Import" and "✓ Added ⌫" are different widths.
            stateControl
                .frame(minWidth: 104, alignment: .trailing)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: entry.state)
    }

    /// Every control here is 26pt tall with the same 8pt radius and hairline
    /// border as the icon buttons to its left, so the row's right edge reads as
    /// one group whichever state it is in.
    @ViewBuilder
    private var stateControl: some View {
        HStack(spacing: 5) {
            switch entry.state {
            case .current:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(L("settings.mcp.clients.imported"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.appAccent.opacity(0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.24), lineWidth: 0.75)
                )

                Button(action: remove) {
                    // The tint has to sit on the label: PaperIconButtonStyle
                    // paints `appMetal` onto it, which would win over a
                    // foregroundStyle applied to the Button from outside.
                    Image(systemName: "trash")
                        .foregroundStyle(hoveringRemove ? Color.appDanger : Color.appMetal.opacity(0.7))
                }
                .buttonStyle(PaperIconButtonStyle(size: 26))
                .help(L("settings.mcp.clients.remove"))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { hoveringRemove = hovering }
                }

            case .outdated:
                Button(L("settings.mcp.clients.update"), action: install)
                    .buttonStyle(MCPRowActionButtonStyle())

            case .notConfigured:
                Button(L("settings.mcp.clients.import"), action: install)
                    .buttonStyle(MCPRowActionButtonStyle())

            case .unreadable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.appWarning)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.appWarning.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.appWarning.opacity(0.26), lineWidth: 0.75)
                    )
                    .help(L("settings.mcp.error.shape"))
            }
        }
    }
}

/// Format switch that floats over a code block, sized and shaped like the copy
/// button opposite it so the two read as one pair of controls on the snippet
/// rather than as a settings widget stacked above it.
private struct CodeFormatPicker: View {
    struct Option: Identifiable {
        let value: MCPClientFormat
        let title: String
        var id: MCPClientFormat { value }
    }

    @Binding var selection: MCPClientFormat
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.appMetal.opacity(0.65))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color.appAccent : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appChipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
    }
}

/// The client row's primary action. Deliberately *not* `PaperActionButtonStyle`
/// `.primary`: a solid accent slab next to three muted icon buttons reads as a
/// different design language. This keeps the icon buttons' height, radius and
/// hairline border, and carries the accent as a tint instead of a fill.
private struct MCPRowActionButtonStyle: ButtonStyle {
    var tint: Color = .appAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.32), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// A client's icon. The installed app's own icon wins when there is one — that
/// is by definition what the user sees in the Dock — and otherwise we fall back
/// to the vendor's brand mark checked into the asset catalog, which is the only
/// option for the CLI agents.
private struct MCPClientIcon: View {
    let entry: MCPClientStore.Entry
    let size: CGFloat

    var body: some View {
        if let image = entry.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let asset = NSImage(named: entry.target.iconAsset) {
            Image(nsImage: asset)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                // Only affects the marks stored as template art (Cursor,
                // Windsurf, LM Studio); full-color ones ignore it.
                .foregroundStyle(entry.target.tint)
        } else {
            let tint = entry.target.tint
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15))
                Image(systemName: entry.target.symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size + 2, height: size + 2)
        }
    }
}

private extension MCPClientTarget {
    /// `tintHex` as a Color. The brand colors are chosen against cream paper,
    /// so several of them (Codex graphite, opencode olive) would sink into the
    /// dark surface — lift those rather than shipping invisible chips.
    var tint: Color {
        guard let base = AccentThemeStore.nsColor(fromHex: tintHex)?.usingColorSpace(.sRGB) else {
            return .appAccent
        }
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard isDark else { return base }
            return base.blended(withFraction: 0.42, of: .white) ?? base
        }
        return Color(nsColor: dynamic)
    }
}

/// The confirmation step for Import: shows the exact slice of the client's
/// config file that the write would touch, in that file's own syntax with the
/// added lines marked, and only writes once the user agrees. Built from the
/// same code path as the write itself, so what you see is what lands on disk.
private struct MCPConfigPreviewSheet: View {
    let entry: MCPClientStore.Entry
    let onClose: () -> Void
    let onInstall: () -> Void

    private var preview: Result<MCPConfigPreview, Error> {
        Result { try MCPClientConfigurator.preview(for: entry.target) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch preview {
                    case .success(let preview):
                        Text(caption(for: preview))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        codeBlock(preview)
                    case .failure(let error):
                        failure(error)
                    }
                }
                .padding(16)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 540, height: 420)
        .background(Color.appPaper)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MCPClientIcon(entry: entry, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.target.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appMetal)
                Text("\(entry.target.displayPath) · \(entry.target.format.badge)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.secondary.opacity(0.15)))
            }
            // Esc is bound to the footer's Cancel button (`.cancelAction`);
            // binding it here too would make the shortcut ambiguous.
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func caption(for preview: MCPConfigPreview) -> String {
        if preview.createsFile { return L("settings.mcp.preview.createsFile") }
        if preview.replacesEntry { return L("settings.mcp.preview.replaces") }
        return L("settings.mcp.preview.inserts")
    }

    private func codeBlock(_ preview: MCPConfigPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(preview.lines) { line in
                HStack(alignment: .top, spacing: 0) {
                    // `String(_:)`, not interpolation: SwiftUI formats a bare
                    // Int with the locale's grouping separator, which turns
                    // line 2629 of a big config into "2,629".
                    Text(String(line.number))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .frame(width: 44, alignment: .trailing)
                        .padding(.trailing, 8)
                    Text(line.isAdded ? "+" : " ")
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 12, alignment: .leading)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(Color.appMetal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.vertical, 2)
                .padding(.trailing, 8)
                .background(line.isAdded ? Color.appAccent.opacity(0.14) : Color.clear)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.appChipFill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func failure(_ error: Error) -> some View {
        let detail = (error as? MCPClientInstallError)?.errorDescription ?? error.localizedDescription
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.appWarning)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMetal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("settings.mcp.preview.manualHint"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Text(entry.target.format.fileSnippet(executablePath: MCPClientConfigurator.executablePath))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appMetal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.appChipFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.appCardBorder, lineWidth: 0.5))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Nothing has touched the file yet — say so, so the buttons read as
            // a decision rather than as a receipt.
            Text(L("settings.mcp.preview.pending"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button(L("common.cancel"), action: onClose)
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .keyboardShortcut(.cancelAction)
            if case .success = preview {
                Button(confirmLabel, action: onInstall)
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var confirmLabel: String {
        switch entry.state {
        case .current, .outdated: return L("settings.mcp.preview.confirmUpdate")
        case .notConfigured, .unreadable: return L("settings.mcp.preview.confirmImport")
        }
    }
}

/// One MCP tool with an enable switch. Turning it off hides the tool from the
/// MCP `tools/list` response (so it stops consuming the client's context
/// window) and rejects direct calls. Because the MCP server runs as a separate
/// `--mcp` process that reads this on launch, the change applies the next time
/// the client spawns the server.
private struct MCPToolToggleRow: View {
    let tool: MCPServer.ToolInfo
    @AppStorage private var enabled: Bool

    init(tool: MCPServer.ToolInfo) {
        self.tool = tool
        self._enabled = AppStorage(
            wrappedValue: true,
            MCPServer.toolEnabledDefaultsKey(tool.name)
        )
    }

    var body: some View {
        // Secondary treatment: a muted icon chip and a small switch mark these
        // as fine-grained sub-controls, so the list of 12 doesn't compete with
        // the master "Enable MCP" toggle above.
        SettingsRow(
            icon: "function",
            iconTint: .secondary,
            title: tool.name,
            subtitle: L(tool.descriptionLocalizationKey)
        ) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.appAccent)
        }
    }
}

// MARK: - Data (export / clear)

private struct DataSection: View {
    @EnvironmentObject var vm: ClipboardViewModel
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var stats = CopyStatsStore.shared
    @ObservedObject private var filters = FilterSettingsStore.shared
    @State private var isImporting = false

    private var retentionOptions: [(value: Int, label: String)] {
        [
            (0, L("retention.forever")), (1, L("retention.oneDay")), (7, L("retention.sevenDays")),
            (30, L("retention.thirtyDays")), (90, L("retention.ninetyDays")), (180, L("retention.oneEightyDays"))
        ]
    }

    private var trashRetentionOptions: [(value: Int, label: String)] {
        [
            (1, L("retention.oneDay")), (3, L("retention.threeDays")), (7, L("retention.sevenDays")),
            (14, L("retention.fourteenDays")), (30, L("retention.thirtyDays")), (0, L("retention.forever"))
        ]
    }

    var body: some View {
        VStack(spacing: 18) {
            SyncSettingsView()

            SettingsGroup(icon: "trash", title: L("settings.data.trash.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "trash.circle",
                    iconTint: .appAccent,
                    title: L("settings.data.trash.enable"),
                    subtitle: L("settings.data.trash.enable.subtitle")
                ) {
                    Toggle("", isOn: $filters.trashEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                if filters.trashEnabled {
                    SettingsRow(
                        icon: "clock.arrow.circlepath",
                        iconTint: .appAccent,
                        title: L("settings.data.trash.autoClean"),
                        subtitle: L("settings.data.trash.autoClean.subtitle")
                    ) {
                        PaperMenuPicker(
                            options: trashRetentionOptions.map { PaperMenuOption($0.value, $0.label) },
                            selection: $filters.trashRetentionDays,
                            width: 110
                        )
                    }
                }
            }

            SettingsGroup(icon: "chart.bar.xaxis", title: L("settings.data.stats.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "chart.line.uptrend.xyaxis",
                    iconTint: .appAccent,
                    title: L("settings.data.stats.recordCopy"),
                    subtitle: L("settings.data.stats.recordCopy.subtitle")
                ) {
                    Toggle("", isOn: $stats.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                }
                SettingsRow(
                    icon: "chart.bar.xaxis",
                    iconTint: .appAccent,
                    title: L("settings.data.export.clearStats"),
                    subtitle: L("settings.data.stats.clear.subtitle")
                ) {
                    Button {
                        ConfirmationCenter.shared.confirm(
                            title: L("confirm.clearStats.title"),
                            message: L("confirm.permanent.message"),
                            confirmLabel: L("settings.data.export.clearStats"),
                            icon: "trash"
                        ) {
                            stats.resetAll()
                            ToastCenter.shared.show(
                                L("settings.data.export.clearedStats"),
                                systemImage: "chart.bar.xaxis",
                                tint: .red
                            )
                        }
                    } label: {
                        Label(L("settings.data.export.clearStats"), systemImage: "trash")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .destructive))
                }
            }

            // Per-type retention. The old "立即清理" button was removed — the
            // app already runs retention cleanup automatically on a timer, so
            // the manual trigger had no real effect users could observe.
            SettingCard(
                title: L("settings.data.retention.title"),
                subtitle: L("settings.data.retention.subtitle")
            ) {
                VStack(spacing: 6) {
                    ForEach(ClipboardItemType.allCases, id: \.self) { type in
                        HStack {
                            Label(type.displayName, systemImage: type.icon)
                                .font(.system(size: 13))
                            Spacer()
                            PaperMenuPicker(
                                options: retentionOptions.map { PaperMenuOption($0.value, $0.label) },
                                selection: retentionBinding(for: type),
                                width: 110
                            )
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            SettingInlineCard(
                title: L("settings.data.export.title"),
                subtitle: L("settings.data.export.subtitle")
            ) {
                Button {
                    vm.showExportPanel = true
                } label: {
                    Label(L("settings.data.export.exportButton"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PaperActionButtonStyle(role: .primary))
            }

            SettingInlineCard(
                title: L("settings.data.import.title"),
                subtitle: L("settings.data.import.subtitle")
            ) {
                Button {
                    importNow()
                } label: {
                    Label(L("settings.data.import.importButton"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
                .disabled(isImporting)
            }

            // Clear history — two-step confirm since it permanently wipes every clip.
            SettingInlineCard(
                title: L("settings.data.clear.title"),
                subtitle: L("settings.data.clear.subtitle")
            ) {
                Button {
                    ConfirmationCenter.shared.confirm(
                        title: L("confirm.deleteAll.title"),
                        message: L("confirm.deleteAll.message"),
                        confirmLabel: L("settings.data.export.clearHistory"),
                        icon: "trash"
                    ) {
                        vm.deleteAll(context: modelContext)
                        ToastCenter.shared.show(
                            L("settings.data.export.clearedHistory"),
                            systemImage: "trash.fill",
                            tint: .red
                        )
                    }
                } label: {
                    Label(L("settings.data.export.clearHistory"), systemImage: "trash")
                }
                .buttonStyle(PaperActionButtonStyle(role: .destructive))
            }

        }
    }

    private func retentionBinding(for type: ClipboardItemType) -> Binding<Int> {
        Binding(
            get: { filters.retentionDays(for: type) },
            set: { filters.setRetentionDays($0, for: type) }
        )
    }

    private func importNow() {
        isImporting = true
        ExportService.shared.importFromJSON(context: modelContext) { result in
            DispatchQueue.main.async {
                isImporting = false
                switch result {
                case .none:
                    break
                case .success(let importResult):
                    ToastCenter.shared.show(
                        L(
                            "import.successFormat",
                            importResult.imported,
                            importResult.skipped,
                            importResult.failed
                        ),
                        systemImage: "square.and.arrow.down.fill",
                        tint: .green
                    )
                    if importResult.imported > 0 {
                        WidgetBridge.shared.refreshNow(context: modelContext)
                    }
                case .failure(let error):
                    ToastCenter.shared.show(
                        L("import.failedFormat", error.localizedDescription),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
        }
    }

}

// MARK: - About

@MainActor
private struct AboutSection: View {
    @State private var showAcknowledgements = false

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "剪迹"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 18) {
            AboutHeaderCard(appName: appName, version: version, copyright: copyright)

            SettingsGroup(icon: "info.circle", title: L("settings.about.info.title"), tint: .blue) {
                SettingsRow(
                    icon: "number",
                    iconTint: .blue,
                    title: L("settings.about.version"),
                    subtitle: nil
                ) {
                    Text(version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(
                    icon: "shippingbox",
                    iconTint: .teal,
                    title: L("settings.about.bundleId"),
                    subtitle: nil
                ) {
                    Text(Bundle.main.bundleIdentifier ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(
                    icon: "desktopcomputer",
                    iconTint: .purple,
                    title: L("settings.about.system"),
                    subtitle: nil
                ) {
                    Text(systemVersionString())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            SettingsGroup(icon: "link", title: L("settings.about.links.title"), tint: .green) {
                SettingsRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    iconTint: .green,
                    title: L("settings.about.repo"),
                    subtitle: Self.repoURL.absoluteString
                ) {
                    Button {
                        NSWorkspace.shared.open(Self.repoURL)
                    } label: {
                        Label(L("settings.about.repo.open"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
                SettingsRow(
                    icon: "exclamationmark.bubble",
                    iconTint: .red,
                    title: L("settings.about.feedback"),
                    subtitle: L("settings.about.feedback.subtitle")
                ) {
                    Button {
                        NSWorkspace.shared.open(Self.issuesURL)
                    } label: {
                        Label(L("settings.about.feedback.open"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
                SettingsRow(
                    icon: "doc.text",
                    iconTint: .orange,
                    title: L("settings.about.license"),
                    subtitle: L("settings.about.license.subtitle")
                ) {
                    Button {
                        NSWorkspace.shared.open(Self.licenseURL)
                    } label: {
                        Label("MIT", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }
            }

            SettingInlineCard(
                title: L("settings.about.acknowledgements.title"),
                subtitle: L("settings.about.acknowledgements.subtitle")
            ) {
                Button {
                    showAcknowledgements = true
                } label: {
                    Label(L("settings.about.acknowledgements.view"), systemImage: "chevron.right")
                }
                .buttonStyle(PaperActionButtonStyle(role: .plain))
            }
        }
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsSheet { showAcknowledgements = false }
        }
    }

    private static let repoURL = URL(string: "https://github.com/wavever/Clipth")!
    private static let licenseURL = URL(string: "https://github.com/wavever/Clipth/blob/main/LICENSE")!
    private static let issuesURL = URL(string: "https://github.com/wavever/Clipth/issues")!

    private func systemVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

// MARK: - About header card
//
// App icon + name + version, with the update check folded into the same row.
// Tapping "检查更新" just triggers `checkForUpdates()`; from there Sparkle
// drives its own standard UI (checking sheet → up-to-date or update-available
// dialog → download progress → install & relaunch), so we don't reimplement
// any of that. The button is disabled (and dimmed) while a check is already
// in flight (`canCheck == false`).
@MainActor
private struct AboutHeaderCard: View {
    let appName: String
    let version: String
    let copyright: String

    @ObservedObject private var updater = UpdaterService.shared

    var body: some View {
        HStack(spacing: 16) {
            AppLogoMark(size: 64, shadowRadius: 8, shadowOpacity: 0.85)
            VStack(alignment: .leading, spacing: 4) {
                Text(appName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appMetal)
                Text(updateStatusText)
                    .font(updateStatusFont)
                    .foregroundStyle(updater.updateAvailable ? Color.appWarning : .secondary)
                if !copyright.isEmpty {
                    Text(copyright)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            Button {
                updater.checkForUpdates()
            } label: {
                Label(updateButtonTitle, systemImage: updateButtonIcon)
            }
            .buttonStyle(PaperActionButtonStyle(role: updater.updateAvailable ? .primary : .plain))
            .disabled(!updater.canCheck)
            .opacity(updater.canCheck ? 1 : 0.5)
            .help(updateButtonHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
        )
        .shadow(color: Color.appCardShadow.opacity(0.55), radius: 7, y: 2)
    }

    private var updateStatusText: String {
        guard updater.updateAvailable else {
            return L("settings.about.versionFormat", version)
        }
        if let label = updater.latestVersionLabel {
            return L("settings.about.update.availableFormat", label)
        }
        return L("settings.about.update.available")
    }

    private var updateStatusFont: Font {
        updater.updateAvailable
            ? .system(size: 12, weight: .semibold)
            : .system(size: 12, design: .monospaced)
    }

    private var updateButtonTitle: String {
        updater.updateAvailable ? L("settings.about.update.install") : L("settings.about.update.check")
    }

    private var updateButtonIcon: String {
        updater.updateAvailable ? "arrow.down.circle.fill" : "arrow.clockwise"
    }

    private var updateButtonHelp: String {
        updater.updateAvailable ? L("settings.about.update.installHelp") : L("settings.about.update.title")
    }
}

// MARK: - Acknowledgements

/// One open-source dependency surfaced in the acknowledgements sheet.
private struct OpenSourceComponent: Identifiable {
    let name: String
    let detail: String
    let url: URL
    var id: String { name }
}

/// Modal listing the open-source components the app ships. Each row links out
/// to its GitHub repository.
private struct AcknowledgementsSheet: View {
    let onClose: () -> Void

    private var components: [OpenSourceComponent] {
        [
            OpenSourceComponent(
                name: "KeyboardShortcuts",
                detail: L("settings.about.ack.keyboardShortcuts"),
                url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!
            ),
            OpenSourceComponent(
                name: "Sparkle",
                detail: L("settings.about.ack.sparkle"),
                url: URL(string: "https://github.com/sparkle-project/Sparkle")!
            ),
            OpenSourceComponent(
                name: "Lobe Icons",
                detail: L("settings.about.ack.lobeIcons"),
                url: URL(string: "https://github.com/lobehub/lobe-icons")!
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.about.acknowledgements.title"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(L("settings.about.acknowledgements.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(components) { component in
                        AcknowledgementRow(component: component)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 380, height: 300)
        .background(Color.appPaper)
    }
}

private struct AcknowledgementRow: View {
    let component: OpenSourceComponent
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(component.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.appAccent.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(component.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.appAccent : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Color.appCardHover : Color.appCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        hovering ? Color.appCardBorderStrong : Color.appCardBorder,
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(component.url.absoluteString)
    }
}

// MARK: - Manual max-record editor

/// Numeric editing lives in a focused sheet instead of expanding the dense
/// settings row. The persisted limit changes only after Save, so opening or
/// cancelling this editor can never prune history accidentally.
private struct ManualMaxRecordsEditor: View {
    private let range = 50...100_000
    let onCancel: () -> Void
    let onSave: (Int) -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        initialValue: Int,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Int) -> Void
    ) {
        self._text = State(initialValue: "\(initialValue)")
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.appAccent.opacity(0.13))
                    Image(systemName: "number")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("settings.storage.maxRecords.editor.title"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appMetal)
                    Text(L("settings.storage.maxRecords.editor.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("", text: $text)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .paperTextField(focused: focused)
                    .onSubmit { save() }
                Text(L("settings.storage.maxRecordsUnit"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appChipFill.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.appCardBorder, lineWidth: 0.75)
            )

            HStack(spacing: 10) {
                Button(L("common.cancel"), action: onCancel)
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                    .keyboardShortcut(.cancelAction)

                Button(L("common.save"), action: save)
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedValue == nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(width: 380)
        .background(Color.appPaper)
        .onAppear {
            Task { @MainActor in
                focused = true
            }
        }
    }

    private var parsedValue: Int? {
        guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)),
              range.contains(parsed) else { return nil }
        return parsed
    }

    private func save() {
        guard let parsedValue else { return }
        onSave(parsedValue)
    }
}

// MARK: - Launch at login

/// Thin wrapper over `SMAppService.mainApp` backing the "launch at login"
/// toggle. The toggle was previously a dead `@AppStorage` bool; this actually
/// registers / unregisters the app as a macOS login item.
enum LoginItemService {
    /// `true` when the app is registered to launch at login. `.requiresApproval`
    /// (registered but pending the user's OK in System Settings › Login Items)
    /// counts as on so the toggle mirrors the user's intent.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// Register or unregister the login item. Errors are logged; the caller
    /// should re-read `isEnabled` to display the resulting state.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval: break   // already set up
                default: try service.register()
                }
            } else {
                switch service.status {
                case .notRegistered, .notFound: break       // already off
                default: try service.unregister()
                }
            }
        } catch {
            NSLog("[LoginItem] failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}

// MARK: - Accent swatches
//
// Row of color circles, one per palette entry, with a ring around the active
// swatch. Tapping a swatch commits the new palette to AppStorage; the root
// scene then re-renders and `Color.appAccent` resolves to the new tint via
// the `.tint()` modifier applied there.
private struct AccentSwatches: View {
    @Binding var selection: AccentPalette
    @Bindable private var accentStore = AccentThemeStore.shared

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentPalette.presetCases) { palette in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = palette }
                } label: {
                    AccentSwatchCircle(color: palette.color, isSelected: selection == palette)
                }
                .buttonStyle(.plain)
                .help(palette.displayName)
            }

            Button {
                openCustomColorPanel()
            } label: {
                AccentSwatchCircle(
                    color: Color(nsColor: accentStore.customColor),
                    isSelected: selection == .custom,
                    symbolName: "plus"
                )
            }
            .buttonStyle(.plain)
            .help(AccentPalette.custom.displayName)
        }
    }

    private func openCustomColorPanel() {
        withAnimation(.easeOut(duration: 0.15)) {
            selection = .custom
        }

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = accentStore.customColor
        AccentColorPanelBridge.shared.onColorChange = { color in
            accentStore.customColor = color.usingColorSpace(.sRGB) ?? color
            if selection != .custom {
                selection = .custom
            }
        }
        panel.setTarget(AccentColorPanelBridge.shared)
        panel.setAction(#selector(AccentColorPanelBridge.colorDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class AccentColorPanelBridge: NSObject {
    static let shared = AccentColorPanelBridge()

    var onColorChange: ((NSColor) -> Void)?

    @objc func colorDidChange(_ sender: NSColorPanel) {
        onColorChange?(sender.color)
    }
}

private struct AccentSwatchCircle: View {
    let color: Color
    let isSelected: Bool
    var symbolName: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                )
            if isSelected {
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 30, height: 30)
            }
            if let symbolName {
                Circle()
                    .fill(Color.appPaper.opacity(0.88))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.appMetal)
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
    }
}
