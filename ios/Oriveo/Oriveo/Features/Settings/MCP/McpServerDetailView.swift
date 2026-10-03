import SwiftUI

/// Server detail and the sheets and dialogs layered over it.
struct McpServerDetailView: View {
    let serverID: UUID
    let intent: McpServerDetailIntent

    @Environment(AppState.self) private var appState
    @State private var model: McpServerDetailModel?

    var body: some View {
        Group {
            if let model {
                McpServerDetailContent(state: model.state, actions: McpServerDetailActions(model: model) { appState.pop() })
                    .sheet(isPresented: sheetBinding(model)) { sheet(model) }
                    .onChange(of: model.isGone) { _, gone in
                        if gone { appState.pop() }
                    }
            } else {
                Color.clear.oriveoScreenBackground()
            }
        }
        .onAppear {
            if model == nil { model = makeModel() }
            model?.appear()
        }
    }

    private func sheetBinding(_ model: McpServerDetailModel) -> Binding<Bool> {
        Binding(
            get: {
                switch model.state.overlay {
                case .toolPermission, .authPrompt, .tokenEntry, .toolsChanged: return true
                case .removeConfirm, nil: return false
                }
            },
            set: { presented in
                if !presented { model.dismissOverlay() }
            }
        )
    }

    @ViewBuilder
    private func sheet(_ model: McpServerDetailModel) -> some View {
        let actions = McpServerDetailActions(model: model) { appState.pop() }
        if let detail = model.state.detail {
            switch model.state.overlay {
            case .toolPermission(let toolName):
                if let tool = detail.snapshots.first(where: { $0.toolName == toolName }) {
                    McpToolPermissionSheet(
                        serverName: detail.record.name, tool: tool, permission: detail.permission(for: tool),
                        onSelect: { actions.setPermission($0, toolName) }
                    )
                }
            case let .authPrompt(authorizationHost, serverHost):
                McpAuthPromptSheet(
                    serverName: detail.record.name, iconURL: detail.record.iconURL,
                    authorizationHost: authorizationHost, serverHost: serverHost,
                    onContinue: actions.approveReauthorization, onCancel: actions.dismissOverlay
                )
            case .tokenEntry:
                McpTokenEntrySheet(
                    token: model.state.token, rejected: model.state.tokenRejected, busy: model.state.busy,
                    onChange: actions.setToken, onSave: actions.submitToken, onCancel: actions.dismissOverlay
                )
            case .toolsChanged:
                McpToolsChangedSheet(
                    serverName: detail.record.name, iconURL: detail.record.iconURL,
                    changes: model.state.pendingChanges, changedAgain: model.state.changedAgain, busy: model.state.busy,
                    onConfirm: actions.confirmChanges, onPause: actions.pauseServer
                )
            case .removeConfirm, nil:
                EmptyView()
            }
        }
    }

    private func makeModel() -> McpServerDetailModel {
        let uid = appState.sessionPartitionUID
        let directory = appState.mcpServerDirectory
        let reauthorization = appState.mcpReauthorizationCoordinator
        return McpServerDetailModel(serverId: serverID, intent: intent, dependencies: .init(
            uid: uid,
            loadDetail: { try directory.detail(serverId: $0, uid: uid) },
            actions: { try McpServerManagement.actions(directory: directory, uid: uid, reauthorization: reauthorization) },
            setPermission: { permission, serverId, toolName in
                try directory.setToolPermission(permission, serverId: serverId, toolName: toolName, uid: uid)
            },
            remove: { try directory.remove(serverId: $0, uid: uid) },
            restoreEndpoint: { try directory.restoreEndpoint(serverId: $0, urlString: $1, uid: uid) }
        ))
    }
}

struct McpServerDetailActions {
    var onBack: @MainActor () -> Void = {}
    var reloadTools: @MainActor () -> Void = {}
    var reauthorize: @MainActor () -> Void = {}
    var approveReauthorization: @MainActor () -> Void = {}
    var reviewChanges: @MainActor () -> Void = {}
    var confirmChanges: @MainActor () -> Void = {}
    var pauseServer: @MainActor () -> Void = {}
    var openToolPermission: @MainActor (String) -> Void = { _ in }
    var setPermission: @MainActor (McpToolPermission, String) -> Void = { _, _ in }
    var toggleReadOnly: @MainActor () -> Void = {}
    var toggleChanging: @MainActor () -> Void = {}
    var setToken: @MainActor (String) -> Void = { _ in }
    var submitToken: @MainActor () -> Void = {}
    var setAddress: @MainActor (String) -> Void = { _ in }
    var saveAddress: @MainActor () -> Void = {}
    var askRemove: @MainActor () -> Void = {}
    var confirmRemove: @MainActor () -> Void = {}
    var dismissOverlay: @MainActor () -> Void = {}

    init() {}

    init(model: McpServerDetailModel, onBack: @escaping @MainActor () -> Void) {
        self.onBack = onBack
        reloadTools = { model.reloadTools() }
        reauthorize = { model.beginReauthorization() }
        approveReauthorization = { model.approveReauthorization() }
        reviewChanges = { model.reviewChanges() }
        confirmChanges = { model.confirmChanges() }
        pauseServer = { model.pauseServer() }
        openToolPermission = { model.openToolPermission($0) }
        setPermission = { model.setPermission($0, toolName: $1) }
        toggleReadOnly = { model.toggleReadOnlyExpanded() }
        toggleChanging = { model.toggleChangingExpanded() }
        setToken = { model.setToken($0) }
        submitToken = { model.submitToken() }
        setAddress = { model.setAddress($0) }
        saveAddress = { model.saveAddress() }
        askRemove = { model.askRemove() }
        confirmRemove = { model.confirmRemove() }
        dismissOverlay = { model.dismissOverlay() }
    }
}

struct McpServerDetailContent: View {
    let state: McpServerDetailUiState
    let actions: McpServerDetailActions

    /// Number of tools shown per group by default; the rest are collapsed.
    static let collapsedToolCount = 3

    var body: some View {
        McpPageScaffold(
            title: state.detail?.record.name ?? "",
            onBack: actions.onBack
        ) {
            if let detail = state.detail {
                hero(detail)
                // When the address is rejected the error sits right under the input field, so no extra notice block.
                if let notice = state.notice, notice != .addressRejected {
                    noticeBlock(notice)
                }
                if detail.snapshots.isEmpty {
                    if detail.health == .connected {
                        McpFootnote(
                            text: L10n.tr("This server doesn't offer any tools.", table: .mcp),
                            tone: OriveoTheme.Palette.textSecondary
                        )
                    }
                } else {
                    toolGroup(
                        detail, readOnly: true, tools: detail.readOnlyTools,
                        expanded: state.expandedReadOnly, toggle: actions.toggleReadOnly
                    )
                    toolGroup(
                        detail, readOnly: false, tools: detail.changingTools,
                        expanded: state.expandedChanging, toggle: actions.toggleChanging
                    )
                }
                Button(action: actions.askRemove) {
                    Text(L10n.tr("Remove server", table: .mcp))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(McpPillTone.danger.foreground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        } footer: {
            EmptyView()
        }
        .overlay {
            if state.overlay == .removeConfirm, let detail = state.detail {
                McpRemoveConfirmDialog(
                    serverName: detail.record.name, onRemove: actions.confirmRemove, onCancel: actions.dismissOverlay
                )
            }
        }
    }

    // MARK: Hero card

    private func hero(_ detail: McpServerDetail) -> some View {
        McpCard {
            VStack(alignment: .leading, spacing: 16) {
                McpHeroHeader(name: detail.record.name, iconURL: detail.record.iconURL) {
                    HStack(spacing: 8) {
                        McpHealthPill(health: detail.health)
                        if let caption = Self.heroCaption(detail) {
                            Text(caption)
                                .font(OriveoTheme.Typography.caption)
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                VStack(spacing: 0) {
                    keyValue(L10n.tr("Address", table: .mcp), Self.displayAddress(detail.record.url), monospaced: true)
                    hairline
                    keyValue(L10n.tr("Sign-in", table: .mcp), Self.signInLabel(detail.signIn), monospaced: false)
                    hairline
                    keyValue(
                        L10n.tr("Last connected", table: .mcp),
                        detail.summary.lastSuccessAt.map { Self.dateLabel($0) } ?? L10n.tr("Never", table: .mcp),
                        monospaced: false
                    )
                }
                heroAction(detail)
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1)
    }

    private func keyValue(_ label: String, _ value: String, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 14, design: .monospaced) : .system(size: 15, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func heroAction(_ detail: McpServerDetail) -> some View {
        switch detail.health {
        case .needsAuth:
            Button(action: actions.reauthorize) {
                busyLabel(L10n.tr("Sign in again", table: .mcp), tint: .white)
            }
            .buttonStyle(McpPrimaryButtonStyle())
            .disabled(state.busy)
        case .needsAddress:
            VStack(alignment: .leading, spacing: 12) {
                McpInputField(
                    label: L10n.tr("Server address", table: .mcp),
                    text: Binding(get: { state.address }, set: actions.setAddress),
                    placeholder: "https://",
                    hint: L10n.tr(
                        "This server's full address isn't on this device. Enter it again to keep using it.",
                        table: .mcp
                    ),
                    error: state.notice == .addressRejected
                        ? L10n.tr("Enter the full address of this same server, starting with https://", table: .mcp)
                        : nil,
                    monospaced: true,
                    keyboard: .URL
                )
                Button(action: actions.saveAddress) {
                    busyLabel(L10n.tr("Save"), tint: OriveoTheme.Palette.primaryTextSafe)
                }
                .buttonStyle(McpSoftButtonStyle())
                .disabled(state.busy || state.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .needsReview:
            Button(action: actions.reviewChanges) {
                Text(L10n.tr("Review changes", table: .mcp))
            }
            .buttonStyle(McpSoftButtonStyle())
            .disabled(state.busy)
        case .connected, .unreachable:
            Button(action: actions.reloadTools) {
                busyLabel(L10n.tr("Reload tools", table: .mcp), tint: OriveoTheme.Palette.primaryTextSafe)
            }
            .buttonStyle(McpSoftButtonStyle())
            .disabled(state.busy)
        }
    }

    private func busyLabel(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            if state.busy {
                ProgressView().controlSize(.small).tint(tint)
            }
            Text(text)
        }
    }

    static func heroCaption(_ detail: McpServerDetail) -> String? {
        switch detail.health {
        case .needsAuth: return L10n.tr("Tools unavailable for now", table: .mcp)
        case .connected, .needsReview:
            return String(format: L10n.tr("Tools: %d", table: .mcp), detail.summary.toolCount)
        case .unreachable, .needsAddress: return McpHealthCopy.caption(detail.summary)
        }
    }

    /// Address for display: strips `https://`.
    static func displayAddress(_ url: String) -> String {
        url.hasPrefix("https://") ? String(url.dropFirst("https://".count)) : url
    }

    static func signInLabel(_ signIn: McpServerSignIn) -> String {
        switch signIn {
        case .browser: return L10n.tr("Browser sign-in", table: .mcp)
        case .token: return L10n.tr("Access token", table: .mcp)
        case .notNeeded: return L10n.tr("Not needed", table: .mcp)
        }
    }

    static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLocalization.currentLanguage.rawValue)
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func noticeBlock(_ notice: McpServerDetailNotice) -> some View {
        switch notice {
        case .signInNotCompleted:
            return McpNoticeBlock(
                title: L10n.tr("Sign-in wasn't completed", table: .mcp),
                message: L10n.tr(
                    "The sign-in page was closed, or the service didn't approve the request. Nothing has changed.",
                    table: .mcp
                ),
                tone: .warning
            )
        case .unreachable:
            return McpNoticeBlock(
                title: L10n.tr("Can't reach this server", table: .mcp),
                message: L10n.tr("Check that this device can reach it right now, then try again.", table: .mcp),
                tone: .danger
            )
        case .removeFailed:
            return McpNoticeBlock(
                title: L10n.tr("Couldn't remove this server", table: .mcp),
                message: L10n.tr("The sign-in details on this device couldn't be deleted. Try again.", table: .mcp),
                tone: .danger
            )
        case .addressRejected:
            return McpNoticeBlock(
                title: L10n.tr("Address not saved", table: .mcp),
                message: L10n.tr("Enter the full address of this same server, starting with https://", table: .mcp),
                tone: .warning
            )
        }
    }

    // MARK: Tool groups

    @ViewBuilder
    private func toolGroup(
        _ detail: McpServerDetail,
        readOnly: Bool,
        tools: [McpToolSnapshot],
        expanded: Bool,
        toggle: @escaping @MainActor () -> Void
    ) -> some View {
        if !tools.isEmpty {
            let visible = expanded ? tools : Array(tools.prefix(Self.collapsedToolCount))
            let hidden = tools.count - visible.count
            VStack(alignment: .leading, spacing: 10) {
                McpSectionTitle(
                    title: McpPermissionCopy.group(readOnly: readOnly),
                    trailing: String(format: L10n.tr("%d items", table: .mcp), tools.count)
                )
                McpCard(padding: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.toolName) { index, tool in
                        if index > 0 {
                            hairline.padding(.horizontal, 16)
                        }
                        toolRow(detail, tool)
                    }
                    if hidden > 0 {
                        hairline.padding(.horizontal, 16)
                        Button(action: toggle) {
                            Text(String(format: L10n.tr("Show %d more", table: .mcp), hidden))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .opacity(state.toolsDisabled ? 0.5 : 1)
            .disabled(state.toolsDisabled)
        }
    }

    private func toolRow(_ detail: McpServerDetail, _ tool: McpToolSnapshot) -> some View {
        let permission = detail.permission(for: tool)
        return Button {
            actions.openToolPermission(tool.toolName)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // Tool titles are shown verbatim as the server provides them, never translated.
                    Text(tool.title)
                        .font(.system(size: 16))
                        .foregroundStyle(
                            permission == .off ? OriveoTheme.Palette.textTertiary : OriveoTheme.Palette.textPrimary
                        )
                        .lineLimit(1)
                    if let caption = Self.toolCaption(tool) {
                        Text(caption)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OriveoTheme.Palette.warningText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(McpPermissionCopy.label(permission))
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(McpPermissionCopy.label(permission))
    }

    static func toolCaption(_ tool: McpToolSnapshot) -> String? {
        if tool.oversized { return L10n.tr("Too large to send to the model", table: .mcp) }
        if tool.pendingReview { return L10n.tr("Review before use", table: .mcp) }
        return nil
    }
}

// MARK: - Single-tool permission

struct McpToolPermissionSheet: View {
    let serverName: String
    let tool: McpToolSnapshot
    let permission: McpToolPermission
    let onSelect: @MainActor (McpToolPermission) -> Void

    var body: some View {
        McpFittedSheet(fallbackHeight: 520) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tool.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(serverName) · \(McpPermissionCopy.group(readOnly: tool.readOnly))")
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("Description from the server (original)", table: .mcp))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    // Shown exactly as the server provides it, not translated.
                    Text(Self.descriptionText(tool))
                        .font(.system(size: 14))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OriveoTheme.Palette.surfaceInset)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                        )
                }
                VStack(spacing: 10) {
                    Button { onSelect(.ask) } label: {
                        option(.ask)
                    }
                    .buttonStyle(.plain)
                    Button { onSelect(.auto) } label: {
                        option(.auto)
                    }
                    .buttonStyle(.plain)
                    Button { onSelect(.off) } label: {
                        option(.off)
                    }
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            EmptyView()
        }
    }

    static func descriptionText(_ tool: McpToolSnapshot) -> String {
        let text = (tool.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L10n.tr("The server didn't provide a description.", table: .mcp) : text
    }

    /// Hints for the three options. For a tool that modifies data, the hint for "run automatically" is the warning.
    static func hint(_ option: McpToolPermission, tool: McpToolSnapshot, serverName: String) -> String {
        switch option {
        case .ask: return L10n.tr("Shows you what the model is about to send before each call.", table: .mcp)
        case .auto:
            return tool.readOnly
                ? L10n.tr("The model can use this tool without asking.", table: .mcp)
                : String(format: L10n.tr("The model can change your data in %@ without asking.", table: .mcp), serverName)
        case .off: return L10n.tr("This tool isn't offered to the model.", table: .mcp)
        }
    }

    private func option(_ option: McpToolPermission) -> some View {
        let selected = option == permission
        let recommended = option == McpToolPermission.defaultFor(readOnly: tool.readOnly)
        let warns = option == .auto && !tool.readOnly
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected ? OriveoTheme.Palette.primary : OriveoTheme.Palette.borderStrong)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(McpPermissionCopy.label(option))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    if recommended {
                        McpStatusPill(text: L10n.tr("Recommended", table: .mcp), tone: .primary)
                    }
                }
                Text(Self.hint(option, tool: tool, serverName: serverName))
                    .font(.system(size: 13.5))
                    .foregroundStyle(warns ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? OriveoTheme.Palette.primarySoft : OriveoTheme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? OriveoTheme.Palette.primary.opacity(0.45) : OriveoTheme.Palette.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Access-token input for an already saved server

struct McpTokenEntrySheet: View {
    let token: String
    let rejected: Bool
    let busy: Bool
    let onChange: @MainActor (String) -> Void
    let onSave: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        McpFittedSheet(fallbackHeight: 380) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Paste a new access token", table: .mcp))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("Create an access token in the service's settings and paste it below.", table: .mcp))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                McpInputField(
                    label: L10n.tr("Access token", table: .mcp),
                    text: Binding(get: { token }, set: onChange),
                    placeholder: L10n.tr("Paste token", table: .mcp),
                    hint: L10n.tr("The token stays on this device.", table: .mcp),
                    error: rejected ? L10n.tr("The server didn't accept this token.", table: .mcp) : nil,
                    monospaced: true,
                    isSecure: true
                )
            }
        } footer: {
            VStack(spacing: 4) {
                Button(action: onSave) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(L10n.tr("Save"))
                    }
                }
                .buttonStyle(McpPrimaryButtonStyle())
                .disabled(busy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                Button(action: onCancel) {
                    Text(L10n.tr("Cancel"))
                }
                .buttonStyle(McpTextButtonStyle())
            }
        }
    }
}

// MARK: - Tools were updated

struct McpToolsChangedSheet: View {
    let serverName: String
    let iconURL: String?
    let changes: [McpPendingToolChange]
    let changedAgain: Bool
    let busy: Bool
    let onConfirm: @MainActor () -> Void
    let onPause: @MainActor () -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        McpFittedSheet(fallbackHeight: 520) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    McpServerIconView(name: serverName, iconURL: iconURL, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: L10n.tr("%@'s tools have changed", table: .mcp), serverName))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.tr("For safety, changed tools aren't offered to the model until you confirm.", table: .mcp))
                            .font(OriveoTheme.Typography.caption)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if changedAgain {
                    Text(L10n.tr("Some tools changed again while you were confirming. Take another look.", table: .mcp))
                        .font(.system(size: 13.5))
                        .foregroundStyle(OriveoTheme.Palette.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                McpGroupCard {
                    ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                        if index > 0 {
                            Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1).padding(.horizontal, 14)
                        }
                        row(change)
                    }
                }
            }
        } footer: {
            VStack(spacing: 4) {
                Button(action: onConfirm) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(L10n.tr("Confirm and keep using", table: .mcp))
                    }
                }
                .buttonStyle(McpPrimaryButtonStyle())
                .disabled(busy)
                Button(action: onPause) {
                    Text(L10n.tr("Pause this server for now", table: .mcp))
                }
                .buttonStyle(McpTextButtonStyle())
                .disabled(busy)
            }
        }
    }

    static func pill(_ kind: McpToolChangeKind) -> (text: String, tone: McpPillTone) {
        switch kind {
        case .added: return (L10n.tr("New", table: .mcp), .primary)
        case .changed: return (L10n.tr("Description changed", table: .mcp), .warning)
        case .removed: return (L10n.tr("Removed", table: .mcp), .neutral)
        }
    }

    /// Row hint: "group · permission after confirmation"; removed tools read "no longer provided by the server".
    static func hint(_ change: McpPendingToolChange) -> String {
        guard change.kind != .removed, let permission = change.permissionAfter else {
            return L10n.tr("No longer offered by the server", table: .mcp)
        }
        return "\(McpPermissionCopy.group(readOnly: change.readOnly)) · \(McpPermissionCopy.label(permission))"
    }

    private func row(_ change: McpPendingToolChange) -> some View {
        let pill = Self.pill(change.kind)
        let isExpanded = expanded.contains(change.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                McpStatusPill(text: pill.text, tone: pill.tone)
                VStack(alignment: .leading, spacing: 2) {
                    // Tool titles are shown verbatim as the server provides them, never translated.
                    Text(change.title)
                        .font(.system(size: 16))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(2)
                    Text(Self.hint(change))
                        .font(.system(size: 13))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if change.kind == .changed {
                    Button {
                        if isExpanded { expanded.remove(change.id) } else { expanded.insert(change.id) }
                    } label: {
                        Text(isExpanded ? L10n.tr("Hide", table: .mcp) : L10n.tr("See what changed", table: .mcp))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 84, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if isExpanded {
                comparison(change)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
    }

    /// Old versus new description. The old one only exists right after a reload (only the latest snapshot is
    /// stored locally).
    private func comparison(_ change: McpPendingToolChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            comparisonBlock(
                L10n.tr("Before", table: .mcp),
                change.previousDescription ?? L10n.tr("The earlier description isn't kept on this device.", table: .mcp)
            )
            comparisonBlock(
                L10n.tr("Now", table: .mcp),
                (change.description ?? "").isEmpty
                    ? L10n.tr("The server didn't provide a description.", table: .mcp)
                    : change.description ?? ""
            )
        }
    }

    private func comparisonBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OriveoTheme.Palette.surfaceInset))
    }
}

// MARK: - Remove confirmation (centered dialog)

struct McpRemoveConfirmDialog: View {
    let serverName: String
    let onRemove: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        ZStack {
            OriveoTheme.Palette.scrim
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Text(String(format: L10n.tr("Remove %@?", table: .mcp), serverName))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.tr(
                    "This deletes the sign-in details saved on this device and removes the server from the list. Tool records in existing chats are kept.",
                    table: .mcp
                ))
                .font(OriveoTheme.Typography.caption)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                Button(action: onRemove) {
                    Text(L10n.tr("Remove", table: .mcp))
                }
                .buttonStyle(McpDangerButtonStyle())
                .padding(.top, 22)
                Button(action: onCancel) {
                    Text(L10n.tr("Cancel"))
                }
                .buttonStyle(McpTextButtonStyle())
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 14)
            .frame(maxWidth: 320)
            .oriveoRoundedSurface(fill: OriveoTheme.Palette.background, border: .clear, radius: 28, shadow: .lifted)
            .padding(.horizontal, 35)
            .accessibilityAddTraits(.isModal)
        }
    }
}
