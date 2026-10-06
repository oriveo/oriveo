import SwiftUI

/// The "Tools" panel in chat: which servers are enabled for this conversation.
///
/// `McpToolPanelState` decides between three shapes: the current connection cannot use tools, there are no
/// servers yet, or the server list.
struct McpToolPanelSheet: View {
    let state: McpToolPanelState
    let onToggle: (_ serverId: UUID, _ enabled: Bool) -> Void
    let onReauthorize: (_ serverId: UUID) -> Void
    let onManage: () -> Void
    let onAddServer: () -> Void
    let onSwitchModel: () -> Void

    var body: some View {
        if !state.availability.isAvailable {
            unsupported
        } else if !state.hasServers {
            empty
        } else {
            servers
        }
    }

    // MARK: Server list

    private var servers: some View {
        McpFittedSheet(fallbackHeight: 460) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    title(L10n.tr("Tools for this chat", table: .mcp))
                    Text(L10n.tr("When on, the model can use these services' tools while answering.", table: .mcp))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                serverList(interactive: true)
                footnote
            }
        } footer: {
            Button(action: onManage) {
                HStack(spacing: 6) {
                    Text(L10n.tr("Manage MCP servers", table: .mcp))
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func serverList(interactive: Bool) -> some View {
        McpGroupCard {
            ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(OriveoTheme.Palette.border)
                        .frame(height: 1)
                        .padding(.horizontal, 14)
                }
                serverRow(row, interactive: interactive)
            }
        }
    }

    private func serverRow(_ row: McpToolPanelServerRow, interactive: Bool) -> some View {
        let dimmed = !interactive || !row.canToggle && row.status != .needsAuth
        return HStack(spacing: 12) {
            McpServerIconView(name: row.name, iconURL: row.iconURL, serverURL: row.serverURL)
                .opacity(dimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                // The server name is third-party text and is not translated.
                Text(row.name)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(dimmed ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle(for: row))
                    .font(.system(size: 13))
                    .foregroundStyle(subtitleColor(for: row, interactive: interactive))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if interactive, row.status == .needsAuth {
                Button {
                    onReauthorize(row.id)
                } label: {
                    Text(L10n.tr("Sign in again", table: .mcp))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            } else {
                Toggle("", isOn: Binding(
                    get: { interactive && row.isEnabled },
                    set: { onToggle(row.id, $0) }
                ))
                .labelsHidden()
                .tint(OriveoTheme.Palette.primary)
                .disabled(!interactive || !row.canToggle)
                .accessibilityLabel(Text(row.name))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }

    private func subtitle(for row: McpToolPanelServerRow) -> String {
        switch row.status {
        case .ready:
            return String(format: L10n.tr("Tools: %d", table: .mcp), row.toolCount)
        case .needsAuth:
            return L10n.tr("Sign-in expired", table: .mcp)
        case let .unreachable(lastSuccessAt):
            guard let lastSuccessAt else { return L10n.tr("Can't connect", table: .mcp) }
            return String(
                format: L10n.tr("Can't connect · last worked %@", table: .mcp),
                Self.relativeTime(lastSuccessAt)
            )
        case .needsAddress:
            return L10n.tr("Address needs to be entered again", table: .mcp)
        }
    }

    private func subtitleColor(for row: McpToolPanelServerRow, interactive: Bool) -> Color {
        guard interactive else { return OriveoTheme.Palette.textTertiary }
        switch row.status {
        case .needsAuth, .needsAddress: return OriveoTheme.Palette.warningText
        case .ready, .unreachable: return OriveoTheme.Palette.textTertiary
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if state.truncated {
            Text(String(
                format: L10n.tr("More than %1$d tools are on. Only %2$d will be sent, taken in turn from each server.", table: .mcp),
                state.maxToolsPerRequest, state.maxToolsPerRequest
            ))
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.warningText)
            .fixedSize(horizontal: false, vertical: true)
        } else if state.outboundToolCount > 0 {
            Text(String(
                format: L10n.tr(
                    "Tools on: %1$d. Tool descriptions are sent with every request, about %2$@ tokens, billed at your model's price.",
                    table: .mcp
                ),
                state.outboundToolCount, Self.grouped(state.estimatedTokens)
            ))
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: No servers yet

    private var empty: some View {
        McpFittedSheet(fallbackHeight: 320) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(OriveoTheme.Palette.primarySoft)
                    Image(systemName: "powerplug")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                }
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)
                title(L10n.tr("No tools yet", table: .mcp))
                Text(L10n.tr(
                    "Connect an MCP server and the model can look things up in Linear, write to Notion, or use tools you host yourself, right in the chat.",
                    table: .mcp
                ))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Button(action: onAddServer) {
                Text(L10n.tr("Add MCP server", table: .mcp))
            }
            .buttonStyle(McpPrimaryButtonStyle())
        }
    }

    // MARK: Current model cannot use tools

    private var unsupported: some View {
        McpFittedSheet(fallbackHeight: 420) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                title(L10n.tr("Tools for this chat", table: .mcp))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("This model can't use tools", table: .mcp))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.warningText)
                    Text(unsupportedReason)
                        .font(.system(size: 13.5))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(OriveoTheme.Palette.warningSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OriveoTheme.Palette.warning.opacity(0.35), lineWidth: 1)
                )
                if state.hasServers {
                    serverList(interactive: false)
                }
            }
        } footer: {
            Button(action: onSwitchModel) {
                Text(L10n.tr("Switch model", table: .mcp))
            }
            .buttonStyle(McpSecondaryButtonStyle())
        }
    }

    private var unsupportedReason: String {
        L10n.tr("This model doesn't support tool calling. Switch to another model to use tools.", table: .mcp)
    }

    // MARK: Shared

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: AppLocalization.currentLanguage.rawValue)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: AppLocalization.currentLanguage.rawValue)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
