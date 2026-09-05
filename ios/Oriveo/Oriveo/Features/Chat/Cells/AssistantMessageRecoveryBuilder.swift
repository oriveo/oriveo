import UIKit

enum MessageRecoveryActionKind: Equatable {
    case retry
    case editMessage
    case regenerate
    case switchModel
    case showTechnicalDetails
}

struct MessageRecoveryCardActionLayout: Equatable {
    let primary: MessageRecoveryActionKind
    let secondary: MessageRecoveryActionKind?
    let tertiary: MessageRecoveryActionKind?
}

func resolveMessageRecoveryCardActionLayout(
    for state: ChatMessageState,
    shouldOfferModelSwitch: Bool
) -> MessageRecoveryCardActionLayout {
    switch state {
    case .failed:
        return .init(
            primary: .retry,
            secondary: .editMessage,
            tertiary: shouldOfferModelSwitch ? .switchModel : nil
        )
    case .interrupted:
        return .init(primary: .regenerate, secondary: nil, tertiary: nil)
    case .delivered, .generating:
        return .init(primary: .retry, secondary: nil, tertiary: nil)
    }
}

func localizedMessageRecoveryTitle(
    for state: ChatMessageState,
    errorTitle: String?
) -> String {
    switch state {
    case .failed:
        return localizedErrorTitle(errorTitle ?? "Send Failed")
    case .interrupted:
        return L10n.tr("Response Interrupted", table: .chat)
    case .delivered, .generating:
        return ""
    }
}

func localizedMessageRecoveryBody(for state: ChatMessageState) -> String {
    switch state {
    case .failed:
        return L10n.tr("The request did not finish cleanly. Retry it now or edit the last user message before sending again.", table: .chat)
    case .interrupted:
        return L10n.tr("The partial reply has been kept. Regenerate to request a fresh full answer.", table: .chat)
    case .delivered, .generating:
        return ""
    }
}

func localizedMessageRecoveryActionTitle(
    _ action: MessageRecoveryActionKind
) -> String {
    switch action {
    case .retry:
        return L10n.tr("Retry")
    case .editMessage:
        return L10n.tr("Edit Message", table: .chat)
    case .regenerate:
        return L10n.tr("Regenerate", table: .chat)
    case .switchModel:
        return L10n.tr("Switch Model")
    case .showTechnicalDetails:
        return L10n.tr("Technical details")
    }
}

func messageRecoveryActionsEnabled(isSendingMessage: Bool) -> Bool {
    !isSendingMessage
}

func shouldShowDeliveredRegenerateAction(
    for state: ChatMessageState,
    isSendingMessage: Bool
) -> Bool {
    state == .delivered && !isSendingMessage
}

/// The recovery card belongs to the newest assistant turn only. Older failed turns keep
/// their inline error text so the transcript does not fill up with retry buttons.
func shouldOfferMessageRecovery(
    state: ChatMessageState,
    role: ChatRole,
    isLastInConversation: Bool
) -> Bool {
    role == .assistant
        && isLastInConversation
        && (state == .failed || state == .interrupted)
}

// MARK: - Recovery card config builder

/// Builds the retry card shown under a failed assistant turn.
@MainActor
enum AssistantMessageRecoveryBuilder {
    static func makeConfig(
        for model: ChatCollectionProjectionBuilder.MessageRenderModel,
        isSendingMessage: Bool,
        isDismissed: Bool,
        isTechnicalDetailExpanded: Bool,
        onRetry: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onRegenerate: @escaping () -> Void,
        onEditMessage: @escaping () -> Void,
        onSwitchModelRequested: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onTechnicalDetailVisibilityChanged: @escaping (Bool) -> Void
    ) -> UIKitRecoveryCard.Config? {
        let state = model.message.state
        guard shouldOfferMessageRecovery(
            state: state,
            role: model.message.role,
            isLastInConversation: model.isLastInConversation
        ), state == .failed, !isDismissed else { return nil }

        let shouldOfferModelSwitch: Bool = {
            let t = model.message.errorTitle?.lowercased() ?? ""
            let d = model.message.errorDetail?.lowercased() ?? ""
            let b = model.message.text.lowercased()
            return t.contains("rate") || t.contains("quota")
                || d.contains("429") || d.contains("insufficient")
                || b.contains("switch models")
        }()

        let actionLayout = resolveMessageRecoveryCardActionLayout(
            for: state,
            shouldOfferModelSwitch: shouldOfferModelSwitch
        )

        let actionRouter: (MessageRecoveryActionKind) -> Void = { action in
            switch action {
            case .retry: onRetry()
            case .editMessage: onEditMessage()
            case .regenerate: onRegenerate()
            case .switchModel: onSwitchModelRequested()
            case .showTechnicalDetails: onTechnicalDetailVisibilityChanged(true)
            }
            _ = onContinue
        }

        return UIKitRecoveryCard.Config(
            title: localizedMessageRecoveryTitle(for: state, errorTitle: model.message.errorTitle),
            message: localizedMessageRecoveryBody(for: state),
            primaryTitle: actionLayout.primary == .retry
                && model.message.errorDetail == "model_control_setting_rejected"
                && model.message.capabilityExecution?.recoveryDescriptors?.count == 1
                    ? L10n.tr("Retry without this setting", table: .chat)
                    : (model.message.errorTitle == "Custom request fields error" && actionLayout.primary == .retry
                        ? L10n.tr("Retry without custom fields", table: .chat)
                        : localizedMessageRecoveryActionTitle(actionLayout.primary)),
            secondaryTitle: actionLayout.secondary.map(localizedMessageRecoveryActionTitle),
            tertiaryTitle: actionLayout.tertiary.map(localizedMessageRecoveryActionTitle),
            tone: state == .interrupted ? .warning : .danger,
            technicalDetail: model.message.errorDetail,
            actionsEnabled: messageRecoveryActionsEnabled(isSendingMessage: isSendingMessage),
            primaryAction: { actionRouter(actionLayout.primary) },
            secondaryAction: actionLayout.secondary.map { action in
                { actionRouter(action) }
            },
            tertiaryAction: actionLayout.tertiary.map { action in
                { actionRouter(action) }
            },
            onDismiss: onDismiss,
            primaryRevealsTechnicalDetail: actionLayout.primary == .showTechnicalDetails,
            showsTechnicalDetail: isTechnicalDetailExpanded,
            onTechnicalDetailVisibilityChanged: onTechnicalDetailVisibilityChanged
        )
    }
}

private func localizedErrorTitle(_ key: String) -> String {
    let chat = L10n.tr(key, table: .chat)
    return chat == key ? L10n.tr(key) : chat
}
