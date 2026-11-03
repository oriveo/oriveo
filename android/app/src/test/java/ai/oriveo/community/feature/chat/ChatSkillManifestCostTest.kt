package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.library.LibraryChatResearchRunner
import ai.oriveo.community.core.mcp.McpChatToolRunner
import ai.oriveo.community.core.mcp.McpToolPlan
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.withSkillIds
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.skills.SkillTurnDependencies
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.StreamRequest
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.skills.SkillChannel
import ai.oriveo.community.core.skills.SkillRuntime
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.telemetry.ChatAttemptKind
import ai.oriveo.community.core.usage.BudgetAlertChecker
import ai.oriveo.community.core.usage.UsageReporter
import ai.oriveo.community.feature.chat.composer.SkillComposerChipsModel
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
import io.mockk.slot
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ChatRepository.sendMessage records the turn's skill list overhead on its assistant row, right where the turn's
 * usage is written (skill_manifest_cost.v1); a turn without a manifest records nothing.
 */
class ChatSkillManifestCostTest {

    private val writer = Skill(
        id = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        name = "Writer",
        systemPrompt = "Write well.",
        whenToUse = "When the user asks for writing help",
        autoInvoke = true,
    )
    private val attached = Skill(id = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", name = "Attached", systemPrompt = "Be brief.")

    private val provider = Provider(
        id = "official-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "local-key",
        models = listOf(AIModel(id = MODEL, name = MODEL, isManual = true)),
    )

    private class Send(val conversationRepository: ConversationRepository, val delivered: ChatMessage)

    private fun turn(channel: SkillChannel, attachedIds: List<String>, autoEnabled: Boolean): SkillTurn {
        val skills = listOf(attached, writer)
        val manifest = SkillRuntime.buildManifest(
            skills.map(SkillTurn::runtimeSkill), attachedIds, emptyList(), autoEnabled, channel, emptyList(),
        )
        return SkillTurn(
            channel = channel,
            manifestIds = manifest.manifestIds,
            attachedSkills = skills.filter { SkillRuntime.canonicalId(it.id) in manifest.attachedIds },
            skills = skills,
            resendInputs = { SkillTurnInputs(skillPrompt = "resent", knowledgeFiles = emptyList(), retrieval = null) },
            recordUsed = { _, _ -> },
            trackAutoUsed = { _, _ -> },
            attachedIds = attachedIds,
            disabledAutoIds = emptyList(),
            autoEnabled = autoEnabled,
        )
    }

    private fun plainService(): ProviderService = mockk<ProviderService>().also { service ->
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any())
        } returns flowOf(StreamEvent.Delta("Plain answer"), StreamEvent.Done(ProviderChatResult(text = "Plain answer")))
    }

    private suspend fun send(
        turn: SkillTurn?,
        appendToAssistant: ChatMessage? = null,
        attemptKind: ChatAttemptKind = ChatAttemptKind.Send,
        provider: Provider = this.provider,
        modelId: String = MODEL,
        service: ProviderService = plainService(),
    ): Send {
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val providerRepository = mockk<ProviderRepository>()
        val mcpRunner = mockk<McpChatToolRunner>()
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        every { providerRepository.currentCapabilityPartitionId() } returns "user-1"
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
        coEvery { mcpRunner.plan(any(), any(), any(), any(), any()) } returns McpToolPlan.Empty
        every { mcpRunner.clearStepLimitReached(any()) } returns Unit
        val repository = ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            usageReporter = mockk<UsageReporter>(relaxed = true),
            budgetAlertChecker = mockk<BudgetAlertChecker>(relaxed = true),
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            libraryChatResearchRunner = mockk<LibraryChatResearchRunner>(),
            toolCallMemoryStore = mockk<ToolCallMemoryStore>(relaxed = true),
            mcpChatToolRunner = mcpRunner,
            relayNegativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L }),
        )
        repository.sendMessage(
            conversation = Conversation(
                id = "conversation-1", title = "Skills", providerID = provider.id, providerKind = provider.kind, modelID = modelId,
            ),
            text = "Help me write?", provider = provider, modelID = modelId,
            existingMessages = listOfNotNull(appendToAssistant),
            outputs = ConversationStreamingOutputs(streamingText = MutableStateFlow(""), streamingMessageId = MutableStateFlow(null)),
            skillTurn = turn,
            appendToAssistant = appendToAssistant,
            attemptKind = attemptKind,
        )
        val updates = mutableListOf<ChatMessage>()
        coVerify { conversationRepository.updateMessage(eq("conversation-1"), capture(updates)) }
        return Send(conversationRepository, updates.last())
    }

    @Test
    fun `marker turn records manifestOverhead on the delivered assistant row`() = runTest {
        val attachedIds = listOf(attached.id)
        val send = send(turn(SkillChannel.MARKER, attachedIds, autoEnabled = true))

        assertEquals(ChatMessageState.Delivered, send.delivered.state)
        // No context ledger in this repository: the turn's rhoHi is RHO0.
        val expected = SkillRuntime.manifestOverhead(
            skills = listOf(attached, writer).map(SkillTurn::runtimeSkill),
            attached = attachedIds,
            disabledAuto = emptyList(),
            autoEnabled = true,
            channel = SkillChannel.MARKER,
            loaded = emptyList(),
            rhoHi = ContextBudget.RHO0,
        )
        assertNotNull(expected)
        assertTrue(expected!!.tokens > 0)
        coVerify(exactly = 1) { send.conversationRepository.updateSkillManifestTokens(send.delivered.id, expected.tokens) }
    }

    @Test
    fun `turn without a manifest records nothing`() = runTest {
        val send = send(turn(SkillChannel.NONE, listOf(attached.id), autoEnabled = false))

        assertEquals(ChatMessageState.Delivered, send.delivered.state)
        coVerify(exactly = 0) { send.conversationRepository.updateSkillManifestTokens(any(), any()) }
    }

    private val previousReply = ChatMessage(
        id = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
        role = ChatRole.Assistant,
        text = "Earlier answer",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = MODEL,
        state = ChatMessageState.Failed,
    )

    @Test
    fun `retry clears the reused row when it starts and records the new turn on delivery`() = runTest {
        val turn = turn(SkillChannel.MARKER, listOf(attached.id), autoEnabled = true)
        val send = send(turn, appendToAssistant = previousReply, attemptKind = ChatAttemptKind.Retry)

        assertEquals(previousReply.id, send.delivered.id)
        val tokens = checkNotNull(turn.manifestTokens(ContextBudget.RHO0))
        coVerifyOrder {
            send.conversationRepository.updateSkillManifestTokens(previousReply.id, null)
            send.conversationRepository.updateMessage("conversation-1", any())
            send.conversationRepository.updateSkillManifestTokens(previousReply.id, tokens)
        }
        coVerify(exactly = 2) { send.conversationRepository.updateSkillManifestTokens(any(), any()) }
    }

    @Test
    fun `continue sends no manifest and records nothing`() = runTest {
        // Production path: the coordinator resolves the continue turn's skill inputs, then the repository sends it.
        val streamingManager = mockk<ChatStreamingManager>(relaxed = true)
        val captured = slot<StreamRequest>()
        every { streamingManager.startStream(capture(captured)) } returns Unit
        val byId = listOf(attached, writer).associateBy { SkillRuntime.canonicalId(it.id) }
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = this,
            skillDependencies = object : SkillTurnDependencies {
                override suspend fun skill(id: String): Skill? = byId[SkillRuntime.canonicalId(id)]
                override suspend fun userSkills(): List<Skill> = listOf(attached, writer)
                override suspend fun recordUse(skillId: String, via: String) = Unit
            },
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        )
        coordinator.launchSend(
            conversation = Conversation(
                id = "conversation-1", title = "Skills", providerID = provider.id, providerKind = provider.kind, modelID = MODEL,
            ).withSkillIds(listOf(attached.id)),
            provider = provider,
            modelId = MODEL,
            text = ContextAssembler.CONTINUE_PROMPT,
            memoryItems = emptyList(),
            existingMessages = listOf(previousReply),
            persistUserMessage = false,
            appendToAssistant = previousReply,
            userMessageAlreadyInHistory = true,
            attemptKind = ChatAttemptKind.Continue,
        )
        advanceUntilIdle()

        val request = captured.captured
        val prompt = request.requestOptions.chatContext?.conversation?.skillPrompt.orEmpty()
        assertTrue(prompt, prompt.contains("Be brief."))
        assertFalse(prompt, prompt.contains(SkillRuntime.MARKER_NOTE))
        assertFalse(prompt, prompt.contains("<oriveo-skills>"))
        val continueTurn = request.skillTurn
        assertTrue(continueTurn == null || continueTurn.channel == SkillChannel.NONE)

        val send = send(continueTurn, appendToAssistant = previousReply, attemptKind = ChatAttemptKind.Continue)
        assertEquals(previousReply.id, send.delivered.id)
        coVerify(exactly = 0) { send.conversationRepository.updateSkillManifestTokens(any(), any()) }
    }

    @Test
    fun disable_then_send_before_cache_refresh_excludes_skill() = runTest {
        // The cached conversation still lists nothing disabled: the store write has not come back yet.
        val stale = Conversation(
            id = "conversation-1", title = "Skills", providerID = provider.id, providerKind = provider.kind, modelID = MODEL,
        )
        // The send setup leaves child jobs behind; they run on the test scheduler and are cancelled at the end.
        val sendScope = kotlinx.coroutines.CoroutineScope(coroutineContext + kotlinx.coroutines.Job(coroutineContext[kotlinx.coroutines.Job]))
        val write = CompletableDeferred<List<String>?>()
        val chips = SkillComposerChipsModel(
            scope = sendScope,
            userSkills = flowOf(listOf(writer)),
            templates = flowOf(emptyList()),
            writeSkillIds = { _, _ -> null },
            track = { _, _ -> },
            disableAuto = { write.await() },
            activeConversationId = { stale.id },
        )
        val launched = mutableListOf<Conversation>()
        val appPreferences = mockk<AppPreferencesRepository>(relaxed = true)
        coEvery { appPreferences.hasAcceptedProviderDisclosure(any()) } returns true
        val providers = mockk<ProviderRepository>()
        coEvery { providers.getById(provider.id) } returns provider
        val conversations = mockk<ConversationRepository>(relaxed = true)
        coEvery { conversations.getWithMessages(any()) } returns stale
        val command = ChatSendCommandCoordinator(
            viewModelScope = sendScope,
            appPreferencesRepository = appPreferences,
            providerRepository = providers,
            conversationRepository = conversations,
            currentConversation = { stale },
            currentConversationId = { stale.id },
            disabledAutoForSend = chips::disabledAutoForSend,
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { conversation, _, _, _, _, _, _, _, _, _, _, _, _, _ -> launched += conversation },
        )

        chips.disableAutoInCurrent(writer.id)
        command.sendMessage("Help me write?", null, provider.id, MODEL)
        advanceUntilIdle()

        val request = launched.single()
        val manifestRow = "id=\"${SkillRuntime.canonicalId(writer.id)}\""
        // Control: the stale cached conversation alone would still list the skill.
        assertTrue(systemOf(stale, sendScope).contains(manifestRow))
        val system = systemOf(request, sendScope)
        assertFalse(system, system.contains(manifestRow))
        write.complete(null)
        sendScope.cancel()
    }

    /** The skill prompt the production send coordinator builds for [conversation]'s next turn. */
    private suspend fun kotlinx.coroutines.test.TestScope.systemOf(
        conversation: Conversation,
        scope: kotlinx.coroutines.CoroutineScope,
    ): String {
        val streamingManager = mockk<ChatStreamingManager>(relaxed = true)
        val captured = slot<StreamRequest>()
        every { streamingManager.startStream(capture(captured)) } returns Unit
        ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = scope,
            skillDependencies = object : SkillTurnDependencies {
                override suspend fun skill(id: String): Skill? = writer.takeIf { SkillRuntime.canonicalId(id) == SkillRuntime.canonicalId(writer.id) }
                override suspend fun userSkills(): List<Skill> = listOf(writer)
                override suspend fun recordUse(skillId: String, via: String) = Unit
            },
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        ).launchSend(
            conversation = conversation,
            provider = provider,
            modelId = MODEL,
            text = "Help me write?",
            memoryItems = emptyList(),
            existingMessages = emptyList(),
            persistUserMessage = false,
            appendToAssistant = null,
            userMessageAlreadyInHistory = false,
            attemptKind = ChatAttemptKind.Send,
        )
        advanceUntilIdle()
        return captured.captured.requestOptions.chatContext?.conversation?.skillPrompt.orEmpty()
    }

    @Test
    fun `dedicated image request carries no system and records nothing`() = runTest {
        val model = AIModel(id = "gpt-image-1", name = "GPT Image", capabilities = listOf(ModelCapability.ImageGen))
        val relay = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(model),
        )
        val service = mockk<RelayService>()
        val options = slot<ChatRequestOptions>()
        coEvery {
            service.generateImageViaImagesEndpoint(any(), any(), any(), any(), capture(options))
        } returns StreamEvent.Done(ProviderChatResult(text = "image"))

        val send = send(
            turn(SkillChannel.MARKER, listOf(attached.id), autoEnabled = true),
            provider = relay,
            modelId = model.id,
            service = service,
        )

        assertEquals("", options.captured.systemPrompt)
        coVerify(exactly = 0) { send.conversationRepository.updateSkillManifestTokens(any(), any()) }
    }

    private companion object {
        const val MODEL = "my-handfilled-model"
    }
}
