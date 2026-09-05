import SwiftUI

///   │ │ https://api.example.com/v1     │ │  ← editable, mono
///   │ 🔑 API Key       ••••2f8a    Edit > │  ← tap row → onEditAPIKey
///   │ [ ⚡  Test Connection            ]  │  ← prominent secondary button
///   │ ✓ Connected via /v1 • 12 models     │  ← inline pulse result
struct RelayConnectionCard: View {
    @Binding var endpoint: String
    let apiKeyPreview: String
    let authMode: RelayAuthMode?
    let securityMode: RelayConnectionSecurityMode
    let hasStoredKey: Bool
    let isSubmitting: Bool
    let isTestingConnection: Bool
    let testResult: RelayConnectionTestStatus?
    let endpointPlaceholder: String
    var endpointNormalizationHighlightToken = 0
    let onChangeSecurityMode: () -> Void
    let onEditAPIKey: () -> Void
    var onRemoveStoredCredential: (() -> Void)? = nil
    let onTestConnection: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isEndpointNormalizationHighlighted = false

    private var sectionTint: Color {
        Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            RelayGroupHeader(
                title: L10n.tr("Connection", table: .providers),
                systemImage: "link",
                tint: sectionTint
            )

            VStack(spacing: 0) {
                endpointBlock
                Divider()
                    .background(OriveoTheme.Palette.border.opacity(0.5))
                RelaySecurityModeSummaryRow(
                    securityMode: securityMode,
                    isDisabled: isSubmitting,
                    onChange: onChangeSecurityMode
                )
                Divider()
                    .background(OriveoTheme.Palette.border.opacity(0.5))
                if credentialAction != .none {
                    apiKeyBlock
                    Divider()
                        .background(OriveoTheme.Palette.border.opacity(0.5))
                }
                testBlock
                if let testResult {
                    testResultRow(testResult)
                }
            }
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceChrome,
                border: sectionTint.opacity(colorScheme == .dark ? 0.16 : 0.10),
                radius: OriveoTheme.Radius.md,
                shadow: .none
            )
        }
    }

    // MARK: - Endpoint

    private var endpointBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Request URL", table: .providers))
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(sectionTint.opacity(0.8))

                TextField(endpointPlaceholder, text: $endpoint)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isSubmitting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset.opacity(colorScheme == .dark ? 0.6 : 0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isEndpointNormalizationHighlighted
                            ? OriveoTheme.Palette.primary
                            : sectionTint.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        lineWidth: isEndpointNormalizationHighlighted ? 1.5 : 0.5
                    )
            )
            .onChange(of: endpointNormalizationHighlightToken) { _, _ in
                isEndpointNormalizationHighlighted = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    isEndpointNormalizationHighlighted = false
                }
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, OriveoTheme.Spacing.md)
        .padding(.bottom, OriveoTheme.Spacing.md)
    }

    // MARK: - API Key

    private var credentialState: RelayCredentialPolicy.State {
        RelayCredentialPolicy.state(
            authMode: authMode,
            hasStoredKey: hasStoredKey,
            securityMode: securityMode
        )
    }

    private var credentialAction: RelayCredentialPolicy.EditAction {
        RelayCredentialPolicy.editAction(authMode: authMode, hasStoredKey: hasStoredKey)
    }

    @ViewBuilder
    private var apiKeyBlock: some View {
        let isMissing = credentialState == .missing
        let tint = isMissing ? OriveoTheme.Palette.warning : OriveoTheme.Palette.textSecondary
        switch credentialAction {
        case .rotate:
            Button(action: onEditAPIKey) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("API Key", table: .providers))
                        .font(OriveoTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    let showsPreview = credentialState == .present
                    Text(credentialSubtitle)
                        .font(showsPreview
                              ? OriveoTheme.Typography.footnote.monospaced()
                              : OriveoTheme.Typography.footnote)
                        .foregroundStyle(isMissing
                                         ? OriveoTheme.Palette.warning
                                         : OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(L10n.tr("Change", table: .providers))
                    .font(OriveoTheme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OriveoTheme.Palette.primarySoft.opacity(0.86)))
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
            .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        case .removeResidual:
            Button(action: { onRemoveStoredCredential?() }) {
                Label(L10n.tr("Remove stored key", table: .providers), systemImage: "key.slash")
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.warning)
                    .padding(.horizontal, OriveoTheme.Spacing.lg)
                    .padding(.vertical, OriveoTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || onRemoveStoredCredential == nil)
        case .none:
            EmptyView()
        }
    }

    private var credentialSubtitle: String {
        switch credentialState {
        case .notRequired:
            return L10n.tr("This connection doesn't need a key", table: .providers)
        case .present:
            let text = apiKeyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? APIKeyMask.fullyMasked : text
        case .missing, .conflict:
            return L10n.tr("API Key required", table: .providers)
        }
    }

    // MARK: - Test Button

    private var testBlock: some View {
        Button(action: onTestConnection) {
            HStack(spacing: OriveoTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(sectionTint.opacity(0.14))
                        .frame(width: 32, height: 32)
                    if isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                            .tint(sectionTint)
                    } else {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(sectionTint)
                    }
                }
                Text(isTestingConnection ? L10n.tr("Testing...", table: .providers) : L10n.tr("Test connection", table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTestingConnection || isSubmitting || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
    }

    // MARK: - Test Result

    @ViewBuilder
    private func testResultRow(_ status: RelayConnectionTestStatus) -> some View {
        let tint: Color = status.isSuccess ? OriveoTheme.Palette.success : OriveoTheme.Palette.warning
        let icon: String = status.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(status.message)
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.top, 4)
        .padding(.bottom, OriveoTheme.Spacing.md)
        .background(tint.opacity(0.08))
    }
}

struct RelaySecurityModeSummaryRow: View {
    let securityMode: RelayConnectionSecurityMode
    var isDisabled = false
    let onChange: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onChange) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                        securityLabel
                        Text(Self.title(for: securityMode))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.tr("Change", table: .providers))
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: OriveoTheme.Spacing.md) {
                        securityLabel
                        Text(Self.title(for: securityMode))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.tr("Change", table: .providers))
                            .font(OriveoTheme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.primary)
                    }
                }
            }
            .padding(.horizontal, OriveoTheme.Spacing.lg)
            .padding(.vertical, OriveoTheme.Spacing.md)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var securityLabel: some View {
        Label {
            Text(L10n.tr("Connection security", table: .providers))
                .font(OriveoTheme.Typography.body.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
        } icon: {
            Image(systemName: securityMode == .remoteHTTPS || securityMode == .tofuHTTPS
                  ? "lock.shield.fill"
                  : "network")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .frame(minWidth: 32, minHeight: 32)
        }
    }

    static func title(for mode: RelayConnectionSecurityMode) -> String {
        switch mode {
        case .remoteHTTPS:
            return L10n.tr("Public HTTPS", table: .providers)
        case .tofuHTTPS:
            return L10n.tr("Paired HTTPS", table: .providers)
        case .localHTTP:
            return L10n.tr("Local HTTP", table: .providers)
        case .privateVPN:
            return L10n.tr("Private VPN", table: .providers)
        }
    }

    static func detail(for mode: RelayConnectionSecurityMode) -> String {
        switch mode {
        case .remoteHTTPS:
            return L10n.tr("Encrypted connection to a public address.", table: .providers)
        case .tofuHTTPS:
            return L10n.tr("Encrypted connection secured during pairing.", table: .providers)
        case .localHTTP:
            return L10n.tr("For addresses on this device or your LAN. Not encrypted, so no credentials are sent.", table: .providers)
        case .privateVPN:
            return L10n.tr("Reached over a private network such as Tailscale.", table: .providers)
        }
    }
}

struct RelaySecurityModePickerSheet: View {
    let endpoint: String
    let currentMode: RelayConnectionSecurityMode
    let hasCredentialMaterial: Bool
    var allowedModes: Set<RelayConnectionSecurityMode> = Set(RelaySecurityModeSelection.selectableModes)
    let onSelect: (RelayConnectionSecurityMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assessment: RelaySecurityModeSelection.Assessment?
    @State private var pendingCleartextMode: RelayConnectionSecurityMode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                    ForEach(RelaySecurityModeSelection.selectableModes, id: \.rawValue) { mode in
                        modeRow(mode)
                    }

                    if let pendingCleartextMode {
                        confirmationCard(mode: pendingCleartextMode)
                    }
                }
                .padding(OriveoTheme.Spacing.xl)
            }
            .oriveoScreenBackground()
            .navigationTitle(L10n.tr("Connection security", table: .providers))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
            }
            .task(id: endpoint) {
                assessment = await RelaySecurityModeSelection.assess(endpoint: endpoint)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func isAvailable(_ mode: RelayConnectionSecurityMode) -> Bool {
        guard allowedModes.contains(mode) else { return false }
        switch mode {
        case .remoteHTTPS: return true
        case .localHTTP: return assessment?.localHTTPAllowed == true
        case .privateVPN: return assessment?.privateVPNAllowed == true
        case .tofuHTTPS: return false
        }
    }

    private func modeRow(_ mode: RelayConnectionSecurityMode) -> some View {
        let available = isAvailable(mode)
        let isCurrent = mode == currentMode
        let isSuggested = assessment?.suggestedMode == mode
        return Button {
            if mode == .remoteHTTPS {
                onSelect(mode)
                dismiss()
            } else {
                pendingCleartextMode = mode
            }
        } label: {
            HStack(alignment: .top, spacing: OriveoTheme.Spacing.md) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(RelaySecurityModeSummaryRow.title(for: mode))
                            .font(OriveoTheme.Typography.body.weight(.semibold))
                        if isSuggested {
                            Text(L10n.tr("Suggested", table: .providers))
                                .font(OriveoTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(OriveoTheme.Palette.primary)
                        }
                    }
                    Text(RelaySecurityModeSummaryRow.detail(for: mode))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !available, mode != .remoteHTTPS {
                        Text(unavailableMessage(for: mode))
                            .font(OriveoTheme.Typography.caption)
                            .foregroundStyle(OriveoTheme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(OriveoTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .oriveoRoundedSurface(
                fill: OriveoTheme.Palette.surfaceChrome,
                border: isCurrent ? OriveoTheme.Palette.primary.opacity(0.35) : OriveoTheme.Palette.border,
                radius: OriveoTheme.Radius.md,
                shadow: .none
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available || isCurrent)
        .opacity(available ? 1 : 0.62)
    }

    private func unavailableMessage(for mode: RelayConnectionSecurityMode) -> String {
        if !allowedModes.contains(mode) {
            return L10n.tr("This engine requires an encrypted connection for its access token.", table: .providers)
        }
        guard assessment != nil else {
            return L10n.tr("Checking this address...", table: .providers)
        }
        return L10n.tr("Use a local, LAN, link-local, or supported private VPN address.", table: .providers)
    }

    private func confirmationCard(mode: RelayConnectionSecurityMode) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
            Label(
                L10n.tr("Confirm unencrypted connection", table: .providers),
                systemImage: "exclamationmark.shield.fill"
            )
            .font(OriveoTheme.Typography.body.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.warning)

            Text(hasCredentialMaterial
                 ? L10n.tr("Switching to an unencrypted connection also deletes: this connection's key, custom headers, and custom query parameters.", table: .providers)
                 : L10n.tr("This looks like a local or LAN address. Over plain LAN HTTP, Oriveo won't send any credentials.", table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.tr("Keep HTTPS", table: .providers)) {
                pendingCleartextMode = nil
            }
            .buttonStyle(OriveoPrimaryButtonStyle())

            Button(mode == .localHTTP
                   ? L10n.tr("Connect over plain LAN HTTP", table: .providers)
                   : L10n.tr("Use Private VPN", table: .providers)) {
                onSelect(mode)
                dismiss()
            }
            .buttonStyle(OriveoSecondaryButtonStyle())
        }
        .padding(OriveoTheme.Spacing.lg)
        .oriveoRoundedSurface(
            fill: OriveoTheme.Palette.warningSoft,
            border: OriveoTheme.Palette.warning.opacity(0.3),
            radius: OriveoTheme.Radius.md,
            shadow: .none
        )
    }
}

struct RelayConnectionTestStatus: Equatable {
    let isSuccess: Bool
    let message: String

    static func success(_ message: String) -> Self { .init(isSuccess: true, message: message) }
    static func failure(_ message: String) -> Self { .init(isSuccess: false, message: message) }
}
