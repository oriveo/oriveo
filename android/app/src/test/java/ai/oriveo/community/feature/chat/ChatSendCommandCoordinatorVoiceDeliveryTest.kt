package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextDelivery
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuoteContext
import io.mockk.coEvery
import io.mockk.mockk
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Voice delivery at the production send entry [ChatSendCommandCoordinator.sendMessage]: a voice turn reaches the
 * launcher with delivery = VOICE through the same gates and leaves the composer alone; a typed send is unchanged.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCommandCoordinatorVoiceDeliveryTest {
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    private val model = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "local-key",
        models = listOf(model),
    )

    private class Outcome {
        var launches = 0
        var delivery: ContextDelivery? = null
        var composerConsumed = false
        var disclosure: PendingDisclosurePayload? = null
    }

    /** Records which overload ran: the plain one means delivery never reached the launcher. */
    private fun launcher(outcome: Outcome) = object : ChatSendLauncher {
        override fun launch(
            conversation: Conversation,
            provider: Provider,
            modelId: String,
            text: String,
            existingMessages: List<ChatMessage>,
            attachments: List<Attachment>?,
            persistUserMessage: Boolean,
            appendToAssistant: ChatMessage?,
            userMessageAlreadyInHistory: Boolean,
            quoteContext: QuoteContext?,
            attemptKind: ContextConfirmAttempt,
        ) {
            outcome.launches++
            outcome.delivery = null
        }

        override fun launch(
            conversation: Conversation,
            provider: Provider,
            modelId: String,
            text: String,
            existingMessages: List<ChatMessage>,
            attachments: List<Attachment>?,
            persistUserMessage: Boolean,
            appendToAssistant: ChatMessage?,
            userMessageAlreadyInHistory: Boolean,
            quoteContext: QuoteContext?,
            attemptKind: ContextConfirmAttempt,
            delivery: ContextDelivery?,
        ) {
            outcome.launches++
            outcome.delivery = delivery
        }
    }

    private fun TestScope.send(delivery: ContextDelivery?, disclosureAccepted: Boolean = true): Outcome {
        val outcome = Outcome()
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns disclosureAccepted
        coEvery { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) } returns Conversation(
            id = "conversation-1",
            title = "New Chat",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = model.id,
            messages = emptyList(),
        )
        coEvery { conversationRepository.getWithMessages(any()) } returns null
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { null },
            currentConversationId = { null },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, payload -> outcome.disclosure = payload },
            onConversationActivated = {},
            onAttachmentsUndeliverable = {},
            resolveAttachmentSendOptions = { _, _ -> null },
            outboundHistory = { it },
            onComposerConsumed = { outcome.composerConsumed = true },
            requestPin = {},
            onSendSettled = {},
            launchSend = launcher(outcome),
        )
        coordinator.sendMessage(
            text = "what's the weather",
            attachments = null,
            providerId = provider.id,
            modelId = model.id,
            delivery = delivery,
        )
        advanceUntilIdle()
        return outcome
    }

    @Test
    fun `voice turn reaches the launcher with VOICE and keeps the composer`() = runTest(timeout = 30.seconds) {
        val outcome = send(ContextDelivery.VOICE)
        assertEquals(1, outcome.launches)
        assertEquals(ContextDelivery.VOICE, outcome.delivery)
        assertFalse(outcome.composerConsumed)
    }

    @Test
    fun `typed send is unchanged`() = runTest(timeout = 30.seconds) {
        val outcome = send(delivery = null)
        assertEquals(1, outcome.launches)
        assertNull(outcome.delivery)
        assertTrue(outcome.composerConsumed)
    }

    @Test
    fun `voice turn stopped by the disclosure gate keeps VOICE for the resumed send`() = runTest(timeout = 30.seconds) {
        val outcome = send(ContextDelivery.VOICE, disclosureAccepted = false)
        assertEquals(0, outcome.launches)
        assertEquals(ContextDelivery.VOICE, outcome.disclosure?.delivery)
    }
}
