package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextMemoryItem
import ai.oriveo.community.core.context.ContextSegmentKind
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.crosscheck.CrosscheckCoordinator
import ai.oriveo.community.feature.settings.MemoryViewModel
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Crosscheck, memory draft and image generation requests come from the assembler
 * by purpose (purpose system only, no memory / instructions / [D]; image = prompt only).
 */
class ContextPipelinePurposesTest {

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun crosscheck_uses_purpose_system_no_memory() = runTest {
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(CHAT_MODEL))
        val service = mockk<ProviderService>()
        val messages = slot<List<ChatMessage>>()
        val options = slot<ChatRequestOptions>()
        every {
            service.sendMessageStream(any(), any(), capture(messages), any(), any(), any(), any(), capture(options))
        } returns flowOf(StreamEvent.Delta("ok"), StreamEvent.Done(ProviderChatResult(text = "ok")))
        val providerRepository = mockk<ProviderRepository>()
        every { providerRepository.serviceFor(provider, any()) } returns service
        val prior = message("u-0", ChatRole.User, "Earlier question")

        CrosscheckCoordinator(scope = this, providerRepository = providerRepository, appLanguageTag = { "en" })
            .start("Q", "A", listOf(prior), provider, CHAT_MODEL)
        advanceUntilIdle()

        val projection = CrosscheckCoordinator.crosscheckProjection("Q", "A", listOf(prior), provider, CHAT_MODEL, "en")
        assertEquals(RequestPurpose.CROSSCHECK, projection.plan.purpose)
        assertEquals(listOf(ContextSegmentKind.PURPOSE_SYSTEM), projection.plan.segments.map { it.kind })
        assertEquals(CrosscheckCoordinator.crosscheckSystemPrompt("en"), projection.plan.system)
        assertEquals(projection.plan.system, options.captured.systemPrompt)
        assertEquals(listOf(ChatRole.User), messages.captured.map { it.role })
        assertEquals(CrosscheckCoordinator.buildUserContent("Q", "A"), messages.captured.single().text)
    }

    @Test
    fun crosscheck_transport_carries_purpose_system() = runTest {
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(CHAT_MODEL))
        val service = mockk<ProviderService>()
        val messages = slot<List<ChatMessage>>()
        val options = slot<ChatRequestOptions>()
        every {
            service.sendMessageStream(any(), any(), capture(messages), any(), any(), any(), any(), capture(options))
        } returns flowOf(StreamEvent.Done(ProviderChatResult(text = "ok")))
        val providerRepository = mockk<ProviderRepository>()
        every { providerRepository.serviceFor(provider, any()) } returns service
        val prior = message("u-0", ChatRole.User, "Earlier question")

        CrosscheckCoordinator(scope = this, providerRepository = providerRepository, appLanguageTag = { "en" })
            .start("Q", "A", listOf(prior), provider, CHAT_MODEL)
        advanceUntilIdle()

        val planned: PlannedChatRequest =
            CrosscheckCoordinator.crosscheckProjection("Q", "A", listOf(prior), provider, CHAT_MODEL, "en")
        val transport = planned.transportInput(ChatRequestOptions())
        assertEquals(planned.plan.system, options.captured.systemPrompt)
        assertEquals(transport.options, options.captured)
        assertEquals(transport.messages.map { it.role to it.text }, messages.captured.map { it.role to it.text })
    }

    @Test
    fun memory_draft_transport_carries_purpose_system() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(CHAT_MODEL))
            val service = mockk<ProviderService>()
            val messages = slot<List<ChatMessage>>()
            val options = slot<ChatRequestOptions>()
            coEvery {
                service.sendMessage(any(), any(), capture(messages), any(), any(), any(), any(), capture(options))
            } returns StreamEvent.Done(ProviderChatResult(text = "Draft"))
            val providerRepository = mockk<ProviderRepository>()
            every { providerRepository.observeAll() } returns MutableStateFlow(listOf(provider))
            every { providerRepository.serviceFor(provider, any()) } returns service
            val conversationRepository = mockk<ConversationRepository>()
            every { conversationRepository.observeHasAnyWithMessages() } returns flowOf(true)
            coEvery { conversationRepository.getRecentConversationsWithMessages(limit = 5) } returns listOf(
                Conversation(
                    id = "conversation-1",
                    title = "Recent",
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = CHAT_MODEL.id,
                    // The drafting scope only takes user messages sent to the selected provider, so fixture messages must carry a providerID.
                    messages = listOf(message("u-0", ChatRole.User, "I write Kotlin.").copy(providerID = provider.id)),
                ),
            )
            val viewModel = MemoryViewModel(
                appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            )
            advanceUntilIdle()

            viewModel.generateDraft()
            advanceUntilIdle()
            // Drafting first shows the pre-run disclosure, and nothing leaves the device before it is confirmed.
            assertEquals("user: I write Kotlin.", viewModel.extractionDisclosure?.excerpts)
            coVerify(exactly = 0) { service.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }

            viewModel.confirmExtraction()
            advanceUntilIdle()

            val planned: PlannedChatRequest = MemoryViewModel.draftProjection("user: I write Kotlin.", provider, CHAT_MODEL)
            val transport = planned.transportInput(ChatRequestOptions())
            assertEquals(planned.plan.system, options.captured.systemPrompt)
            assertEquals(transport.options, options.captured)
            assertEquals(transport.messages.map { it.role to it.text }, messages.captured.map { it.role to it.text })
            assertEquals("Draft", viewModel.editor?.text)
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun memory_extraction_uses_purpose_system() {
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(CHAT_MODEL))

        val projection = MemoryViewModel.draftProjection("user: I write Kotlin.", provider, CHAT_MODEL)

        assertEquals(RequestPurpose.MEMORY_EXTRACTION, projection.plan.purpose)
        assertEquals(listOf(ContextSegmentKind.PURPOSE_SYSTEM), projection.plan.segments.map { it.kind })
        val system = projection.system.orEmpty()
        assertTrue(system.startsWith("Based on the following conversation excerpts"))
        assertTrue(system.endsWith("Write in first person, as if the user is describing themselves."))
        val user = projection.messages.single()
        assertEquals(ChatRole.User, user.role)
        assertEquals("user: I write Kotlin.", user.text)
        assertFalse(user.text.contains("Based on the following"))
    }

    @Test
    fun image_generation_prompt_only() = runTest {
        val model = AIModel(id = "gpt-image-1", name = "GPT Image", capabilities = listOf(ModelCapability.ImageGen))
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(model),
        )
        val service = mockk<RelayService>()
        val messages = slot<List<ChatMessage>>()
        val options = slot<ChatRequestOptions>()
        coEvery {
            service.generateImageViaImagesEndpoint(any(), any(), capture(messages), any(), capture(options))
        } returns StreamEvent.Done(ProviderChatResult(text = "image"))

        send(provider, model, service)

        assertEquals(listOf(ChatRole.User), messages.captured.map { it.role })
        assertEquals(IMAGE_PROMPT, messages.captured.single().text)
        assertEquals("", options.captured.systemPrompt)
    }

    @Test
    fun image_generation_prompt_only_direct() = runTest {
        val model = AIModel(
            id = "gpt-image-1",
            name = "GPT Image",
            capabilities = listOf(ModelCapability.ImageGen),
            imageGenProfile = "openai",
        )
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(model))
        applyImageRoutes()
        val service = mockk<ProviderService>()
        val messages = slot<List<ChatMessage>>()
        val options = slot<ChatRequestOptions>()
        coEvery {
            service.sendMessage(any(), any(), capture(messages), any(), true, any(), any(), capture(options))
        } returns StreamEvent.Done(ProviderChatResult(text = "image"))

        send(provider, model, service)

        assertEquals(listOf(ChatRole.User), messages.captured.map { it.role })
        assertEquals(IMAGE_PROMPT, messages.captured.single().text)
        assertEquals("", options.captured.systemPrompt)
    }

    /** Conversational image output (Gemini image modality, route chat_api) is a chat request: full chat plan, not the image prompt. */
    @Test
    fun image_generation_conversational_stays_chat() = runTest {
        val model = AIModel(
            id = "gemini-image",
            name = "Gemini Image",
            capabilities = listOf(ModelCapability.ImageGen),
            imageGenProfile = "gemini_image",
        )
        val provider = Provider(id = "gemini-1", kind = ProviderKind.Gemini, apiKey = "key", models = listOf(model))
        applyImageRoutes()
        val service = mockk<ProviderService>()
        val messages = slot<List<ChatMessage>>()
        val options = slot<ChatRequestOptions>()
        coEvery {
            service.sendMessage(any(), any(), capture(messages), any(), true, any(), any(), capture(options))
        } returns StreamEvent.Done(ProviderChatResult(text = "image"))

        send(provider, model, service)

        assertEquals(listOf(ChatRole.User, ChatRole.Assistant, ChatRole.User), messages.captured.map { it.role })
        assertEquals(listOf("Earlier question", "Earlier answer"), messages.captured.take(2).map { it.text })
        assertTrue(messages.captured.last().text.startsWith(IMAGE_PROMPT))
        assertTrue(options.captured.systemPrompt, options.captured.systemPrompt.contains("Likes cats."))
    }

    /** Dedicated image routes (Qwen dashscope_multimodal, MiniMax minimax_image_generation) are purpose imageGeneration. */
    @Test
    fun image_generation_dedicated_routes() = runTest {
        listOf(
            Triple(ProviderKind.Qwen, "qwen-image", "qwen_image"),
            Triple(ProviderKind.MiniMax, "image-01", "minimax_image"),
        ).forEach { (kind, modelId, profile) ->
            val model = AIModel(
                id = modelId,
                name = modelId,
                capabilities = listOf(ModelCapability.ImageGen),
                imageGenProfile = profile,
            )
            val provider = Provider(id = "$kind-1", kind = kind, apiKey = "key", models = listOf(model))
            applyImageRoutes()
            val service = mockk<ProviderService>()
            val messages = slot<List<ChatMessage>>()
            val options = slot<ChatRequestOptions>()
            coEvery {
                service.sendMessage(any(), any(), capture(messages), any(), true, any(), any(), capture(options))
            } returns StreamEvent.Done(ProviderChatResult(text = "image"))

            send(provider, model, service)

            assertEquals("$kind", listOf(ChatRole.User), messages.captured.map { it.role })
            assertEquals("$kind", IMAGE_PROMPT, messages.captured.single().text)
            assertEquals("$kind", "", options.captured.systemPrompt)
        }
    }

    /** gpt-image-1 (OpenAI) routes to images_api; gemini-image (Gemini) is conversational chat_api. */
    private fun applyImageRoutes() = MetadataTestFixtures.applyRaw(
        """
        {
          "version": 1,
          "providers": {
            "openAI": {
              "resolveMap": { "gpt-image-1": "gpt-image-1" },
              "models": { "gpt-image-1": { "canonicalModelId": "gpt-image-1", "capabilities": ["imageGeneration"], "profiles": { "imageGen": "openai_images" } } }
            },
            "gemini": {
              "resolveMap": { "gemini-image": "gemini-image" },
              "models": { "gemini-image": { "canonicalModelId": "gemini-image", "capabilities": ["imageGeneration"], "profiles": { "imageGen": "gemini_image" } } }
            },
            "qwen": {
              "resolveMap": { "qwen-image": "qwen-image" },
              "models": { "qwen-image": { "canonicalModelId": "qwen-image", "capabilities": ["imageGeneration"], "profiles": { "imageGen": "qwen_image" } } }
            },
            "miniMax": {
              "resolveMap": { "image-01": "image-01" },
              "models": { "image-01": { "canonicalModelId": "image-01", "capabilities": ["imageGeneration"], "profiles": { "imageGen": "minimax_image" } } }
            }
          },
          "profiles": {
            "imageGen": {
              "openai_images": { "route": "images_api" },
              "gemini_image": { "route": "chat_api" },
              "qwen_image": { "route": "dashscope_multimodal" },
              "minimax_image": { "route": "minimax_image_generation" }
            }
          }
        }
        """.trimIndent(),
    )

    // ---------- Local memory items are injected when the conversation memory switch is on ----------

    @Test
    fun memory_items_injected_as_standing_and_facts() = runTest {
        val items = listOf(
            memoryItem("f-1", MemoryKind.FACT, "Lives in Berlin."),
            memoryItem("i-1", MemoryKind.INSTRUCTION, "Answer in English."),
            memoryItem("f-2", MemoryKind.PREFERENCE, "Likes cats.", pinned = true),
            memoryItem("c-1", MemoryKind.CONSTRAINT, "Never share keys.", pinned = true),
            memoryItem("p-1", MemoryKind.PROJECT, "Folder project.", scope = MemoryItemScope(MemoryScopeType.FOLDER, FOLDER)),
            memoryItem("x-1", MemoryKind.FACT, "Other chat.", scope = MemoryItemScope(MemoryScopeType.CONVERSATION, "other")),
            memoryItem("e-1", MemoryKind.EVENT, "Went hiking.", layer = MemoryLayer.EPISODIC),
        )
        val context = ChatContextRequest.memoryItems(
            useMemory = true, items = items, conversationId = CONVERSATION, folderId = FOLDER, now = NOW,
        )
        assertEquals(listOf("c-1", "i-1", "f-2", "f-1", "p-1"), context.map { it.id })

        val system = chatSystem(useMemory = true, memoryItems = context)

        val standing = system.substringAfter("<oriveo-standing-instructions>").substringBefore("</oriveo-standing-instructions>")
        val memory = system.substringAfter("<oriveo-memory>").substringBefore("</oriveo-memory>")
        assertEquals(
            listOf("Never share keys.", "Answer in English."),
            ENTRY.findAll(standing).map { it.groupValues[1] }.toList(),
        )
        assertEquals(
            listOf("Likes cats.", "Lives in Berlin.", "Folder project."),
            ENTRY.findAll(memory).map { it.groupValues[1] }.toList(),
        )
        assertTrue(system.indexOf("<oriveo-standing-instructions>") < system.indexOf("<oriveo-memory>"))
        assertFalse(system.contains("Other chat."))
        assertFalse(system.contains("Went hiking."))
    }

    @Test
    fun memory_switch_off_no_items() = runTest {
        val items = listOf(
            memoryItem("i-1", MemoryKind.INSTRUCTION, "Answer in English."),
            memoryItem("f-1", MemoryKind.FACT, "Lives in Berlin."),
        )

        assertEquals(
            emptyList<ContextMemoryItem>(),
            ChatContextRequest.memoryItems(useMemory = false, items = items, conversationId = CONVERSATION, folderId = null, now = NOW),
        )
        // While the conversation switch is off, the assembler does not inject even when items are supplied.
        val injected = ChatContextRequest.memoryItems(
            useMemory = true, items = items, conversationId = CONVERSATION, folderId = null, now = NOW,
        )
        val system = chatSystem(useMemory = false, memoryItems = injected)
        assertFalse(system.contains("<oriveo-standing-instructions>"))
        assertFalse(system.contains("<oriveo-memory>"))
        assertFalse(system.contains("Lives in Berlin."))
    }

    @Test
    fun paused_and_conflicted_not_injected() = runTest {
        val items = listOf(
            memoryItem("a-1", MemoryKind.FACT, "Active fact."),
            memoryItem("p-1", MemoryKind.FACT, "Paused fact.", status = MemoryStatus.PAUSED),
            memoryItem("c-1", MemoryKind.INSTRUCTION, "Conflicted rule.", status = MemoryStatus.CONFLICTED),
            memoryItem("s-1", MemoryKind.FACT, "Superseded fact.", status = MemoryStatus.SUPERSEDED),
            memoryItem("d-1", MemoryKind.FACT, "Deleted fact.", status = MemoryStatus.DELETED),
            memoryItem("x-1", MemoryKind.FACT, "Expired fact.", expiresAt = "2026-10-01T00:00:00Z"),
        )
        val context = ChatContextRequest.memoryItems(
            useMemory = true, items = items, conversationId = CONVERSATION, folderId = null, now = NOW,
        )
        assertEquals(listOf("a-1"), context.map { it.id })

        val system = chatSystem(useMemory = true, memoryItems = context)
        assertTrue(system.contains("<entry>Active fact.</entry>"))
        listOf("Paused fact.", "Conflicted rule.", "Superseded fact.", "Deleted fact.", "Expired fact.").forEach {
            assertFalse(it, system.contains(it))
        }
        assertFalse(system.contains("<oriveo-standing-instructions>"))
    }

    private fun memoryItem(
        id: String,
        kind: MemoryKind,
        content: String,
        status: MemoryStatus = MemoryStatus.ACTIVE,
        scope: MemoryItemScope = MemoryItemScope(),
        layer: MemoryLayer = MemoryLayer.SEMANTIC,
        pinned: Boolean = false,
        expiresAt: String? = null,
    ) = MemoryItem(
        id = id, layer = layer, kind = kind, status = status, content = content, scope = scope, pinned = pinned,
        mutationId = "mutation-$id", deviceId = "device-1", expiresAt = expiresAt,
    )

    /** Sends one chat through the real ChatRepository and returns the system of the outbound options. */
    private suspend fun chatSystem(useMemory: Boolean, memoryItems: List<ContextMemoryItem>): String {
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(CHAT_MODEL))
        val service = mockk<ProviderService>()
        val options = slot<ChatRequestOptions>()
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), capture(options))
        } returns flowOf(StreamEvent.Delta("ok"), StreamEvent.Done(ProviderChatResult(text = "ok")))
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
        val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val conversation = Conversation(
            id = CONVERSATION, title = "Memory", providerID = provider.id, providerKind = provider.kind,
            modelID = CHAT_MODEL.id, useMemory = useMemory, folderID = FOLDER,
        )
        repository.sendMessage(
            conversation = conversation,
            text = "Hello",
            provider = provider,
            modelID = CHAT_MODEL.id,
            existingMessages = emptyList(),
            requestOptions = ChatRequestOptions(
                chatContext = ChatContextRequest(
                    conversation = ContextConversation(id = CONVERSATION, useMemory = useMemory),
                    memoryItems = memoryItems,
                ),
            ),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
        )
        return options.captured.systemPrompt.orEmpty()
    }

    private suspend fun send(provider: Provider, model: AIModel, service: ProviderService) {
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
        val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Image",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = model.id,
            useMemory = true,
        )
        repository.sendMessage(
            conversation = conversation,
            text = IMAGE_PROMPT,
            provider = provider,
            modelID = model.id,
            existingMessages = listOf(
                message("u-0", ChatRole.User, "Earlier question"),
                message("a-0", ChatRole.Assistant, "Earlier answer"),
            ),
            requestOptions = ChatRequestOptions(
                systemPrompt = "Legacy system",
                chatContext = ChatContextRequest(
                    conversation = ContextConversation(id = conversation.id, useMemory = true, instructions = "Be brief."),
                    memoryItems = listOf(ContextMemoryItem(id = "m-1", kind = "fact", content = "Likes cats.")),
                    attachmentGuide = "Attachment guide.",
                ),
            ),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
        )
    }

    private fun message(id: String, role: ChatRole, text: String) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT",
        state = ChatMessageState.Delivered,
    )

    private companion object {
        const val IMAGE_PROMPT = "Draw a cat on a skateboard"
        const val CONVERSATION = "conversation-1"
        const val FOLDER = "folder-1"
        val NOW: java.time.Instant = java.time.Instant.parse("2026-10-16T00:00:00Z")
        val ENTRY = Regex("<entry>(.*?)</entry>")
        val CHAT_MODEL = AIModel(id = "gpt-4o", name = "GPT-4o", contextLength = 128_000, maxOutputTokens = 16_384)
    }
}
