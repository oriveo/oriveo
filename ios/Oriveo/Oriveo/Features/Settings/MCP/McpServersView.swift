import SwiftUI

/// MCP servers: the empty state and the server list.
///
/// Both "MCP servers" in Settings and "Manage MCP servers" in the chat tool panel lead here.
struct McpServersView: View {
    @Environment(AppState.self) private var appState
    @State private var servers: [McpServerSummary] = []
    /// The first read of local storage has not returned yet: do not draw the empty state, so people who already
    /// have servers never see a flash of "no servers yet".
    @State private var loaded = false

    var body: some View {
        McpServersContent(
            servers: servers,
            loaded: loaded,
            onBack: { appState.pop() },
            onAddServer: { appState.navigation.attemptNavigate(to: .mcpAddServer) },
            onOpenServer: { appState.navigation.attemptNavigate(to: .mcpServerDetail(serverID: $0, intent: .view)) }
        )
        .refreshable { await refresh() }
        // Re-read when coming back from the add page or the detail page.
        .onAppear(perform: reload)
    }

    private func reload() {
        servers = (try? appState.mcpServerDirectory.overview(uid: appState.sessionPartitionUID)) ?? []
        loaded = true
    }

    /// Pull to refresh: re-probe the connection status of every server.
    private func refresh() async {
        let uid = appState.sessionPartitionUID
        if let actions = try? McpServerManagement.actions(
            directory: appState.mcpServerDirectory, uid: uid,
            reauthorization: appState.mcpReauthorizationCoordinator
        ) {
            await actions.probeAll()
        }
        reload()
    }
}

struct McpServersContent: View {
    let servers: [McpServerSummary]
    let loaded: Bool
    let onBack: @MainActor () -> Void
    let onAddServer: @MainActor () -> Void
    let onOpenServer: @MainActor (UUID) -> Void

    private var isEmpty: Bool { loaded && servers.isEmpty }

    var body: some View {
        McpPageScaffold(
            title: L10n.tr("MCP servers", table: .mcp),
            onBack: onBack
        ) {
            if !servers.isEmpty {
                Button(action: onAddServer) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(OriveoFlatIconButtonStyle())
                .padding(.trailing, -11)
                .accessibilityLabel(L10n.tr("Add server", table: .mcp))
            }
        } content: {
            if isEmpty {
                emptyState
            } else if loaded {
                list
            }
        } footer: {
            if isEmpty {
                Button(action: onAddServer) {
                    Text(L10n.tr("Add server", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
            }
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(OriveoTheme.Palette.primarySoft)
                Image(systemName: "powerplug")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
            Text(L10n.tr("Let the model use your services", table: .mcp))
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.tr(
                "MCP servers turn services like Linear and Notion, or tools you host yourself, into things the model can do in a chat.",
                table: .mcp
            ))
            .font(OriveoTheme.Typography.body)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 28)

        // The three promises reuse the style of the privacy card in Settings: a green check plus one sentence.
        McpCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                promise(L10n.tr("Sign-in details stay on this device", table: .mcp))
                promise(L10n.tr("Anything that changes your data asks you first", table: .mcp))
                promise(L10n.tr("Turn it on or off per chat", table: .mcp))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(OriveoTheme.Palette.success)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    // MARK: Server list

    @ViewBuilder
    private var list: some View {
        McpSectionTitle(
            title: L10n.tr("Added", table: .mcp),
            trailing: String(format: L10n.tr("%d items", table: .mcp), servers.count)
        )
        VStack(spacing: 12) {
            ForEach(servers) { server in
                Button {
                    onOpenServer(server.id)
                } label: {
                    serverCard(server)
                }
                .buttonStyle(.plain)
            }
        }
        McpFootnote(text: L10n.tr(
            "Tools come from third parties, and what they return is passed to the model. Only connect servers you trust.",
            table: .mcp
        ))
    }

    private func serverCard(_ server: McpServerSummary) -> some View {
        McpCard(padding: 16) {
            HStack(spacing: 14) {
                McpServerIconView(name: server.record.name, iconURL: server.record.iconURL, size: 44, serverURL: server.record.url)
                VStack(alignment: .leading, spacing: 6) {
                    // The server name is third-party text and is not translated.
                    Text(server.record.name)
                        .font(OriveoTheme.Typography.title2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        McpHealthPill(health: server.health)
                        if let caption = McpHealthCopy.caption(server) {
                            Text(caption)
                                .font(OriveoTheme.Typography.caption)
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
        }
        .contentShape(Rectangle())
    }
}

/// Status pill of one server (shared by the list card and the hero card on the detail page).
struct McpHealthPill: View {
    let health: McpServerHealth

    var body: some View {
        switch health {
        case .connected: McpStatusPill(text: L10n.tr("Connected", table: .mcp), tone: .success)
        case .needsAuth: McpStatusPill(text: L10n.tr("Sign-in expired", table: .mcp), tone: .warning)
        case .unreachable: McpStatusPill(text: L10n.tr("Can't connect", table: .mcp), tone: .neutral)
        case .needsReview: McpStatusPill(text: L10n.tr("Tools changed", table: .mcp), tone: .primary)
        case .needsAddress: McpStatusPill(text: L10n.tr("Address needed", table: .mcp), tone: .warning)
        }
    }
}

enum McpHealthCopy {
    /// The caption next to the status pill.
    static func caption(_ server: McpServerSummary, now: Date = Date()) -> String? {
        switch server.health {
        case .connected:
            return String(format: L10n.tr("Tools: %d", table: .mcp), server.toolCount)
        case .needsAuth:
            return L10n.tr("Needs sign-in again", table: .mcp)
        case .unreachable:
            guard let lastSuccessAt = server.lastSuccessAt else { return nil }
            return String(
                format: L10n.tr("Last worked %@", table: .mcp),
                McpToolPanelSheet.relativeTime(lastSuccessAt, now: now)
            )
        case .needsReview:
            return L10n.tr("Review before use", table: .mcp)
        case .needsAddress:
            // The pill already says "address required"; do not repeat it next to it.
            return nil
        }
    }

    /// Subtitle of the "MCP servers" row in Settings: nothing before the data is read; a short hint when there are
    /// no servers; the trailing part only when something needs attention.
    static func settingsSubtitle(_ summary: McpSettingsEntrySummary?) -> String? {
        guard let summary else { return nil }
        if summary.serverCount == 0 { return L10n.tr("Let the model use your services", table: .mcp) }
        if summary.attentionCount > 0 {
            return String(
                format: L10n.tr("Servers: %1$d · Need attention: %2$d", table: .mcp),
                summary.serverCount, summary.attentionCount
            )
        }
        return String(format: L10n.tr("Servers: %d", table: .mcp), summary.serverCount)
    }
}

/// The "Tools & connections" group in Settings, holding the MCP servers row.
struct McpSettingsSection: View {
    let iconColor: Color
    let mcpSummary: McpSettingsEntrySummary?
    let onOpenMcpServers: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            flatSectionHeader(L10n.tr("Tools & connections", table: .mcp))

            flatGroup {
                flatTapRow(action: onOpenMcpServers) {
                    SettingsRow(
                        icon: "wrench.adjustable.fill",
                        title: L10n.tr("MCP servers", table: .mcp),
                        subtitle: McpHealthCopy.settingsSubtitle(mcpSummary),
                        iconColor: iconColor
                    )
                }
            }
        }
    }
}
