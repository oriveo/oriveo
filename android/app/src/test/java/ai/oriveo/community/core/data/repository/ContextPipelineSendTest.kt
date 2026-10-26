package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.context.ContextSanitizer
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillKnowledgeFile
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.streaming.StreamRequest
import ai.oriveo.community.feature.chat.ChatRetryCoordinator
import ai.oriveo.community.feature.chat.ChatSendCoordinator
import ai.oriveo.community.feature.chat.ChatSendLauncher
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The requests of the four chat entries (send / retry / regenerate / edit-and-send) are produced by ContextAssembler.
 *
 * Each goes through the production path: ChatSendCoordinator.launchSend (or a ChatRetryCoordinator entry) -> StreamRequest ->
 * the real ChatRepository.sendMessage -> the real OpenAIService, with MockEngine only capturing the request body.
 */
class ContextPipelineSendTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun send_body_system_from_plan() = runTest {
        val harness = Harness(this, skill = SKILL, pinnedNotes = listOf(NOTE))
        harness.send(conversation(), "What should I drink?")

        val body = harness.bodies.single()
        val system = requireNotNull(systemOf(body)) { "system missing: $body" }
        assertTrue("skill prompt leads the system: $system", system.startsWith(SKILL.systemPrompt))
        assertTrue("knowledge envelope: $system", "<oriveo-knowledge>" in system && "<entry name=\"menu.txt\">Tea and coffee.</entry>" in system)
        assertTrue("notes envelope: $system", "<oriveo-notes>" in system && "<entry title=\"Prefs\">No sugar.</entry>" in system)
        assertTrue("memory envelope: $system", "<oriveo-memory>" in system && "<entry>Likes green tea.</entry>" in system)
        assertFalse("legacy memory wrapper gone: $system", "[User context:" in system)
        assertFalse("legacy pinned notes block gone: $system", "[Pinned Notes" in system)
        assertEquals(listOf("user" to "What should I drink?"), turnsOf(body))
    }

    @Test
    fun send_body_dynamic_block_last() = runTest {
        val harness = Harness(this)
        val file = Attachment(
            id = "file-1",
            kind = AttachmentKind.File,
            fileName = "notes.txt",
            mimeType = "text/plain",
            base64Data = java.util.Base64.getEncoder().encodeToString("file body".toByteArray()),
        )
        harness.send(conversation(), "Summarize the file", attachments = listOf(file))

        val body = harness.bodies.single()
        val system = systemOf(body)
        assertFalse("attachment guidance left the system: $system", system?.contains(AttachmentInjector.SYSTEM_PROMPT_GUIDANCE) == true)
        val lastUser = turnsOf(body).last { it.first == "user" }.second
        val guide = "<oriveo-attachment-guide>\n${AttachmentInjector.SYSTEM_PROMPT_GUIDANCE}\n</oriveo-attachment-guide>"
        assertTrue("current user text starts with the typed text: $lastUser", lastUser.startsWith("Summarize the file"))
        assertTrue("[D] closes the current user text: $lastUser", lastUser.trimEnd().endsWith(guide) || "Summarize the file\n\n$guide" in lastUser)
    }

    @Test
    fun transport_input_carries_plan_system_and_dynamic() = runTest {
        val harness = Harness(this)
        val file = Attachment(
            id = "file-1",
            kind = AttachmentKind.File,
            fileName = "notes.txt",
            mimeType = "text/plain",
            base64Data = java.util.Base64.getEncoder().encodeToString("file body".toByteArray()),
        )
        harness.send(conversation(), "Summarize the file", attachments = listOf(file))

        // The options the production path hands to ProviderService: system and [D] both come from the same plan.
        val options = harness.sentOptions.single()
        val body = harness.bodies.single()
        val system = requireNotNull(systemOf(body)) { "plan system missing: $body" }
        assertTrue("memory envelope is the plan system: $system", "<oriveo-memory>" in system)
        assertEquals(system, options.systemPrompt)
        val guide = "<oriveo-attachment-guide>\n${AttachmentInjector.SYSTEM_PROMPT_GUIDANCE}\n</oriveo-attachment-guide>"
        assertEquals(guide, options.dynamicText)
        val lastUser = turnsOf(body).last { it.first == "user" }.second
        assertTrue("[D] still rides on the current user text: $lastUser", "Summarize the file\n\n$guide" in lastUser)
    }

    @Test
    fun send_body_memory_switch_off() = runTest {
        val harness = Harness(this)
        harness.send(conversation().copy(useMemory = false), "Hello")

        val body = harness.bodies.single()
        assertNull("no system without skill / notes / memory: $body", systemOf(body))
        assertFalse("memory text never leaves the device when the switch is off: $body", "Likes green tea." in body.toString())
        assertEquals(listOf("user" to "Hello"), turnsOf(body))
    }

    @Test
    fun send_body_unanswered_merged() = runTest {
        val harness = Harness(this)
        val earlier = message("u-earlier", ChatRole.User, "Is a<b?")
        harness.send(conversation(), "Second question", existing = listOf(earlier))

        val body = harness.bodies.single()
        val expected = "<${ContextSanitizer.UNANSWERED_TAG}>\n<note>${ContextSanitizer.UNANSWERED_NOTE}</note>\n" +
            "Is a&lt;b?\n</${ContextSanitizer.UNANSWERED_TAG}>\n\nSecond question"
        assertEquals(listOf("user" to expected), turnsOf(body))
        assertTrue("memory envelope rides along: ${systemOf(body)}", systemOf(body)?.contains("<oriveo-memory>") == true)
    }

    @Test
    fun retry_body_from_plan() = runTest {
        val harness = Harness(this)
        val user = message("u-1", ChatRole.User, "First question")
        val failed = message("a-1", ChatRole.Assistant, "partial", ChatMessageState.Failed)
        harness.retry(conversation().copy(messages = listOf(user, failed))) { it.retryMessage(failed.id) }

        val body = harness.bodies.single()
        assertEquals(memorySystem(), systemOf(body))
        assertEquals(listOf("user" to "First question"), turnsOf(body))
    }

    @Test
    fun regenerate_body_from_plan() = runTest {
        val harness = Harness(this)
        val user = message("u-1", ChatRole.User, "First question")
        val answer = message("a-1", ChatRole.Assistant, "First answer")
        harness.retry(conversation().copy(messages = listOf(user, answer))) { it.regenerateMessage(answer.id) }

        val body = harness.bodies.single()
        assertEquals(memorySystem(), systemOf(body))
        assertEquals(listOf("user" to "First question"), turnsOf(body))
    }

    @Test
    fun send_recalls_episodic_item_into_dynamic_block() = runTest {
        // One L3 item is in the store: the last user message of a new send carries <oriveo-recall>, and the item carries a date attribute.
        val episodic = ai.oriveo.community.core.context.MemoryItem(
            id = "30000000-0000-4000-8000-000000000001",
            layer = ai.oriveo.community.core.context.MemoryLayer.EPISODIC,
            kind = ai.oriveo.community.core.context.MemoryKind.DECISION,
            content = "Decided the saga ends in 1453 in Constantinople",
            mutationId = "mutation-2",
            deviceId = "device-1",
            occurredAt = "2026-10-01T09:00:00Z",
        )
        val harness = Harness(this, memoryItems = MEMORY_ITEMS + episodic)
        harness.send(conversation(), "Where does the saga end, Constantinople in 1453?")

        val lastUser = turnsOf(harness.bodies.single()).last { it.first == "user" }.second
        assertTrue("recall envelope in [D]: $lastUser", "<oriveo-recall>" in lastUser)
        assertTrue("dated entry: $lastUser", "<entry date=\"2026-10-01\">${episodic.content}</entry>" in lastUser)
        assertTrue("[D] follows the typed text: $lastUser", lastUser.startsWith("Where does the saga end, Constantinople in 1453?\n\n<oriveo-recall>"))
    }

    @Test
    fun send_without_memory_has_no_recall() = runTest {
        val episodic = ai.oriveo.community.core.context.MemoryItem(
            id = "30000000-0000-4000-8000-000000000001",
            layer = ai.oriveo.community.core.context.MemoryLayer.EPISODIC,
            kind = ai.oriveo.community.core.context.MemoryKind.DECISION,
            content = "Decided the saga ends in 1453 in Constantinople",
            mutationId = "mutation-2",
            deviceId = "device-1",
        )
        val harness = Harness(this, memoryItems = listOf(episodic))
        harness.send(conversation().copy(useMemory = false), "Where does the saga end, Constantinople in 1453?")

        val lastUser = turnsOf(harness.bodies.single()).last { it.first == "user" }.second
        assertFalse("useMemory off: no recall: $lastUser", "<oriveo-recall>" in lastUser)
    }

    @Test
    fun edit_resend_body_from_plan() = runTest {
        val harness = Harness(this)
        val u1 = message("u-1", ChatRole.User, "Hi")
        val a1 = message("a-1", ChatRole.Assistant, "Hello")
        val u2 = message("u-2", ChatRole.User, "Old wording")
        val a2 = message("a-2", ChatRole.Assistant, "Old answer")
        val conv = conversation().copy(messages = listOf(u1, a1, u2, a2))
        var editedText: String? = null
        harness.retry(conv) { editedText = it.editMessageInline(u2.id) }
        assertEquals("Old wording", editedText)
        // Edit-and-send = the truncated history + the rewritten text, through the ordinary send entry.
        harness.send(conv.copy(messages = listOf(u1, a1)), "New wording", existing = listOf(u1, a1))

        val body = harness.bodies.single()
        assertEquals(memorySystem(), systemOf(body))
        assertEquals(listOf("user" to "Hi", "assistant" to "Hello", "user" to "New wording"), turnsOf(body))
    }

    @Test
    fun image_only_message_reaches_wire() = runTest {
        val harness = Harness(this)
        val image = Attachment(
            id = "image-1",
            kind = AttachmentKind.Image,
            fileName = "photo.png",
            mimeType = "image/png",
            base64Data = "iVBORw0KGgo=",
        )
        harness.send(conversation(), "", attachments = listOf(image))

        // The current round has an empty body and only one image: the last user message handed to the service still carries that image.
        val lastUser = harness.sentMessages.single().last { it.role == ChatRole.User }
        assertEquals(listOf("image-1"), lastUser.attachments.orEmpty().map { it.id })
        val body = harness.bodies.single()
        val wireUser = (body["messages"] ?: body["input"])!!.jsonArray.map { it.jsonObject }
            .last { it["role"]?.jsonPrimitive?.content == "user" }
        assertTrue("image reaches the wire: $wireUser", "data:image/png;base64,iVBORw0KGgo=" in wireUser.toString())
    }

    @Test
    fun vision_gate_image_only_keeps_placeholder() = runTest {
        // An official model whose vision verdict is unavailable (outbound follows the projection): the local attachment is kept, the outbound gets a placeholder, and the last message is still a user message.
        ai.oriveo.community.core.provider.MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"${ProviderKind.DeepSeek.rawValue}":{"resolveMap":{"deepseek-chat":"deepseek-chat"},""" +
                """"models":{"deepseek-chat":{"canonicalModelId":"deepseek-chat","transport":"openai_chat",""" +
                """"capabilityControls":{"vision_input":{"state":"unavailable","reasonCode":"model_capability_absent"}}}}}}}""",
        )
        val model = AIModel(id = "deepseek-chat", name = "DeepSeek Chat", contextLength = 64_000, maxOutputTokens = 8_192)
        val provider = Provider(id = "deepseek-1", kind = ProviderKind.DeepSeek, apiKey = "byok-key", models = listOf(model))
        val harness = Harness(
            this,
            provider = provider,
            serviceFactory = { ai.oriveo.community.core.provider.DeepSeekService(it, json) },
        )
        val image = Attachment(
            id = "image-1",
            kind = AttachmentKind.Image,
            fileName = "photo.png",
            mimeType = "image/png",
            base64Data = "iVBORw0KGgo=",
        )
        harness.send(conversation(), "", attachments = listOf(image))

        val sent = harness.sentMessages.single()
        assertEquals(ChatRole.User, sent.last().role)
        assertEquals(listOf("image-1"), sent.last().attachments.orEmpty().map { it.id })
        val wire = harness.bodies.single()["messages"]!!.jsonArray.map { it.jsonObject }
        val last = wire.last()
        assertEquals("user", last["role"]?.jsonPrimitive?.content)
        val placeholder = ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat.imagePlaceholderText!!
        // DeepSeek only accepts string content and this turn has no body text: the outbound content is the placeholder line itself (no leading separator).
        assertEquals("placeholder on the wire: $last", placeholder, last["content"]?.jsonPrimitive?.content)
        assertTrue("no image bytes on the wire: $last", "iVBORw0KGgo=" !in last.toString())
    }

    // ── harness ──

    private inner class Harness(
        private val scope: TestScope,
        private val skill: Skill? = null,
        private val pinnedNotes: List<Note> = emptyList(),
        private val memoryItems: List<ai.oriveo.community.core.context.MemoryItem> = MEMORY_ITEMS,
        private val provider: Provider = PROVIDER,
        /** The real service (MockEngine client), OpenAI by default; swap in the matching vendor's service when the provider changes. */
        private val serviceFactory: (HttpClient) -> ai.oriveo.community.core.provider.ProviderService = {
            OpenAIService(it, json, TransportRegistry(json))
        },
    ) {
        val bodies = mutableListOf<JsonObject>()
        /** The requestOptions the production path hands to ProviderService (recorded by the fake service before it delegates to the real OpenAIService). */
        val sentOptions = mutableListOf<ai.oriveo.community.core.model.ChatRequestOptions>()
        /** The message list the production path hands to ProviderService. */
        val sentMessages = mutableListOf<List<ChatMessage>>()
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
        private val providerRepository = mockk<ai.oriveo.community.core.data.repository.ProviderRepository>(relaxed = true).also {
            val real = serviceFactory(client)
            every { it.serviceFor(any<Provider>(), any()) } returns object : ai.oriveo.community.core.provider.ProviderService by real {
                override fun sendMessageStream(
                    apiKey: String,
                    modelID: String,
                    messages: List<ChatMessage>,
                    baseUrl: String?,
                    supportsImageGen: Boolean,
                    reasoningMode: ai.oriveo.community.core.model.ReasoningMode,
                    webSearchEnabled: Boolean,
                    requestOptions: ai.oriveo.community.core.model.ChatRequestOptions,
                ): kotlinx.coroutines.flow.Flow<ai.oriveo.community.core.model.StreamEvent> {
                    sentOptions += requestOptions
                    sentMessages += messages
                    return real.sendMessageStream(apiKey, modelID, messages, baseUrl, supportsImageGen, reasoningMode, webSearchEnabled, requestOptions)
                }
            }
            coEvery { it.getById(provider.id) } returns provider
        }
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        private val streamingManager = mockk<ChatStreamingManager>(relaxed = true).also {
            every { it.startStream(any()) } answers { requests += firstArg<StreamRequest>() }
        }
        private val sendCoordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = scope,
            skillProvider = { id -> skill?.takeIf { it.id == id } },
            providersProvider = { listOf(provider) },
            untitledNoteFallback = "Untitled",
            pinnedNotesResolver = { ids -> pinnedNotes.filter { it.id in ids } },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            // Index building runs on the test scheduler so that advanceUntilIdle can wait for it.
            memoryRecallIndexCache = ai.oriveo.community.core.memory.MemoryRecallIndexCache(
                kotlinx.coroutines.test.StandardTestDispatcher(scope.testScheduler),
            ),
        )
        private val launcher = ChatSendLauncher { conversation, provider, modelId, text, existingMessages, attachments,
            persistUserMessage, appendToAssistant, userMessageAlreadyInHistory, quoteContext, attemptKind ->
            sendCoordinator.launchSend(
                conversation = conversation,
                provider = provider,
                modelId = modelId,
                text = text,
                memoryItems = memoryItems,
                existingMessages = existingMessages,
                attachments = attachments,
                quoteContext = quoteContext,
                persistUserMessage = persistUserMessage,
                appendToAssistant = appendToAssistant,
                userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                attemptKind = attemptKind,
            )
        }

        suspend fun send(
            conversation: Conversation,
            text: String,
            existing: List<ChatMessage> = emptyList(),
            attachments: List<Attachment>? = null,
        ) {
            sendCoordinator.launchSend(
                conversation = conversation.copy(skillId = skill?.id, pinnedNoteIds = pinnedNotes.map { it.id }),
                provider = provider,
                modelId = provider.models.first().id,
                text = text,
                memoryItems = memoryItems,
                existingMessages = existing,
                attachments = attachments,
            )
            drain()
        }

        suspend fun retry(conversation: Conversation, action: (ChatRetryCoordinator) -> Unit) {
            // The delete lands on the fake repository: regenerate re-reads the history after deleting, and what it reads must be the post-delete state.
            var stored = conversation
            coEvery { conversationRepository.getWithMessages(conversation.id) } answers { stored }
            coEvery { conversationRepository.deleteMessagesAfter(conversation.id, any()) } answers {
                val keepThrough = stored.messages.indexOfFirst { it.id == secondArg<String>() }
                stored = stored.copy(messages = stored.messages.take(keepThrough + 1))
            }
            val coordinator = ChatRetryCoordinator(
                viewModelScope = scope,
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                chatStreamingManager = streamingManager,
                currentConversation = { conversation },
                activeProviderId = { PROVIDER.id },
                activeModelId = { MODEL.id },
                providers = { listOf(PROVIDER) },
                requestPin = {},
                launchSend = launcher,
            )
            action(coordinator)
            drain()
        }

        /** Runs the entry coroutine to completion and hands every request given to the streaming manager to the real ChatRepository to send. */
        private suspend fun drain() {
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

    // -- body readers (both Chat Completions and Responses shapes are recognised) --

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

    private fun memorySystem(): String =
        "<oriveo-memory>\n<note>${ContextAssembler.ENVELOPE_NOTES.getValue("oriveo-memory")}</note>\n<entry>$MEMORY</entry>\n</oriveo-memory>"

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
        useMemory = true,
    )

    private fun message(
        id: String,
        role: ChatRole,
        text: String,
        state: ChatMessageState = ChatMessageState.Delivered,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerID = PROVIDER.id,
        providerKind = PROVIDER.kind,
        providerName = PROVIDER.displayName,
        modelID = MODEL.id,
        modelName = MODEL.name,
        state = state,
    )

    private companion object {
        const val MEMORY = "Likes green tea."
        val MEMORY_ITEMS = listOf(
            ai.oriveo.community.core.context.MemoryItem(
                id = "memory-1", kind = ai.oriveo.community.core.context.MemoryKind.FACT, content = MEMORY,
                mutationId = "mutation-1", deviceId = "device-1",
            ),
        )
        val MODEL = AIModel(id = "gpt-4o", name = "GPT-4o", contextLength = 128_000, maxOutputTokens = 16_384)
        val PROVIDER = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "byok-key", models = listOf(MODEL))
        val SKILL = Skill(
            id = "skill-1",
            name = "Barista",
            systemPrompt = "You are a barista.",
            knowledgeFiles = listOf(SkillKnowledgeFile(id = "k-1", name = "menu.txt", content = "Tea and coffee.", charCount = 15)),
        )
        val NOTE = Note(
            id = "note-1",
            title = "Prefs",
            body = "No sugar.",
            createdAt = "2026-10-15T00:00:00Z",
            updatedAt = "2026-10-15T00:00:00Z",
        )
    }
}
