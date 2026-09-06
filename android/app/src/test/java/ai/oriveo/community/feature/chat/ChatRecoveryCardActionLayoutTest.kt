package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.messageRecoveryActionsEnabled
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import ai.oriveo.community.feature.chat.recovery.shouldShowDeliveredRegenerateAction
import ai.oriveo.community.feature.chat.recovery.shouldShowRecoveryCard
import ai.oriveo.community.feature.chat.recovery.titleRes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatRecoveryCardActionLayoutTest {
    @Test
    fun `local custom pre-token 400 promotes the explicit omit-custom action only`() {
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsAvailable = true,
            customRetryWithoutFieldsCode = "capability_setting_pre_token_400:custom:generation:-:L3RlbXBlcmF0dXJl",
        )
        assertEquals(MessageRecoveryActionKind.RetryWithoutLocalCustomFields, layout.primary)
        assertEquals(R.string.retry_without_custom_fields, layout.primary.titleRes())
        assertEquals(MessageRecoveryActionKind.EditMessage, layout.secondary)
    }

    @Test
    fun `provider recipe pre-token 400 uses setting-specific localized action`() {
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = false,
            customRetryWithoutFieldsAvailable = true,
            customRetryWithoutFieldsCode = "capability_setting_pre_token_400:provider_recipe:web:cmVjaXBl:L3dlYl9zZWFyY2hfb3B0aW9ucw",
        )
        assertEquals(MessageRecoveryActionKind.RetryWithoutLocatedSetting, layout.primary)
        assertEquals(R.string.retry_without_this_setting, layout.primary.titleRes())
        assertEquals(MessageRecoveryActionKind.EditMessage, layout.secondary)
    }

    @Test
    fun `interrupted recovery primary is continue and secondary keeps regenerate`() {

        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Interrupted,
            shouldOfferModelSwitch = false,
        )

        assertEquals(MessageRecoveryActionKind.ContinueGeneration, layout.primary)
        assertEquals(MessageRecoveryActionKind.Regenerate, layout.secondary)
        assertNull(layout.tertiary)
    }

    @Test
    fun `failed recovery keeps retry edit and optional switch model`() {
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = true,
        )

        assertEquals(MessageRecoveryActionKind.Retry, layout.primary)
        assertEquals(MessageRecoveryActionKind.EditMessage, layout.secondary)
        assertEquals(MessageRecoveryActionKind.SwitchModel, layout.tertiary)
    }

    @Test
    fun `recovery actions disable while a message is already generating`() {
        assertFalse(messageRecoveryActionsEnabled(isSendingMessage = true))
        assertTrue(messageRecoveryActionsEnabled(isSendingMessage = false))
    }

    @Test
    fun `delivered regenerate entry hides while a message is already generating`() {
        assertTrue(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = false))
        assertFalse(shouldShowDeliveredRegenerateAction(ChatMessageState.Delivered, isSendingMessage = true))
        assertFalse(shouldShowDeliveredRegenerateAction(ChatMessageState.Interrupted, isSendingMessage = false))
    }

    @Test
    fun `recovery card shows only for the last interrupted message`() {

        assertTrue(shouldShowRecoveryCard(ChatMessageState.Interrupted, ChatRole.Assistant, isLastMessage = true))
        assertFalse(shouldShowRecoveryCard(ChatMessageState.Interrupted, ChatRole.Assistant, isLastMessage = false))
    }

    @Test
    fun `recovery card shows only for the last failed message`() {
        assertTrue(shouldShowRecoveryCard(ChatMessageState.Failed, ChatRole.Assistant, isLastMessage = true))
        assertFalse(shouldShowRecoveryCard(ChatMessageState.Failed, ChatRole.Assistant, isLastMessage = false))
    }

    @Test
    fun `recovery card hidden for delivered or user message even when last`() {
        assertFalse(shouldShowRecoveryCard(ChatMessageState.Delivered, ChatRole.Assistant, isLastMessage = true))
        assertFalse(shouldShowRecoveryCard(ChatMessageState.Generating, ChatRole.Assistant, isLastMessage = true))
        assertFalse(shouldShowRecoveryCard(ChatMessageState.Interrupted, ChatRole.User, isLastMessage = true))
    }
}
