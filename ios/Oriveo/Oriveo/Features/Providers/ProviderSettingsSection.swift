import SwiftUI

/// Official connections only: relay and local connections use `RelayDetailBoard`, and
/// `ProviderSettingsRow.usesSettingsSection` already excludes them.
struct ProviderSettingsSection: View {
    let provider: Provider
    @Binding var showEditEndpoint: Bool
    @Binding var showConnectionSettings: Bool
    @Binding var showDeleteAlert: Bool
    @Binding var showGenerationParameters: Bool

    private var setupCatalog: ProviderSetupCatalog { ProviderSetupCatalog.current() }
    private var setupEndpointOptions: [ProviderEndpointOption] {
        setupCatalog.setupEndpointOptions(for: provider.kind)
    }

    private var rows: [ProviderSettingsRow] {
        ProviderSettingsRow.rows(for: provider, hasEndpointOptions: !setupEndpointOptions.isEmpty)
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    if index > 0 { rowDivider }
                    settingsRow(for: row)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                    .stroke(OriveoTheme.Palette.border.opacity(0.72), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border.opacity(0.45))
            .frame(height: 0.5)
            .padding(.leading, 60)
    }

    @ViewBuilder
    private func settingsRow(for row: ProviderSettingsRow) -> some View {
        switch row {
        case .endpoint:
            // Current region: prefer the option the endpoint source points to, otherwise look up the stored URL literally in the unfiltered catalog (the trusted table only limits selectable options).
            let endpoint = ProviderEndpointEditPolicy.currentOption(
                catalog: setupCatalog,
                kind: provider.kind,
                baseURLText: provider.baseURLText,
                endpointSource: provider.endpointSource
            )
            settingsRow(
                icon: provider.kind == .qwen ? "location.circle.fill" : row.icon,
                title: provider.kind.setupEndpointTitle,
                value: endpoint.map { provider.kind.localizedSetupEndpointLabel(for: $0) }
                    ?? provider.baseURLText
                    ?? setupCatalog.defaultBaseURLText(for: provider.kind),
                action: { showEditEndpoint = true }
            )
        case .connection:
            settingsRow(
                icon: row.icon,
                title: L10n.tr("Connection settings", table: .providers),
                value: nil,
                action: { showConnectionSettings = true }
            )
        case .parameters:
            settingsRow(
                icon: row.icon,
                // The entry name must match the page it opens, otherwise users think they landed somewhere else.
                title: L10n.tr("Parameters", table: .providers),
                value: nil,
                action: { showGenerationParameters = true }
            )
        case .delete:
            settingsRow(
                icon: row.icon,
                title: L10n.tr("Delete Provider", table: .providers),
                value: nil,
                tint: OriveoTheme.Palette.danger,
                action: { showDeleteAlert = true }
            )
        }
    }

    @ViewBuilder
    private func settingsRow(
        icon: String,
        title: String,
        value: String?,
        tint: Color = OriveoTheme.Palette.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ProviderManagementRow(
                icon: icon,
                title: title,
                value: value,
                tint: tint
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct ProviderManagementRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var tint: Color = OriveoTheme.Palette.textPrimary

    var body: some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(tint)

                if let value {
                    Text(value)
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Edit API Key Sheet

struct EditAPIKeySheet: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newAPIKey = ""
    @State private var isSaving = false
    @State private var saveError: OriveoError?

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    private var hasStoredKey: Bool {
        RelayCredentialPolicy.hasStoredKey(provider.map { ProviderCredentialResolver.apiKey(provider: $0, modelID: nil) })
    }

    private var credentialState: RelayCredentialPolicy.State {
        RelayCredentialPolicy.state(provider?.relayRequested, hasStoredKey: hasStoredKey)
    }

    private var requiresKeyInput: Bool {
        RelayCredentialPolicy.credentialInputRequired(
            mode: .edit,
            authMode: provider?.relayRequested?.authMode,
            hasStoredKey: hasStoredKey
        )
    }

    private var trimmedDraftKey: String {
        newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && (!requiresKeyInput || !trimmedDraftKey.isEmpty)
    }

    private var keyRotationFootnote: String {
        provider?.kind == .relay
            ? L10n.tr("Saving sends one tiny test request to confirm the new key works.", table: .providers)
            : L10n.tr("Models will be re-synced automatically after replacing the key.", table: .providers)
    }

    private var saveButtonTitle: String {
        guard isSaving else { return L10n.tr("Save & Sync", table: .providers) }
        return provider?.kind == .relay
            ? L10n.tr("Verifying the new key…", table: .providers)
            : L10n.tr("Working...", table: .providers)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                Text(L10n.tr("Edit API Key", table: .providers))
                    .font(OriveoTheme.Typography.title1)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                if let provider {
                    OriveoCard {
                        HStack(spacing: OriveoTheme.Spacing.md) {
                            // The relay keys page (RelayKeysPage) also presents this card, so the avatar must match the list
                            ConnectionAvatarIcon(provider: provider, kind: provider.kind)
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                                Text(provider.displayName)
                                    .font(OriveoTheme.Typography.title3)
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                Text(currentCredentialLine(for: provider))
                                    .font(OriveoTheme.Typography.caption)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                if credentialState == .notRequired {
                    Text(L10n.tr("No authentication. No credentials are sent.", table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OriveoLabeledField(
                    title: L10n.tr("New API Key", table: .providers),
                    text: $newAPIKey,
                    placeholder: provider.map { ProviderSetupCatalog.current().apiKeyPlaceholder(for: $0.kind) } ?? "",
                    footnote: keyRotationFootnote,
                    isSecure: true
                )

                if let saveError {
                    OriveoErrorCard(error: saveError) {
                        self.saveError = nil
                    }
                }

                Spacer()

                Button(saveButtonTitle) {
                    Task { await saveAndSync() }
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.4)
            }
            .padding(OriveoTheme.Spacing.xl)
            .oriveoScreenBackground()
        }
    }

    private func currentCredentialLine(for provider: Provider) -> String {
        switch credentialState {
        case .notRequired:
            return L10n.tr("This connection doesn't need a key", table: .providers)
        case .present:
            let preview = provider.apiKeyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(
                format: L10n.tr("Current: %@", table: .providers),
                preview.isEmpty ? APIKeyMask.fullyMasked : preview
            )
        case .missing, .conflict:
            return L10n.tr("API Key required", table: .providers)
        }
    }

    private func saveAndSync() async {
        let trimmedKey = trimmedDraftKey
        guard !trimmedKey.isEmpty else {
            dismiss()
            return
        }
        guard ProviderKeyInput.isPrintableASCII(trimmedKey) else {
            saveError = ProviderKeyInput.illegalCharsError()
            return
        }
        if let provider, let requested = provider.relayRequested {
            var credentials = RelayCredentialPolicy.endpointCredentials(
                for: requested,
                hasStoredKey: hasStoredKey
            )
            credentials.hasKey = true
            let verdict = RelayEndpointPolicy.classify(
                provider.baseURLText ?? "",
                securityMode: requested.securityMode,
                credentials: credentials
            )
            if !verdict.allowed, verdict.reason == "cleartext_credentials" {
                saveError = OriveoError(
                    id: UUID(),
                    title: L10n.tr("API Key", table: .providers),
                    message: L10n.tr("An unencrypted connection can't carry a key.", table: .providers),
                    actionTitle: L10n.tr("OK"),
                    detail: provider.baseURLText ?? "",
                    severity: .warning
                )
                return
            }
        }

        isSaving = true
        saveError = nil

        do {
            try await appState.updateAPIKey(
                providerID: providerID,
                newKey: trimmedKey
            )
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            if let provider, provider.kind == .relay {
                saveError = RelayEditFailurePresentation.error(
                    from: error,
                    provider: provider,
                    actionTitle: L10n.tr("OK")
                )
            } else {
                saveError = makeProviderError(error)
            }
        }
    }
}

struct EditProviderEndpointSheet: View {
    let providerID: UUID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedOptionID = ""
    @State private var setupFieldValues: [String: String] = [:]
    @State private var isSaving = false
    @State private var saveError: OriveoError?

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    /// nil means a template option with placeholders is selected but its values are invalid, so saving is unavailable.
    private var detailSave: ProviderEndpointEditPolicy.DetailSave? {
        guard let provider, !selectedOptionID.isEmpty else { return nil }
        let catalog = ProviderSetupCatalog.current()
        return ProviderEndpointEditPolicy.detailSave(
            catalog: catalog,
            kind: provider.kind,
            selectedOptionID: selectedOptionID,
            current: ProviderEndpointEditPolicy.currentOption(
                catalog: catalog, kind: provider.kind, baseURLText: provider.baseURLText,
                endpointSource: provider.endpointSource
            ),
            storedBaseURLText: provider.baseURLText,
            values: setupFieldValues
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    Text(provider?.kind.setupEndpointTitle ?? L10n.tr("Base URL", table: .providers))
                        .font(OriveoTheme.Typography.title1)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)

                    if let provider {
                        OriveoCard {
                            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                                ConnectionAvatarIcon(provider: provider, kind: provider.kind)
                                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
                                    Text(provider.displayName)
                                        .font(OriveoTheme.Typography.title3)
                                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                    let catalog = ProviderSetupCatalog.current()
                                    let currentEndpoint = ProviderEndpointEditPolicy.currentOption(
                                        catalog: catalog,
                                        kind: provider.kind,
                                        baseURLText: provider.baseURLText,
                                        endpointSource: provider.endpointSource
                                    )
                                    Text(
                                        String(
                                            format: L10n.tr("Current: %@", table: .providers),
                                            currentEndpoint.map { provider.kind.localizedSetupEndpointLabel(for: $0) }
                                                ?? provider.baseURLText
                                                ?? catalog.defaultBaseURLText(for: provider.kind)
                                                ?? provider.displayName
                                        )
                                    )
                                    .font(OriveoTheme.Typography.caption)
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                    if let currentEndpointURL = currentEndpoint?.baseURLText ?? provider.baseURLText {
                                        Text(currentEndpointURL)
                                            .font(OriveoTheme.Typography.caption)
                                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        ProviderEndpointPicker(
                            kind: provider.kind,
                            setupCatalog: ProviderSetupCatalog.current(),
                            selectedOptionID: $selectedOptionID,
                            pinnedCurrent: ProviderEndpointEditPolicy.currentOption(
                                catalog: ProviderSetupCatalog.current(),
                                kind: provider.kind,
                                baseURLText: provider.baseURLText,
                                endpointSource: provider.endpointSource
                            ),
                            includesTemplateOptions: true
                        )

                        // Shown only when the selected address template has placeholders, directly below the region picker.
                        let fieldIDs = ProviderSetupCatalog.current().setupFieldIDs(for: provider.kind, optionID: selectedOptionID)
                        if !fieldIDs.isEmpty {
                            ProviderSetupFieldsSection(
                                fieldIDs: fieldIDs,
                                values: $setupFieldValues,
                                isSubmitting: isSaving
                            )
                        }
                    }

                    if let saveError {
                        OriveoErrorCard(error: saveError) {
                            self.saveError = nil
                        }
                    }
                }
                .padding(OriveoTheme.Spacing.xl)
                .padding(.bottom, OriveoTheme.Spacing.xl)
            }
            .oriveoScreenBackground()
            .onAppear(perform: syncSelectionFromProvider)
            .safeAreaInset(edge: .bottom) {
                Button(isSaving ? L10n.tr("Working...", table: .providers) : L10n.tr("Save & Sync", table: .providers)) {
                    Task { await saveAndSync() }
                }
                .buttonStyle(OriveoPrimaryButtonStyle())
                .disabled(detailSave == nil || isSaving)
                .opacity(detailSave == nil || isSaving ? 0.4 : 1)
                .padding(.horizontal, OriveoTheme.Spacing.xl)
                .padding(.vertical, OriveoTheme.Spacing.lg)
                .background(OriveoTheme.Palette.surfaceChrome)
                .background(OriveoTheme.Palette.background)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(OriveoTheme.Palette.border)
                        .frame(height: 1)
                }
            }
        }
    }

    private func syncSelectionFromProvider() {
        guard let provider else { return }
        let catalog = ProviderSetupCatalog.current()
        selectedOptionID = ProviderEndpointEditPolicy.currentOption(
            catalog: catalog, kind: provider.kind, baseURLText: provider.baseURLText,
            endpointSource: provider.endpointSource
        )?.id
            ?? catalog.defaultSetupEndpointID(for: provider.kind)
            ?? ""
        setupFieldValues = provider.setupValues ?? [:]
    }

    private func saveAndSync() async {
        guard provider != nil else { return }

        isSaving = true
        saveError = nil

        do {
            switch detailSave {
            case let .baseURL(baseURLText):
                try await appState.updateBaseURL(providerID: providerID, baseURLText: baseURLText)
            case let .setup(submission):
                try await appState.updateEndpointSetup(providerID: providerID, submission: submission)
            case nil:
                isSaving = false
                return
            }
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            saveError = makeProviderError(error)
        }
    }
}
