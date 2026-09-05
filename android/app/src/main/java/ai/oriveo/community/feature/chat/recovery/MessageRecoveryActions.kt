package ai.oriveo.community.feature.chat.recovery

import ai.oriveo.community.R
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole

internal enum class MessageRecoveryActionKind {
    Retry,
    EditMessage,
    Regenerate,
    SwitchModel,
    ContinueGeneration,
    RetryWithoutLocalCustomFields,
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
): MessageRecoveryCardActionLayout {
    if (customRetryWithoutFieldsAvailable) {
        return MessageRecoveryCardActionLayout(
            // When the diagnostic pinned the offending setting down to a single recipe entry we can
            // promise to drop just that one; otherwise all we can honestly offer is a retry with the
            // whole local custom fragment left out.
            primary = if (customRetryWithoutFieldsCode?.startsWith("capability_setting_pre_token_400:provider_recipe:") == true) {
                MessageRecoveryActionKind.RetryWithoutLocatedSetting
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
        MessageRecoveryActionKind.ContinueGeneration -> R.string.continue_generating
        MessageRecoveryActionKind.RetryWithoutLocalCustomFields -> R.string.retry_without_custom_fields
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
) {
    when (action) {
        MessageRecoveryActionKind.Retry -> onRetry()
        MessageRecoveryActionKind.EditMessage -> onEdit()
        MessageRecoveryActionKind.Regenerate -> onRegenerate()
        MessageRecoveryActionKind.SwitchModel -> onSwitchModel()
        MessageRecoveryActionKind.ContinueGeneration -> onContinue()
        // Both variants run the same retry; they differ only in how precisely the card could name
        // what is being left out.
        MessageRecoveryActionKind.RetryWithoutLocalCustomFields,
        MessageRecoveryActionKind.RetryWithoutLocatedSetting,
        -> onRetryWithoutLocalCustomFields()
    }
}
