package ai.oriveo.community.feature.chat.recovery

import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** When the current model is a realtime voice model, the regenerate / edit actions on messages are not rendered at all; text models are unchanged. */
class MessageRealtimeActionsTest {
    @Test
    fun realtime_model_hides_regenerate() {
        assertFalse(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = false, isRealtimeModel = true))
    }

    @Test
    fun text_model_keeps_regenerate() {
        assertTrue(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = false, isRealtimeModel = false))
        assertTrue(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = false))
        assertFalse(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = true))
        assertFalse(shouldShowDeliveredRegenerateAction(ChatMessageState.Failed, isSendingMessage = false))
    }

    @Test
    fun realtime_model_hides_edit() {
        assertFalse(shouldShowEditAction(ChatRole.User, isRealtimeModel = true))
    }

    @Test
    fun text_model_keeps_edit_for_user_messages_only() {
        assertTrue(shouldShowEditAction(ChatRole.User, isRealtimeModel = false))
        assertFalse(shouldShowEditAction(ChatRole.Assistant, isRealtimeModel = false))
    }

    @Test
    fun realtime_model_recovery_card_only_offers_switch_model() {
        val switchOnly = MessageRecoveryCardActionLayout(MessageRecoveryActionKind.SwitchModel, null, null)
        for (state in listOf(ChatMessageState.Failed, ChatMessageState.Interrupted)) {
            assertEquals(
                switchOnly,
                resolveMessageRecoveryCardActionLayout(state, shouldOfferModelSwitch = false, offersSwitchKey = true, isRealtimeModel = true),
            )
        }
        // Back to a text model: unchanged (failed card offers retry + edit; interrupted card offers continue + regenerate).
        assertEquals(
            MessageRecoveryCardActionLayout(MessageRecoveryActionKind.Retry, MessageRecoveryActionKind.EditMessage, null),
            resolveMessageRecoveryCardActionLayout(ChatMessageState.Failed, shouldOfferModelSwitch = false),
        )
        assertEquals(
            MessageRecoveryCardActionLayout(MessageRecoveryActionKind.ContinueGeneration, MessageRecoveryActionKind.Regenerate, null),
            resolveMessageRecoveryCardActionLayout(ChatMessageState.Interrupted, shouldOfferModelSwitch = false),
        )
    }
}
