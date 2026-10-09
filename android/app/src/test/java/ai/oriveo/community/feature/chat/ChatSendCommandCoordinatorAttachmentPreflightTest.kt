package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.AttachmentSendPreflight
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import java.util.Base64
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When send is tapped and this turn's attachments do not fit: no conversation is created, no message is created, the composer is not cleared, and only a notice is shown.
 * The assertions all rest on the real behavior of the production send entry point [ChatSendCommandCoordinator.sendMessage].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCommandCoordinatorAttachmentPreflightTest {
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private class Outcome {
        var blocked: ProviderServiceError? = null
        var composerConsumed = false
        var launchedAttachments: List<Attachment>? = null
        var launched = false
        var settled = false
    }

    private fun TestScope.send(
        provider: Provider,
        attachments: List<Attachment>,
        text: String = "read these",
        resolveSendOptions: ((Provider, String) -> AttachmentSendPreflight.SendOptions?)? = null,
    ): Outcome {
        val outcome = Outcome()
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) } returns Conversation(
            id = "conversation-1",
            title = "New Chat",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = "relay-model",
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
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onAttachmentsUndeliverable = { outcome.blocked = it },
            resolveAttachmentSendOptions = { p, modelId -> resolveSendOptions?.invoke(p, modelId) },
            onComposerConsumed = { outcome.composerConsumed = true },
            requestPin = {},
            onSendSettled = { outcome.settled = true },
            launchSend = ChatSendLauncher { _, _, _, _, _, sent, _, _, _, _ ->
                outcome.launched = true
                outcome.launchedAttachments = sent
            },
        )
        coordinator.sendMessage(text, attachments, provider.id, "relay-model")
        advanceUntilIdle()
        return outcome
    }

    private fun relayProvider(transport: RelayTransport = RelayTransport.OpenAIChatCompletions): Provider {
        val model = AIModel(
            id = "relay-model",
            name = "Relay Model",
            isDefault = true,
            capabilities = listOf(ModelCapability.Text, ModelCapability.File),
        )
        return Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
            catalogModels = listOf(model),
        )
    }

    private fun textFile(name: String, bytes: Int) = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = "text/plain",
        base64Data = Base64.getEncoder().encodeToString("x".repeat(bytes).toByteArray()),
    )

    @Test
    fun `text over the budget is stopped before any conversation or message exists`() = runTest {
        val outcome = send(relayProvider(), listOf(textFile("a.txt", 150 * 1024), textFile("b.txt", 150 * 1024)))

        assertEquals(ProviderServiceError.AttachmentTextOverLimit(listOf("b.txt")), outcome.blocked)
        assertFalse("The composer must not be cleared", outcome.composerConsumed)
        assertFalse("The send must not proceed", outcome.launched)
        assertTrue("The send guard must be reset", outcome.settled)
        coVerify(exactly = 0) { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { conversationRepository.updateDraft(any(), any()) }

        val toast = attachmentsUndeliverableToast(outcome.blocked!!)!!
        assertEquals(
            UiText.Resource(R.string.file_extraction_send_blocked_text_budget, listOf("b.txt")),
            toast.message,
        )
        assertEquals(GlobalToastStyle.Error, toast.style)
    }

    @Test
    fun `the toast for count and text limits together has one line for each`() {
        val toast = attachmentsUndeliverableToast(
            ProviderServiceError.AttachmentTextOverLimit(listOf("big.txt"), countLimit = 3),
        )!!
        assertEquals(
            UiText.Lines(
                listOf(
                    UiText.Resource(R.string.file_attachment_count_limit_reached, listOf(3)),
                    UiText.Resource(R.string.file_extraction_send_blocked_text_budget, listOf("big.txt")),
                ),
            ),
            toast.message,
        )
    }

    @Test
    fun `the preflight is asked with the options this send will actually use`() = runTest {
        val asked = mutableListOf<String>()
        val outcome = send(
            relayProvider(),
            listOf(textFile("fits.txt", 16)),
            resolveSendOptions = { provider, modelId ->
                asked += "${provider.id}/$modelId"
                AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = true, toolLoopPossible = false)
            },
        )
        assertEquals(listOf("relay-1/relay-model"), asked)
        assertTrue(outcome.launched)
    }

    @Test
    fun `too many files alone is reported as a count limit`() = runTest {
        val max = FileExtractionLimits.DEFAULT.maxFiles
        val files = (0..max).map { textFile("f$it.txt", 16) }

        val outcome = send(relayProvider(RelayTransport.LlamaCppNative), files)

        assertEquals(ProviderServiceError.AttachmentCountOverLimit(max), outcome.blocked)
        assertFalse(outcome.composerConsumed)
        assertFalse(outcome.launched)
        coVerify(exactly = 0) { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) }
        assertEquals(
            UiText.Resource(R.string.file_attachment_count_limit_reached, listOf(max)),
            attachmentsUndeliverableToast(outcome.blocked!!)!!.message,
        )
    }

    @Test
    fun `attachments that fit are sent exactly as before`() = runTest {
        val files = listOf(textFile("a.txt", 1024), textFile("b.txt", 1024))

        val outcome = send(relayProvider(), files)

        assertNull(outcome.blocked)
        assertTrue(outcome.composerConsumed)
        assertTrue(outcome.launched)
        assertEquals(files, outcome.launchedAttachments)
        coVerify(exactly = 1) { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a file whose text is still on disk is left to the send path`() = runTest {
        // A file imported generically stores only a reference, so the body size is only known once it is hydrated at send time.
        val pending = Attachment(
            id = "raw",
            kind = AttachmentKind.File,
            fileName = "raw.bin",
            mimeType = "application/octet-stream",
            rawContentRef = "blob-1",
        )
        val files = listOf(textFile("a.txt", 150 * 1024), textFile("b.txt", 150 * 1024), pending)

        val outcome = send(relayProvider(), files)

        assertNull(outcome.blocked)
        assertTrue(outcome.launched)
    }

    @Test
    fun `an unresolved route is left to the send path`() = runTest {
        // The official Responses route depends on the metadata catalog; while the catalog has not arrived, no verdict is made in advance.
        MetadataTestFixtures.clear()
        val files = listOf(textFile("a.txt", 150 * 1024), textFile("b.txt", 150 * 1024))

        val outcome = send(relayProvider(RelayTransport.OpenAIResponses), files)

        assertNull(outcome.blocked)
        assertTrue(outcome.launched)
    }

    @Test
    fun `messages without files never consult the route`() = runTest {
        val outcome = send(relayProvider(), emptyList(), text = "hello")

        assertNull(outcome.blocked)
        assertTrue(outcome.launched)
    }
}
