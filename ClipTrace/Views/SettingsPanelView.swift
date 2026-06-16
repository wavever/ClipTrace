import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import KeyboardShortcuts
import ServiceManagement

struct SettingsPanelView: View {
    @ObservedObject private var nav = AppNavigation.shared
    @State private var section: Section = .general

    @AppStorage("maxRecords") private var maxRecords = 500
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
    private var dynamicIslandCanReplaceMenuBar: Bool {
        dynamicIslandEnabled && DynamicIslandController.hasNotchedDisplay
    }
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { dynamicIslandCanReplaceMenuBar ? false : menuBarIcon },
            set: { menuBarIcon = $0 }
        )
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
                    subtitle: dynamicIslandCanReplaceMenuBar
                        ? L("settings.window.menuBarIcon.disabledByDynamicIsland")
                        : L("settings.window.menuBarIcon.subtitle")
                ) {
                    Toggle("", isOn: menuBarIconBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.appAccent)
                        .disabled(dynamicIslandCanReplaceMenuBar)
                }
                .opacity(dynamicIslandCanReplaceMenuBar ? 0.58 : 1)
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
            }

            // Storage.
            SettingsGroup(icon: "internaldrive", title: L("settings.storage.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "tray.full",
                    iconTint: .appAccent,
                    title: L("settings.storage.maxRecords"),
                    subtitle: L("settings.storage.maxRecords.subtitle")
                ) {
                    MaxRecordsField(value: $maxRecords)
                        .onChange(of: maxRecords) { _, _ in
                            vm.enforceMaxRecords(context: modelContext)
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
                        QuickPasteKeyRecorder(shortcut: $quickPasteKeys.commitShortcut)
                        Button {
                            quickPasteKeys.resetCommit()
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
                        QuickPasteKeyRecorder(shortcut: $quickPasteKeys.toggleSelectShortcut)
                        Button {
                            quickPasteKeys.resetToggleSelect()
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
/// `build/.../ClipTrace.app` is a *different* entry from a Release install
/// at `/Applications/ClipTrace.app` even though both share the bundle ID.
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

/// Records one of the QuickPaste panel's keyboard-flow keys. Click to arm,
/// then press any key (with or without modifiers); Esc cancels without
/// changing the binding.
///
/// Capture goes through an embedded AppKit probe rather than
/// `KeyboardShortcuts.Recorder`: that component installs a *global* hotkey for
/// whatever it records, which would hijack the key system-wide. These
/// shortcuts must stay panel-local.
private struct QuickPasteKeyRecorder: View {
    @Binding var shortcut: KeyboardShortcuts.Shortcut
    @State private var isRecording = false

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
                QuickPasteKeyProbe(isRecording: $isRecording, shortcut: $shortcut)
            }
        }
    }
}

/// Invisible AppKit probe inserted while `QuickPasteKeyRecorder` is armed.
/// Grabs the next keystroke, writes it to `shortcut`, and disarms. `hitTest`
/// returns `nil` so a click still falls through to the button beneath it.
private struct QuickPasteKeyProbe: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: KeyboardShortcuts.Shortcut

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isRecording = $isRecording
        view.shortcut = $shortcut
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.isRecording = $isRecording
        nsView.shortcut = $shortcut
    }

    final class ProbeView: NSView {
        var isRecording: Binding<Bool>?
        var shortcut: Binding<KeyboardShortcuts.Shortcut>?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        /// Records `event` (unless it is Esc) and disarms. Always returns
        /// `true` so the keystroke is swallowed instead of triggering app
        /// shortcuts while recording.
        @discardableResult
        private func capture(_ event: NSEvent) -> Bool {
            if event.keyCode != 53,  // 53 = Esc → cancel, leave binding intact
               let recorded = KeyboardShortcuts.Shortcut(event: event) {
                shortcut?.wrappedValue = recorded
            }
            isRecording?.wrappedValue = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            capture(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            capture(event)
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
            KeyboardShortcuts.disable(name)
            isRecording = true
        }
    }

    /// Single exit point for a recording session (the probe guarantees it runs
    /// exactly once — via a captured key or via resigning first responder).
    private func finishRecording(_ event: NSEvent?) {
        isRecording = false
        if let event, event.keyCode != 53, let recorded = KeyboardShortcuts.Shortcut(event: event) {
            KeyboardShortcuts.setShortcut(recorded, for: name)   // registers the new global hotkey
            current = recorded
        } else {
            KeyboardShortcuts.enable(name)   // Esc / click-away / invalid → restore the paused binding
        }
    }

    private func clear() {
        KeyboardShortcuts.setShortcut(nil, for: name)
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
                    ForEach($store.textFilters) { $rule in
                        HStack(spacing: 8) {
                            PaperMenuPicker(
                                options: TextFilterRule.Mode.allCases.map {
                                    PaperMenuOption($0, $0.displayName)
                                },
                                selection: $rule.mode,
                                width: 130
                            )

                            TextField(L("settings.filter.textRules.placeholder"), text: $rule.text)
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

    private var executablePath: String {
        Bundle.main.executablePath ?? ""
    }

    private var configJSON: String {
        """
        {
          "mcpServers": {
            "cliptrace": {
              "command": "\(executablePath)",
              "args": ["--mcp"]
            }
          }
        }
        """
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
                Text(configJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appMetal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .padding(.trailing, 32) // reserve space for the floating copy button
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.appChipFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.appCardBorder, lineWidth: 0.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(configJSON, forType: .string)
                            ToastCenter.shared.show(
                                L("settings.mcp.copied"),
                                systemImage: "doc.on.clipboard.fill",
                                tint: .appAccent
                            )
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(PaperIconButtonStyle(size: 26))
                        .help(L("settings.mcp.copyButton"))
                        .padding(6)
                    }
            }

            SettingsGroup(icon: "wrench.and.screwdriver", title: L("settings.mcp.tools.title"), tint: .appAccent) {
                ForEach(MCPServer.publicTools, id: \.name) { tool in
                    MCPToolToggleRow(tool: tool)
                        .disabled(!mcpEnabled)
                }
            }
        }
        .opacity(mcpEnabled ? 1 : 0.6)
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
    @Query private var groups: [ClipboardGroup]
    @ObservedObject private var stats = CopyStatsStore.shared
    @ObservedObject private var filters = FilterSettingsStore.shared
    @State private var newGroupName = ""

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
            SettingsGroup(icon: "folder.badge.gearshape", title: L("settings.data.groups.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "folder.badge.plus",
                    iconTint: .appAccent,
                    title: L("settings.data.groups.create"),
                    subtitle: L("settings.data.groups.subtitle")
                ) {
                    HStack(spacing: 8) {
                        TextField(L("group.name.placeholder"), text: $newGroupName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.appChipFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.appCardBorder, lineWidth: 0.6)
                            )
                            .frame(width: 150)
                            .onSubmit { addGroup() }
                        Button {
                            addGroup()
                        } label: {
                            Label(L("common.add"), systemImage: "plus")
                        }
                        .buttonStyle(PaperActionButtonStyle(role: .primary))
                    }
                }

                if groups.isEmpty {
                    SettingsRow(
                        icon: "tray",
                        iconTint: .secondary,
                        title: L("settings.data.groups.empty"),
                        subtitle: L("settings.data.groups.empty.subtitle")
                    ) {
                        EmptyView()
                    }
                } else {
                    ForEach(groups.sortedForDisplay()) { group in
                        DataGroupSettingsRow(
                            group: group,
                            canMoveUp: groups.sortedForDisplay().first?.id != group.id,
                            canMoveDown: groups.sortedForDisplay().last?.id != group.id,
                            onRename: { name in
                                vm.renameGroup(group, to: name, context: modelContext)
                            },
                            onMoveUp: {
                                vm.moveGroup(group, direction: -1, groups: groups, context: modelContext)
                            },
                            onMoveDown: {
                                vm.moveGroup(group, direction: 1, groups: groups, context: modelContext)
                            },
                            onDelete: {
                                ConfirmationCenter.shared.confirm(
                                    title: L("confirm.deleteGroup.title"),
                                    message: L("confirm.deleteGroup.message"),
                                    confirmLabel: L("common.delete"),
                                    icon: "folder.badge.minus"
                                ) {
                                    vm.deleteGroup(group, context: modelContext)
                                }
                            }
                        )
                    }
                }
            }

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

    private func addGroup() {
        guard vm.createGroup(named: newGroupName, groups: groups, context: modelContext) != nil else { return }
        newGroupName = ""
    }
}

private struct DataGroupSettingsRow: View {
    let group: ClipboardGroup
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRename: (String) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsRow(
            icon: "folder.fill",
            iconTint: .appAccent,
            title: L("settings.data.groups.item.title"),
            subtitle: L("settings.data.groups.item.subtitle")
        ) {
            HStack(spacing: 6) {
                TextField(L("group.name.placeholder"), text: $draft)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.appChipFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(focused ? Color.appAccent.opacity(0.55) : Color.appCardBorder, lineWidth: 0.6)
                    )
                    .frame(width: 150)
                    .onSubmit { commitRename() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitRename() }
                    }

                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .disabled(!canMoveUp)
                .help(L("group.moveUp"))

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .disabled(!canMoveDown)
                .help(L("group.moveDown"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(PaperIconButtonStyle(size: 28))
                .help(L("common.delete"))
            }
        }
        .onAppear { draft = group.displayName }
        .onChange(of: group.name) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !focused { draft = trimmed.isEmpty ? L("group.untitled") : trimmed }
        }
    }

    private func commitRename() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != group.displayName else { return }
        onRename(trimmed)
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

    private static let repoURL = URL(string: "https://github.com/wavever/ClipTrace")!
    private static let licenseURL = URL(string: "https://github.com/wavever/ClipTrace/blob/main/LICENSE")!
    private static let issuesURL = URL(string: "https://github.com/wavever/ClipTrace/issues")!

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
                Text(L("settings.about.versionFormat", version))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
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
                Label(L("settings.about.update.check"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(PaperActionButtonStyle(role: .plain))
            .disabled(!updater.canCheck)
            .opacity(updater.canCheck ? 1 : 0.5)
            .help(L("settings.about.update.title"))
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

// MARK: - Max records field
//
// A numeric input that lets the user type any value within `range` directly.
// Commits on Return / focus loss and clamps out-of-range entries; a non-numeric
// entry reverts to the last valid value so the UI never holds an invalid state.
private struct MaxRecordsField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 50...100_000

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .font(.system(size: 13, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .focused($focused)
                .paperTextField(focused: focused)
                .onAppear { text = "\(value)" }
                .onChange(of: value) { _, newValue in
                    if !focused { text = "\(newValue)" }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onSubmit { commit() }
            Text(L("settings.storage.maxRecordsUnit"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        let digits = text.filter(\.isNumber)
        if let parsed = Int(digits) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = clamped
            text = "\(clamped)"
        } else {
            // Reject empty / non-numeric — fall back to the last good value.
            text = "\(value)"
        }
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

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentPalette.allCases) { palette in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = palette }
                } label: {
                    ZStack {
                        Circle()
                            .fill(palette.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                            )
                        if selection == palette {
                            Circle()
                                .strokeBorder(palette.color, lineWidth: 2)
                                .frame(width: 30, height: 30)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(palette.displayName)
            }
        }
    }
}
