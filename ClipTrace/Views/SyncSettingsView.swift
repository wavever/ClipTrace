import AppKit
import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject private var sync = SyncService.shared
    @AppStorage(SyncPreferenceKeys.provider) private var providerRaw = SyncProvider.off.rawValue
    @AppStorage(SyncPreferenceKeys.automatic) private var automatic = true
    @AppStorage(SyncPreferenceKeys.intervalMinutes) private var intervalMinutes = SyncService.defaultIntervalMinutes
    @AppStorage(SyncPreferenceKeys.webDAVURL) private var webDAVURL = ""
    @AppStorage(SyncPreferenceKeys.webDAVUsername) private var webDAVUsername = ""
    @AppStorage(SyncPreferenceKeys.s3Endpoint) private var s3Endpoint = ""
    @AppStorage(SyncPreferenceKeys.s3Region) private var s3Region = "us-east-1"
    @AppStorage(SyncPreferenceKeys.s3Bucket) private var s3Bucket = ""
    @AppStorage(SyncPreferenceKeys.s3Prefix) private var s3Prefix = "ClipTrace"
    @AppStorage(SyncPreferenceKeys.s3AccessKeyID) private var s3AccessKeyID = ""
    @AppStorage(SyncPreferenceKeys.s3PathStyle) private var s3PathStyle = true
    @AppStorage(SyncPreferenceKeys.localFolderPath) private var localFolderPath = ""

    @State private var webDAVPassword = ""
    @State private var s3SecretAccessKey = ""
    @State private var s3SessionToken = ""
    @State private var recoveryKeyInput = ""

    private var provider: SyncProvider {
        SyncProvider(rawValue: providerRaw) ?? .off
    }

    private var providerBinding: Binding<SyncProvider> {
        Binding(
            get: { provider },
            set: { newValue in
                providerRaw = newValue.rawValue
                if newValue != .off {
                    do {
                        _ = try sync.ensureEncryptionKey()
                    } catch {
                        showError(error)
                    }
                }
                sync.settingsDidChange()
            }
        )
    }

    private var intervalOptions: [PaperMenuOption<Int>] {
        [5, 15, 30, 60].map {
            PaperMenuOption($0, L("settings.sync.interval.minutes", $0))
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            SettingsGroup(icon: "arrow.triangle.2.circlepath", title: L("settings.sync.title"), tint: .appAccent) {
                SettingsRow(
                    icon: "externaldrive.connected.to.line.below",
                    iconTint: .appAccent,
                    title: L("settings.sync.provider"),
                    subtitle: L("settings.sync.provider.subtitle")
                ) {
                    PaperMenuPicker(
                        options: SyncProvider.allCases.map { PaperMenuOption($0, $0.localizedName) },
                        selection: providerBinding,
                        width: 148
                    )
                }

                if provider != .off {
                    SettingsRow(
                        icon: "clock.arrow.2.circlepath",
                        iconTint: .appAccent,
                        title: L("settings.sync.automatic"),
                        subtitle: L("settings.sync.automatic.subtitle")
                    ) {
                        Toggle("", isOn: $automatic)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.appAccent)
                            .onChange(of: automatic) { _, _ in sync.settingsDidChange() }
                    }

                    if automatic {
                        SettingsRow(
                            icon: "timer",
                            iconTint: .appAccent,
                            title: L("settings.sync.interval"),
                            subtitle: L("settings.sync.interval.subtitle")
                        ) {
                            PaperMenuPicker(
                                options: intervalOptions,
                                selection: $intervalMinutes,
                                width: 112
                            )
                            .onChange(of: intervalMinutes) { _, _ in sync.settingsDidChange() }
                        }
                    }
                }
            }

            if provider == .iCloudDrive {
                iCloudCard
            } else if provider == .webDAV {
                webDAVCard
            } else if provider == .localFolder {
                localFolderCard
            } else if provider == .s3 {
                s3Card
            }

            if provider != .off {
                encryptionCard
                statusCard
            }
        }
        .onAppear {
            webDAVPassword = sync.webDAVPassword()
            s3SecretAccessKey = sync.s3SecretAccessKey()
            s3SessionToken = sync.s3SessionToken()
        }
    }

    private var iCloudCard: some View {
        SettingCard(
            title: L("settings.sync.icloud.title"),
            subtitle: L("settings.sync.icloud.subtitle")
        ) {
            HStack(spacing: 10) {
                Image(systemName: sync.iCloudDriveLocation == nil ? "icloud.slash" : "icloud.fill")
                    .foregroundStyle(sync.iCloudDriveLocation == nil ? Color.appWarning : Color.appAccent)
                Text(sync.iCloudDriveLocation ?? L("settings.sync.icloud.unavailable"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appMetal.opacity(0.82))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appChipFill)
            )
        }
    }

    private var webDAVCard: some View {
        SettingCard(
            title: L("settings.sync.webdav.title"),
            subtitle: L("settings.sync.webdav.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(L("settings.sync.webdav.url"), text: $webDAVURL)
                    .textContentType(.URL)
                    .paperTextField()
                TextField(L("settings.sync.webdav.username"), text: $webDAVUsername)
                    .textContentType(.username)
                    .paperTextField()
                SecureField(L("settings.sync.webdav.password"), text: $webDAVPassword)
                    .textContentType(.password)
                    .paperTextField()

                if webDAVURL.lowercased().hasPrefix("http://") {
                    Label(L("settings.sync.webdav.httpWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appWarning)
                }

                HStack {
                    Spacer()
                    Button {
                        do {
                            try sync.saveWebDAVPassword(webDAVPassword)
                            sync.settingsDidChange(syncImmediately: true)
                            ToastCenter.shared.show(
                                L("settings.sync.webdav.saved"),
                                systemImage: "checkmark.circle.fill",
                                tint: .appAccent
                            )
                        } catch {
                            showError(error)
                        }
                    } label: {
                        Label(L("settings.sync.webdav.saveAndSync"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .disabled(webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var localFolderCard: some View {
        SettingInlineCard(
            title: L("settings.sync.folder.title"),
            subtitle: localFolderPath.isEmpty ? L("settings.sync.folder.subtitle") : localFolderPath
        ) {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = L("settings.sync.folder.choose")
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try sync.chooseLocalFolder(url)
                    } catch {
                        showError(error)
                    }
                }
            } label: {
                Label(L("settings.sync.folder.choose"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(PaperActionButtonStyle(role: .plain))
        }
    }

    private var s3Card: some View {
        SettingCard(
            title: L("settings.sync.s3.title"),
            subtitle: L("settings.sync.s3.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(L("settings.sync.s3.endpoint"), text: $s3Endpoint)
                    .textContentType(.URL)
                    .paperTextField()

                HStack(spacing: 8) {
                    TextField(L("settings.sync.s3.region"), text: $s3Region)
                        .paperTextField()
                    TextField(L("settings.sync.s3.bucket"), text: $s3Bucket)
                        .paperTextField()
                }

                HStack(spacing: 8) {
                    TextField(L("settings.sync.s3.prefix"), text: $s3Prefix)
                        .paperTextField()
                    TextField(L("settings.sync.s3.accessKey"), text: $s3AccessKeyID)
                        .textContentType(.username)
                        .paperTextField()
                }

                SecureField(L("settings.sync.s3.secretKey"), text: $s3SecretAccessKey)
                    .textContentType(.password)
                    .paperTextField()
                SecureField(L("settings.sync.s3.sessionToken"), text: $s3SessionToken)
                    .textContentType(.password)
                    .paperTextField()

                Toggle(isOn: $s3PathStyle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("settings.sync.s3.pathStyle"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appMetal)
                        Text(L("settings.sync.s3.pathStyle.subtitle"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(.appAccent)

                if s3Endpoint.lowercased().hasPrefix("http://") {
                    Label(L("settings.sync.s3.httpWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appWarning)
                }

                HStack {
                    Spacer()
                    Button {
                        do {
                            try sync.saveS3Credentials(
                                secretAccessKey: s3SecretAccessKey,
                                sessionToken: s3SessionToken
                            )
                            sync.settingsDidChange(syncImmediately: true)
                            ToastCenter.shared.show(
                                L("settings.sync.s3.saved"),
                                systemImage: "checkmark.circle.fill",
                                tint: .appAccent
                            )
                        } catch {
                            showError(error)
                        }
                    } label: {
                        Label(L("settings.sync.s3.saveAndSync"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .disabled(
                        s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            s3Region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            s3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            s3SecretAccessKey.isEmpty
                    )
                }
            }
        }
    }

    private var encryptionCard: some View {
        SettingCard(
            title: L("settings.sync.encryption.title"),
            subtitle: L("settings.sync.encryption.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.appAccent)
                    Text(L("settings.sync.encryption.enabled"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appMetal)
                    Spacer()
                    Button {
                        do {
                            let recoveryKey = try sync.currentRecoveryKey()
                            ClipboardMonitor.markInternalWrite()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recoveryKey, forType: .string)
                            ClipboardMonitor.markInternalWrite()
                            ToastCenter.shared.show(
                                L("settings.sync.encryption.copied"),
                                systemImage: "key.fill",
                                tint: .appAccent
                            )
                        } catch {
                            showError(error)
                        }
                    } label: {
                        Label(L("settings.sync.encryption.copyKey"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .plain))
                }

                Divider().overlay(Color.appPaperDivider.opacity(0.7))

                Text(L("settings.sync.encryption.importHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField(L("settings.sync.encryption.keyPlaceholder"), text: $recoveryKeyInput)
                        .font(.system(size: 11, design: .monospaced))
                        .paperTextField()
                    Button(L("settings.sync.encryption.useKey")) {
                        do {
                            try sync.installRecoveryKey(recoveryKeyInput)
                            recoveryKeyInput = ""
                            sync.syncNow()
                            ToastCenter.shared.show(
                                L("settings.sync.encryption.keySaved"),
                                systemImage: "checkmark.shield.fill",
                                tint: .appAccent
                            )
                        } catch {
                            showError(error)
                        }
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .disabled(recoveryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var statusCard: some View {
        SettingCard(
            title: L("settings.sync.status.title"),
            subtitle: L("settings.sync.status.subtitle")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.appMetal)
                        if let detail = statusDetail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 10)
                    Button {
                        sync.syncNow()
                    } label: {
                        Label(L("settings.sync.now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PaperActionButtonStyle(role: .primary))
                    .disabled(!sync.isConfigured || sync.activity == .syncing)
                }

                Label(
                    L("settings.sync.scope", SyncService.maximumAttachmentBytes / 1024 / 1024),
                    systemImage: "info.circle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch sync.activity {
        case .syncing:
            ProgressView().controlSize(.small).tint(.appAccent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.appWarning)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
        case .idle:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch sync.activity {
        case .idle: return L("settings.sync.status.idle")
        case .syncing: return L("settings.sync.status.syncing")
        case .succeeded: return L("settings.sync.status.succeeded")
        case .failed: return L("settings.sync.status.failed")
        }
    }

    private var statusDetail: String? {
        switch sync.activity {
        case .failed(let message):
            return message
        default:
            guard let date = sync.lastSuccess else { return sync.activeLocation }
            return L("settings.sync.status.lastSuccess", Self.dateFormatter.string(from: date))
        }
    }

    private func showError(_ error: Error) {
        ToastCenter.shared.show(
            error.localizedDescription,
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
