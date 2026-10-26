package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.NativeFileFallback
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Native file fallback on relay routes: when the upstream rejects a request carrying file blocks with 400 / 404 / 413 / 415 / 422 before producing any output,
 * the request is resent once with the files injected as text. Every case enters through the Service's real send entry point, and the request body is captured by MockEngine.
 */
class NativeFileFallbackSendChainTest {

    private val json = Json { ignoreUnknownKeys = true }

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

    private fun message(attachment: Attachment?): List<ChatMessage> = listOf(
        ProviderTestFixtures.userMessage("read", ProviderKind.Relay, MODEL)
            .copy(attachments = attachment?.let(::listOf)),
    )

    /** [statuses] gives the status codes in request order; every request after them gets 200. */
    private fun client(bodies: MutableList<String>, vararg statuses: Int): HttpClient = HttpClient(
        MockEngine { request ->
            bodies += when (val body = request.body) {
                is TextContent -> body.text
                is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
                else -> error("unexpected request body ${body::class}")
            }
            val status = statuses.getOrNull(bodies.size - 1) ?: 200
            if (status == 200) {
                respond(SUCCESS, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            } else {
                respond(
                    """{"error":{"message":"rejected"}}""",
                    HttpStatusCode.fromValue(status),
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        },
    )

    private fun relayOptions() = ChatRequestOptions(
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.GeminiGenerateContent,
            authMode = RelayAuthMode.XGoogApiKey,
        ),
    )

    private suspend fun relayStream(client: HttpClient, attachment: Attachment?): List<StreamEvent> =
        RelayTransportCoordinator(client = client, json = json, transportRegistry = TransportRegistry(json))
            .sendMessageStream(
                apiKey = "relay-key", modelID = MODEL, messages = message(attachment),
                baseUrl = "https://relay.example.com/v1beta", supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = relayOptions(),
            ).toList()

    @Test
    fun `a rejected native file is resent as text once and the connection is remembered`() = runTest {
        val bodies = mutableListOf<String>()
        val client = client(bodies, 400)

        val events = relayStream(client, textPdf())

        assertTrue("The resend should succeed: $events", events.last() is StreamEvent.Done)
        assertEquals(2, bodies.size)
        assertTrue(bodies[0], bodies[0].contains(""""inlineData":{"mimeType":"application/pdf","data":"$ORIGINAL"}"""))
        assertFalse(bodies[0], bodies[0].contains(EXTRACTED))
        assertFalse("The resend should not carry file blocks again: ${bodies[1]}", bodies[1].contains("inlineData"))
        assertTrue(bodies[1], bodies[1].contains(EXTRACTED))

        // The next message on the same connection goes straight to text, with a single request.
        relayStream(client, textPdf())
        assertEquals(3, bodies.size)
        assertFalse(bodies[2], bodies[2].contains("inlineData"))
        assertTrue(bodies[2], bodies[2].contains(EXTRACTED))
    }

    @Test
    fun `RL2_NEGCACHE_01 Relay with a connection identity records file in the negative cache instead of process memory`() = runTest {
        val bodies = mutableListOf<String>()
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
        val coordinator = RelayTransportCoordinator(
            client = client(bodies, 400, 200, 200, 413),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
        )
        suspend fun send(options: ChatRequestOptions) = coordinator.sendMessageStream(
            apiKey = "relay-key", modelID = MODEL, messages = message(textPdf()),
            baseUrl = "https://relay.example.com/v1beta", supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = options,
        ).toList()
        val identified = relayOptions().copy(capabilityEvidenceIdentity = identity("c1"))
        val v2 = ai.oriveo.community.core.capability.InputNegativeCache.shared
        v2.clearConnection("c1")
        v2.clearConnection("c2")

        assertTrue(send(identified).last() is StreamEvent.Done)
        assertEquals(2, bodies.size)
        val key = RelayNegativeCache.Key("c1", MODEL, RelayTransport.GeminiGenerateContent.value)
        assertEquals(listOf(key to RelayNegativeCache.Kind.File), cache.entries().map { it.key to it.kind })
        // The v1 entry is mirrored by a v2 file_input entry (protocol family follows this request's protocol) with signature relay.classified_rejected.
        assertEquals(
            listOf(
                ai.oriveo.community.core.capability.InputNegativeCache.Key("c1", MODEL, "gemini.inline_data", CapabilityEvidenceFacade.FILE_INPUT) to
                    ai.oriveo.community.core.capability.InputRejectionFlow.RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID,
            ),
            v2.entries().filter { it.first.connectionId == "c1" }.map { it.first to it.second.signatureId },
        )

        // The next message for the same connection x model x protocol goes straight to text.
        send(identified)
        assertEquals(3, bodies.size)
        assertFalse(bodies[2], bodies[2].contains("inlineData"))

        // Other connections are unaffected and the in-process memory was not written: 413 (not a rejected signal) falls back once as before but is not remembered.
        val other = relayOptions().copy(capabilityEvidenceIdentity = identity("c2"))
        assertTrue(send(other).last() is StreamEvent.Done)
        assertEquals(5, bodies.size)
        assertTrue(bodies[3], bodies[3].contains("inlineData"))
        assertEquals(1, cache.entries().size)
        // 413 is not a rejected signal: neither v1 nor v2 remembers it.
        assertTrue(v2.entries().none { it.first.connectionId == "c2" })
        v2.clearConnection("c1")
    }

    @Test
    fun `RL2_NEGCACHE_01 the file entry uses the read side keyFor model id`() = runTest {
        val bodies = mutableListOf<String>()
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
        val coordinator = RelayTransportCoordinator(
            client = client(bodies, 400),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
        )
        // The stored model (the read side keyFor uses its id) has a different id from the one sent upstream.
        val stored = ai.oriveo.community.core.model.AIModel(id = "stored-model", name = "stored-model")
        coordinator.sendMessageStream(
            apiKey = "relay-key", modelID = MODEL, messages = message(textPdf()),
            baseUrl = "https://relay.example.com/v1beta", supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = relayOptions().copy(capabilityEvidenceIdentity = identity("c1"), activeModel = stored),
        ).toList()
        val provider = ai.oriveo.community.core.model.Provider(
            id = "c1",
            kind = ProviderKind.Relay,
            relayRequested = relayOptions().relayRequested,
        )
        assertEquals(
            listOf(RelayNegativeCache.keyFor(provider, stored)!! to RelayNegativeCache.Kind.File),
            cache.entries().map { it.key to it.kind },
        )
    }

    private fun responsesCoordinator(
        bodies: MutableList<Pair<String, String>>,
        next: RelayTransport = RelayTransport.OpenAIChatCompletions,
    ) = RelayTransportCoordinator(
        client = HttpClient(
            MockEngine { request ->
                val path = request.url.encodedPath
                bodies += path to (request.body as TextContent).text
                if (path.endsWith("/responses")) {
                    respond("""{"error":{"message":"not found"}}""", HttpStatusCode.NotFound, headersOf(HttpHeaders.ContentType, "application/json"))
                } else {
                    val success = if (path.contains("generateContent", ignoreCase = true)) SUCCESS else CHAT_SUCCESS
                    respond(success, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                }
            },
        ),
        json = json,
        transportRegistry = TransportRegistry(json),
        negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
        protocolCandidates = { _, _, _ -> listOf(RelayTransport.OpenAIResponses, next) },
    )

    private suspend fun responsesStream(coordinator: RelayTransportCoordinator, attachment: Attachment): List<StreamEvent> {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"openAI":{"resolveMap":{"$OPENAI_MODEL":"$OPENAI_MODEL"},
               "models":{"$OPENAI_MODEL":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        return coordinator.sendMessageStream(
            apiKey = "relay-key", modelID = OPENAI_MODEL,
            messages = listOf(
                ProviderTestFixtures.userMessage("read", ProviderKind.Relay, OPENAI_MODEL).copy(attachments = listOf(attachment)),
            ),
            baseUrl = "https://relay.example.com/v1", supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            // Connection protocol is auto and this send goes out via Responses: a connection whose protocol the user chose does not switch protocol.
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto, authMode = RelayAuthMode.Bearer),
                relayRouteTransport = RelayTransport.OpenAIResponses,
            ),
        ).toList()
    }

    @Test
    fun protocolFallback_extractedTextFile_targetWithoutNativeFiles_switches() = runTest {
        val bodies = mutableListOf<Pair<String, String>>()
        val events = responsesStream(responsesCoordinator(bodies), textPdf())

        assertTrue("$events", events.last() is StreamEvent.Done)
        // The original protocol first falls back to text (still 404) before switching protocol; the request body after switching is recomputed by the Chat builder under Chat's delivery decision.
        assertEquals(listOf("/v1/responses", "/v1/responses", "/v1/chat/completions"), bodies.map { it.first })
        assertTrue(bodies[0].second, bodies[0].second.contains(ORIGINAL))
        val chat = bodies.last().second
        assertFalse("After switching protocol the PDF must not be sent as a native block: $chat", chat.contains(ORIGINAL))
        assertFalse(chat, chat.contains("input_file"))
        assertFalse(chat, chat.contains("image_url"))
        assertTrue(chat, chat.contains(EXTRACTED))
    }

    @Test
    fun protocolFallback_scannedFileOnly_targetWithoutNativeFiles_keepsOriginalError() = runTest {
        val bodies = mutableListOf<Pair<String, String>>()
        val error = runCatching { responsesStream(responsesCoordinator(bodies), scannedPdf()) }.exceptionOrNull()

        // The target protocol Chat does not accept native files and the scan has no text version: do not switch, report the original error.
        assertEquals(listOf("/v1/responses"), bodies.map { it.first })
        assertTrue("$error", error is ProviderServiceError)
    }

    @Test
    fun protocolFallback_scannedFileOnly_targetWithNativeFiles_switches() = runTest {
        val bodies = mutableListOf<Pair<String, String>>()
        val events = responsesStream(responsesCoordinator(bodies, next = RelayTransport.GeminiGenerateContent), scannedPdf())

        // The target protocol Gemini accepts native files: switch as usual, and the Gemini builder redoes the delivery decision.
        assertTrue("$events", events.last() is StreamEvent.Done)
        assertEquals("/v1/responses", bodies.first().first)
        assertTrue(bodies.map { it.first }.toString(), bodies.last().first.contains("generateContent", ignoreCase = true))
    }

    private fun identity(connectionId: String) = CapabilityEvidenceIdentity(
        partitionId = "partition",
        connectionInstanceId = connectionId,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = ProviderKind.Relay.rawValue,
        authMode = "api_key",
    )

    @Test
    fun `the non streaming path falls back the same way`() = runTest {
        val bodies = mutableListOf<String>()
        val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { request ->
                    bodies += (request.body as TextContent).text
                    if (bodies.size == 1) {
                        respond("""{"error":{"message":"rejected"}}""", HttpStatusCode.UnprocessableEntity)
                    } else {
                        respond(
                            """{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}""",
                            HttpStatusCode.OK,
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                    }
                },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
        )

        val done = coordinator.sendMessage(
            apiKey = "relay-key", modelID = MODEL, messages = message(textPdf()),
            baseUrl = "https://relay.example.com/v1beta", supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
            requestOptions = relayOptions(),
        )

        assertEquals("ok", done.result.text)
        assertEquals(2, bodies.size)
        assertTrue(bodies[0], bodies[0].contains("inlineData"))
        assertFalse(bodies[1], bodies[1].contains("inlineData"))
        assertTrue(bodies[1], bodies[1].contains(EXTRACTED))
    }

    @Test
    fun `a rejected scanned pdf is not resent because there is no text to fall back to`() = runTest {
        val bodies = mutableListOf<String>()
        val error = runCatching { relayStream(client(bodies, 400), scannedPdf()) }.exceptionOrNull()

        assertEquals(1, bodies.size)
        assertEquals(400, (error as ProviderServiceError.Upstream).statusCode)
        // Without a successful fallback, the connection is not remembered as "does not accept file blocks".
        relayStream(client(bodies), textPdf())
        assertTrue(bodies.last(), bodies.last().contains("inlineData"))
    }

    @Test
    fun `auth rate limit and server errors are never retried as text`() = runTest {
        for (status in listOf(401, 403, 429, 500)) {
            val bodies = mutableListOf<String>()
            val error = runCatching { relayStream(client(bodies, status), textPdf()) }.exceptionOrNull()
            assertEquals("status $status", 1, bodies.size)
            assertTrue("status $status: $error", error is ProviderServiceError)
        }
    }

    @Test
    fun `a rejection without any native file in the request is surfaced unchanged`() = runTest {
        val bodies = mutableListOf<String>()
        val error = runCatching { relayStream(client(bodies, 400), attachment = null) }.exceptionOrNull()
        assertEquals(1, bodies.size)
        assertTrue("$error", error is ProviderServiceError.Upstream)
    }

    @Test
    fun `when the text resend is rejected too the first error is the one shown`() = runTest {
        val bodies = mutableListOf<String>()
        val error = runCatching { relayStream(client(bodies, 413, 500), textPdf()) }.exceptionOrNull()

        assertEquals(2, bodies.size)
        assertEquals(413, (error as ProviderServiceError.Upstream).statusCode)
        // The resend did not succeed, so the next message still tries native first.
        relayStream(client(bodies), textPdf())
        assertTrue(bodies.last(), bodies.last().contains("inlineData"))
    }

    @Test
    fun `the direct gemini route never falls back`() = runTest {
        val bodies = mutableListOf<String>()
        val error = runCatching {
            GeminiService(client(bodies, 400), json, TransportRegistry(json)).sendMessageStream(
                apiKey = "sk-test", modelID = MODEL,
                messages = listOf(
                    ProviderTestFixtures.userMessage("read", ProviderKind.Gemini, MODEL).copy(attachments = listOf(textPdf())),
                ),
                baseUrl = null, supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic, webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()

        assertEquals(1, bodies.size)
        assertTrue(bodies[0], bodies[0].contains("inlineData"))
        assertTrue("$error", error is ProviderServiceError)
    }

    private companion object {
        const val MODEL = "gemini-x"
        const val EXTRACTED = "extracted report body"
        const val ORIGINAL = "VEVYVFBERg=="
        const val OPENAI_MODEL = "gpt-x"
        const val CHAT_SUCCESS = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
        const val SUCCESS = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}\n\n"
    }
}
