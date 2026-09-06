import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct BackupImportSection: View {
    @Environment(AppState.self) private var appState

    @State private var showImporter = false
    @State private var showImportPreview = false
    @State private var importError: String?
    @State private var importErrorDetail: String?

    @State private var parsedBackupFile: BackupFile?
    @State private var parsedImages: [String: Data] = [:]
    @State private var importPreview: ImportPreview?
    @State private var selectedImportMode: ImportMode = .importNewOnly
    @State private var checksumWarning = false

    @State private var showPasswordPrompt = false
    @State private var importPassword = ""

    @State private var isImporting = false
    @State private var importResult: ImportResult?
    @State private var showImportResult = false

    @State private var showReplaceConfirmation = false

    @State private var passwordError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            importContent

            if let error = importError {
                errorCard(
                    title: L10n.tr("Import Failed", table: .backup),
                    message: error,
                    actionTitle: L10n.tr("Choose Another Backup", table: .backup),
                    detail: importErrorDetail
                ) {
                    importError = nil
                    importErrorDetail = nil
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.oriveoBackup, .json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showImportPreview) {
            importPreviewSheet
        }
        .sheet(isPresented: $showPasswordPrompt) {
            passwordPromptSheet
        }
        .sheet(isPresented: $showImportResult) {
            importResultSheet
        }
        .alert(
            L10n.tr("Replace All Data", table: .backup),
            isPresented: $showReplaceConfirmation
        ) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Replace"), role: .destructive) {
                if parsedBackupFile?.containsKeys == true {
                    showPasswordPrompt = true
                } else {
                    startImport()
                }
            }
        } message: {
            Text(L10n.tr("This will clear all local data and replace it with the backup contents. A temporary backup will be created automatically.", table: .backup))
        }
    }


    private var importContent: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            OriveoSectionHeader(title: L10n.tr("Import & Restore", table: .backup))

            OriveoCard {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    Text(L10n.tr("Restore conversations, providers, and settings from a backup file.", table: .backup))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)

                    Button(L10n.tr("Import Backup", table: .backup)) {
                        showImporter = true
                    }
                    .buttonStyle(OriveoSecondaryButtonStyle())
                }
            }
        }
    }


    private var importPreviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    if let preview = importPreview {
                        OriveoCard {
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                                Text(L10n.tr("Backup Info", table: .backup))
                                    .font(OriveoTheme.Typography.title3)
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                                infoRow(label: L10n.tr("Created", table: .backup), value: formatBackupDate(preview.backupCreatedAt))
                                infoRow(label: L10n.tr("Platform", table: .backup), value: preview.backupPlatform)
                                infoRow(label: L10n.tr("App Version", table: .backup), value: preview.backupAppVersion)
                                infoRow(
                                    label: L10n.tr("Contains API Keys", table: .backup),
                                    value: preview.containsKeys ? L10n.tr("Yes", table: .backup) : L10n.tr("No", table: .backup)
                                )
                            }
                        }

                        OriveoCard {
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                                Text(L10n.tr("Contents", table: .backup))
                                    .font(OriveoTheme.Typography.title3)
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                                dataRow(
                                    icon: "bubble.left.and.bubble.right",
                                    label: L10n.tr("Conversations", table: .backup),
                                    value: preview.existingConversations > 0
                                        ? "\(preview.totalConversations) (\(preview.existingConversations) \(L10n.tr("already exist", table: .backup)))"
                                        : "\(preview.totalConversations)"
                                )
                                dataRow(
                                    icon: "sparkles",
                                    label: L10n.tr("Providers"),
                                    value: preview.existingProviders > 0
                                        ? "\(preview.totalProviders) (\(preview.existingProviders) \(L10n.tr("already exist", table: .backup)))"
                                        : "\(preview.totalProviders)"
                                )
                                dataRow(
                                    icon: "text.bubble",
                                    label: L10n.tr("Messages", table: .backup),
                                    value: "\(preview.totalMessages)"
                                )
                                if preview.totalImages > 0 {
                                    dataRow(
                                        icon: "photo",
                                        label: L10n.tr("Images", table: .backup),
                                        value: "\(preview.totalImages)"
                                    )
                                }
                            }
                        }

                        if checksumWarning {
                            HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(OriveoTheme.Palette.warning)
                                Text(L10n.tr("The backup file may have been modified or corrupted. Proceed with caution.", table: .backup))
                                    .font(OriveoTheme.Typography.caption)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                            .padding(OriveoTheme.Spacing.md)
                            .oriveoRoundedSurface(
                                fill: OriveoTheme.Palette.warningSoft,
                                border: OriveoTheme.Palette.warning.opacity(0.25),
                                shadow: .none
                            )
                        }

                        OriveoCard {
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                                Text(L10n.tr("Import Mode", table: .backup))
                                    .font(OriveoTheme.Typography.title3)
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                                ForEach(ImportMode.allCases) { mode in
                                    importModeRow(mode)
                                }
                            }
                        }
                    }
                }
                .padding(OriveoTheme.Spacing.xl)
                .padding(.bottom, OriveoTheme.Spacing.xxl)
            }
            .oriveoScreenBackground()
            .navigationTitle(L10n.tr("Import Preview", table: .backup))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) {
                        showImportPreview = false
                        resetImportState()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        confirmImport()
                    } label: {
                        if isImporting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Text(L10n.tr("Import", table: .backup))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isImporting)
                }
            }
        }
        .presentationDetents([.large])
    }


    private var passwordPromptSheet: some View {
        NavigationStack {
            VStack(spacing: OriveoTheme.Spacing.xl) {
                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(OriveoTheme.Palette.primary)

                VStack(spacing: OriveoTheme.Spacing.sm) {
                    Text(L10n.tr("Enter Backup Password", table: .backup))
                        .font(OriveoTheme.Typography.title2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    Text(L10n.tr("This backup contains encrypted API keys. Enter the password to restore them, or skip to import without keys.", table: .backup))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }

                OriveoLabeledField(
                    title: L10n.tr("Password", table: .backup),
                    text: $importPassword,
                    placeholder: L10n.tr("Enter backup password", table: .backup),
                    isSecure: true
                )

                if let passwordError {
                    Text(passwordError)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.danger)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: OriveoTheme.Spacing.md) {
                    Button(L10n.tr("Unlock & Import", table: .backup)) {
                        passwordError = nil
                        showPasswordPrompt = false
                        startImport()
                    }
                    .buttonStyle(OriveoPrimaryButtonStyle())
                    .disabled(importPassword.isEmpty)
                    .opacity(importPassword.isEmpty ? 0.5 : 1)

                    Button(L10n.tr("Skip API Keys", table: .backup)) {
                        importPassword = ""
                        showPasswordPrompt = false
                        startImport()
                    }
                    .buttonStyle(OriveoTextButtonStyle())
                }

                Spacer()
            }
            .padding(OriveoTheme.Spacing.xl)
            .oriveoScreenBackground()
            .navigationTitle(L10n.tr("Encrypted Backup", table: .backup))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) {
                        showPasswordPrompt = false
                        resetImportState()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }


    private var importResultSheet: some View {
        NavigationStack {
            VStack(spacing: OriveoTheme.Spacing.xl) {
                Spacer()

                if let result = importResult {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(OriveoTheme.Palette.success)

                    Text(L10n.tr("Import Complete", table: .backup))
                        .font(OriveoTheme.Typography.title1)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    OriveoCard {
                        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                            if result.newConversations > 0 {
                                resultRow(
                                    icon: "plus.circle.fill",
                                    color: OriveoTheme.Palette.success,
                                    text: String(format: L10n.tr("%d new conversations added", table: .backup), result.newConversations)
                                )
                            }
                            if result.mergedConversations > 0 {
                                resultRow(
                                    icon: "arrow.triangle.merge",
                                    color: OriveoTheme.Palette.primary,
                                    text: String(format: L10n.tr("%d conversations merged", table: .backup), result.mergedConversations)
                                )
                            }
                            if result.skippedConversations > 0 {
                                resultRow(
                                    icon: "arrow.uturn.right.circle",
                                    color: OriveoTheme.Palette.textTertiary,
                                    text: String(format: L10n.tr("%d conversations skipped", table: .backup), result.skippedConversations)
                                )
                            }
                            if result.newProviders > 0 {
                                resultRow(
                                    icon: "plus.circle.fill",
                                    color: OriveoTheme.Palette.success,
                                    text: String(format: L10n.tr("%d new providers added", table: .backup), result.newProviders)
                                )
                            }
                            if result.skippedProviders > 0 {
                                resultRow(
                                    icon: "arrow.uturn.right.circle",
                                    color: OriveoTheme.Palette.textTertiary,
                                    text: String(format: L10n.tr("%d providers skipped", table: .backup), result.skippedProviders)
                                )
                            }
                            if result.newSkills > 0 {
                                resultRow(
                                    icon: "plus.circle.fill",
                                    color: OriveoTheme.Palette.success,
                                    text: String(format: L10n.tr("%d new skills added", table: .backup), result.newSkills)
                                )
                            }
                            if result.mergedSkills > 0 {
                                resultRow(
                                    icon: "arrow.triangle.merge",
                                    color: OriveoTheme.Palette.primary,
                                    text: String(format: L10n.tr("%d skills merged", table: .backup), result.mergedSkills)
                                )
                            }
                            if result.skippedSkills > 0 {
                                resultRow(
                                    icon: "arrow.uturn.right.circle",
                                    color: OriveoTheme.Palette.textTertiary,
                                    text: String(format: L10n.tr("%d skills skipped", table: .backup), result.skippedSkills)
                                )
                            }
                            if result.restoredKeys > 0 {
                                resultRow(
                                    icon: "key.fill",
                                    color: OriveoTheme.Palette.success,
                                    text: String(format: L10n.tr("%d API keys restored", table: .backup), result.restoredKeys)
                                )
                            }
                            if result.restoredImages > 0 {
                                resultRow(
                                    icon: "photo.fill",
                                    color: OriveoTheme.Palette.success,
                                    text: String(format: L10n.tr("%d images restored", table: .backup), result.restoredImages)
                                )
                            }
                            if result.skippedImages > 0 {
                                resultRow(
                                    icon: "photo",
                                    color: OriveoTheme.Palette.warning,
                                    text: String(format: L10n.tr("%d images missing (thumbnails preserved)", table: .backup), result.skippedImages)
                                )
                            }
                            if result.restoredPreferences {
                                resultRow(
                                    icon: "gearshape.fill",
                                    color: OriveoTheme.Palette.primary,
                                    text: L10n.tr("Theme and language restored")
                                )
                            }
                            if result.restoredLastUsedModel {
                                resultRow(
                                    icon: "sparkles",
                                    color: OriveoTheme.Palette.primary,
                                    text: L10n.tr("Last used model selection restored")
                                )
                            }
                        }
                    }

                    if result.skillsRequiringKnowledgeReupload > 0 {
                        HStack(alignment: .top, spacing: OriveoTheme.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(OriveoTheme.Palette.warning)
                            Text(L10n.tr("Knowledge base files need to be re-uploaded before they can be used again.", table: .backup))
                                .font(OriveoTheme.Typography.caption)
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        }
                        .padding(OriveoTheme.Spacing.md)
                        .oriveoRoundedSurface(
                            fill: OriveoTheme.Palette.warningSoft,
                            border: OriveoTheme.Palette.warning.opacity(0.25),
                            shadow: .none
                        )
                    }
                }

                Spacer()

                Button(L10n.tr("Done")) {
                    showImportResult = false
                    resetImportState()
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
            }
            .padding(OriveoTheme.Spacing.xl)
            .oriveoScreenBackground()
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }


    private func importModeRow(_ mode: ImportMode) -> some View {
        Button {
            selectedImportMode = mode
        } label: {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                Image(systemName: selectedImportMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        selectedImportMode == mode ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary
                    )
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        Text(mode.title)
                            .font(OriveoTheme.Typography.title3)
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        if mode.isDefault {
                            StatusPill(title: L10n.tr("Recommended"), tone: .primary)
                        }
                    }
                    Text(mode.description)
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }

                Spacer()
            }
            .padding(.vertical, OriveoTheme.Spacing.xs)
        }
        .buttonStyle(.plain)
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

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
        }
    }

    private func resultRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: OriveoTheme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
        }
    }

    private func errorCard(
        title: String,
        message: String,
        actionTitle: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        OriveoErrorCard(
            error: OriveoError(
                id: UUID(),
                title: title,
                message: message,
                actionTitle: actionTitle,
                detail: detail ?? message,
                severity: .warning
            ),
            action: action
        )
    }


    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let localConversations = appState.conversations
            let localProviders = appState.providers

            Task.detached(priority: .userInitiated) {
                do {
                    let data = try SecurityScopedFileAccess.withAccess(to: url) {
                        try BackupService.loadImportData(at: url)
                    }
                    let (backupFile, images) = try BackupService.parseBackup(from: data)

                    if backupFile.version > BackupService.currentVersion {
                        throw BackupError.versionTooNew(backupFile.version)
                    }

                    let checksumValid = BackupService.validateChecksum(backupFile)

                    var hasChecksumWarning = false
                    if let expectedChecksums = backupFile.attachmentChecksums {
                        let corrupted = BackupService.validateAttachmentChecksums(
                            expected: expectedChecksums, images: images
                        )
                        if !corrupted.isEmpty { hasChecksumWarning = true }
                    }
                    if !checksumValid { hasChecksumWarning = true }

                    let preview = BackupService.previewImport(
                        backupFile: backupFile,
                        localConversations: localConversations,
                        localProviders: localProviders
                    )
                    let shouldShowChecksumWarning = hasChecksumWarning

                    await MainActor.run {
                        parsedBackupFile = backupFile
                        parsedImages = images
                        checksumWarning = shouldShowChecksumWarning
                        importPreview = preview
                        showImportPreview = true
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                        importErrorDetail = String(describing: error)
                    }
                }
            }

        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func confirmImport() {
        guard let backup = parsedBackupFile else { return }
        showImportPreview = false

        if selectedImportMode == .replaceAll {
            showReplaceConfirmation = true
            return
        }

        if backup.containsKeys {
            showPasswordPrompt = true
            return
        }

        startImport()
    }

    private func startImport() {
        guard let backup = parsedBackupFile else { return }
        isImporting = true

        Task {
            do {
                let result = try await BackupService.executeImport(
                    backupFile: backup,
                    images: parsedImages,
                    mode: selectedImportMode,
                    password: importPassword.isEmpty ? nil : importPassword,
                    appState: appState
                )
                await MainActor.run {
                    self.importResult = result
                    isImporting = false
                    showImportResult = true
                    if !appState.hasCompletedOnboarding && result.hasChanges {
                        appState.hasCompletedOnboarding = true
                    }
                }
            } catch is CryptoKitError {
                await MainActor.run {
                    isImporting = false
                    importPassword = ""
                    passwordError = L10n.tr("Incorrect password. Please try again or skip to import without keys.")
                    showPasswordPrompt = true
                }
            } catch BackupError.decryptionFailed {
                await MainActor.run {
                    isImporting = false
                    importPassword = ""
                    passwordError = L10n.tr("Incorrect password. Please try again or skip to import without keys.")
                    showPasswordPrompt = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                    importErrorDetail = String(describing: error)
                }
            }
        }
    }

    private func resetImportState() {
        parsedBackupFile = nil
        parsedImages = [:]
        importPreview = nil
        selectedImportMode = .importNewOnly
        checksumWarning = false
        importPassword = ""
        passwordError = nil
        importResult = nil
    }


    private func formatBackupDate(_ iso: String) -> String {
        guard let date = ISO8601Parser.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}
