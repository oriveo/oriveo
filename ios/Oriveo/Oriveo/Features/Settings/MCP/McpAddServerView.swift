import SwiftUI

/// Add server. The page only draws `McpAddUiState`; probing, sign-in and persistence sit behind `McpAddServerModel`.
struct McpAddServerView: View {
    @Environment(AppState.self) private var appState
    @State private var model: McpAddServerModel?

    var body: some View {
        Group {
            if let model {
                McpAddServerContent(
                    state: model.state,
                    actions: McpAddServerActions(model: model, onBack: { appState.pop() })
                )
                .sheet(isPresented: authPromptBinding(model)) {
                    McpAuthPromptSheet(
                        serverName: model.state.displayName,
                        iconURL: nil,
                        authorizationHost: authorizationHost(model.state) ?? "",
                        serverHost: model.state.host,
                        onContinue: { model.approveSignIn() },
                        onCancel: { model.cancel() }
                    )
                }
                .onChange(of: model.state.completedServerId) { _, completed in
                    if completed != nil { appState.pop() }
                }
            } else {
                Color.clear.oriveoScreenBackground()
            }
        }
        .onAppear {
            if model == nil { model = makeModel() }
        }
        .onDisappear { model?.close() }
    }

    private func authorizationHost(_ state: McpAddUiState) -> String? {
        if case .progress(.authPrompt, let host, _) = state.screen { return host }
        return nil
    }

    private func authPromptBinding(_ model: McpAddServerModel) -> Binding<Bool> {
        Binding(
            get: { authorizationHost(model.state) != nil },
            // The sheet cannot be dismissed by dragging; reaching this means the state already left the pre-sign-in prompt.
            set: { _ in }
        )
    }

    private func makeModel() -> McpAddServerModel {
        let uid = appState.sessionPartitionUID
        let directory = appState.mcpServerDirectory
        let runtimeConfig = MetadataClient.shared.syncMcpRuntimeConfig()
        return McpAddServerModel(dependencies: .init(
            uid: uid,
            makeCoordinator: {
                let authorizer = directory.authorizer(for: uid)
                let probe = McpAddProbe(
                    runtimeConfig: runtimeConfig, authorizer: authorizer, credentialStore: directory.credentialStore
                )
                return try directory.makeAddCoordinator(probe: probe, uid: uid, runtimeConfig: runtimeConfig)
            }
        ))
    }
}

/// Page actions. Kept as a value so snapshot tests can draw every state without building a model.
struct McpAddServerActions {
    var setURL: @MainActor (String) -> Void = { _ in }
    var setName: @MainActor (String) -> Void = { _ in }
    var setToken: @MainActor (String) -> Void = { _ in }
    var connect: @MainActor () -> Void = {}
    var retry: @MainActor () -> Void = {}
    var connectWithToken: @MainActor () -> Void = {}
    var editAddress: @MainActor () -> Void = {}
    var cancel: @MainActor () -> Void = {}
    var setReadOnlyPermission: @MainActor (McpToolPermission) -> Void = { _ in }
    var setChangesPermission: @MainActor (McpToolPermission) -> Void = { _ in }
    var finishReview: @MainActor () -> Void = {}
    var onBack: @MainActor () -> Void = {}

    init() {}

    init(model: McpAddServerModel, onBack: @escaping @MainActor () -> Void) {
        setURL = { model.setURL($0) }
        setName = { model.setName($0) }
        setToken = { model.setToken($0) }
        connect = { model.connect() }
        retry = { model.retry() }
        connectWithToken = { model.connectWithToken() }
        editAddress = { model.editAddress() }
        cancel = { model.cancel() }
        setReadOnlyPermission = { model.setReadOnlyPermission($0) }
        setChangesPermission = { model.setChangesPermission($0) }
        finishReview = { model.finishReview() }
        self.onBack = onBack
    }
}

struct McpAddServerContent: View {
    let state: McpAddUiState
    let actions: McpAddServerActions

    var body: some View {
        McpPageScaffold(
            title: L10n.tr("Add server", table: .mcp),
            // Going back while connecting cancels; going back from the permission review abandons the add (the
            // model finishes up when the page disappears).
            onBack: actions.onBack
        ) {
            switch state.screen {
            case .form: form
            case let .progress(stage, _, signedIn): progress(stage: stage, signedIn: signedIn)
            case .review(let review): reviewContent(review)
            case .failure(let failure): failureContent(failure)
            }
        } footer: {
            footer
        }
    }

    // MARK: Address form

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("Add server", table: .mcp))
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Text(L10n.tr("Paste the address of an MCP server", table: .mcp))
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
        .padding(.horizontal, 4)

        McpInputField(
            label: L10n.tr("Server address", table: .mcp),
            text: Binding(get: { state.url }, set: actions.setURL),
            placeholder: "https://mcp.example.com/mcp",
            hint: L10n.tr(
                "Only servers reachable over the network are supported. Servers that need a command run on your computer work in the desktop app.",
                table: .mcp
            ),
            error: state.urlError.map(Self.urlErrorText),
            monospaced: true,
            keyboard: .URL,
            submitLabel: .go,
            onSubmit: { if state.canConnect { actions.connect() } }
        )

        McpInputField(
            label: L10n.tr("Name (optional)", table: .mcp),
            text: Binding(get: { state.name }, set: actions.setName),
            placeholder: L10n.tr("Leave empty to use the server's own name", table: .mcp)
        )

        // The form only has address and name: the sign-in method is decided by probing, and an access token is
        // only asked for when the server requires one.
        McpFootnote(text: L10n.tr(
            "If the server asks you to sign in, its own sign-in page opens. Oriveo never sees your password.",
            table: .mcp
        ))
    }

    static func urlErrorText(_ reason: McpInvalidURLReason) -> String {
        switch reason {
        case .malformed:
            return L10n.tr("The address needs to start with https://, for example https://mcp.linear.app/mcp", table: .mcp)
        case .hasUserinfo:
            return L10n.tr("The address can't include a username or password. Use an access token instead.", table: .mcp)
        }
    }

    private var tokenField: some View {
        McpInputField(
            label: L10n.tr("Access token", table: .mcp),
            text: Binding(get: { state.token }, set: actions.setToken),
            placeholder: L10n.tr("Paste token", table: .mcp),
            hint: L10n.tr("The token stays on this device.", table: .mcp),
            error: state.tokenRejected ? L10n.tr("The server didn't accept this token.", table: .mcp) : nil,
            monospaced: true,
            isSecure: true
        )
    }

    // MARK: Connecting

    @ViewBuilder
    private func progress(stage: McpAddStage, signedIn: Bool) -> some View {
        McpCard {
            McpHeroHeader(name: state.displayName, iconURL: nil, serverURL: state.url, showsGlobe: state.nameIsUnknown) {
                Text(Self.progressCaption(stage))
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
        }
        McpChecklistCard(items: Self.checklist(stage: stage, signedIn: signedIn, name: state.displayName))
    }

    static func progressCaption(_ stage: McpAddStage) -> String {
        switch stage {
        case .connecting: return L10n.tr("Connecting…", table: .mcp)
        case .authPrompt, .browser: return L10n.tr("Sign-in needed", table: .mcp)
        case .finishing: return L10n.tr("Finishing up…", table: .mcp)
        }
    }

    /// Three-step checklist. Only steps that **already happened** are marked done: until connected, the first step
    /// keeps spinning and is never ticked early.
    static func checklist(stage: McpAddStage, signedIn: Bool, name: String) -> [McpChecklistItem] {
        let found = L10n.tr("Server found", table: .mcp)
        let checking = L10n.tr("Checking how to sign in", table: .mcp)
        let reading = L10n.tr("Reading the tool list", table: .mcp)
        let needed = String(format: L10n.tr("Sign-in needed for %@", table: .mcp), name)
        switch stage {
        case .connecting:
            return [
                McpChecklistItem(id: 0, title: found, detail: nil, state: .active),
                McpChecklistItem(id: 1, title: checking, detail: nil, state: .waiting),
                McpChecklistItem(id: 2, title: reading, detail: nil, state: .waiting),
            ]
        case .authPrompt:
            return [
                McpChecklistItem(id: 0, title: found, detail: nil, state: .done),
                McpChecklistItem(id: 1, title: checking, detail: needed, state: .done),
                McpChecklistItem(id: 2, title: reading, detail: nil, state: .waiting),
            ]
        case .browser:
            return [
                McpChecklistItem(id: 0, title: found, detail: nil, state: .done),
                McpChecklistItem(id: 1, title: checking, detail: needed, state: .active),
                McpChecklistItem(id: 2, title: reading, detail: nil, state: .waiting),
            ]
        case .finishing:
            return [
                McpChecklistItem(id: 0, title: found, detail: nil, state: .done),
                McpChecklistItem(
                    id: 1,
                    title: signedIn ? String(format: L10n.tr("Signed in to %@", table: .mcp), name) : checking,
                    detail: nil, state: .done
                ),
                McpChecklistItem(id: 2, title: reading, detail: nil, state: .active),
            ]
        }
    }

    // MARK: Review default permissions

    @ViewBuilder
    private func reviewContent(_ review: McpAddReviewScreen) -> some View {
        McpCard {
            McpHeroHeader(name: state.displayName, iconURL: nil, serverURL: state.url) {
                HStack(spacing: 8) {
                    McpStatusPill(text: L10n.tr("Connected", table: .mcp), tone: .success)
                    Text(String(format: L10n.tr("Tools: %d", table: .mcp), review.tools.count))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }
        }
        if review.tools.isEmpty {
            McpFootnote(text: L10n.tr("This server doesn't offer any tools.", table: .mcp), tone: OriveoTheme.Palette.textSecondary)
        } else {
            McpSectionTitle(title: L10n.tr("Default permissions", table: .mcp))
            McpCard(padding: 0) {
                if !review.readOnlyTools.isEmpty {
                    permissionRow(
                        readOnly: true, tools: review.readOnlyTools, permission: review.readOnlyPermission,
                        select: actions.setReadOnlyPermission
                    )
                }
                if !review.readOnlyTools.isEmpty, !review.changingTools.isEmpty {
                    Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1).padding(.horizontal, 16)
                }
                if !review.changingTools.isEmpty {
                    permissionRow(
                        readOnly: false, tools: review.changingTools, permission: review.changesPermission,
                        select: actions.setChangesPermission
                    )
                }
            }
            McpFootnote(text: L10n.tr(
                "You can adjust each tool later in the server's details. The grouping comes from the server's own labels. Tools without a label are treated as changing data.",
                table: .mcp
            ))
        }
    }

    private func permissionRow(
        readOnly: Bool,
        tools: [McpToolSnapshot],
        permission: McpToolPermission,
        select: @escaping @MainActor (McpToolPermission) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(McpPermissionCopy.group(readOnly: readOnly))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                // Tool titles are shown verbatim as the server provides them, never translated.
                HStack(spacing: 4) {
                    Text(Self.groupNames(tools))
                        .lineLimit(1)
                    Text("· \(String(format: L10n.tr("%d items", table: .mcp), tools.count))")
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 13))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            Spacer(minLength: 8)
            Menu {
                Button {
                    select(.auto)
                } label: { Text(McpPermissionCopy.label(.auto)) }
                Button {
                    select(.ask)
                } label: { Text(McpPermissionCopy.label(.ask)) }
                Button {
                    select(.off)
                } label: { Text(McpPermissionCopy.label(.off)) }
            } label: {
                HStack(spacing: 6) {
                    Text(McpPermissionCopy.label(permission))
                        .font(.system(size: 15))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(McpPermissionCopy.group(readOnly: readOnly))
            .accessibilityValue(McpPermissionCopy.label(permission))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
    }

    /// Description of a group row: the first 3 tool titles (verbatim from the server), followed by the count.
    static func groupNames(_ tools: [McpToolSnapshot]) -> String {
        tools.prefix(3).map(\.title).joined(separator: ", ")
    }

    // MARK: Failure and other terminal states

    @ViewBuilder
    private func failureContent(_ failure: McpAddFailure) -> some View {
        let copy = Self.failureCopy(failure)
        McpCard {
            McpHeroHeader(name: state.displayName, iconURL: nil, serverURL: state.url, showsGlobe: state.nameIsUnknown) {
                McpStatusPill(text: copy.pill, tone: copy.tone)
            }
        }
        McpNoticeBlock(title: copy.title, message: copy.message, tone: copy.tone)
        if failure == .needsToken {
            tokenField
        }
    }

    struct FailureCopy {
        var pill: String
        var title: String
        var message: String
        var tone: McpPillTone
    }

    static func failureCopy(_ failure: McpAddFailure) -> FailureCopy {
        switch failure {
        case .unreachable:
            return FailureCopy(
                pill: L10n.tr("Can't connect", table: .mcp),
                title: L10n.tr("Can't reach this server", table: .mcp),
                message: L10n.tr(
                    "Check the address, and whether this device can reach it right now. Servers on a home or office network usually can't be reached from elsewhere.",
                    table: .mcp
                ),
                tone: .danger
            )
        case .notMcp:
            return FailureCopy(
                pill: L10n.tr("Not recognized", table: .mcp),
                title: L10n.tr("This address isn't an MCP server", table: .mcp),
                message: L10n.tr(
                    "The address works, but it didn't respond the way an MCP server does. A missing path such as /mcp is a common cause. Check the service's documentation.",
                    table: .mcp
                ),
                tone: .danger
            )
        case .needsToken:
            return FailureCopy(
                pill: L10n.tr("Token needed", table: .mcp),
                title: L10n.tr("This server doesn't support automatic sign-in", table: .mcp),
                message: L10n.tr("Create an access token in the service's settings and paste it below.", table: .mcp),
                tone: .warning
            )
        case .authCancelled:
            return FailureCopy(
                pill: L10n.tr("Sign-in not finished", table: .mcp),
                title: L10n.tr("Sign-in wasn't completed", table: .mcp),
                message: L10n.tr(
                    "The sign-in page was closed, or the service didn't approve the request. The server hasn't been added.",
                    table: .mcp
                ),
                tone: .warning
            )
        case .limitReached(let max):
            return FailureCopy(
                pill: L10n.tr("Not added", table: .mcp),
                title: L10n.tr("You've reached the server limit", table: .mcp),
                message: String(
                    format: L10n.tr(
                        "You can connect up to %d servers. Remove one you no longer use, then add this one.",
                        table: .mcp
                    ),
                    max
                ),
                tone: .warning
            )
        case .saveFailed:
            return FailureCopy(
                pill: L10n.tr("Not added", table: .mcp),
                title: L10n.tr("Couldn't save this server", table: .mcp),
                message: L10n.tr(
                    "The server responded, but it couldn't be saved on this device. Try again in a moment.",
                    table: .mcp
                ),
                tone: .danger
            )
        }
    }

    // MARK: Bottom buttons

    @ViewBuilder
    private var footer: some View {
        switch state.screen {
        case .form:
            Button(action: actions.connect) {
                Text(L10n.tr("Connect", table: .mcp))
            }
            .buttonStyle(McpPrimaryButtonStyle())
            .disabled(!state.canConnect)
            .opacity(state.canConnect ? 1 : 0.5)
        case .progress:
            Button(action: actions.cancel) {
                Text(L10n.tr("Cancel"))
            }
            .buttonStyle(McpTextButtonStyle())
        case .review(let review):
            Button(action: actions.finishReview) {
                Text(L10n.tr("Done"))
            }
            .buttonStyle(McpPrimaryButtonStyle())
            .disabled(review.saving)
        case .failure(let failure):
            failureFooter(failure)
        }
    }

    @ViewBuilder
    private func failureFooter(_ failure: McpAddFailure) -> some View {
        VStack(spacing: 4) {
            switch failure {
            case .unreachable, .saveFailed:
                Button(action: actions.retry) {
                    Text(L10n.tr("Try again", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button(action: actions.editAddress) {
                    Text(L10n.tr("Edit address", table: .mcp))
                }
                .buttonStyle(McpTextButtonStyle())
            case .notMcp:
                Button(action: actions.editAddress) {
                    Text(L10n.tr("Edit address", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
            case .needsToken:
                Button(action: actions.connectWithToken) {
                    Text(L10n.tr("Connect", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                .disabled(state.trimmedToken.isEmpty)
                .opacity(state.trimmedToken.isEmpty ? 0.5 : 1)
                Button(action: actions.editAddress) {
                    Text(L10n.tr("Edit address", table: .mcp))
                }
                .buttonStyle(McpTextButtonStyle())
            case .authCancelled:
                Button(action: actions.retry) {
                    Text(L10n.tr("Try signing in again", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button(action: actions.onBack) {
                    Text(L10n.tr("Cancel"))
                }
                .buttonStyle(McpTextButtonStyle())
            case .limitReached:
                Button(action: actions.onBack) {
                    Text(L10n.tr("Done"))
                }
                .buttonStyle(McpSecondaryButtonStyle())
            }
        }
    }
}
