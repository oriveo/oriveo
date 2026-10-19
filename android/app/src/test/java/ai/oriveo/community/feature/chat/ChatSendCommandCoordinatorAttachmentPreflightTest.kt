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
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
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
import kotlinx.serialization.json.jsonObject
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
        modelId: String = "relay-model",
        existing: Conversation? = null,
        outboundHistory: (suspend (List<ChatMessage>) -> List<ChatMessage>)? = null,
        stored: Provider? = provider,
    ): Outcome {
        val outcome = Outcome()
        coEvery { providerRepository.getById(provider.id) } returns stored
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.create(any(), any(), any(), any(), any(), any(), any()) } returns Conversation(
            id = "conversation-1",
            title = "New Chat",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = "relay-model",
            messages = emptyList(),
        )
        coEvery { conversationRepository.getWithMessages(any()) } returns existing
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { existing },
            currentConversationId = { existing?.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            outboundHistory = outboundHistory ?: { it },
            onAttachmentsUndeliverable = { outcome.blocked = it },
            resolveAttachmentSendOptions = { p, modelId -> resolveSendOptions?.invoke(p, modelId) },
            onComposerConsumed = { outcome.composerConsumed = true },
            requestPin = {},
            onSendSettled = { outcome.settled = true },
            launchSend = ChatSendLauncher { _, _, _, _, _, sent, _, _, _, _, _ ->
                outcome.launched = true
                outcome.launchedAttachments = sent
            },
        )
        coordinator.sendMessage(text, attachments, provider.id, modelId)
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

    /**
     * When the conversation history contains a video the outbound does not use Gemini Interactions; the preflight reads the whole history and judges the same way -
     * a file that only generateContent (native PDF upload) can accommodate must not be blocked under Interactions limits.
     */
    @Test
    fun `video earlier in the conversation keeps the preflight on generateContent`() = runTest {
        applyGeminiInteractionsMetadata()
        val model = AIModel(id = "gemini-3-flash", name = "Gemini 3 Flash", isDefault = true)
        val gemini = Provider(
            id = "gemini-1", kind = ProviderKind.Gemini, status = ProviderConnectionState.Connected,
            apiKey = "key", models = listOf(model),
        )
        coEvery { providerRepository.getById(gemini.id) } returns gemini
        val pdf = textFile("paper.pdf", 150 * 1024).copy(
            mimeType = "application/pdf", originalBase64Data = "JVBERi0=", extractedSizeBytes = 8,
        )
        val files = listOf(textFile("a.txt", 150 * 1024), pdf)
        val webOn = { _: Provider, _: String ->
            AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = true, toolLoopPossible = false)
        }
        fun conversation(history: List<ChatMessage>) = Conversation(
            id = "conversation-1", title = "Chat", providerID = gemini.id, providerKind = ProviderKind.Gemini,
            modelID = model.id, messages = history,
        )
        val textOnly = ChatMessage(
            id = "u0", role = ChatRole.User, text = "hi", providerKind = ProviderKind.Gemini, providerName = "Gemini",
            modelName = model.id, state = ai.oriveo.community.core.model.ChatMessageState.Delivered,
        )
        val withVideo = textOnly.copy(
            id = "u1",
            attachments = listOf(Attachment(id = "v", kind = AttachmentKind.Video, fileName = "clip.mp4", mimeType = "video/mp4")),
        )

        val blocked = send(gemini, files, resolveSendOptions = webOn, modelId = model.id, existing = conversation(listOf(textOnly)))
        assertEquals(ProviderServiceError.AttachmentTextOverLimit(listOf("paper.pdf")), blocked.blocked)

        val sent = send(gemini, files, resolveSendOptions = webOn, modelId = model.id, existing = conversation(listOf(withVideo)))
        assertNull(sent.blocked)
        assertTrue(sent.launched)
    }

    /**
     * The preflight judges video using the outbound history (the same trimming chain as sending). When a video exists only in early turns and is trimmed away by the attachment budget,
     * the outbound carries no video and uses Interactions; the preflight judges the same way and blocks files that only generateContent can accommodate under Interactions limits.
     */
    @Test
    fun GI_PREFLIGHT_USES_OUTBOUND_HISTORY() = runTest {
        applyGeminiInteractionsMetadata()
        val model = AIModel(id = "gemini-3-flash", name = "Gemini 3 Flash", isDefault = true)
        val gemini = Provider(
            id = "gemini-1", kind = ProviderKind.Gemini, status = ProviderConnectionState.Connected,
            apiKey = "key", models = listOf(model),
        )
        coEvery { providerRepository.getById(gemini.id) } returns gemini
        val pdf = textFile("paper.pdf", 150 * 1024).copy(
            mimeType = "application/pdf", originalBase64Data = "JVBERi0=", extractedSizeBytes = 8,
        )
        val files = listOf(textFile("a.txt", 150 * 1024), pdf)
        // A large video in an early turn is stored only as a disk reference: 20MiB exceeds the outbound attachment budget and is trimmed to a placeholder line.
        val earlyVideo = ChatMessage(
            id = "u0", role = ChatRole.User, text = "clip", providerKind = ProviderKind.Gemini, providerName = "Gemini",
            modelName = model.id, state = ai.oriveo.community.core.model.ChatMessageState.Delivered,
            attachments = listOf(
                Attachment(id = "v", kind = AttachmentKind.Video, fileName = "clip.mp4", mimeType = "video/mp4", rawContentRef = "blob-v"),
            ),
        )
        val answer = earlyVideo.copy(id = "a0", role = ChatRole.Assistant, text = "A ball rolls.", attachments = null)
        val existing = Conversation(
            id = "conversation-1", title = "Chat", providerID = gemini.id, providerKind = ProviderKind.Gemini,
            modelID = model.id, messages = listOf(earlyVideo, answer),
        )
        // The same trimming chain as production sending (ChatRepository.sendMessage calls it too).
        val trim: suspend (List<ChatMessage>) -> List<ChatMessage> = { raw ->
            ai.oriveo.community.core.data.repository.OutboundHistory.projected(
                rawMessages = raw,
                imageSizeOf = { 0L },
                blobSizeOf = { ref -> if (ref == "blob-v") 20L * 1024 * 1024 else 0L },
            )
        }
        val webOn = { _: Provider, _: String ->
            AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = true, toolLoopPossible = false)
        }

        // Outbound: the history produced by the same trimming chain no longer has a video, and the wire is Interactions.
        val outbound = trim(existing.messages + ChatMessage(
            id = "u1", role = ChatRole.User, text = "read these", providerKind = ProviderKind.Gemini, providerName = "Gemini",
            modelName = model.id, state = ai.oriveo.community.core.model.ChatMessageState.Delivered, attachments = files,
        ))
        assertFalse(ai.oriveo.community.core.provider.GeminiService.hasVideoAttachment(outbound))
        assertTrue(
            ai.oriveo.community.core.provider.GeminiService.interactionsRoute(
                model.id, true, ReasoningMode.Automatic, ai.oriveo.community.core.provider.GeminiService.hasVideoAttachment(outbound),
            ) != null,
        )
        // Preflight: judges Interactions the same way and blocks the PDF accordingly.
        val outcome = send(gemini, files, resolveSendOptions = webOn, modelId = model.id, existing = existing, outboundHistory = trim)
        assertEquals(ProviderServiceError.AttachmentTextOverLimit(listOf("paper.pdf")), outcome.blocked)
    }

    private fun applyGeminiInteractionsMetadata() {
        val root = java.io.File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val registry = kotlinx.serialization.json.Json.parseToJsonElement(
            java.io.File(root, "shared/capabilityrecipe/capability_runtime.v1.json").readText(),
        ).jsonObject
        val runtime = kotlinx.serialization.json.JsonObject(registry + mapOf(
            "revision" to kotlinx.serialization.json.JsonPrimitive("sha256:preflight-test"),
            "generatedAt" to kotlinx.serialization.json.JsonPrimitive("2026-10-13T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(
            """{"version":1,"capabilityRuntime":$runtime,"providers":{"gemini":{
              "resolveMap":{"gemini-3-flash":"gemini-3-flash"},
              "models":{"gemini-3-flash":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true,
                "transport":"gemini_interactions",
                "capabilityControls":{"web":{"state":"auto_available","recipeRef":"gemini.interactions.web.v1"}}}}}}}""",
        )
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
