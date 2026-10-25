import UIKit

enum MessageRecoveryActionKind: Equatable {
    case retry
    case editMessage
    case regenerate
    case switchModel
    case resendWithoutImages
    case resendWithoutFiles
    case resendWithoutVideos
    case resendWithoutParameter
    /// The relay's current key was judged unauthorized while another key lists this model: open the key-switch sheet, do not resend.
    case switchKey
    case showTechnicalDetails
}

struct MessageRecoveryCardActionLayout: Equatable {
    let primary: MessageRecoveryActionKind
    let secondary: MessageRecoveryActionKind?
    let tertiary: MessageRecoveryActionKind?
}

func resolveMessageRecoveryCardActionLayout(
    for state: ChatMessageState,
    shouldOfferModelSwitch: Bool,
    isAttachmentOverLimit: Bool = false,
    offersSwitchKey: Bool = false,
    recoveryPrimaryAction: String? = nil
) -> MessageRecoveryCardActionLayout {
    let base = baseMessageRecoveryCardActionLayout(
        for: state,
        shouldOfferModelSwitch: shouldOfferModelSwitch,
        isAttachmentOverLimit: isAttachmentOverLimit,
        recoveryPrimaryAction: recoveryPrimaryAction
    )
    guard offersSwitchKey, state == .failed else { return base }
    // "Switch key" takes the slot of "Edit Message" (the key was refused, so editing the message would not help);
    // when there is no edit slot it goes into the first empty one.
    var slots: [MessageRecoveryActionKind?] = [base.primary, base.secondary, base.tertiary]
    if let index = slots.firstIndex(of: .editMessage) {
        slots[index] = .switchKey
    } else if let index = slots.firstIndex(where: { $0 == nil }) {
        slots[index] = .switchKey
    }
    return .init(primary: slots[0] ?? base.primary, secondary: slots[1], tertiary: slots[2])
}

private func baseMessageRecoveryCardActionLayout(
    for state: ChatMessageState,
    shouldOfferModelSwitch: Bool,
    isAttachmentOverLimit: Bool,
    recoveryPrimaryAction: String?
) -> MessageRecoveryCardActionLayout {
    switch state {
    case .failed:
        // The local markers for "this relay model does not take images / files" lead straight to switching models.
        if recoveryPrimaryAction == relayImageUnsupportedRecoveryAction
            || recoveryPrimaryAction == relayFileUnsupportedRecoveryAction {
            return .init(primary: .switchModel, secondary: nil, tertiary: nil)
        }
        switch recoveryPrimaryAction {
        case officialImageRejectedRecoveryAction:
            return .init(primary: .resendWithoutImages, secondary: .switchModel, tertiary: nil)
        case officialFileRejectedRecoveryAction:
            return .init(primary: .resendWithoutFiles, secondary: .switchModel, tertiary: nil)
        case officialVideoRejectedRecoveryAction:
            return .init(primary: .resendWithoutVideos, secondary: .switchModel, tertiary: nil)
        case officialParameterRejectedRecoveryAction:
            return .init(primary: .resendWithoutParameter, secondary: .switchModel, tertiary: nil)
        default:
            break
        }
        // The send was stopped locally because the attachments do not fit the model's limit: retrying as is
        // would be stopped again, so editing the message comes first.
        if isAttachmentOverLimit {
            return .init(
                primary: .editMessage,
                secondary: .retry,
                tertiary: shouldOfferModelSwitch ? .switchModel : nil
            )
        }
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

/// Marker written locally into the failed message when a relay model rejected an image before any output and image
/// support was unknown at send time: the card body becomes "doesn't support images" and the primary action reuses
/// "Switch Model". Images get no text fallback and are never resent automatically.
let relayImageUnsupportedRecoveryAction = "relay_image_unsupported"

/// An official connection's image was rejected by the upstream by signature before any output: a negative cache entry is recorded and nothing is retried automatically.
/// The recovery card's primary action is "resend without images" (a tap is a plain resend: the outbound projection strips the image and writes a placeholder, the local message is unchanged), with "Switch Model" second.
let officialImageRejectedRecoveryAction = "official_image_rejected"
/// Same as above, for a rejected file / video: the primary action is "resend without files" / "resend without videos", with "Switch Model" second.
let officialFileRejectedRecoveryAction = "official_file_rejected"
let officialVideoRejectedRecoveryAction = "official_video_rejected"
/// An official connection's request parameter was rejected by the upstream by signature (param_rejected): a `param:<name>` negative cache entry is recorded and nothing is retried automatically.
/// The recovery card's primary action is "resend without this parameter" (a plain resend: the outbound request drops the parameter per the negative cache), with "Switch Model" second.
let officialParameterRejectedRecoveryAction = "official_parameter_rejected"

/// The rejected key a failed message recorded for itself → recovery action marker: the three input keys each give resend-without-that-media,
/// `param:<name>` gives resend-without-this-parameter; any other key gives nil (the recovery card stays as before).
func officialInputRejectedRecoveryAction(capabilityKey: String) -> String? {
    switch capabilityKey {
    case CapabilityEvidenceFacade.visionInputKey: officialImageRejectedRecoveryAction
    case CapabilityEvidenceFacade.fileInputKey: officialFileRejectedRecoveryAction
    case CapabilityEvidenceFacade.videoInputKey: officialVideoRejectedRecoveryAction
    default:
        capabilityKey.hasPrefix(InputRejectionFlow.parameterCapabilityKey(""))
            ? officialParameterRejectedRecoveryAction(
                parameter: String(capabilityKey.dropFirst(InputRejectionFlow.parameterCapabilityKey("").count))
            )
            : nil
    }
}

/// A parameter-rejected marker with the parameter name: shown on the same card as the bare value.
func officialParameterRejectedRecoveryAction(parameter: String) -> String {
    parameter.isEmpty ? officialParameterRejectedRecoveryAction : officialParameterRejectedRecoveryAction + ":" + parameter
}

/// The rejected parameter name inside a parameter-rejected marker; nil when there is none.
func officialRejectedParameterName(recoveryAction: String?) -> String? {
    let prefix = officialParameterRejectedRecoveryAction + ":"
    guard let recoveryAction, recoveryAction.hasPrefix(prefix) else { return nil }
    let name = String(recoveryAction.dropFirst(prefix.count))
    return name.isEmpty ? nil : name
}

/// Marker written locally when a request carrying native file blocks was rejected first and the fallback chain also
/// failed: the card body becomes "doesn't support these files" and the primary action reuses "Switch Model".
/// The error shown is still the first one.
let relayFileUnsupportedRecoveryAction = "relay_file_unsupported"

/// Where the primary action of a failure card comes from. Only the local markers (relay and official input rejections) are read here;
/// every other failure uses the default layout.
func recoveryPrimaryAction(for message: ChatMessage) -> String? {
    // The parameter-rejected marker with a parameter name shows on the same card as the bare value.
    if message.recoveryPrimaryAction?.hasPrefix(officialParameterRejectedRecoveryAction + ":") == true {
        return officialParameterRejectedRecoveryAction
    }
    if message.recoveryPrimaryAction == relayImageUnsupportedRecoveryAction
        || message.recoveryPrimaryAction == officialImageRejectedRecoveryAction
        || message.recoveryPrimaryAction == officialFileRejectedRecoveryAction
        || message.recoveryPrimaryAction == officialVideoRejectedRecoveryAction
        || message.recoveryPrimaryAction == officialParameterRejectedRecoveryAction
        || message.recoveryPrimaryAction == relayFileUnsupportedRecoveryAction {
        return message.recoveryPrimaryAction
    }
    return nil
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

func localizedMessageRecoveryBody(
    for state: ChatMessageState,
    localPrimaryAction: String? = nil
) -> String {
    switch state {
    case .failed:
        if localPrimaryAction == relayImageUnsupportedRecoveryAction {
            return L10n.tr("This model doesn't support images. Switch to another model to send them.", table: .chat)
        }
        if localPrimaryAction == relayFileUnsupportedRecoveryAction {
            return L10n.tr("This model doesn't support these files. Switch to another model to send them.", table: .chat)
        }
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
    case .resendWithoutImages:
        return InputCapabilityCopy.resendWithout(.image)
    case .resendWithoutFiles:
        return InputCapabilityCopy.resendWithout(.file)
    case .resendWithoutVideos:
        return InputCapabilityCopy.resendWithout(.video)
    case .resendWithoutParameter:
        return L10n.tr("Retry without this setting", table: .chat)
    case .switchKey:
        return L10n.tr(RelaySwitchKey.buttonKey, table: .providers)
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
        offersSwitchKey: Bool = false,
        onSwitchKeyRequested: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void,
        onTechnicalDetailVisibilityChanged: @escaping (Bool) -> Void
    ) -> UIKitRecoveryCard.Config? {
        let state = model.message.state
        guard shouldOfferMessageRecovery(
            state: state,
            role: model.message.role,
            isLastInConversation: model.isLastInConversation
        ), state == .failed, !isDismissed else { return nil }

        let shouldOfferModelSwitch = ChatFailurePresentation.offersModelSwitch(
            errorTitle: model.message.errorTitle,
            errorDetail: model.message.errorDetail,
            bodyText: model.message.text
        )

        let actionLayout = resolveMessageRecoveryCardActionLayout(
            for: state,
            shouldOfferModelSwitch: shouldOfferModelSwitch,
            isAttachmentOverLimit: model.message.errorDetail.map(ProviderServiceError.attachmentOverLimitCodes.contains) == true,
            offersSwitchKey: offersSwitchKey,
            recoveryPrimaryAction: recoveryPrimaryAction(for: model.message)
        )

        let actionRouter: (MessageRecoveryActionKind) -> Void = { action in
            switch action {
            case .retry: onRetry()
            case .resendWithoutImages, .resendWithoutFiles, .resendWithoutVideos, .resendWithoutParameter: onRetry()
            case .editMessage: onEditMessage()
            case .regenerate: onRegenerate()
            case .switchModel: onSwitchModelRequested()
            case .switchKey: onSwitchKeyRequested()
            case .showTechnicalDetails: onTechnicalDetailVisibilityChanged(true)
            }
            _ = onContinue
        }

        return UIKitRecoveryCard.Config(
            title: localizedMessageRecoveryTitle(for: state, errorTitle: model.message.errorTitle),
            message: localizedMessageRecoveryBody(
                for: state,
                localPrimaryAction: recoveryPrimaryAction(for: model.message)
            ),
            primaryTitle: actionLayout.primary == .retry
                && model.message.errorDetail == "model_control_setting_rejected"
                && model.message.capabilityExecution?.recoveryDescriptors?.count == 1
                    ? L10n.tr("Retry without this setting", table: .chat)
                    : (model.message.errorTitle == "Custom request fields error" && actionLayout.primary == .retry
                        ? L10n.tr("Retry without custom fields", table: .chat)
                        : (model.message.errorTitle == AdditionalRequestBody.upstreamRejectionTitleKey
                            && actionLayout.primary == .retry
                            ? L10n.tr("Retry without additional request body", table: .chat)
                            : localizedMessageRecoveryActionTitle(actionLayout.primary))),
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
