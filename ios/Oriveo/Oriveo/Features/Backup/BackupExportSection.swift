import SwiftUI
import UniformTypeIdentifiers

struct BackupExportSection: View {
    @Environment(AppState.self) private var appState

    @State private var formState = BackupExportFormState()
    @State private var isExporting = false
    @State private var showExporter = false
    @State private var exportDocument: BackupDocument?
    @State private var exportError: String?
    @State private var exportSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            exportContent

            if let error = exportError {
                OriveoErrorCard(
                    error: OriveoError(
                        id: UUID(),
                        title: L10n.tr("Export Failed"),
                        message: error,
                        actionTitle: L10n.tr("Dismiss"),
                        detail: error,
                        severity: .warning
                    ),
                    action: { exportError = nil }
                )
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .oriveoBackup,
            defaultFilename: BackupService.defaultFilename()
        ) { result in
            switch result {
            case .success:
                exportSuccess = true
                formState.password = ""
                formState.confirmPassword = ""
            case .failure:
                exportError = L10n.tr("Failed to save backup file.", table: .backup)
            }
            exportDocument = nil
        }
        .alert(
            L10n.tr("Export Complete", table: .backup),
            isPresented: $exportSuccess
        ) {
            Button(L10n.tr("OK"), role: .cancel) { }
        } message: {
            Text(L10n.tr("Backup exported successfully.", table: .backup))
        }
    }


    private var exportContent: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            OriveoSectionHeader(title: L10n.tr("Export Backup", table: .backup))

            OriveoCard {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    Toggle(L10n.tr("Include API Keys", table: .backup), isOn: $formState.includeKeys)
                        .tint(OriveoTheme.Palette.primary)

                    if formState.includeKeys {
                        OriveoLabeledField(
                            title: L10n.tr("Encryption Password", table: .backup),
                            text: $formState.password,
                            placeholder: L10n.tr("At least 8 characters", table: .backup),
                            footnote: L10n.tr("API keys will be encrypted with this password. Keep it safe — you'll need it to restore keys.", table: .backup),
                            isSecure: true
                        )

                        OriveoLabeledField(
                            title: L10n.tr("Confirm Password", table: .backup),
                            text: $formState.confirmPassword,
                            placeholder: L10n.tr("Enter password again", table: .backup),
                            isSecure: true
                        )

                        if formState.shouldShowPasswordMismatchWarning {
                            Text(L10n.tr("Passwords do not match.", table: .backup))
                                .font(OriveoTheme.Typography.footnote)
                                .foregroundStyle(OriveoTheme.Palette.danger)
                        }
                    }

                    Button {
                        performExport()
                    } label: {
                        if isExporting {
                            HStack(spacing: OriveoTheme.Spacing.sm) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .scaleEffect(0.8)
                                Text(L10n.tr("Preparing...", table: .backup))
                            }
                        } else {
                            Text(L10n.tr("Export Backup", table: .backup))
                        }
                    }
                    .buttonStyle(OriveoPrimaryButtonStyle())
                    .disabled(isExporting || !formState.canExport)
                    .opacity(!formState.canExport ? 0.5 : 1)
                }
            }

            OriveoCard {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    Text(L10n.tr("Your Data", table: .backup))
                        .font(OriveoTheme.Typography.title3)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    dataRow(
                        icon: "bubble.left.and.bubble.right",
                        label: L10n.tr("Conversations", table: .backup),
                        value: "\(appState.conversations.filter { !$0.isDraft || !$0.messages.isEmpty }.count)"
                    )
                    dataRow(
                        icon: "sparkles",
                        label: L10n.tr("Providers"),
                        value: "\(appState.providers.count)"
                    )
                    dataRow(
                        icon: "text.bubble",
                        label: L10n.tr("Messages", table: .backup),
                        value: "\(appState.conversations.reduce(0) { $0 + $1.messages.count })"
                    )
                }
            }
        }
    }


    private func performExport() {
        guard formState.canExport else { return }
        isExporting = true
        exportError = nil
        exportSuccess = false

        Task {
            do {
                let data = try await BackupService.exportBackup(
                    providers: appState.providers,
                    conversations: appState.conversations,
                    folders: appState.folders,
                    skills: appState.skillManager.userSkills,
                    preferences: appState.preferences,
                    lastUsedModelRef: appState.lastUsedModelRef,
                    includeKeys: formState.includeKeys,
                    password: formState.includeKeys ? formState.password : nil,
                    notes: appState.noteManager.allNotesForSync(),
                    noteFolders: appState.noteManager.allNoteFoldersForSync()
                )
                let conversationCount = appState.conversations.count
                let encrypted = formState.includeKeys && !formState.password.isEmpty
                await MainActor.run {
                    exportDocument = BackupDocument(data: data)
                    showExporter = true
                    isExporting = false
                    BackupService.emitBackupExported(
                        zipSize: data.count,
                        encrypted: encrypted,
                        conversationCount: conversationCount
                    )
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }


    private func dataRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 20)
            Text(label)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
        }
    }
}

struct BackupExportFormState {
    var includeKeys = false
    var password = ""
    var confirmPassword = ""

    var passwordsMatch: Bool {
        password == confirmPassword
    }

    var passwordMeetsLengthRequirement: Bool {
        password.count >= 8
    }

    var canExport: Bool {
        guard includeKeys else { return true }
        return passwordMeetsLengthRequirement && passwordsMatch
    }

    var shouldShowPasswordMismatchWarning: Bool {
        includeKeys &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        !passwordsMatch
    }
}
