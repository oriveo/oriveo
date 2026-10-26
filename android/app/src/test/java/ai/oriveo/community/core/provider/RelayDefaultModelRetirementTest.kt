package ai.oriveo.community.core.provider

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.feature.chat.ChatConversationIssueKind
import ai.oriveo.community.feature.chat.ChatModelSelectionCoordinator
import ai.oriveo.community.feature.chat.ChatRetryCoordinator
import ai.oriveo.community.feature.chat.ChatSendCommandCoordinator
import ai.oriveo.community.feature.chat.ChatSendLauncher
import ai.oriveo.community.feature.chat.components.relayModelRemovedBannerContent
import ai.oriveo.community.feature.chat.resolveChatConversationState
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.util.Collections
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Retirement of the relay default model. Selection semantics are driven by the shared fixture
 * `shared/test-fixtures/relay/model-selection.v1.json`, one RD1_SELECT_<id> test per case;
 * the remaining cases go through production entry points (conversation state resolution, send / retry entry, selection coordinator, repository registration and re-detection, cloud sync encoding).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayDefaultModelRetirementTest {
    private val json = Json { ignoreUnknownKeys = true }

    // ── Fixture ──

    private val fixture: JsonObject by lazy {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/relay/model-selection.v1.json")
            if (candidate.exists()) return@lazy Json.parseToJsonElement(candidate.readText()).jsonObject
            dir = dir.parentFile
        }
        throw IllegalStateException("model-selection.v1.json not found")
    }

    private fun case(id: String): JsonObject =
        fixture.getValue("cases").jsonArray.map { it.jsonObject }.single { it.getValue("id").jsonPrimitive.content == id }

    private fun JsonObject.str(key: String): String? =
        this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    private fun fixtureProvider(raw: JsonObject): Provider {
        val kind = when (raw.str("kind")) {
            "relay" -> ProviderKind.Relay
            "openAI" -> ProviderKind.OpenAI
            else -> error("unknown kind ${raw.str("kind")}")
        }
        return Provider(
            id = raw.str("id")!!,
            kind = kind,
            status = ProviderConnectionState.Connected,
            customName = raw.str("name"),
            // The default authMode needs credentials: without a key a new conversation drops it for missing credentials.
            apiKey = "sk-test",
            relayKind = if (kind == ProviderKind.Relay) RelayKind.OpenAICompatible else null,
            relayRequested = if (kind == ProviderKind.Relay) {
                RelayRequestedConfig(engineProfile = raw.str("engineProfile"))
            } else {
                null
            },
            models = raw.getValue("models").jsonArray.map { element ->
                val model = element.jsonObject
                AIModel(
                    id = model.str("id")!!,
                    name = model.str("id")!!,
                    isDefault = model["isDefault"]?.jsonPrimitive?.booleanOrNull ?: false,
                )
            },
            catalogModels = raw.getValue("catalogModels").jsonArray.map { id ->
                AIModel(id = id.jsonPrimitive.content, name = id.jsonPrimitive.content)
            },
        )
    }

    private fun runSelectCase(id: String) {
        val case = case(id)
        val provider = fixtureProvider(case.getValue("provider").jsonObject)
        val lastUsed = (case["lastUsedModelRef"] as? JsonObject)?.let {
            LastUsedModelRef(providerID = it.str("providerId")!!, modelID = it.str("modelId")!!)
        }
        val conversationModelId = case.str("conversationModelId")
        val expect = case.getValue("expect").jsonObject

        if (expect.containsKey("fallbackModelId")) {
            assertEquals("$id: fallback", expect.str("fallbackModelId"), RelayModelFallback.fallbackModel(provider, lastUsed)?.id)
            // The new-conversation entry (home / empty chat) shares its source with the fallback.
            assertEquals(
                "$id: new-conversation entry",
                expect.str("fallbackModelId"),
                resolveActiveModel(listOf(provider), lastUsed)?.model?.id,
            )
        }
        if (expect.containsKey("verificationSampleModelId")) {
            assertEquals(
                "$id: verification sample",
                expect.str("verificationSampleModelId"),
                RelayModelFallback.verificationSampleModelID(provider, lastUsed),
            )
        }

        if (conversationModelId != null) {
            val conversation = Conversation(
                id = "conv-$id",
                title = "t",
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = conversationModelId,
            )
            val state = resolveChatConversationState(
                conversation = conversation,
                providers = listOf(provider),
                activeProviderId = conversation.providerID,
                activeModelId = conversation.modelID,
                providersLoaded = true,
            )
            val removed = expect.getValue("removed").jsonPrimitive.content.toBoolean()
            assertEquals("$id: removed", removed, state.issue?.removedConnectionName != null)
            if (removed) {
                assertEquals("$id: connection name", expect.str("connectionName"), state.issue?.removedConnectionName)
                assertEquals(ChatConversationIssueKind.ModelMissing, state.issue?.kind)
                assertTrue("$id: send unavailable", state.isSendBlocked)
                assertFalse("$id: input box still editable", state.isReadOnly)
                assertNull("$id: no silent replacement", state.model)
            } else if (expect.containsKey("conversationModelId")) {
                assertEquals("$id: conversation model", expect.str("conversationModelId"), state.model?.id)
            } else if (provider.kind == ProviderKind.Relay) {
                assertEquals("$id: empty conversation model uses fallback", expect.str("fallbackModelId"), state.model?.id)
            }
            expect.str("conversationModelId")?.let {
                assertEquals("$id: conversation model not rewritten", it, conversation.modelID)
            }
        }
    }

    @Test fun RD1_SELECT_last_used_on_connection() = runSelectCase("last_used_on_connection")
    @Test fun RD1_SELECT_legacy_default_ignored() = runSelectCase("legacy_default_ignored")
    @Test fun RD1_SELECT_last_used_model_gone() = runSelectCase("last_used_model_gone")
    @Test fun RD1_SELECT_no_enabled_models_catalog_only() = runSelectCase("no_enabled_models_catalog_only")
    @Test fun RD1_SELECT_nothing_to_verify() = runSelectCase("nothing_to_verify")
    @Test fun RD1_SELECT_conversation_model_present() = runSelectCase("conversation_model_present")
    @Test fun RD1_SELECT_conversation_model_removed() = runSelectCase("conversation_model_removed")
    @Test fun RD1_SELECT_local_engine_model_removed() = runSelectCase("local_engine_model_removed")
    @Test fun RD1_SELECT_empty_conversation_model_uses_fallback() = runSelectCase("empty_conversation_model_uses_fallback")
    @Test fun RD1_SELECT_official_provider_not_in_scope() = runSelectCase("official_provider_not_in_scope")

    @Test
    fun `RD1_SELECT every fixture case has a matching test`() {
        val covered = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("RD1_SELECT_") }
            .map { it.removePrefix("RD1_SELECT_") }.toSet()
        val ids = fixture.getValue("cases").jsonArray.map { it.jsonObject.str("id")!! }.toSet()
        assertEquals(ids, covered)
    }

    // ── Conversation model removed: banner and send entry ──

    private val relay = Provider(
        id = "relay-a",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        customName = "My Relay",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        models = listOf(AIModel(id = "gpt-5.4", name = "gpt-5.4", isDefault = true), AIModel(id = "claude-4-haiku", name = "claude-4-haiku")),
    )

    private fun removedConversation() = Conversation(
        id = "conv-removed",
        title = "t",
        providerID = relay.id,
        providerKind = ProviderKind.Relay,
        modelID = "retired-model",
        messages = listOf(
            ChatMessage(id = "u1", role = ChatRole.User, text = "hi", providerKind = ProviderKind.Relay, providerName = "My Relay", modelName = "retired-model", state = ChatMessageState.Delivered),
            ChatMessage(id = "a1", role = ChatRole.Assistant, text = "partial", providerKind = ProviderKind.Relay, providerName = "My Relay", modelName = "retired-model", state = ChatMessageState.Failed),
        ),
    )

    @Test
    fun `RD1_BANNER_01 removed conversation shows the banner, blocks sending and every send entry makes zero requests`() = runTest {
        val conversation = removedConversation()
        val state = resolveChatConversationState(conversation, listOf(relay), relay.id, conversation.modelID, providersLoaded = true)
        val issue = requireNotNull(state.issue)
        val content = requireNotNull(relayModelRemovedBannerContent(issue))
        assertEquals(R.string.chat_model_removed_banner, content.messageRes)
        assertEquals("My Relay", content.connectionName)
        assertEquals(R.string.chat_model_removed_choose, content.actionRes)
        assertTrue("banner is above the input area (inside ChatComposerHost)", issue.rendersAboveComposer)
        assertFalse("input box still editable", state.isReadOnly)
        assertTrue("send unavailable", state.isSendBlocked)

        val providerRepository = mockk<ProviderRepository>()
        coEvery { providerRepository.getById(relay.id) } returns relay
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        val appPreferences = mockk<AppPreferencesRepository>(relaxed = true)
        coEvery { appPreferences.hasAcceptedProviderDisclosure(any()) } returns true
        val launches = mutableListOf<String>()
        val launcher = ChatSendLauncher { _, _, modelId, _, _, _, _, _, _, _, _ -> launches += modelId }
        var settled = false

        val send = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferences,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conversation },
            currentConversationId = { conversation.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = { settled = true },
            launchSend = launcher,
        )
        send.sendMessage("again", null, relay.id, conversation.modelID)
        advanceUntilIdle()

        val retry = ChatRetryCoordinator(
            viewModelScope = this,
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            currentConversation = { conversation },
            activeProviderId = { relay.id },
            activeModelId = { conversation.modelID },
            providers = { listOf(relay) },
            requestPin = {},
            launchSend = launcher,
        )
        retry.retryMessage("a1")
        retry.regenerateMessage("a1")
        retry.continueMessage("a1")
        advanceUntilIdle()

        assertTrue("zero requests", launches.isEmpty())
        assertTrue("send guard reset", settled)
        coVerify(exactly = 0) { conversationRepository.deleteMessagesAfter(any(), any()) }
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
        assertEquals("conversation model unchanged", "retired-model", conversation.modelID)
    }

    @Test
    fun `RD1_BANNER_02 picking a model through the production selection path updates the conversation and clears the banner`() = runTest {
        val conversation = removedConversation()
        val providerRepository = mockk<ProviderRepository>()
        coEvery { providerRepository.getById(relay.id) } returns relay
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        var activeProvider: String? = relay.id
        var activeModel: String? = conversation.modelID
        assertNotNull(resolveChatConversationState(conversation, listOf(relay), activeProvider, activeModel, providersLoaded = true).issue)

        val selection = ChatModelSelectionCoordinator(
            viewModelScope = this,
            appPreferencesRepository = mockk(relaxed = true),
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            providers = { listOf(relay) },
            activeProviderId = { activeProvider },
            activeModelId = { activeModel },
            activeConversationId = { conversation.id },
        )
        selection.selectModel(relay.id, "claude-4-haiku") { p, m ->
            activeProvider = p
            activeModel = m
        }
        advanceUntilIdle()

        coVerify { conversationRepository.updateProviderAndModel(conversation.id, relay.id, ProviderKind.Relay, "claude-4-haiku", any()) }
        val after = resolveChatConversationState(conversation.copy(modelID = "claude-4-haiku"), listOf(relay), activeProvider, activeModel, providersLoaded = true)
        assertNull("banner disappears", after.issue)
        assertEquals("claude-4-haiku", after.model?.id)
    }

    @Test
    fun `RD1_NEWCHAT_01 starting a chat from a relay connection uses the first enabled model when lastUsed points elsewhere`() {
        val official = Provider(
            id = "openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-5.6-sol", name = "gpt-5.6-sol")),
        )
        val legacy = relay.copy(models = listOf(AIModel(id = "gpt-5.4", name = "gpt-5.4"), AIModel(id = "claude-4-haiku", name = "claude-4-haiku", isDefault = true)))
        val lastUsed = LastUsedModelRef(providerID = official.id, modelID = "gpt-5.6-sol")
        assertEquals("gpt-5.4", RelayModelFallback.fallbackModel(legacy, lastUsed)?.id)
        val state = resolveChatConversationState(
            conversation = null,
            providers = listOf(official, legacy),
            activeProviderId = legacy.id,
            activeModelId = null,
            providersLoaded = true,
        )
        assertEquals("gpt-5.4", state.model?.id)
        assertEquals("gpt-5.4", ProviderSelectionSnapshot.newChatFallbackModel(legacy)?.id)
        assertEquals("gpt-5.4", legacy.defaultModel?.id)
    }

    // ── Repository writes and re-detection ──

    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

    private inner class Harness(initial: Provider?, catalogIDs: List<String>) {
        val pings: MutableList<String> = Collections.synchronizedList(mutableListOf())
        var stored: ai.oriveo.community.core.data.entity.ProviderEntity? =
            initial?.let { with(ProviderMapper) { it.toEntity(accountID) } }
        private val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get) {
                val body = """{"object":"list","data":[${catalogIDs.joinToString(",") { """{"id":"$it","object":"model"}""" }}]}"""
                return@MockEngine respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
            }
            val model = Json.parseToJsonElement((request.body as TextContent).text).jsonObject.getValue("model").jsonPrimitive.content
            pings += model
            respond(
                """{"id":"x","choices":[{"message":{"content":"p"}}]}""",
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } returns "sk-test"
            ProviderRepository(
                dao = dao,
                secureKeyStore = keys,
                openRouterService = mockk(relaxed = true),
                openAIService = mockk(relaxed = true),
                deepSeekService = mockk(relaxed = true),
                grokService = mockk(relaxed = true),
                anthropicService = mockk(relaxed = true),
                geminiService = mockk(relaxed = true),
                groqService = mockk(relaxed = true),
                togetherService = mockk(relaxed = true),
                fireworksService = mockk(relaxed = true),
                miniMaxService = mockk(relaxed = true),
                zhipuService = mockk(relaxed = true),
                qwenService = mockk(relaxed = true),
                moonshotService = mockk(relaxed = true),
                mistralService = mockk(relaxed = true),
                siliconFlowService = mockk(relaxed = true),
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain("sk-test") }
    }

    @Test
    fun `RD1_WRITE_01 relay registration persists no default flag and no requested model id`() = runBlocking {
        val harness = Harness(initial = null, catalogIDs = emptyList())
        val result = harness.repository.registerRelayProvider(
            apiKey = "sk-test",
            baseUrl = "https://relay.example.com/v1",
            customName = "My Relay",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, modelID = "model-second"),
            catalogModelIDs = listOf("model-first", "model-second"),
            preferredModelID = "model-second",
        )
        val persisted = harness.current()
        for (provider in listOf(result, persisted)) {
            assertTrue("no default marker", (provider.models + provider.catalogModels).none { it.isDefault })
            assertTrue("relayRequested.modelID is empty", provider.relayRequested?.modelID.isNullOrEmpty())
            assertEquals("selected model is enabled", listOf("model-second"), provider.models.map { it.id })
        }
    }

    @Test
    fun `RD1_REDETECT_01 redetect probes every enabled model whose protocol is empty after clearing reachable`() = runBlocking {
        val initial = Provider(
            id = "33333333-3333-4333-8333-333333333333",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            baseUrlText = "https://relay.example.com/v1",
            relayKind = RelayKind.OpenAICompatible,
            // Connection transport auto: a connection whose transport the user chose is not re-probed (see RelayProbeOrchestrationTest).
            relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto),
            models = listOf(
                AIModel(id = "model-a", name = "model-a", relayTransport = RelayTransport.AnthropicMessages, relayTransportSource = RelayTransportSource.User),
                AIModel(id = "model-b", name = "model-b", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Reachable),
                AIModel(id = "model-c", name = "model-c"),
            ),
            catalogModels = listOf("model-a", "model-b", "model-c").map { AIModel(id = it, name = it) },
        )
        val harness = Harness(initial = initial, catalogIDs = listOf("model-a", "model-b", "model-c"))

        harness.repository.redetectRelayModels(initial.id)

        assertEquals(listOf("model-b", "model-c"), harness.pings.toList())
        val stored = harness.current()
        assertEquals(RelayTransportSource.User, stored.models.single { it.id == "model-a" }.relayTransportSource)
        assertTrue(stored.models.none { it.isDefault })
    }
}
