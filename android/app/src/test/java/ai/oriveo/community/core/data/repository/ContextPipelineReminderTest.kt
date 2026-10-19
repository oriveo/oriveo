package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.streaming.StreamRequest
import ai.oriveo.community.feature.chat.ChatSendCoordinator
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conversation instructions go into the system of the production request; the sixth user message carries <oriveo-reminder>;
 * when the remote switch context_reminder_enabled is off only the reminder is turned off and the instruction section stays.
 *
 * Production path: ChatSendCoordinator.launchSend -> StreamRequest -> the real ChatRepository.sendMessage ->
 * the real OpenAIService, with MockEngine only capturing the request body.
 */
class ContextPipelineReminderTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        // MetadataClient is a process-wide singleton: reset it so featureFlags do not leak into other tests.
        MetadataTestFixtures.clear()
    }

    @Test
    fun pipeline_instructions_in_system() = runTest {
        val harness = Harness(this)
        harness.send(conversation(), "Hello")

        val body = harness.bodies.single()
        val system = requireNotNull(systemOf(body)) { "system missing: $body" }
        assertTrue("instructions segment in system: $system", "${ContextAssembler.INSTRUCTIONS_HEADER}\n$INSTRUCTIONS" in system)
        val lastUser = turnsOf(body).last { it.first == "user" }.second
        assertFalse("no reminder on the first message: $lastUser", "<oriveo-reminder>" in lastUser)
    }

    @Test
    fun pipeline_reminder_after_six_user_messages() = runTest {
        val harness = Harness(this)
        harness.send(conversation(), "Question six", existing = fiveTurns())

        val body = harness.bodies.single()
        val lastUser = turnsOf(body).last { it.first == "user" }.second
        assertTrue("sixth user message carries the reminder: $lastUser", "<oriveo-reminder>" in lastUser)
        assertTrue("reminder repeats the instructions: $lastUser", INSTRUCTIONS in lastUser.substringAfter("<oriveo-reminder>"))
    }

    @Test
    fun pipeline_reminder_disabled_by_remote_flag() = runTest {
        // Go through the production switch read: the remote payload delivers runtimeConfig.featureFlags.context_reminder_enabled = false.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{},"runtimeConfig":{"featureFlags":{"${ChatSendCoordinator.REMINDER_FLAG_KEY}":false}}}""",
        )
        val harness = Harness(this)
        harness.send(conversation(), "Question six", existing = fiveTurns())

        val body = harness.bodies.single()
        val lastUser = turnsOf(body).last { it.first == "user" }.second
        assertFalse("flag off drops the reminder: $lastUser", "<oriveo-reminder>" in lastUser)
        val system = requireNotNull(systemOf(body)) { "system missing: $body" }
        assertTrue("instructions stay in system: $system", "${ContextAssembler.INSTRUCTIONS_HEADER}\n$INSTRUCTIONS" in system)
    }

    private inner class Harness(
        private val scope: TestScope,
    ) {
        val bodies = mutableListOf<JsonObject>()
        private val requests = mutableListOf<StreamRequest>()
        private val client = HttpClient(MockEngine { request ->
            bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
            if (request.url.encodedPath.endsWith("/responses")) {
                respond(
                    "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n" +
                        "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"output\":[]}}\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            } else {
                respond(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        }).also { openClients += it }
        private val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns OpenAIService(client, json, TransportRegistry(json))
            coEvery { it.getById(PROVIDER.id) } returns PROVIDER
        }
        private val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        private val streamingManager = mockk<ChatStreamingManager>(relaxed = true).also {
            every { it.startStream(any()) } answers { requests += firstArg<StreamRequest>() }
        }
        private val sendCoordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = scope,
            providersProvider = { listOf(PROVIDER) },
            untitledNoteFallback = "Untitled",
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        )

        suspend fun send(conversation: Conversation, text: String, existing: List<ChatMessage> = emptyList()) {
            sendCoordinator.launchSend(
                conversation = conversation,
                provider = PROVIDER,
                modelId = MODEL.id,
                text = text,
                memoryItems = emptyList(),
                existingMessages = existing,
                attachments = null,
            )
            scope.advanceUntilIdle()
            val pending = requests.toList()
            requests.clear()
            pending.forEach { request ->
                repository.sendMessage(
                    conversation = request.conversation,
                    text = request.text,
                    provider = request.provider,
                    modelID = request.modelID,
                    existingMessages = request.existingMessages,
                    attachments = request.attachments,
                    quoteContext = request.quoteContext,
                    reasoningMode = request.reasoningMode,
                    webSearchEnabled = request.webSearchEnabled,
                    requestOptions = request.requestOptions,
                    outputs = ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                    persistUserMessage = request.persistUserMessage,
                    userMessageAlreadyInHistory = request.userMessageAlreadyInHistory,
                    appendToAssistant = request.appendToAssistant,
                    attemptKind = request.attemptKind,
                )
            }
        }
    }

    private fun systemOf(body: JsonObject): String? {
        (body["instructions"] as? JsonPrimitive)?.content?.let { return it }
        val items = (body["messages"] ?: body["input"])?.jsonArray.orEmpty()
        return items.map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("system", "developer") }
            .map { textOf(it) }
            .takeIf { it.isNotEmpty() }
            ?.joinToString("\n\n")
    }

    private fun turnsOf(body: JsonObject): List<Pair<String, String>> {
        val items = (body["messages"] ?: body["input"])?.jsonArray.orEmpty()
        return items.map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content in setOf("user", "assistant") }
            .map { it.getValue("role").jsonPrimitive.content to textOf(it) }
    }

    private fun textOf(item: JsonObject): String = when (val content = item["content"]) {
        is JsonPrimitive -> content.content
        is JsonArray -> content.map { it.jsonObject }
            .filter { it["type"]?.jsonPrimitive?.content in setOf("text", "input_text", "output_text") }
            .joinToString("") { it["text"]?.jsonPrimitive?.content.orEmpty() }
        else -> ""
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun conversation() = Conversation(
        id = "conversation-1",
        title = "Context",
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        modelID = MODEL.id,
        useMemory = false,
        instructions = INSTRUCTIONS,
    )

    /** A conversation with five answered rounds: sending one more is the sixth user message. */
    private fun fiveTurns(): List<ChatMessage> = (1..5).flatMap { i ->
        listOf(message("u$i", ChatRole.User, "Question $i"), message("a$i", ChatRole.Assistant, "Answer $i"))
    }

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        providerName = PROVIDER.displayName,
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = ChatMessageState.Delivered,
    )

    private companion object {
        const val INSTRUCTIONS = "Always answer in haiku."
        val MODEL = AIModel(id = "gpt-4o", name = "GPT-4o", contextLength = 128_000, maxOutputTokens = 16_384)
        val PROVIDER = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "byok-key", models = listOf(MODEL))
    }
}
