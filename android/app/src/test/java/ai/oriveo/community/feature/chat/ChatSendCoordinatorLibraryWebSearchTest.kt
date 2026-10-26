package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.StreamRequest
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.After
import org.junit.Before
import java.io.File

/**
 * Outbound request options built by [ChatSendCoordinator.launchSend]: web search, reasoning, typed
 * preferences, local custom fragments and the evidence identity all reach the stream request.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCoordinatorLibraryWebSearchTest {
    @Before
    fun setUpRuntimeIdentity() {
        ModelControlRejectionCache.clearForTesting()
        val registry = Json.parseToJsonElement(workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText()).jsonObject
        val customControl = "fixture.openai.web.options"
        val generationControl = "fixture.openai.generation.temperature"
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("runtime-r7"),
            "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
            "controlDefinitions" to JsonObject(registry["controlDefinitions"]!!.jsonObject + mapOf(
                customControl to buildJsonObject {
                    put("id", customControl)
                    put("owner", "web")
                    put("kind", "boolean")
                    put("labelKey", "fixture.web")
                    put("descriptionKey", "fixture.web.desc")
                    put("targetPointer", "/web_search_options")
                    put("defaultBehavior", "provider_default")
                    put("riskTier", "privacy_impacting")
                    put("sourceRefs", JsonArray(listOf(JsonPrimitive("openai.web_search"))))
                },
                generationControl to buildJsonObject {
                    put("id", generationControl)
                    put("owner", "generation")
                    put("kind", "number_range")
                    put("min", 0)
                    put("max", 2)
                    put("labelKey", "fixture.generation.temperature")
                    put("descriptionKey", "fixture.generation.temperature.desc")
                    put("targetPointer", "/temperature")
                    put("defaultBehavior", "provider_default")
                    put("riskTier", "cost_impacting")
                    put("sourceRefs", JsonArray(listOf(JsonPrimitive("openai.reasoning"))))
                },
            )),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put("openAI", buildJsonObject {
                    put("resolveMap", buildJsonObject { put("gpt-4.1", "gpt-4.1") })
                    put("models", buildJsonObject {
                        put("gpt-4.1", buildJsonObject {
                            put("canonicalModelId", "gpt-4.1")
                            put("transport", "openai_responses")
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", "openai.responses.web.v1")
                                    put("customControlRefs", JsonArray(listOf(JsonPrimitive(customControl))))
                                })
                                put("generation", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", "openai.responses.generation.v1")
                                    put("customControlRefs", JsonArray(listOf(JsonPrimitive(generationControl))))
                                })
                            })
                        })
                    })
                })
            })
        }.toString())
    }

    @After
    fun tearDownRuntimeIdentity() {
        MetadataTestFixtures.clear()
        ModelControlRejectionCache.clearForTesting()
    }

    /** A voice send hands delivery = VOICE to the context request; a typed send leaves it null. */
    @Test
    fun `voice send carries delivery into the chat context and typed send does not`() = runTest {
        val voice = launchAndCapture(
            scope = this,
            delivery = ai.oriveo.community.core.context.ContextDelivery.VOICE,
        )
        assertEquals(ai.oriveo.community.core.context.ContextDelivery.VOICE, voice.requestOptions.chatContext?.delivery)

        val typed = launchAndCapture(scope = this)
        assertEquals(null, typed.requestOptions.chatContext?.delivery)
        assertEquals(voice.requestOptions.chatContext?.copy(delivery = null), typed.requestOptions.chatContext)
    }

    /** A new conversation without an explicit typed preference must stay Off; the old evidence gate must not fill in Automatic. */
    @Test
    fun `a plain send without a typed preference keeps web search off`() = runTest {
        val request = launchAndCapture(
            scope = this,
        )

        assertFalse(request.webSearchEnabled)
        assertEquals(CapabilityWebPreference.Off, request.requestOptions.capabilityPreferences?.web)
    }

    @Test
    fun `production send coordinator consumes the exact preference identity`() = runTest {
        var payload: String? = null
        val store = CapabilityPreferenceStore({ payload }, { payload = it })
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "deep"),
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
        )

        val request = launchAndCapture(
            scope = this,
            capabilityPreferenceStore = store,
        )

        assertTrue(request.webSearchEnabled)
        assertEquals(CapabilityWebPreference.Force, request.requestOptions.capabilityPreferences?.web)
        assertEquals(ReasoningMode.Deep, request.reasoningMode)
        assertEquals(identity, request.requestOptions.modelControlRuntimeIdentity)
    }

    @Test
    fun `custom and official recipe rejection caches never poison each other`() = runTest {
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!
        var cachePayload: String? = null
        ModelControlRejectionCache.configurePersistenceForTesting(
            read = { cachePayload }, write = { cachePayload = it },
        )
        var preferencePayload: String? = null
        val preferenceStore = CapabilityPreferenceStore({ preferencePayload }, { preferencePayload = it })
        preferenceStore.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
        )
        var customPayload: String? = null
        val rejectedCustomStore = LocalCapabilityCustomFragmentStore({ customPayload }, { customPayload = it })
        rejectedCustomStore.setFragment(
            "{\"web_search_options\":{\"enabled\":true}}",
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
            LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        ModelControlRejectionCache.record(identity, "web", "custom", "/web_search_options")
        ModelControlRejectionCache.simulateColdStartForTesting()
        val officialRequest = launchAndCapture(
            this,
            capabilityPreferenceStore = preferenceStore,
            localCustomFragmentStore = rejectedCustomStore,
        )
        assertFalse("normal send keeps the rejected custom owner fully dormant", officialRequest.webSearchEnabled)
        assertFalse("rejected custom blob is dormant on this identity", "web" in officialRequest.requestOptions.localCustomFragments)
        assertEquals(setOf("web"), officialRequest.requestOptions.dormantCapabilityOwners)
        assertEquals(
            "{\"web_search_options\":{\"enabled\":true}}",
            rejectedCustomStore.fragment(
                provider.id, identity.canonicalModelId, conversation.id, identity.storageIdentity,
                LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
            ),
        )

        rejectedCustomStore.setFragment(
            "{\"web_search_options\":{\"enabled\":false}}",
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
            LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        val reconfirmedRequest = launchAndCapture(
            this,
            capabilityPreferenceStore = preferenceStore,
            localCustomFragmentStore = rejectedCustomStore,
        )
        assertEquals(
            "{\"web_search_options\":{\"enabled\":false}}",
            reconfirmedRequest.requestOptions.localCustomFragments["web"],
        )
        assertTrue("explicitly edited custom blob clears only its custom rejection", reconfirmedRequest.requestOptions.dormantCapabilityOwners.isEmpty())

        // Switching away from Custom deletes only the raw blob. The retained custom-source cache
        // must not suppress a subsequently selected official typed recipe for the same owner.
        rejectedCustomStore.setFragment(
            null,
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
            LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        ModelControlRejectionCache.record(identity, "web", "custom", "/web_search_options")
        val switchedToOfficial = launchAndCapture(
            this,
            capabilityPreferenceStore = preferenceStore,
            localCustomFragmentStore = rejectedCustomStore,
        )
        assertTrue("custom-source cache cannot poison the official recipe after source switch", switchedToOfficial.webSearchEnabled)
        assertTrue(switchedToOfficial.requestOptions.dormantCapabilityOwners.isEmpty())

        ModelControlRejectionCache.clearForTesting()
        ModelControlRejectionCache.record(
            identity,
            "web",
            "provider_recipe",
            "/web_search_options",
            recipeRef = "openai.responses.web.v1",
        )
        customPayload = null
        val customStore = LocalCapabilityCustomFragmentStore({ customPayload }, { customPayload = it })
        customStore.setFragment(
            "{\"web_search_options\":{\"enabled\":false}}",
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
            LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        val customRequest = launchAndCapture(
            this,
            localCustomFragmentStore = customStore,
        )
        assertEquals(
            "recipe rejection must not suppress the actual custom fragment",
            "{\"web_search_options\":{\"enabled\":false}}",
            customRequest.requestOptions.localCustomFragments["web"],
        )
    }

    @Test
    fun `normal recipe send is whole-owner dormant while an exact CTA latch omits one pointer`() = runTest {
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!
        var preferencePayload: String? = null
        val preferenceStore = CapabilityPreferenceStore({ preferencePayload }, { preferencePayload = it })
        preferenceStore.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
        )
        val recipeRef = "openai.responses.web.v1"
        val pointer = "/web_search_options"
        ModelControlRejectionCache.record(
            identity,
            "web",
            "provider_recipe",
            pointer,
            recipeRef = recipeRef,
        )

        val normal = launchAndCapture(
            this,
            capabilityPreferenceStore = preferenceStore,
        )
        assertFalse(normal.webSearchEnabled)
        assertEquals(setOf("web"), normal.requestOptions.dormantCapabilityOwners)
        assertTrue(normal.requestOptions.rejectedRecipeSettings.isEmpty())

        fun encode(value: String) = java.util.Base64.getUrlEncoder().withoutPadding()
            .encodeToString(value.toByteArray(Charsets.UTF_8))
        val latch = "omit_capability_setting_once:provider_recipe:web:${encode(recipeRef)}:${encode(pointer)}"
        val explicit = launchAndCapture(
            this,
            capabilityPreferenceStore = preferenceStore,
            appendToAssistant = ChatMessage(
                id = "failed-recipe",
                role = ChatRole.Assistant,
                text = "",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "fixture-r3",
                state = ChatMessageState.Failed,
                customRetryWithoutFieldsCode = latch,
            ),
        )
        assertTrue(explicit.webSearchEnabled)
        assertTrue(explicit.requestOptions.dormantCapabilityOwners.isEmpty())
        assertEquals(
            mapOf("web" to mapOf(recipeRef to setOf(pointer))),
            explicit.requestOptions.rejectedRecipeSettings,
        )
    }

    /** "Resend without this parameter": the one-shot omit marker of a failed message reaches the request options through the production launchSend; a plain send carries none. */
    @Test
    fun `omit parameter once marker reaches the request options through launchSend`() = runTest {
        val plain = launchAndCapture(this)
        assertTrue(plain.requestOptions.omitParametersOnce.isEmpty())

        val marker = parameterResendMarker("input_parameter_rejected:temperature")
        val resend = launchAndCapture(
            this,
            appendToAssistant = ChatMessage(
                id = "failed-param",
                role = ChatRole.Assistant,
                text = "",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "GPT-4.1",
                state = ChatMessageState.Failed,
                customRetryWithoutFieldsCode = marker,
            ),
        )
        assertEquals(setOf("temperature"), resend.requestOptions.omitParametersOnce)
    }

    // A legacy generation custom field is migrated into the additional request body and goes out through the new path.
    @Test
    fun `legacy generation fragment reaches the wire as the additional body`() = runTest {
        var localPayload: String? = null
        val store = LocalCapabilityCustomFragmentStore({ localPayload }, { localPayload = it })
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!.storageIdentity
        store.setFragment("{\"temperature\":0.2}", provider.id, "gpt-4.1", conversation.id, identity)

        val request = launchAndCapture(
            scope = this,
            localCustomFragmentStore = store,
        )

        assertEquals(null, request.requestOptions.localCustomFragment)
        assertEquals("{\"temperature\":0.2}", request.requestOptions.additionalRequestBody)
    }

    /**
     * The global developer switch is retired: the only condition for going out is that this owner's
     * custom fragment is enabled. A disabled draft stays on disk (the user can still see what they
     * wrote) but not one byte goes out; letting drafts suddenly go out once the switch is gone would
     * decide something for the user that they never decided.
     */
    @Test
    fun `a disabled draft keeps its raw json but never reaches the wire`() = runTest {
        var localPayload: String? = null
        val store = LocalCapabilityCustomFragmentStore({ localPayload }, { localPayload = it })
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!.storageIdentity
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = false, rawJSON = "{\"temperature\":0.2}"),
            provider.id,
            "gpt-4.1",
            conversation.id,
            identity,
        )

        val request = launchAndCapture(this, localCustomFragmentStore = store)

        assertEquals(null, request.requestOptions.localCustomFragment)
        assertEquals(null, request.requestOptions.additionalRequestBody)
        assertEquals(
            "the draft must be kept as written; disabling is not deleting",
            "{\"temperature\":0.2}",
            store.additionalBody(provider.id, "gpt-4.1", conversation.id).rawJSON,
        )
    }

    // Coexists with panel parameters: writing an additional body does not clear the panel parameters, and on a name clash the additional body wins when merged.
    @Test
    fun `additional body coexists with typed generation parameters`() = runTest {
        var localPayload: String? = null
        val store = LocalCapabilityCustomFragmentStore({ localPayload }, { localPayload = it })
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!.storageIdentity
        store.setFragment("{\"temperature\":0.2}", provider.id, "gpt-4.1", conversation.id, identity)
        var settingsPayload: String? = null
        val settings = GenerationParameterSettingsStore({ settingsPayload }, { settingsPayload = it })
        settings.setModelDefaults(GenerationParameterOverrides(mapOf(
            "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
        )), provider.id, "gpt-4.1")

        val request = launchAndCapture(this, settings = settings, localCustomFragmentStore = store)

        assertEquals("{\"temperature\":0.2}", request.requestOptions.additionalRequestBody)
        assertEquals(JsonPrimitive(0.4), request.requestOptions.generationParameters?.values?.get("temperature")?.value)

        val retry = launchAndCapture(
            this, settings = settings, localCustomFragmentStore = store,
            appendToAssistant = ChatMessage(
                id = "assistant-retry",
                role = ChatRole.Assistant,
                text = "",
                providerKind = ProviderKind.OpenAI,
                providerName = "OpenAI",
                modelName = "gpt-4.1",
                state = ChatMessageState.Failed,
                customRetryWithoutFieldsCode = "omit_local_fields_once:additional_body",
            ),
        )
        assertEquals("a one-shot retry drops only the additional body", null, retry.requestOptions.additionalRequestBody)
        assertEquals(JsonPrimitive(0.4), retry.requestOptions.generationParameters?.values?.get("temperature")?.value)
        assertEquals("the stored content is untouched", "{\"temperature\":0.2}", store.outboundAdditionalBody(provider.id, "gpt-4.1", conversation.id))
    }

    @Test
    fun `relay Auto does not put an unknown generation parameter in a request without final scope`() = runTest {
        var settingsPayload: String? = null
        val settings = GenerationParameterSettingsStore(
            readPayload = { settingsPayload },
            writePayload = { settingsPayload = it },
        )
        settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = "relay-auto",
            modelID = "relay-model",
        )
        val relay = Provider(
            id = "relay-auto",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            models = listOf(AIModel(id = "relay-model", name = "Relay Model")),
            relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto),
        )
        val request = launchAndCapture(
            scope = this,
            provider = relay,
            modelId = "relay-model",
            settings = settings,
        )

        assertEquals("openai_chat_completions", request.requestOptions.activeModel?.generationProfile?.template)
        val body = Json.parseToJsonElement(buildOpenAIChatBody(
            modelID = request.modelID,
            messages = emptyList(),
            stream = true,
            reasoningMode = request.reasoningMode,
            requestOptions = request.requestOptions,
        )).jsonObject
        // This low-level builder has no final URL / actual transport, so it cannot build a full Relay scope.
        // The Relay kind is not an unknown pass-through: an explicit unverified exception can only be
        // decided by the core final writer after projecting the full production identity.
        assertFalse(body.containsKey("temperature"))
    }

    @Test
    fun `all providers carry the production evidence identity`() = runTest {
        val identity = CapabilityEvidenceIdentity(
            partitionId = "account-1",
            connectionInstanceId = provider.id,
            connectionGeneration = "connection-1",
            credentialEpoch = "credential-1",
            providerKind = "openai",
            authMode = ProviderAuthMode.ApiKey.rawValue,
            canonicalModelId = "gpt-4.1",
            metadataRevision = "etag-1",
            generationRevision = "generation-1",
        )

        val request = launchAndCapture(
            scope = this,
            capabilityIdentity = identity,
        )

        assertEquals(identity, request.requestOptions.capabilityEvidenceIdentity)
        assertEquals("gpt-4.1", request.requestOptions.activeModel?.id)
    }

    @Test
    fun `send captures account A partition before suspended identity producer observes account B`() = runTest {
        var partition = "account-a"
        val observedPartitions = mutableListOf<String>()
        val identityReady = CompletableDeferred<CapabilityEvidenceIdentity?>()
        val identityA = CapabilityEvidenceIdentity(
            partitionId = "account-a",
            connectionInstanceId = provider.id,
            connectionGeneration = "connection-a",
            credentialEpoch = "credential-a",
            providerKind = ProviderKind.OpenAI.rawValue,
            authMode = ProviderAuthMode.ApiKey.rawValue,
        )
        val streamingManager = mockk<ChatStreamingManager>(relaxed = true)
        val captured = slot<StreamRequest>()
        every { streamingManager.startStream(capture(captured)) } returns Unit
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = this,
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(
                readPayload = { null },
                writePayload = {},
            ),
            capabilityEvidencePartition = { partition },
            capabilityEvidenceIdentity = { _, _, capturedPartition ->
                observedPartitions += capturedPartition
                identityReady.await()
            },
        )

        coordinator.launchSend(
            conversation = conversation,
            provider = provider,
            modelId = "gpt-4.1",
            text = "Question",
            memoryItems = emptyList(),
            existingMessages = emptyList(),
        )
        partition = "account-b"
        identityReady.complete(identityA)
        advanceUntilIdle()

        assertEquals(listOf("account-a"), observedPartitions)
        assertEquals(identityA, captured.captured.requestOptions.capabilityEvidenceIdentity)
    }

    /**
     * The web search / reasoning values the pre-send check gets are the very two values the same send
     * hands to the streaming manager: both read the same resolver instead of each deriving its own.
     */
    @Test
    fun `the preflight options are the very values the send hands to the stream`() = runTest {
        var payload: String? = null
        val store = CapabilityPreferenceStore({ payload }, { payload = it })
        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, provider.models.single())!!
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "deep"),
            provider.id,
            identity.canonicalModelId,
            conversation.id,
            identity.storageIdentity,
        )
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            applicationScope = this,
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            capabilityPreferenceStore = store,
        )
        val sent = launchAndCapture(
            scope = this,
            capabilityPreferenceStore = store,
        )
        val options = coordinator.attachmentSendOptions(
            provider = provider,
            modelId = "gpt-4.1",
            conversationId = conversation.id,
            skillId = conversation.skillId,
            mcpEnabledServerCount = 0,
        )
        assertEquals(sent.webSearchEnabled, options.webSearchEnabled)
        assertEquals(sent.reasoningMode, options.reasoningMode)
        assertFalse(options.toolLoopPossible)
        // The stored Force preference turns web search on; two enabled MCP servers make a tool loop possible.
        assertTrue(
            coordinator.attachmentSendOptions(provider, "gpt-4.1", conversation.id, null, 0).webSearchEnabled,
        )
        assertTrue(
            coordinator.attachmentSendOptions(provider, "gpt-4.1", conversation.id, null, 2).toolLoopPossible,
        )
    }

    private fun launchAndCapture(
        scope: kotlinx.coroutines.test.TestScope,
        provider: Provider = this.provider,
        modelId: String = "gpt-4.1",
        settings: GenerationParameterSettingsStore = GenerationParameterSettingsStore(
            readPayload = { null },
            writePayload = {},
        ),
        capabilityIdentity: CapabilityEvidenceIdentity? = null,
        localCustomFragmentStore: LocalCapabilityCustomFragmentStore? = null,
        capabilityPreferenceStore: CapabilityPreferenceStore? = null,
        appendToAssistant: ChatMessage? = null,
        delivery: ai.oriveo.community.core.context.ContextDelivery? = null,
        text: String = "Question",
    ): StreamRequest {
        val streamingManager = mockk<ChatStreamingManager>(relaxed = true)
        val captured = slot<StreamRequest>()
        every { streamingManager.startStream(capture(captured)) } returns Unit
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = streamingManager,
            applicationScope = scope,
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = settings,
            localCustomFragmentStore = localCustomFragmentStore,
            capabilityPreferenceStore = capabilityPreferenceStore,
            capabilityEvidencePartition = { "account-1" },
            capabilityEvidenceIdentity = { _, _, _ -> capabilityIdentity },
        )

        coordinator.launchSend(
            conversation = conversation.copy(
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = modelId,
            ),
            provider = provider,
            modelId = modelId,
            text = text,
            memoryItems = emptyList(),
            existingMessages = emptyList(),
            appendToAssistant = appendToAssistant,
            delivery = delivery,
        )
        scope.advanceUntilIdle()

        return captured.captured
    }

    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "local-key",
        models = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1")),
    )

    private val conversation = Conversation(
        id = "conversation-1",
        title = "Web search",
        providerID = "openai-1",
        providerKind = ProviderKind.OpenAI,
        modelID = "gpt-4.1",
    )

    private fun workspaceFile(relativePath: String): File = generateSequence(
        File(System.getProperty("user.dir") ?: ".").absoluteFile,
    ) { it.parentFile }
        .map { File(it, relativePath) }
        .firstOrNull { it.isFile }
        ?: error("workspace file missing: $relativePath")
}
