import SwiftUI

// Read-only connection-security summary row and the mode picker page. The local-compute setup
// page and the connection editor share the picker; the editor builds its own address and
// security rows through `RelayEditBoardModel` and `RelayEditBoardView`.

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
                (isCurrent ? PhosphorIcon.checkCircle.image(.duotone) : PhosphorIcon.circle.image(.regular))
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
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
