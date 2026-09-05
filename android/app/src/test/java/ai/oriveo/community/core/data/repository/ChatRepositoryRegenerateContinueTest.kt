package ai.oriveo.community.core.data.repository

import androidx.room.Room
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.MessageContinuationStore
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.data.dao.MessageContinuationDao
import ai.oriveo.community.core.data.entity.MessageContinuationEntity
import ai.oriveo.community.core.data.database.MessageContinuationDatabase
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.mockk.CapturingSlot
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File


@RunWith(RobolectricTestRunner::class)
class ChatRepositoryRegenerateContinueTest {

    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val providerService = mockk<ProviderService>()
    private val attachmentStore = mockk<ai.oriveo.community.core.data.attachment.AttachmentStore>(relaxed = true)

    private val repository = ChatRepository(
        conversationRepository = conversationRepository,
        providerRepository = providerRepository,
        attachmentStore = attachmentStore,
    )

    private fun newOutputs() = ConversationStreamingOutputs(
        streamingText = MutableStateFlow(""),
        streamingMessageId = MutableStateFlow<String?>(null),
    )

    private fun provider() = Provider(
        id = "p-anthropic",
        kind = ProviderKind.Anthropic,
        status = ProviderConnectionState.Connected,
        models = emptyList(),
        catalogModels = emptyList(),
        apiKey = "sk-ant",
        apiKeyPreview = "sk-...ant",
    )

    private fun conv(provider: Provider) = Conversation(
        id = "conv-1",
        title = "test",
        providerID = provider.id,
        providerKind = provider.kind,
        modelID = "claude-3",
    )

    private fun assistantMessage(id: String, text: String, state: ChatMessageState) = ChatMessage(
        id = id,
        role = ChatRole.Assistant,
        text = text,
        providerKind = ProviderKind.Anthropic,
        providerName = "Anthropic",
        modelName = "Claude 3",
        state = state,
    )

    private fun userMessage(id: String, text: String) = ChatMessage(
        id = id,
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Anthropic,
        providerName = "Anthropic",
        modelName = "Claude 3",
        state = ChatMessageState.Delivered,
    )

    private fun stubStream(vararg events: StreamEvent): CapturingSlot<List<ChatMessage>> {
        val messagesSlot = slot<List<ChatMessage>>()
        every {
            providerService.sendMessageStream(
                apiKey = any(),
                modelID = any(),
                messages = capture(messagesSlot),
                baseUrl = any(),
                supportsImageGen = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
            )
        } returns flow { events.forEach { emit(it) } }
        return messagesSlot
    }

    @Test
    fun `regenerate does not persist a second user message but still sends it to the model`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        every { providerRepository.serviceFor(provider) } returns providerService
        val messagesSlot = stubStream(
            StreamEvent.Delta("Regenerated answer"),
            StreamEvent.Done(ProviderChatResult(text = "Regenerated answer")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "My question",
            provider = provider,
            modelID = "claude-3",
            existingMessages = emptyList(),
            outputs = newOutputs(),
            persistUserMessage = false,
        )

        
        coVerify(exactly = 0) {
            conversationRepository.addMessage(any(), match { it.role == ChatRole.User })
        }
        
        coVerify(exactly = 1) {
            conversationRepository.addMessage(eq(conversation.id), match { it.role == ChatRole.Assistant })
        }
        
        assertTrue(
            "user text must reach the model as request context",
            messagesSlot.captured.any { it.role == ChatRole.User && it.text == "My question" },
        )
    }

    @Test
    fun `tool-only provider response is delivered as a local fallback card`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        every { providerRepository.serviceFor(provider) } returns providerService
        stubStream(
            StreamEvent.ToolCallDeltas(
                listOf(
                    ai.oriveo.community.core.model.ToolCallDelta(
                        index = 0,
                        id = "call_1",
                        type = "function",
                        name = "search",
                        arguments = "{\"q\":\"news\"}",
                    ),
                ),
            ),
            StreamEvent.Done(ProviderChatResult(text = "")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "Search",
            provider = provider,
            modelID = "claude-3",
            existingMessages = emptyList(),
            outputs = newOutputs(),
        )

        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
        val delivered = updates.last { it.state == ChatMessageState.Delivered }
        assertEquals("", delivered.text)
        assertEquals(1, delivered.unhandledToolCalls.size)
        assertEquals("call_1", delivered.unhandledToolCalls.single().id)
        assertEquals("search", delivered.unhandledToolCalls.single().name)
        assertEquals("{\"q\":\"news\"}", delivered.unhandledToolCalls.single().arguments)
    }

    @Test
    fun `retry failed assistant uses the retained user once when it is already in history`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        val retainedUser = userMessage("u1", "My question")
        val failedAssistant = assistantMessage("a1", "", ChatMessageState.Failed)
        every { providerRepository.serviceFor(provider) } returns providerService
        val messagesSlot = stubStream(
            StreamEvent.Delta("Retried answer"),
            StreamEvent.Done(ProviderChatResult(text = "Retried answer")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "My question",
            provider = provider,
            modelID = "claude-3",
            existingMessages = listOf(retainedUser, failedAssistant),
            outputs = newOutputs(),
            persistUserMessage = false,
            userMessageAlreadyInHistory = true,
            appendToAssistant = failedAssistant,
        )

        coVerify(exactly = 0) {
            conversationRepository.addMessage(any(), match { it.role == ChatRole.User })
        }
        val sentUsers = messagesSlot.captured.filter { it.role == ChatRole.User && it.text == "My question" }
        assertEquals(1, sentUsers.size)
        
        
        assertTrue(
            "empty failed assistant must be filtered out of the outbound payload",
            messagesSlot.captured.none { it.id == "a1" },
        )
        assertEquals(ChatRole.User, messagesSlot.captured.last().role)
    }

    @Test
    fun `retry after switching provider rebinds the request message to the new provider`() = runTest {
        val currentProvider = Provider(
            id = "oriveo-free",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = emptyList(),
            catalogModels = emptyList(),
        )
        val currentModelID = "google/gemma-4-26b-a4b-it:free"
        val conversation = Conversation(
            id = "conv-switch",
            title = "test",
            providerID = currentProvider.id,
            providerKind = currentProvider.kind,
            modelID = currentModelID,
        )
        val retainedUser = userMessage("u-switch", "My question")
        val failedAssistant = ChatMessage(
            id = "a-switch",
            role = ChatRole.Assistant,
            text = "",
            providerID = "gemini-provider",
            providerKind = ProviderKind.Gemini,
            providerName = "Gemini",
            modelID = "gemini-3-pro-image",
            modelName = "Gemini 3 Pro Image",
            servedModelID = "gemini-3-pro-image",
            state = ChatMessageState.Failed,
        )
        every { providerRepository.serviceFor(currentProvider) } returns providerService
        stubStream(
            StreamEvent.Done(
                ProviderChatResult(
                    text = "Retried answer",
                    servedModelID = currentModelID,
                ),
            ),
        )
        try {
            repository.sendMessage(
                conversation = conversation,
                text = "My question",
                provider = currentProvider,
                modelID = currentModelID,
                existingMessages = listOf(retainedUser, failedAssistant),
                outputs = newOutputs(),
                persistUserMessage = false,
                userMessageAlreadyInHistory = true,
                appendToAssistant = failedAssistant,
            )

            val updates = mutableListOf<ChatMessage>()
            coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
            assertTrue(updates.isNotEmpty())
            updates.forEach { message ->
                assertEquals(currentProvider.id, message.providerID)
                assertEquals(currentProvider.kind, message.providerKind)
                assertEquals(currentModelID, message.modelID)
            }
            assertEquals(null, updates.first().servedModelID)
            assertEquals(currentModelID, updates.last().servedModelID)

        } finally {
        }
    }

    @Test
    fun `continue does not persist the instruction and reuses the original assistant id`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        val original = assistantMessage("a1", "Part one.", ChatMessageState.Interrupted)
        every { providerRepository.serviceFor(provider) } returns providerService
        val messagesSlot = stubStream(
            StreamEvent.Delta(" Part two."),
            StreamEvent.Done(ProviderChatResult(text = " Part two.")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "Continue from where you stopped. Do not repeat what you have already said.",
            provider = provider,
            modelID = "claude-3",
            existingMessages = listOf(userMessage("u1", "Question"), original),
            outputs = newOutputs(),
            persistUserMessage = false,
            appendToAssistant = original,
        )

        
        coVerify(exactly = 0) { conversationRepository.addMessage(any(), any()) }

        
        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
        assertTrue("all updates target the original assistant id", updates.all { it.id == "a1" })
        assertEquals(ChatMessageState.Generating, updates.first().state)
        val delivered = updates.last()
        assertEquals(ChatMessageState.Delivered, delivered.state)

        
        assertEquals("Part one. Part two.", delivered.text)

        
        val sent = messagesSlot.captured
        assertEquals(ChatRole.User, sent.last().role)
        assertTrue(sent.last().text.contains("Continue from where you stopped"))
    }

    @Test
    fun `validated model-control resend appends while preserving all generated content`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        val oldCitation = Citation(url = "https://old.example", title = "Old")
        val newCitation = Citation(url = "https://new.example", title = "New")
        val oldAttachment = Attachment(
            id = "generated-old",
            kind = AttachmentKind.File,
            fileName = "result.txt",
            mimeType = "text/plain",
        )
        val original = assistantMessage("a-model-control", "Existing answer.", ChatMessageState.Failed).copy(
            reasoningText = "Existing reasoning.",
            citations = listOf(oldCitation),
            attachments = listOf(oldAttachment),
            customRetryWithoutFieldsCode = "omit_capability_setting_once:custom:generation:-:L3RlbXBlcmF0dXJl",
        )
        every { providerRepository.serviceFor(provider) } returns providerService
        stubStream(
            StreamEvent.Reasoning(" New reasoning."),
            StreamEvent.Citations(listOf(newCitation)),
            StreamEvent.Delta(" New answer."),
            StreamEvent.Done(ProviderChatResult(text = " New answer.")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "Question",
            provider = provider,
            modelID = "claude-3",
            existingMessages = listOf(userMessage("u1", "Question"), original),
            outputs = newOutputs(),
            requestOptions = ChatRequestOptions(),
            persistUserMessage = false,
            appendToAssistant = original,
        )

        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
        val delivered = updates.last()
        assertEquals("Existing answer. New answer.", delivered.text)
        assertEquals("Existing reasoning. New reasoning.", delivered.reasoningText)
        assertEquals(setOf(oldCitation.url, newCitation.url), delivered.citations.orEmpty().map { it.url }.toSet())
        assertEquals(listOf(oldAttachment), delivered.attachments)
    }

    @Test
    fun `continue keeps original text when no new tokens are produced`() = runTest {
        val provider = provider()
        val conversation = conv(provider)
        val original = assistantMessage("a1", "Original partial.", ChatMessageState.Interrupted)
        every { providerRepository.serviceFor(provider) } returns providerService
        stubStream(
            
            StreamEvent.Done(ProviderChatResult(text = "")),
        )

        repository.sendMessage(
            conversation = conversation,
            text = "Continue from where you stopped. Do not repeat what you have already said.",
            provider = provider,
            modelID = "claude-3",
            existingMessages = listOf(userMessage("u1", "Question"), original),
            outputs = newOutputs(),
            persistUserMessage = false,
            appendToAssistant = original,
        )

        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq(conversation.id), capture(updates)) }
        val delivered = updates.last()
        
        assertEquals("Original partial.", delivered.text)
    }

    @Test
    fun `production continuation event persists then only explicit continue loads and acknowledges it`() = runTest {
        val dao = FakeContinuationDao()
        val state = JsonObject(mapOf("blocks" to JsonArray(listOf(JsonObject(mapOf(
            "type" to JsonPrimitive("thinking"), "thinking" to JsonPrimitive("opaque"), "signature" to JsonPrimitive("sig"),
        ))))))
        val nextState = JsonObject(mapOf("blocks" to JsonArray(listOf(JsonObject(mapOf(
            "type" to JsonPrimitive("thinking"), "thinking" to JsonPrimitive("next"), "signature" to JsonPrimitive("sig-2"),
        ))))))
        val store = MessageContinuationStore(dao, Json { ignoreUnknownKeys = true })
        val repo = ChatRepository(
            conversationRepository, providerRepository, attachmentStore,
            continuationStore = store,
            continuationAccountId = { "account" },
        )
        val provider = provider()
        val conversation = conv(provider)
        every { providerRepository.serviceFor(provider) } returns providerService
        var call = 0
        var secondOptions: ChatRequestOptions? = null
        var secondMessages: List<ChatMessage>? = null
        every {
            providerService.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            val messages = arg<List<ChatMessage>>(2)
            val options = arg<ChatRequestOptions>(7)
            flow {
                val index = call++
                if (index == 0) {
                    emit(StreamEvent.RecipeContinuation("replay_blocks", state = state))
                    emit(StreamEvent.Done(ProviderChatResult("first")))
                } else {
                    secondOptions = options
                    secondMessages = messages
                    if (index == 2) emit(StreamEvent.RecipeContinuation("replay_blocks", state = nextState))
                    emit(StreamEvent.Done(ProviderChatResult(" continued")))
                }
            }
        }

        repo.sendMessage(
            conversation, "question", provider, "claude-3", emptyList(),
            outputs = newOutputs(),
        )
        assertEquals("normal send must not read continuation sidecar", 0, dao.getCalls)
        val saved = requireNotNull(dao.rows.values.singleOrNull())
        val partial = assistantMessage(saved.messageId, "first", ChatMessageState.Interrupted)
        repo.sendMessage(
            conversation, "continue", provider, "claude-3",
            listOf(userMessage("u-old", "question"), partial),
            outputs = newOutputs(), persistUserMessage = false, appendToAssistant = partial,
        )

        assertEquals(state, secondOptions?.localContinuationState)
        assertTrue(secondOptions?.localContinuationExplicit == true)
        assertTrue(secondMessages.orEmpty().none { it.id == partial.id })
        assertEquals(ChatRole.User, secondMessages.orEmpty().last().role)
        assertNull("successful provider completion acknowledges sidecar", dao.get("account", partial.id))

        store.save("account", conversation.id, partial.id, "replay_blocks", state)
        repo.sendMessage(
            conversation, "continue again", provider, "claude-3",
            listOf(userMessage("u-old", "question"), partial),
            outputs = newOutputs(), persistUserMessage = false, appendToAssistant = partial,
        )
        assertEquals(nextState, store.loadForExplicit("account", partial.id)?.state)
    }

    @Test
    fun `explicit continuation network failure retains state for retry then successful Done acknowledges`() = runTest {
        val dao = FakeContinuationDao()
        val state = JsonObject(mapOf("previousResponseId" to JsonPrimitive("resp-opaque")))
        val store = MessageContinuationStore(dao, Json { ignoreUnknownKeys = true })
        val repo = ChatRepository(
            conversationRepository, providerRepository, attachmentStore,
            continuationStore = store, continuationAccountId = { "account" },
        )
        val provider = provider()
        val conversation = conv(provider)
        val partial = assistantMessage("a-retry", "partial", ChatMessageState.Interrupted)
        store.save("account", conversation.id, partial.id, "previous_id", state)
        every { providerRepository.serviceFor(provider) } returns providerService
        val seen = mutableListOf<JsonObject?>()
        var attempt = 0
        every {
            providerService.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            val options = arg<ChatRequestOptions>(7)
            seen += options.localContinuationState
            flow {
                if (attempt++ == 0) throw java.io.IOException("first network attempt failed")
                emit(StreamEvent.Done(ProviderChatResult("continued")))
            }
        }

        runCatching {
            repo.sendMessage(
                conversation, "continue", provider, "claude-3", listOf(userMessage("u1", "question"), partial),
                outputs = newOutputs(), persistUserMessage = false, appendToAssistant = partial,
            )
        }
        assertEquals(state, store.loadForExplicit("account", partial.id)?.state)

        repo.sendMessage(
            conversation, "retry", provider, "claude-3", listOf(userMessage("u1", "question"), partial),
            outputs = newOutputs(), persistUserMessage = false, appendToAssistant = partial,
        )
        assertEquals(listOf(state, state), seen)
        assertNull(dao.get("account", partial.id))
    }

    @Test
    fun `shared continuation coverage drives every real provider parser through store and explicit replay`() = runTest {
        data class Case(
            val kind: ProviderKind,
            val wireKind: String,
            val model: String,
            val transport: String,
            val capability: String,
            val recipe: String,
            val reasoning: ai.oriveo.community.core.model.ReasoningMode,
            val web: Boolean,
            val expectedKind: String,
            val parserKind: String,
            val variant: String?,
        )
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val executionFixture = Json.parseToJsonElement(
            File(root, "shared/model-contracts/provider_recipe_execution.v1.json").readText(),
        ).jsonObject
        val coverage = executionFixture["continuationRecipeCoverage"]!!.jsonArray
        require(coverage.size == 19)
        val cases = coverage.map { raw ->
            val row = raw.jsonObject
            val provider = row["providerKind"]!!.jsonPrimitive.content
            Case(
                kind = when (provider) {
                    "openAI" -> ProviderKind.OpenAI
                    "anthropic" -> ProviderKind.Anthropic
                    "gemini" -> ProviderKind.Gemini
                    "grok" -> ProviderKind.Grok
                    "deepseek" -> ProviderKind.DeepSeek
                    "openRouter" -> ProviderKind.OpenRouter
                    "moonshot" -> ProviderKind.Moonshot
                    "miniMax" -> ProviderKind.MiniMax
                    "mistral" -> ProviderKind.Mistral
                    else -> error("unmapped continuation provider $provider")
                },
                wireKind = provider,
                model = row["modelId"]!!.jsonPrimitive.content,
                transport = row["selectorTransport"]?.jsonPrimitive?.content ?: row["transport"]!!.jsonPrimitive.content,
                capability = row["capability"]!!.jsonPrimitive.content,
                recipe = row["recipeRef"]!!.jsonPrimitive.content,
                reasoning = if (row["capability"]!!.jsonPrimitive.content == "reasoning") ai.oriveo.community.core.model.ReasoningMode.Max else ai.oriveo.community.core.model.ReasoningMode.Automatic,
                web = row["capability"]!!.jsonPrimitive.content == "web",
                expectedKind = row["continuationKind"]!!.jsonPrimitive.content,
                parserKind = row["responseParserKind"]!!.jsonPrimitive.content,
                variant = row["continuationVariant"]?.jsonPrimitive?.content,
            )
        }
        val registryPath = executionFixture["registryPath"]!!.jsonPrimitive.content
        val registry = Json.parseToJsonElement(File(root, registryPath).readText()).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:joined-continuation"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        try {
            cases.forEach { case ->
                MetadataTestFixtures.applyRaw(buildJsonObject {
                    put("version", 1); put("capabilityRuntime", runtime)
                    put("providers", buildJsonObject { put(case.wireKind, buildJsonObject {
                        put("resolveMap", buildJsonObject { put(case.model, case.model) })
                        put("models", buildJsonObject { put(case.model, buildJsonObject {
                            put("transport", case.transport)
                            put("capabilityControls", buildJsonObject { put(case.capability, buildJsonObject {
                                put("state", "auto_available"); put("recipeRef", case.recipe)
                                if (case.capability == "reasoning") {
                                    put("availableIntents", JsonArray(listOf(JsonPrimitive("max"))))
                                }
                            }) })
                        }) })
                    }) })
                }.toString())
                val captured = mutableListOf<Pair<String, String>>()
                var providerLeg = 0
                val providerJson = Json { ignoreUnknownKeys = true }
                val client = HttpClient(MockEngine { request ->
                    val requestBody = (request.body as? TextContent)?.text.orEmpty()
                    captured += request.url.encodedPath to requestBody
                    val path = request.url.encodedPath
                    when {
                        path.endsWith("/formulas/moonshot/web-search:latest/tools") -> respond(
                            """{"tools":[{"type":"function","function":{"name":"search","parameters":{}}}]}""",
                            HttpStatusCode.OK,
                        )
                        path.endsWith("/formulas/moonshot/web-search:latest/fibers") -> respond(
                            """{"context":{"encrypted_output":"opaque-fiber"}}""", HttpStatusCode.OK,
                        )
                        else -> {
                            providerLeg += 1
                            val payload = when {
                                case.transport == "gemini_interactions" -> if (providerLeg == 1) """
                                    data: {"event_type":"step.delta","step":{"type":"model_output","delta":{"text":"first"}}}

                                    data: {"event_type":"interaction.completed","interaction":{"id":"interaction-1","status":"completed"}}

                                    data: [DONE]
                                """.trimIndent() else """
                                    data: {"event_type":"step.delta","step":{"type":"model_output","delta":{"text":"next"}}}

                                    data: {"event_type":"interaction.completed","interaction":{"status":"completed"}}

                                    data: [DONE]
                                """.trimIndent()
                                case.transport == "gemini_generate" -> """
                                    data: {"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"opaque","thoughtSignature":"sig-$providerLeg"},{"text":"${if (providerLeg == 1) "first" else "next"}"}]}}]}

                                    data: [DONE]
                                """.trimIndent()
                                case.kind == ProviderKind.Anthropic -> """
                                    event: content_block_start
                                    data: {"index":0,"content_block":{"type":"thinking","thinking":"opaque","signature":"sig-$providerLeg"}}

                                    event: content_block_start
                                    data: {"index":1,"content_block":{"type":"text","text":"${if (providerLeg == 1) "first" else "next"}"}}

                                    event: message_stop
                                    data: {}
                                """.trimIndent()
                                case.parserKind == "minimax_anthropic_web_v1" -> """
                                    event: message_start
                                    data: {"type":"message_start","message":{"usage":{"input_tokens":7}}}

                                    event: content_block_start
                                    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"opaque","signature":"sig-$providerLeg"}}

                                    event: content_block_start
                                    data: {"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"web-$providerLeg","name":"web_search","input":{"query":"news"}}}

                                    event: content_block_start
                                    data: {"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"web-$providerLeg","content":[{"type":"web_search_result","url":"https://example.com/$providerLeg","title":"Example","content":"citation"}]}}

                                    event: content_block_start
                                    data: {"type":"content_block_start","index":3,"content_block":{"type":"text","text":"${if (providerLeg == 1) "first" else "next"}"}}

                                    event: message_delta
                                    data: {"type":"message_delta","usage":{"output_tokens":9}}

                                    event: message_stop
                                    data: {"type":"message_stop"}
                                """.trimIndent()
                                case.transport == "openai_responses" -> """
                                    event: response.output_text.delta
                                    data: {"type":"response.output_text.delta","delta":"${if (providerLeg == 1) "first" else "next"}"}

                                    event: response.completed
                                    data: {"type":"response.completed","response":{${if (providerLeg == 1) "\"id\":\"response-1\"" else ""}}}

                                    data: [DONE]
                                """.trimIndent()
                                case.parserKind == "openrouter_reasoning_v1" -> """
                                    data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"opaque"}],"content":"${if (providerLeg == 1) "first" else "next"}"}}]}

                                    data: [DONE]
                                """.trimIndent()
                                case.parserKind == "mistral_reasoning_v1" -> """
                                    data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"opaque"}],"closed":true},{"type":"text","text":"${if (providerLeg == 1) "first" else "next"}"}]}}]}

                                    data: [DONE]
                                """.trimIndent()
                                case.expectedKind == "replay_reasoning" -> """
                                    data: {"choices":[{"delta":{"reasoning_content":"opaque","content":"${if (providerLeg == 1) "first" else "next"}"}}]}

                                    data: [DONE]
                                """.trimIndent()
                                case.expectedKind == "tool_loop" && providerLeg == 1 -> """
                                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"${if (case.variant == "fiber") "function" else "builtin_function"}","function":{"name":"${if (case.variant == "fiber") "search" else "${'$'}web_search"}","arguments":"{\"q\":\"news\"}"}}]}}]}

                                    data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                                    data: [DONE]
                                """.trimIndent()
                                else -> """
                                    data: {"choices":[{"delta":{"content":"${if (providerLeg <= 2) "first" else "next"}"}}]}

                                    data: [DONE]
                                """.trimIndent()
                            }
                            respond(payload, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                        }
                    }
                })
                val continuationDb = Room.inMemoryDatabaseBuilder(
                    RuntimeEnvironment.getApplication(), MessageContinuationDatabase::class.java,
                ).allowMainThreadQueries().build()
                try {
                val parsedEvents = mutableListOf<StreamEvent>()
                val parserService: ProviderService = when (case.kind) {
                    ProviderKind.OpenAI -> OpenAIService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.Anthropic -> AnthropicService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.Gemini -> GeminiService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.Grok -> GrokService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.DeepSeek -> DeepSeekService(client, providerJson)
                    ProviderKind.OpenRouter -> OpenRouterService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.Moonshot -> MoonshotService(client, providerJson, TransportRegistry(providerJson))
                    ProviderKind.MiniMax -> MiniMaxService(client, providerJson)
                    ProviderKind.Mistral -> MistralService(client, providerJson, TransportRegistry(providerJson))
                    else -> error("unsupported joined case")
                }
                val actualService = object : ProviderService by parserService {
                    override fun sendMessageStream(
                        apiKey: String,
                        modelID: String,
                        messages: List<ChatMessage>,
                        baseUrl: String?,
                        supportsImageGen: Boolean,
                        reasoningMode: ai.oriveo.community.core.model.ReasoningMode,
                        webSearchEnabled: Boolean,
                        requestOptions: ChatRequestOptions,
                    ) = parserService.sendMessageStream(
                        apiKey, modelID, messages, baseUrl, supportsImageGen,
                        reasoningMode, webSearchEnabled, requestOptions,
                    ).onEach { event -> parsedEvents.add(event) }
                }
                val dao = continuationDb.dao()
                val store = MessageContinuationStore(dao, Json)
                val repo = ChatRepository(
                    conversationRepository, providerRepository, attachmentStore,
                    continuationStore = store, continuationAccountId = { "account" },
                )
                val provider = Provider(
                    id = "p-${case.kind.rawValue}", kind = case.kind, status = ProviderConnectionState.Connected,
                    models = emptyList(), catalogModels = emptyList(), apiKey = "sk-test", apiKeyPreview = "sk-...",
                )
                every { providerRepository.serviceFor(provider) } returns actualService
                val conversation = Conversation(
                    id = "c-${case.kind.rawValue}", title = "test", providerID = provider.id,
                    providerKind = case.kind, modelID = case.model,
                )
                repo.sendMessage(
                    conversation, "question", provider, case.model, emptyList(), reasoningMode = case.reasoning,
                    webSearchEnabled = case.web, outputs = newOutputs(),
                )
                val saved = requireNotNull(dao.listForAccount("account").singleOrNull()) {
                    "${case.recipe}/${case.expectedKind} producer did not persist; events=$parsedEvents requests=$captured"
                }
                require(saved.kind == case.expectedKind) { "${case.expectedKind} saved unexpected kind=${saved.kind}" }
                val partial = ChatMessage(
                    saved.messageId, ChatRole.Assistant, "first", providerKind = case.kind,
                    providerName = case.kind.rawValue, modelID = case.model, modelName = case.model,
                    state = ChatMessageState.Interrupted,
                )
                val eventsBeforeReplay = parsedEvents.size
                repo.sendMessage(
                    conversation, "continue", provider, case.model,
                    listOf(ChatMessage("u-old", ChatRole.User, "question", providerKind = case.kind, providerName = case.kind.rawValue, modelName = case.model, state = ChatMessageState.Delivered), partial),
                    reasoningMode = case.reasoning, webSearchEnabled = case.web, outputs = newOutputs(),
                    persistUserMessage = false, appendToAssistant = partial,
                )
                val replayBodyText = requireNotNull(captured.asReversed().firstOrNull { (_, body) ->
                    runCatching {
                        val objectBody = Json.parseToJsonElement(body).jsonObject
                        objectBody.keys.any { it in setOf("messages", "input", "contents") }
                    }.getOrDefault(false)
                }) { "${case.recipe} captured no provider request body: $captured" }.second
                val replayBody = Json.parseToJsonElement(replayBodyText).jsonObject
                when (case.expectedKind) {
                    "previous_id" -> {
                        val key = if (case.transport == "gemini_interactions") "previous_interaction_id" else "previous_response_id"
                        val expected = if (case.transport == "gemini_interactions") "interaction-1" else "response-1"
                        require(replayBody[key]?.jsonPrimitive?.content == expected) { "${case.recipe} previous_id replay=$replayBody events=$parsedEvents" }
                        val inputKey = if (case.transport == "gemini_interactions") "input" else "input"
                        require(replayBody[inputKey]?.jsonArray?.size == 1) { "${case.recipe} resent represented history: $replayBody" }
                    }
                    "replay_blocks" -> require((replayBody["messages"] as? JsonArray).orEmpty().any {
                        it.jsonObject["role"]?.jsonPrimitive?.content == "assistant" && it.jsonObject["content"] is JsonArray
                    } || (replayBody["contents"] as? JsonArray).orEmpty().any {
                        it.jsonObject["role"]?.jsonPrimitive?.content == "model" && it.jsonObject["parts"] is JsonArray
                    }) { "${case.recipe} replay_blocks missing exact assistant/model block: $replayBody events=$parsedEvents" }
                    "replay_reasoning" -> require(replayBody["messages"]!!.jsonArray.any {
                        val assistant = it.jsonObject
                        if (case.parserKind == "openrouter_reasoning_v1") {
                            (assistant["reasoning_details"] as? JsonArray)?.isNotEmpty() == true
                        } else if (case.parserKind == "mistral_reasoning_v1") {
                            (assistant["content"] as? JsonArray)?.any { block ->
                                block.jsonObject["type"]?.jsonPrimitive?.content == "thinking"
                            } == true
                        } else {
                            assistant["reasoning_content"]?.jsonPrimitive?.content == "opaque"
                        }
                    }) { "${case.recipe} replay_reasoning missing exact parser-owned assistant message: $replayBody events=$parsedEvents" }
                    "tool_loop" -> {
                        val roles = replayBody["messages"]!!.jsonArray.map { it.jsonObject["role"]!!.jsonPrimitive.content }
                        require(roles.takeLast(3) == listOf("assistant", "tool", "user")) { "tool_loop order=$roles body=$replayBody events=$parsedEvents" }
                    }
                }
                val producedReplacement = parsedEvents.drop(eventsBeforeReplay).any { it is StreamEvent.RecipeContinuation }
                val rowAfterReplay = dao.get("account", saved.messageId)
                if (producedReplacement) {
                    require(rowAfterReplay != null && rowAfterReplay.updatedAt != saved.updatedAt) {
                        "${case.expectedKind} new producer state was deleted by old snapshot ACK"
                    }
                } else {
                    require(rowAfterReplay == null) { "${case.expectedKind} successful replay did not compare-ack" }
                }
                } finally {
                    client.close()
                    continuationDb.close()
                }
            }
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    private class FakeContinuationDao : MessageContinuationDao {
        val rows = linkedMapOf<Pair<String, String>, MessageContinuationEntity>()
        var getCalls = 0
        override suspend fun upsert(entity: MessageContinuationEntity) { rows[entity.accountId to entity.messageId] = entity }
        override suspend fun get(accountId: String, messageId: String): MessageContinuationEntity? {
            getCalls += 1
            return rows[accountId to messageId]
        }
        override suspend fun delete(accountId: String, messageId: String) { rows.remove(accountId to messageId) }
        override suspend fun deleteOtherProcessSessions(currentToken: String) {
            rows.entries.removeAll { it.value.processSessionToken != currentToken }
        }
        override suspend fun deleteMessages(accountId: String, messageIds: List<String>) { messageIds.forEach { rows.remove(accountId to it) } }
        override suspend fun deleteIfUnchanged(accountId: String, messageId: String, updatedAt: Long, processSessionToken: String, stateJson: String): Int {
            val key = accountId to messageId
            val row = rows[key]
            return if (row?.updatedAt == updatedAt && row.processSessionToken == processSessionToken &&
                row.stateJson == stateJson && !row.interrupted
            ) { rows.remove(key); 1 } else 0
        }
        override suspend fun markInterrupted(accountId: String, messageId: String, updatedAt: Long) {
            val key = accountId to messageId; rows[key]?.let { rows[key] = it.copy(interrupted = true, updatedAt = updatedAt) }
        }
        override suspend fun deleteForConversation(accountId: String, conversationId: String) {
            rows.entries.removeAll { it.value.accountId == accountId && it.value.conversationId == conversationId }
        }
        override suspend fun listForAccount(accountId: String) = rows.values.filter { it.accountId == accountId }
    }
}
