package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.isRelayAttachmentUnsupportedDetail
import ai.oriveo.community.feature.chat.recovery.relayRecoveryOffersModelSwitch
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * BOARD-OPTIONS-11: the first rejection of a Relay request carrying native file blocks counts as a rejection signal (400 / 404 / 415 / 422 before output),
 * and if the fallback chain finally fails or all files are scans that cannot fall back, the failure message is stamped with [ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL],
 * and the card's primary action is Switch Model; 413, a successful fallback, and non-Relay do not stamp it; when image-recognition rejection also applies, the image card takes precedence.
 * Everything enters through production ChatRepository + production RelayTransportCoordinator, with MockEngine as upstream.
 */
class RelayFileUnsupportedCardTest {

    @Before
    fun setUp() {
        NativeFileFallback.resetForTest()
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"gemini":{"resolveMap":{"$MODEL":"$MODEL"},
               "models":{"$MODEL":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
    }

    @After
    fun tearDown() {
        NativeFileFallback.resetForTest()
        MetadataTestFixtures.clear()
    }

    @Test
    fun `text resend also rejected marks the failed message and offers Switch Model`() = runTest {
        val harness = Harness(400, 400)
        val failed = harness.send(listOf(textPdf()))

        assertEquals(2, harness.bodies.size)
        assertTrue("The first request carries the native file block", harness.bodies[0].contains("inlineData"))
        assertFalse("The resend is text", harness.bodies[1].contains("inlineData"))
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, failed.errorDetail)
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(failed.errorDetail))
        assertTrue(relayRecoveryOffersModelSwitch(isRateLimitError = false, errorDetail = failed.errorDetail))
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = true,
            relayAttachmentUnsupported = isRelayAttachmentUnsupportedDetail(failed.errorDetail),
        )
        assertEquals(MessageRecoveryActionKind.SwitchModel, layout.primary)
        assertEquals(MessageRecoveryActionKind.EditMessage, layout.secondary)
        assertEquals(MessageRecoveryActionKind.Retry, layout.tertiary)
    }

    @Test
    fun `scanned only files that cannot fall back are marked`() = runTest {
        val harness = Harness(415)
        val failed = harness.send(listOf(scannedPdf()))
        assertEquals(1, harness.bodies.size)
        assertEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, failed.errorDetail)
    }

    @Test
    fun `fallback success, 413 and requests without native files are not marked`() = runTest {
        val recovered = Harness(400).send(listOf(textPdf()))
        assertEquals(ChatMessageState.Delivered, recovered.state)
        assertNotEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, recovered.errorDetail)

        val tooLarge = Harness(413, 413).send(listOf(textPdf()))
        assertEquals(ChatMessageState.Failed, tooLarge.state)
        assertNotEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, tooLarge.errorDetail)

        val plain = Harness(400).send(null)
        assertEquals(ChatMessageState.Failed, plain.state)
        assertNotEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, plain.errorDetail)
    }

    @Test
    fun `a protocol switch that starts output and then fails is not marked`() = runTest {
        // Native file 404, text resend 404, switch to Chat: the stream breaks only after body output, so no file-rejection marker is stamped.
        // When the connection has a chosen protocol, models following the connection do not switch protocol; a model must have its own probed protocol to switch.
        val harness = Harness(
            404, 404,
            candidates = listOf(RelayTransport.GeminiGenerateContent, RelayTransport.OpenAIChatCompletions),
            modelTransportSource = RelayTransportSource.Observed,
            chatReply = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n" +
                "data: {\"error\":{\"message\":\"boom\",\"code\":400}}\n\n",
        )
        val failed = harness.send(listOf(textPdf()))
        assertEquals(3, harness.bodies.size)
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals("partial", failed.text)
        assertNotEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, failed.errorDetail)
    }

    @Test
    fun `image rejection wins over file rejection on the same failure`() = runTest {
        val failed = Harness(400, 400).send(listOf(image(), textPdf()))
        assertEquals(ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL, failed.errorDetail)
    }

    @Test
    fun `non relay sends get no file rejection callback`() = runTest {
        var callbackSeen: Boolean? = null
        val service = mockk<ProviderService>()
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            val options = arg<ChatRequestOptions>(7)
            flow {
                callbackSeen = options.relayFileRejected != null
                options.relayFileRejected?.invoke()
                throw ProviderServiceError.Upstream(400, "rejected")
            }
        }
        val official = Provider(id = "gemini-1", kind = ProviderKind.Gemini, apiKey = "k", status = ProviderConnectionState.Connected)
        val failed = Harness(service = service, provider = official).send(listOf(textPdf()))
        assertEquals(false, callbackSeen)
        assertEquals(ChatMessageState.Failed, failed.state)
        assertNotEquals(ChatRepository.RELAY_FILE_UNSUPPORTED_DETAIL, failed.errorDetail)
    }

    private fun textPdf() = Attachment(
        id = "text-pdf",
        kind = AttachmentKind.File,
        fileName = "report.pdf",
        mimeType = "application/pdf",
        base64Data = Base64.getEncoder().encodeToString(EXTRACTED.toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = ORIGINAL,
    )

    private fun scannedPdf() = Attachment(
        id = "scan-pdf",
        kind = AttachmentKind.File,
        fileName = "scan.pdf",
        mimeType = "application/pdf",
        base64Data = "",
        extractedSizeBytes = 5_000,
        originalBase64Data = ORIGINAL,
        extractionErrorCode = "scanned_pdf",
    )

    private fun image() = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = IMAGE_BASE64)

    /** Production ChatRepository + production RelayTransportCoordinator (Gemini protocol); [statuses] are given in request order and once used up everything is 200. */
    private inner class Harness(
        vararg statuses: Int,
        private val service: ProviderService? = null,
        provider: Provider? = null,
        private val candidates: List<RelayTransport> = listOf(RelayTransport.GeminiGenerateContent),
        private val chatReply: String? = null,
        modelTransportSource: RelayTransportSource? = null,
    ) {
        private val codes = statuses.toList()
        val bodies = mutableListOf<String>()
        private val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        private val model = AIModel(
            id = MODEL,
            name = MODEL,
            capabilities = listOf(ModelCapability.Text),
            relayTransport = modelTransportSource?.let { RelayTransport.GeminiGenerateContent },
            relayTransportSource = modelTransportSource,
        )
        private val provider = provider ?: Provider(
            id = "c1",
            kind = ProviderKind.Relay,
            apiKey = "relay-key",
            baseUrlText = "https://relay.example.com/v1beta",
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.GeminiGenerateContent,
                authMode = RelayAuthMode.XGoogApiKey,
                resolvedAPIBaseURL = "https://relay.example.com/v1beta",
            ),
            models = listOf(model),
        )
        private val providerRepository = mockk<ProviderRepository>(relaxed = true)
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val updates = mutableListOf<ChatMessage>()
        private val json = Json { ignoreUnknownKeys = true }
        private val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { request ->
                    bodies += when (val content = request.body) {
                        is TextContent -> content.text
                        is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                        else -> ""
                    }
                    val status = codes.getOrNull(bodies.size - 1) ?: 200
                    if (chatReply != null && request.url.toString().endsWith("/chat/completions")) {
                        respond(chatReply, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                    } else if (status == 200) {
                        respond(SUCCESS, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                    } else {
                        respond(
                            """{"error":{"message":"rejected"}}""",
                            HttpStatusCode.fromValue(status),
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    }
                },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
            protocolCandidates = { _, _, _ -> candidates },
        )

        suspend fun send(attachments: List<Attachment>?): ChatMessage {
            every { providerRepository.serviceFor(any<Provider>(), any()) } returns (service ?: coordinator)
            every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { conversationRepository.updateMessage(any(), capture(updates)) } returns Unit
            val repository = ChatRepository(
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                attachmentStore = mockk<AttachmentStore>(relaxed = true),
                relayNegativeCache = cache,
            )
            repository.sendMessage(
                conversation = Conversation(
                    id = "conversation-1", title = "t", providerID = provider.id,
                    providerKind = provider.kind, modelID = model.id,
                ),
                text = "read this",
                provider = provider,
                modelID = model.id,
                existingMessages = emptyList(),
                attachments = attachments,
                requestOptions = ChatRequestOptions(
                    activeModel = model,
                    capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                        partitionId = "partition",
                        connectionInstanceId = provider.id,
                        connectionGeneration = "generation",
                        credentialEpoch = "epoch",
                        providerKind = provider.kind.rawValue,
                        authMode = provider.authMode.rawValue,
                    ),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
            )
            return updates.last()
        }
    }

    private companion object {
        const val MODEL = "gemini-x"
        const val EXTRACTED = "extracted report body"
        const val ORIGINAL = "VEVYVFBERg=="
        const val IMAGE_BASE64 = "iVBORw0KGgo="
        const val SUCCESS = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}\n\n"
    }
}
