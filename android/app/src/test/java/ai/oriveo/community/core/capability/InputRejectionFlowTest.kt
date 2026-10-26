package ai.oriveo.community.core.capability

import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityDisabledReason
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityOutbound
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.messagesForInputOutbound
import ai.oriveo.community.core.provider.routeImagePlaceholder
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.time.Instant
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Feeding an official connection's upstream rejection back into the capability state: the signature table
 * comes from the APK asset, the verdict from the real qwen entry in the bundled snapshot, and both the
 * negative cache and the projection go through production entries.
 */
@RunWith(RobolectricTestRunner::class)
class InputRejectionFlowTest {
    private val now: Instant = Instant.parse("2026-10-19T00:00:00Z")
    private val cache = InputNegativeCache(InputNegativeCache.MemoryStore()) { now.epochSecond }
    private val client: MetadataClient by lazy { qwenClient() }
    private val table: RejectionSignatureTable by lazy {
        requireNotNull(RejectionSignatures.load(RuntimeEnvironment.getApplication())) { "the signature table asset should be packaged with the APK" }
    }
    private val provider = Provider(id = "official-qwen", kind = ProviderKind.Qwen)
    private val model = AIModel(id = "qwen-plus", name = "qwen-plus")

    @Test
    fun `dashscope unexpected item type with an image records the v2 cache and offers resend keyed by the rejected input`() {
        val result = record(listOf(userMessage(withImage = true)), dashscopeRejection())

        assertNotNull(result)
        assertEquals("dashscope.unexpected_item_type", result!!.signatureId)
        val entries = cache.entries()
        assertEquals(1, entries.size)
        val (key, value) = entries.single()
        assertEquals(InputNegativeCache.Key("official-qwen", "qwen-plus", "openai_chat.image_url", "vision_input"), key)
        assertEquals("dashscope.unexpected_item_type", value.signatureId)

        // A failed message takes its code from the result it recorded itself: the code for a rejected image is still the old value, so older messages still offer "resend without the image".
        val code = InputRejectionFlow.recoveryCode(result, rejectedParameter = null)
        assertEquals(InputRejectionFlow.RESEND_WITHOUT_IMAGE_CODE, code)
        assertEquals("input_capability_rejected:vision_input", code)
        assertEquals(MessageRecoveryActionKind.ResendWithoutImage, failedCardPrimary(code))
        // The same code generalizes by key: file and video each get their own action.
        assertEquals(
            MessageRecoveryActionKind.ResendWithoutFile,
            failedCardPrimary(InputRejectionFlow.recoveryCode(result.copy(capabilityKey = "file_input"), null)),
        )
        assertEquals(
            MessageRecoveryActionKind.ResendWithoutVideo,
            failedCardPrimary(InputRejectionFlow.recoveryCode(result.copy(capabilityKey = "video_input"), null)),
        )
    }

    private fun failedCardPrimary(code: String?) = resolveMessageRecoveryCardActionLayout(
        state = ChatMessageState.Failed,
        shouldOfferModelSwitch = false,
        customRetryWithoutFieldsCode = code,
    ).primary

    @Test
    fun `same error without an image writes nothing`() {
        assertNull(record(listOf(userMessage(withImage = false)), dashscopeRejection()))
        assertTrue(cache.entries().isEmpty())
    }

    @Test
    fun `out of table 400 writes nothing and keeps the error as is`() {
        val error = ProviderServiceError.Upstream(400, "Invalid image.").apply {
            rawBody = """{"error":{"type":"invalid_request_error","message":"Invalid image."}}"""
        }
        assertNull(record(listOf(userMessage(withImage = true)), error))
        assertTrue(cache.entries().isEmpty())
        assertEquals("Invalid image.", error.detail)
        // An ordinary failed card: retry is the primary action and there is no "resend without the image".
        val layout = resolveMessageRecoveryCardActionLayout(state = ChatMessageState.Failed, shouldOfferModelSwitch = false)
        assertEquals(MessageRecoveryActionKind.Retry, layout.primary)
    }

    @Test
    fun `next image send to the same model projects rejected_recently and swaps in the placeholder`() {
        val before = project()
        assertEquals(InputCapabilityOutbound.NATIVE_PART, before.vision.outbound)

        assertNotNull(record(listOf(userMessage(withImage = true)), dashscopeRejection()))

        val after = project()
        assertEquals(InputCapabilityDisabledReason.REJECTED_RECENTLY, after.vision.disabledReason)
        assertEquals(InputCapabilityOutbound.PLACEHOLDER, after.vision.outbound)
        val outbound = messagesForInputOutbound(listOf(userMessage(withImage = true)), after, PLACEHOLDER).single()
        assertTrue(outbound.attachments.orEmpty().none { it.kind == AttachmentKind.Image })
        assertEquals(listOf(PLACEHOLDER), outbound.outboundPlaceholders)
    }

    @Test
    fun `production send after a dashscope image rejection swaps the image for a placeholder on the next send`() = runTest {
        val harness = SendHarness(modelTransport = null)

        harness.send()
        assertEquals(1, harness.bodies.size)
        assertTrue("the first send should carry the image: ${harness.bodies[0]}", harness.bodies[0].contains("image_url"))
        assertEquals(listOf(QWEN_PLUS_VISION_KEY), qwenEntries())

        harness.send()
        assertEquals(2, harness.bodies.size)
        val second = harness.bodies[1]
        assertFalse("the second image send to the same model should no longer carry image_url: $second", second.contains("image_url"))
        assertTrue("the second send should carry the placeholder line: $second", second.contains(routeImagePlaceholder(ProviderKind.Qwen.rawValue)))
    }

    @Test
    fun `record key follows the dispatched transport when the metadata entry names another one`() = runTest {
        // The entry names another transport while QwenService actually dispatches over openai_chat, so both the signature protocol and the key must follow the dispatched route.
        val harness = SendHarness(modelTransport = "dashscope_native")

        harness.send()
        assertTrue(harness.bodies[0].contains("image_url"))
        assertEquals(listOf(QWEN_PLUS_VISION_KEY), qwenEntries())

        harness.send()
        assertFalse("the next outbound request hits the negative cache on the same route: ${harness.bodies[1]}", harness.bodies[1].contains("image_url"))
    }

    @Test
    fun `same 400 after the history image was swapped for a placeholder and no new image does not rewrite vision`() = runTest {
        val harness = SendHarness(modelTransport = null)
        harness.send()
        assertEquals(listOf(QWEN_PLUS_VISION_KEY), qwenEntries())

        // The image in history has been swapped for a placeholder by the outbound gate this time and this turn carries no image; upstream still answers with the same family of 400 (a different signature is used to show whether the entry gets rewritten).
        harness.rejectEverythingWith(DASHSCOPE_CONTENT_MUST_BE_STRING_BODY)
        harness.send(
            existingMessages = listOf(userMessage(withImage = true).copy(id = "history-1")),
            attachments = emptyList(),
        )
        assertFalse("the history image should have been swapped for a placeholder: ${harness.bodies[1]}", harness.bodies[1].contains("image_url"))
        val entry = InputNegativeCache.shared.entries().single { it.first == QWEN_PLUS_VISION_KEY }
        assertEquals("dashscope.unexpected_item_type", entry.second.signatureId)
    }

    @Test
    fun `text injected txt file does not count as file_input`() {
        val txt = Attachment(
            id = "f1", kind = AttachmentKind.File, fileName = "notes.txt", mimeType = "text/plain",
            originalBase64Data = "aGVsbG8=",
        )
        assertNull(record(listOf(userMessage(withImage = false).copy(attachments = listOf(txt))), fileRejection(), fileTable(), pdfModel))
        assertTrue(cache.entries().isEmpty())
    }

    @Test
    fun `native pdf routed by AttachmentRouter records file_input`() {
        val pdf = Attachment(
            id = "f1", kind = AttachmentKind.File, fileName = "a.pdf", mimeType = "application/pdf",
            originalBase64Data = "JVBERi0xLjQ=",
        )
        assertEquals(AttachmentRoute.Native, AttachmentRouter.decide(pdf, provider.kind, pdfModel))
        val result = record(listOf(userMessage(withImage = false).copy(attachments = listOf(pdf))), fileRejection(), fileTable(), pdfModel)
        assertEquals("test.native_file_rejected", result?.signatureId)
        assertEquals(listOf("file_input"), cache.entries().map { it.first.capabilityKey })
        assertEquals(MessageRecoveryActionKind.ResendWithoutFile, failedCardPrimary(InputRejectionFlow.recoveryCode(result, null)))
    }

    @After
    fun tearDown() {
        InputNegativeCache.shared.clearConnection(provider.id)
        openClients.forEach { it.close() }
        openClients.clear()
    }

    // ---- helpers ----

    private val openClients = mutableListOf<HttpClient>()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }

    private fun qwenEntries() = InputNegativeCache.shared.entries().map { it.first }.filter { it.connectionId == provider.id }

    /**
     * Real ChatRepository + real QwenService + production singletons (metadata / negative cache / signature table); MockEngine plays the upstream:
     * a request body carrying image_url gets the DashScope rejection 400, anything else streams normally.
     */
    private inner class SendHarness(modelTransport: String?) {
        val bodies = mutableListOf<String>()
        private var rejectAllBody: String? = null

        fun rejectEverythingWith(body: String) {
            rejectAllBody = body
        }
        private val connection = provider.copy(apiKey = "byok-key", models = listOf(model))
        private val client = HttpClient(MockEngine { request ->
            val body = when (val content = request.body) {
                is TextContent -> content.text
                is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                else -> error("Unsupported request body type: ${content::class.java.name}")
            }
            bodies += body
            val rejection = rejectAllBody ?: DASHSCOPE_REJECTION_BODY.takeIf { body.contains("image_url") }
            if (rejection != null) {
                respond(
                    rejection,
                    HttpStatusCode.BadRequest,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            } else {
                respond(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        }).also { openClients += it }
        private val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.serviceFor(any<Provider>(), any()) } returns QwenService(client, json, TransportRegistry(json))
            },
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )

        init {
            qwenClient(MetadataClient.instance, modelTransport)
            val app = RuntimeEnvironment.getApplication()
            InputNegativeCache.configure(app)
            InputRejectionFlow.configure(app)
            InputNegativeCache.shared.clearConnection(connection.id)
        }

        suspend fun send(
            existingMessages: List<ChatMessage> = emptyList(),
            attachments: List<Attachment> = listOf(
                Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = PNG_BASE64),
            ),
        ) {
            runCatching {
                repository.sendMessage(
                    conversation = Conversation(
                        id = "conversation-1",
                        title = "Vision",
                        providerID = connection.id,
                        providerKind = connection.kind,
                        modelID = model.id,
                    ),
                    text = "what is this",
                    provider = connection,
                    modelID = model.id,
                    existingMessages = existingMessages,
                    attachments = attachments,
                    requestOptions = ChatRequestOptions(
                        activeModel = model,
                        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                            partitionId = "partition-1",
                            connectionInstanceId = connection.id,
                            connectionGeneration = "1",
                            credentialEpoch = "1",
                            providerKind = connection.kind.rawValue,
                            authMode = connection.authMode.rawValue,
                        ),
                    ),
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
        }
    }

    private fun record(
        messages: List<ChatMessage>,
        error: Throwable,
        signatureTable: RejectionSignatureTable = table,
        sentModel: AIModel = model,
    ) = InputRejectionFlow.recordOfficial(
        provider = provider,
        model = sentModel,
        messages = messages,
        error = error,
        outputStarted = false,
        table = signatureTable,
        negativeCache = cache,
        metadataClient = client,
    )

    private fun project() = requireNotNull(
        resolveInputCapabilityProjections(provider, model, metadataClient = client, negativeCache = cache, now = now),
    )

    private fun dashscopeRejection() = ProviderServiceError.Upstream(400, "invalid_parameter_error").apply {
        rawBody = """{"error":{"code":"invalid_parameter_error","message":"The provided messages input is invalid. The error info is [Unexpected item type in content]"}}"""
    }

    /** The same model with native PDF over input_file (the precondition for AttachmentRouter to decide Native). */
    private val pdfModel = model.copy(nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = true)

    /** The shared signature table has no file_input entry yet: build one through the same parse entry and only verify whether a native file was carried. */
    private fun fileTable() = RejectionSignatures.parse(
        """{"byProtocol":{"openai_chat":[{"signatureId":"test.native_file_rejected","httpStatus":400,"messagePattern":"file input is not supported","kind":"input_rejected","capabilityKey":"file_input"}]}}""",
    )

    private fun fileRejection() = ProviderServiceError.Upstream(400, "invalid_request_error").apply {
        rawBody = """{"error":{"code":"invalid_request_error","message":"file input is not supported"}}"""
    }

    private fun userMessage(withImage: Boolean) = ChatMessage(
        id = "u1",
        role = ChatRole.User,
        text = "what is this",
        providerKind = ProviderKind.Qwen,
        providerName = "Qwen",
        modelName = "qwen-plus",
        state = ChatMessageState.Delivered,
        attachments = if (withImage) listOf(Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = PNG_BASE64)) else null,
    )

    /** Publishes the real qwen entry of the bundled snapshot to a separate client through the production decode / publish boundary. */
    private fun qwenClient(target: MetadataClient = MetadataClient(), modelTransport: String? = null): MetadataClient {
        val providers = bundledPayload().getValue("providers").jsonObject
        var qwen = providers.getValue("qwen").jsonObject
        if (modelTransport != null) {
            val models = qwen.getValue("models").jsonObject
            val plus = JsonObject(models.getValue(model.id).jsonObject + ("transport" to JsonPrimitive(modelTransport)))
            qwen = JsonObject(qwen + ("models" to JsonObject(models + (model.id to plus))))
        }
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", JsonObject(mapOf("qwen" to qwen)))
        }
        return target.apply { loadNetworkPayloadForTesting(payload.toString(), "\"input-rejection\"") }
    }

    private fun bundledPayload(): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/model-contracts/bundled-metadata.v2.json.gz")
            if (candidate.exists()) {
                val text = GZIPInputStream(candidate.inputStream()).bufferedReader().use { it.readText() }
                return Json.parseToJsonElement(text).jsonObject
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("bundled-metadata.v2.json.gz not found")
    }

    private companion object {
        const val PLACEHOLDER = "[Image omitted]"
        const val PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        const val DASHSCOPE_CONTENT_MUST_BE_STRING_BODY =
            """{"error":{"code":"invalid_parameter_error","message":"input content must be a string."}}"""
        const val DASHSCOPE_REJECTION_BODY =
            """{"error":{"code":"invalid_parameter_error","message":"The provided messages input is invalid. The error info is [Unexpected item type in content]"}}"""
        val QWEN_PLUS_VISION_KEY = InputNegativeCache.Key("official-qwen", "qwen-plus", "openai_chat.image_url", "vision_input")
    }
}
