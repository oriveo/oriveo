package ai.oriveo.community.feature.chat.recovery

import ai.oriveo.community.R
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.LOCAL_FIELDS_RETRY_OFFER_PREFIX
import ai.oriveo.community.core.provider.AdditionalRequestBody

internal enum class MessageRecoveryActionKind {
    Retry,
    EditMessage,
    Regenerate,
    SwitchModel,
    /** The relay's current key has no access to this model and another key lists it. */
    SwitchKey,
    ContinueGeneration,
    RetryWithoutLocalCustomFields,
    RetryWithoutAdditionalBody,
    RetryWithoutLocatedSetting,
}

internal data class MessageRecoveryCardActionLayout(
    val primary: MessageRecoveryActionKind,
    val secondary: MessageRecoveryActionKind?,
    val tertiary: MessageRecoveryActionKind?,
)

internal fun resolveMessageRecoveryCardActionLayout(
    state: ChatMessageState,
    shouldOfferModelSwitch: Boolean,
    customRetryWithoutFieldsAvailable: Boolean = false,
    customRetryWithoutFieldsCode: String? = null,
    attachmentTextOverLimit: Boolean = false,
    relayAttachmentUnsupported: Boolean = false,
    offersSwitchKey: Boolean = false,
): MessageRecoveryCardActionLayout {
    val layout = baseMessageRecoveryCardActionLayout(
        state = state,
        shouldOfferModelSwitch = shouldOfferModelSwitch,
        customRetryWithoutFieldsAvailable = customRetryWithoutFieldsAvailable,
        customRetryWithoutFieldsCode = customRetryWithoutFieldsCode,
        attachmentTextOverLimit = attachmentTextOverLimit,
        relayAttachmentUnsupported = relayAttachmentUnsupported,
    )
    if (!offersSwitchKey || state != ChatMessageState.Failed) return layout
    // "Switch key" replaces the "Edit message" slot, Retry stays the primary button and Switch Model stays; when there is no edit slot it fills the first empty slot.
    return when {
        layout.secondary == MessageRecoveryActionKind.EditMessage -> layout.copy(secondary = MessageRecoveryActionKind.SwitchKey)
        layout.tertiary == MessageRecoveryActionKind.EditMessage -> layout.copy(tertiary = MessageRecoveryActionKind.SwitchKey)
        layout.secondary == null -> layout.copy(secondary = MessageRecoveryActionKind.SwitchKey)
        layout.tertiary == null -> layout.copy(tertiary = MessageRecoveryActionKind.SwitchKey)
        else -> layout
    }
}

private fun baseMessageRecoveryCardActionLayout(
    state: ChatMessageState,
    shouldOfferModelSwitch: Boolean,
    customRetryWithoutFieldsAvailable: Boolean,
    customRetryWithoutFieldsCode: String?,
    attachmentTextOverLimit: Boolean,
    relayAttachmentUnsupported: Boolean,
): MessageRecoveryCardActionLayout {
    if (relayAttachmentUnsupported) {
        // Retrying the same image / the same files unchanged will be rejected again; the way out is switching to a model that accepts them (same primary action as iOS).
        return MessageRecoveryCardActionLayout(
            primary = MessageRecoveryActionKind.SwitchModel,
            secondary = MessageRecoveryActionKind.EditMessage,
            tertiary = MessageRecoveryActionKind.Retry,
        )
    }
    if (attachmentTextOverLimit) {
        // Retrying as is gives the same result; the way out is to go back and remove files, or switch to a model with a larger limit.
        return MessageRecoveryCardActionLayout(
            primary = MessageRecoveryActionKind.EditMessage,
            secondary = MessageRecoveryActionKind.Retry,
            tertiary = MessageRecoveryActionKind.SwitchModel,
        )
    }
    if (customRetryWithoutFieldsAvailable) {
        return MessageRecoveryCardActionLayout(
            // When the diagnostic pinned the offending setting down to a single recipe entry we can
            // promise to drop just that one; otherwise all we can honestly offer is a retry with the
            // whole local custom fragment left out.
            primary = if (customRetryWithoutFieldsCode?.startsWith("capability_setting_pre_token_400:provider_recipe:") == true) {
                MessageRecoveryActionKind.RetryWithoutLocatedSetting
            } else if (customRetryWithoutFieldsCode == "$LOCAL_FIELDS_RETRY_OFFER_PREFIX${AdditionalRequestBody.OWNER}") {
                MessageRecoveryActionKind.RetryWithoutAdditionalBody
            } else {
                MessageRecoveryActionKind.RetryWithoutLocalCustomFields
            },
            secondary = MessageRecoveryActionKind.EditMessage,
            tertiary = if (shouldOfferModelSwitch) MessageRecoveryActionKind.SwitchModel else null,
        )
    }
    return when (state) {
        ChatMessageState.Failed -> MessageRecoveryCardActionLayout(
            primary = MessageRecoveryActionKind.Retry,
            secondary = MessageRecoveryActionKind.EditMessage,
            // Switching model is only worth surfacing when the failure is one the same model would
            // hit again, such as a rate limit.
            tertiary = if (shouldOfferModelSwitch) MessageRecoveryActionKind.SwitchModel else null,
        )
        ChatMessageState.Interrupted -> MessageRecoveryCardActionLayout(
            primary = MessageRecoveryActionKind.ContinueGeneration,
            secondary = MessageRecoveryActionKind.Regenerate,
            tertiary = null,
        )
        ChatMessageState.Delivered,
        ChatMessageState.Generating,
        -> MessageRecoveryCardActionLayout(
            primary = MessageRecoveryActionKind.Retry,
            secondary = null,
            tertiary = null,
        )
    }
}

/**
 * Whether the failure card offers "Switch Model": besides rate limiting, the notice card for a Relay image rejected by the upstream also offers it -
 * images get no text fallback and are not resent automatically, so the way out is switching to a model that accepts images.
 */
internal fun relayRecoveryOffersModelSwitch(isRateLimitError: Boolean, errorDetail: String?): Boolean =
    isRateLimitError || isRelayAttachmentUnsupportedDetail(errorDetail)

internal fun isRelayImageUnsupportedDetail(errorDetail: String?): Boolean =
    errorDetail == ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL

/** Notice cards for rejected images or files: both cards share the same set of actions. */
internal fun isRelayAttachmentUnsupportedDetail(errorDetail: String?): Boolean =
    isRelayImageUnsupportedDetail(errorDetail) || errorDetail == ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL

internal fun messageRecoveryActionsEnabled(isSendingMessage: Boolean): Boolean = !isSendingMessage

internal fun shouldShowDeliveredRegenerateAction(
    state: ChatMessageState,
    isSendingMessage: Boolean,
): Boolean = state == ChatMessageState.Delivered && !isSendingMessage

/**
 * Whether the interrupted/failed recovery card (continue, regenerate, retry) should be offered.
 *
 * Only the last message of a conversation gets it. Once the user has sent something else the
 * conversation has moved on and the older interrupted message is frozen: continuing or regenerating
 * it at that point would delete or overwrite everything that came after it, which is exactly the
 * "stop A, send B, continue A and lose B" failure this guard exists to prevent.
 */
internal fun shouldShowRecoveryCard(
    state: ChatMessageState,
    role: ChatRole,
    isLastMessage: Boolean,
): Boolean = role == ChatRole.Assistant &&
    isLastMessage &&
    (state == ChatMessageState.Failed || state == ChatMessageState.Interrupted)

internal fun MessageRecoveryActionKind.titleRes(): Int {
    return when (this) {
        MessageRecoveryActionKind.Retry -> R.string.retry
        MessageRecoveryActionKind.EditMessage -> R.string.edit_message
        MessageRecoveryActionKind.Regenerate -> R.string.regenerate
        MessageRecoveryActionKind.SwitchModel -> R.string.switch_model
        MessageRecoveryActionKind.SwitchKey -> R.string.relay_chat_switch_key
        MessageRecoveryActionKind.ContinueGeneration -> R.string.continue_generating
        MessageRecoveryActionKind.RetryWithoutLocalCustomFields -> R.string.retry_without_custom_fields
        MessageRecoveryActionKind.RetryWithoutAdditionalBody -> R.string.additional_body_retry_without
        MessageRecoveryActionKind.RetryWithoutLocatedSetting -> R.string.retry_without_this_setting
    }
}

internal fun performRecoveryAction(
    action: MessageRecoveryActionKind,
    onRetry: () -> Unit,
    onEdit: () -> Unit,
    onRegenerate: () -> Unit,
    onSwitchModel: () -> Unit,
    onContinue: () -> Unit,
    onRetryWithoutLocalCustomFields: () -> Unit = {},
    onSwitchKey: () -> Unit = {},
) {
    when (action) {
        MessageRecoveryActionKind.Retry -> onRetry()
        MessageRecoveryActionKind.EditMessage -> onEdit()
        MessageRecoveryActionKind.Regenerate -> onRegenerate()
        MessageRecoveryActionKind.SwitchModel -> onSwitchModel()
        MessageRecoveryActionKind.SwitchKey -> onSwitchKey()
        MessageRecoveryActionKind.ContinueGeneration -> onContinue()
        // Both variants run the same retry; they differ only in how precisely the card could name
        // what is being left out.
        MessageRecoveryActionKind.RetryWithoutLocalCustomFields,
        MessageRecoveryActionKind.RetryWithoutAdditionalBody,
        MessageRecoveryActionKind.RetryWithoutLocatedSetting,
        -> onRetryWithoutLocalCustomFields()
    }
}
