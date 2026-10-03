import SwiftUI

/// Confirmation before a write: before a tool whose permission is "ask every time" runs, the user is shown
/// what the model is about to submit.
///
/// Two levels inside one sheet: the key-value summary, then "View full text" opens the full-text page (which
/// only keeps "Allow once" and "Deny").
/// It cannot be swiped away: without a choice no `tools/call` is sent, so one option has to be picked.
struct McpConfirmationSheet: View {
    let request: McpConfirmationRequest
    /// Title of the conversation that started this call. The sheet is attached at the app root and follows the
    /// user, who may be in a different conversation right now: it has to be clear which conversation is asking,
    /// and "allow for this conversation" applies to that conversation too.
    var conversationTitle: String?
    let onChoose: (McpConfirmationChoice) -> Void

    /// The content shown on the full-text page; nil = the summary page.
    @State private var fullText: String?

    private var parameters: [McpConfirmationParameter] {
        McpConfirmationContent.parameters(for: request.arguments)
    }

    var body: some View {
        Group {
            if let fullText {
                fullPage(fullText)
            } else {
                summaryPage
            }
        }
        .onAppear { OriveoHaptic.warning() }
    }

    // MARK: Summary page

    private var summaryPage: some View {
        McpFittedSheet(fallbackHeight: 520, allowsInteractiveDismiss: false) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    McpServerIconView(name: request.serverName, iconURL: nil, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        // The server name and the tool title are third-party text; only the sentence pattern is localized.
                        Text(String(
                            format: L10n.tr("Allow %1$@ to %2$@?", table: .mcp),
                            request.serverName, toolTitle
                        ))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        if request.changesData {
                            Text(String(
                                format: L10n.tr(
                                    "This step changes your data in %@. Here's what the model is about to send.",
                                    table: .mcp
                                ),
                                request.serverName
                            ))
                            .font(OriveoTheme.Typography.caption)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                McpGroupCard {
                    if let conversationTitle = McpConfirmationContent.displayConversationTitle(conversationTitle) {
                        infoRow(key: L10n.tr("Chat", table: .mcp)) {
                            Text(conversationTitle)
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                .lineLimit(1)
                        }
                        divider
                    }
                    infoRow(key: L10n.tr("Server", table: .mcp)) {
                        (Text(request.serverName).foregroundStyle(OriveoTheme.Palette.textPrimary)
                            + Text(request.serverHost.isEmpty ? "" : " · \(request.serverHost)")
                            .foregroundStyle(OriveoTheme.Palette.textTertiary))
                            .lineLimit(2)
                    }
                    ForEach(parameters) { parameter in
                        divider
                        parameterRow(parameter)
                    }
                    if McpConfirmationContent.hasMoreParameters(request.arguments) {
                        divider
                        HStack {
                            Spacer()
                            viewAllButton { fullText = McpConfirmationContent.allParametersText(request.arguments) }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        } footer: {
            VStack(spacing: 10) {
                Button { onChoose(.once) } label: {
                    Text(L10n.tr("Allow once", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button { onChoose(.conversation) } label: {
                    Text(L10n.tr("Always allow in this chat", table: .mcp))
                }
                .buttonStyle(McpSecondaryButtonStyle())
                Button { onChoose(.deny) } label: {
                    Text(L10n.tr("Decline", table: .mcp))
                }
                .buttonStyle(McpTextButtonStyle())
            }
        }
    }

    private var toolTitle: String {
        request.toolTitle.isEmpty ? request.toolName : request.toolTitle
    }

    private var divider: some View {
        Rectangle().fill(OriveoTheme.Palette.border).frame(height: 1).padding(.horizontal, 16)
    }

    private func infoRow<Value: View>(
        key: String,
        verticalPadding: CGFloat = 13,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // The key is the argument name as defined by the server and is not translated.
            Text(key)
                .font(.system(size: 14))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            value()
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
    }

    @ViewBuilder
    private func parameterRow(_ parameter: McpConfirmationParameter) -> some View {
        switch parameter.display {
        case let .inline(text):
            infoRow(key: parameter.key) {
                Text(text)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
            }
        case let .long(characterCount):
            // The inline "View full text" brings its own 44pt tap height, so the row's vertical padding shrinks to match
            // and the row ends up as tall as the others.
            infoRow(key: parameter.key, verticalPadding: 2) {
                HStack {
                    Text(String(format: L10n.tr("About %d characters", table: .mcp), characterCount))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Spacer(minLength: 8)
                    viewAllButton { fullText = parameter.fullText }
                }
            }
        }
    }

    private func viewAllButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.tr("View all", table: .mcp))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: Full-text page

    private func fullPage(_ text: String) -> some View {
        McpFittedSheet(fallbackHeight: 620, allowsInteractiveDismiss: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Button { fullText = nil } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("Back")))
                    Text(L10n.tr("What will be sent", table: .mcp))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                    )
                Text(String(
                    format: L10n.tr("The model wrote this. It will be sent to %@ exactly as shown.", table: .mcp),
                    request.serverName
                ))
                .font(.system(size: 12.5))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            VStack(spacing: 10) {
                Button { onChoose(.once) } label: {
                    Text(L10n.tr("Allow once", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button { onChoose(.deny) } label: {
                    Text(L10n.tr("Decline", table: .mcp))
                }
                .buttonStyle(McpTextButtonStyle())
            }
        }
    }
}

// MARK: - Presentation

private struct McpConfirmationPresenter: ViewModifier {
    /// Passed in explicitly instead of read from the environment: this modifier is attached to the outermost
    /// level of `AppRootView`, and the `AppState` the root view injects is for the content **inside** it. The
    /// outer level would only see one if whatever hosts the root view injected it a second time.
    let appState: AppState

    /// The confirmation at the head of the queue, not filtered by conversation (the same rule as other
    /// confirmations): it needs UI to present it even after the user switches to another conversation, or that
    /// answer would wait forever. The choice is routed back by confirmation id to the wait that raised it.
    private var confirmation: Binding<PendingMcpConfirmation?> {
        Binding(
            get: { appState.mcpConfirmationCoordinator.pending.first },
            set: { _ in }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: confirmation) { pending in
            McpConfirmationSheet(
                request: pending.request,
                conversationTitle: appState.conversation(for: pending.request.conversationId)?.title
            ) { choice in
                // The choice is routed back by confirmation id to the wait that raised it. "Allow for this conversation"
                // is recorded by that execution against its own conversation, whichever conversation the user is in now.
                appState.mcpConfirmationCoordinator.resolve(id: pending.id, choice: choice)
            }
            // When confirming one by one, the next request must start on the summary page instead of inheriting the
            // previous one's full-text state.
            .id(pending.id)
        }
    }
}

extension View {
    func mcpConfirmationPresenter(appState: AppState) -> some View {
        modifier(McpConfirmationPresenter(appState: appState))
    }
}

// MARK: - The expired-authorization prompt at the app root

/// The app-root prompt for a step parked at "sign in again". It does the same thing as the two buttons under
/// the step block: Reauthorize opens that server's detail page to sign in, and after a successful sign-in the
/// loop carries on from this step; Skip feeds back `auth_skipped`.
struct McpReauthorizationSheet: View {
    let request: McpReauthorizationRequest
    var conversationTitle: String?
    let onReauthorize: () -> Void
    let onSkip: () -> Void

    var body: some View {
        McpFittedSheet(fallbackHeight: 360) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    McpServerIconView(name: request.serverName, iconURL: nil, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(format: L10n.tr("%@'s sign-in expired", table: .mcp), request.serverName))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.tr("After you sign in, it picks up from this step. Earlier results are kept.", table: .mcp))
                            .font(OriveoTheme.Typography.caption)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let conversationTitle = McpConfirmationContent.displayConversationTitle(conversationTitle) {
                    McpGroupCard {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(L10n.tr("Chat", table: .mcp))
                                .font(.system(size: 14))
                                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                .frame(width: 76, alignment: .leading)
                            Text(conversationTitle)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                }
            }
        } footer: {
            VStack(spacing: 10) {
                Button(action: onReauthorize) {
                    Text(L10n.tr("Sign in again", table: .mcp))
                }
                .buttonStyle(McpPrimaryButtonStyle())
                Button(action: onSkip) {
                    Text(L10n.tr("Skip this step", table: .mcp))
                }
                .buttonStyle(McpSecondaryButtonStyle())
            }
        }
    }
}

private struct McpReauthorizationPresenter: ViewModifier {
    /// Passed in explicitly, for the same reason as in `McpConfirmationPresenter`.
    let appState: AppState
    /// Prompts the user swiped away. Dismissing does not decide for the user: the step keeps waiting and can still
    /// be handled under the step block after returning to that conversation.
    @State private var dismissed: Set<UUID> = []

    private var prompt: Binding<PendingMcpReauthorization?> {
        Binding(
            get: {
                appState.mcpReauthorizationCoordinator.rootPrompt(
                    signingInServerId: McpReauthorizationCoordinator.signingInServerId(in: appState.navigation.path),
                    dismissed: dismissed
                )
            },
            set: { newValue in
                guard newValue == nil,
                      let current = appState.mcpReauthorizationCoordinator.rootPrompt(
                          signingInServerId: McpReauthorizationCoordinator.signingInServerId(in: appState.navigation.path),
                          dismissed: dismissed
                      ) else { return }
                dismissed.insert(current.id)
            }
        )
    }

    func body(content: Content) -> some View {
        content.sheet(item: prompt) { pending in
            McpReauthorizationSheet(
                request: pending.request,
                conversationTitle: appState.conversation(for: pending.request.conversationId)?.title,
                onReauthorize: {
                    appState.navigation.path.append(
                        .mcpServerDetail(serverID: pending.request.serverId, intent: .reauthorize)
                    )
                },
                onSkip: {
                    appState.mcpReauthorizationCoordinator.skip(
                        conversationID: pending.request.conversationId, stepID: pending.request.stepId
                    )
                }
            )
            .id(pending.id)
        }
    }
}

/// While on screen, the chat view registers the conversation it is showing: that conversation's
/// expired-authorization prompt is already under the step block, so the root does not present another one.
private struct McpReauthorizationInlineHost: ViewModifier {
    @Environment(AppState.self) private var appState
    let conversationID: UUID?
    @State private var registered: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { register(conversationID) }
            .onChange(of: conversationID) { _, id in register(id) }
            .onDisappear { register(nil) }
    }

    private func register(_ id: UUID?) {
        guard id != registered else { return }
        if let registered { appState.mcpReauthorizationCoordinator.chatPageDisappeared(registered) }
        if let id { appState.mcpReauthorizationCoordinator.chatPageAppeared(id) }
        registered = id
    }
}

extension View {
    /// The app-root presenter for the expired-authorization prompt.
    func mcpReauthorizationPresenter(appState: AppState) -> some View {
        modifier(McpReauthorizationPresenter(appState: appState))
    }

    /// For the chat view: registers "this conversation's step block is on screen".
    func mcpReauthorizationInlineHost(conversationID: UUID?) -> some View {
        modifier(McpReauthorizationInlineHost(conversationID: conversationID))
    }
}
