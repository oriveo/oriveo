package ai.oriveo.community.core.capability.capabilitymatrix

import ai.oriveo.community.core.attachments.NativeFileFallback
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.feature.chat.ChatCapabilityOutboundDecision
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.feature.chat.modelcontrols.ChatTemplateThinking
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.relay.RelayWebFragments
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Capability matrix, relay form (CAP-RELAY-*).
 * Request bodies are all sent by production `ChatRepository.sendMessage` -> `RelayService`; MockEngine only captures the bytes;
 * the web segment goes through the production local store (in-memory backend) and production effective-segment resolution.
 */
class CapabilityMatrixRelayTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val fixture by lazy { readJson("shared/test-fixtures/relay/web-fragment.v1.json") }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        cacheFamilies(null)
        openClients.forEach { it.close() }
        openClients.clear()
    }

    // ── WEB ──

    @Test
    fun CAP_RELAY_WEB_01_saved_fragment_is_merged_into_every_chat_request_of_that_protocol() = runTest {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val responses = relay(RelayTransport.OpenAIResponses)
        val responsesTemplate = template("openai_responses")
        assertTrue(store.save(responses.id, RelayTransport.OpenAIResponses, responsesTemplate.toString()) is RelayWebFragments.Validation.Ok)

        val body = send(responses, store, webSearchEnabled = false)

        val tools = body.getValue("tools").jsonArray
        assertEquals("Segment tool is appended after the builder tools: $body", responsesTemplate.getValue("tools").jsonArray.single(), tools.last())
        assertTrue("The builder's own image_generation is still first: $body", tools.dropLast(1).any { it.toString().contains("image_generation") })

        // Chat protocol: non-tools keys in the segment are added to the request body per mergeCases, and are always sent even when the chat web preference is off.
        val chat = relay(RelayTransport.OpenAIChatCompletions)
        val plugins = mergeCase("chat_plugins_are_added").getValue("fragment").jsonObject
        assertTrue(store.save(chat.id, RelayTransport.OpenAIChatCompletions, plugins.toString()) is RelayWebFragments.Validation.Ok)
        val chatBody = send(chat, store, webSearchEnabled = false)
        assertEquals(chatBody.toString(), plugins.getValue("plugins"), chatBody["plugins"])
    }

    @Test
    fun CAP_RELAY_WEB_02_no_fragment_and_no_legacy_field_sends_no_web_fields() = runTest {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        listOf(RelayTransport.OpenAIResponses, RelayTransport.GeminiGenerateContent, RelayTransport.OpenAIChatCompletions).forEach { transport ->
            // Chat web preference on and the model inheriting the official web profile still carry no web field.
            val provider = relay(
                transport,
                model = AIModel(
                    id = "gpt-5.5",
                    name = "gpt-5.5",
                    capabilities = listOf(ModelCapability.Text, ModelCapability.Web),
                    webSearchProfile = "oai_responses_web",
                ),
            )
            val body = send(provider, store, webSearchEnabled = true).toString()
            assertFalse("$transport must not carry web_search: $body", body.contains("web_search"))
            assertFalse("$transport must not carry googleSearch: $body", body.contains("googleSearch") || body.contains("google_search"))
            assertFalse("$transport must not carry plugins: $body", body.contains("\"plugins\""))
        }
    }

    @Test
    fun CAP_RELAY_WEB_03_legacy_flag_maps_to_the_template_without_rewriting_the_connection() = runTest {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val legacy = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses, hasWebSearch = true)
        val provider = relay(RelayTransport.OpenAIResponses, requested = legacy)

        val body = send(provider, store, webSearchEnabled = false)

        assertEquals(
            "Responses segment mapped from the legacy connection = template: $body",
            template("openai_responses").getValue("tools").jsonArray.single(),
            body.getValue("tools").jsonArray.last(),
        )
        assertEquals("Connection config in storage is not rewritten", legacy, provider.relayRequested)
        assertEquals("Mapping is not written back to local storage", emptyMap<String, JsonObject>(), store.stored(provider.id))
    }

    // ── REASON ──

    @Test
    fun CAP_RELAY_REASON_01_model_facts_tiers_reach_the_wire_and_max_sends_the_gemini_max_budget() = runTest {
        MetadataTestFixtures.applyRaw(modelFactsMetadata("gemini/gemini-2.5-pro" to listOf("low", "medium", "high", "xhigh")))
        val model = AIModel(id = "gemini-2.5-pro", name = "Gemini 2.5 Pro")
        val provider = relay(RelayTransport.GeminiGenerateContent, model = model)
        cacheFamilies(mapOf("gemini-2.5-pro" to "google"))

        // The panel and outbound read the same ruling: auto set = "auto" + model-facts tiers.
        val controls = ChatModelCapabilityResolver().modelControls(provider, model, finalTransport = null)
        assertEquals(listOf("automatic", "low", "balanced", "deep", "max"), controls.reasoningIntents)
        // No tier ever selected: still no thinking field is sent, existing request bodies unchanged.
        val untouched = ChatCapabilityOutboundDecision.resolve(CapabilityPreferenceValues(), controls)
        assertEquals(ReasoningMode.Automatic, untouched.reasoningMode)
        val defaultBody = send(
            provider,
            RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()),
            webSearchEnabled = false,
            reasoningMode = untouched.reasoningMode,
            identity = evidenceIdentity(provider),
        )
        assertFalse(defaultBody.toString(), defaultBody.toString().contains("thinking"))
        val decision = ChatCapabilityOutboundDecision.resolve(
            CapabilityPreferenceValues(reasoningIntent = "max"),
            controls,
        )
        assertEquals(ReasoningMode.Max, decision.reasoningMode)

        // Production chat send carries the connection identity (injected by ChatSendCoordinator), so the outbound evidence gate accepts this explicit tier.
        val body = send(
            provider,
            RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()),
            webSearchEnabled = false,
            reasoningMode = decision.reasoningMode,
            identity = evidenceIdentity(provider),
        )

        val budget = body.getValue("generationConfig").jsonObject.getValue("thinkingConfig").jsonObject.getValue("thinkingBudget")
        assertEquals(body.toString(), 24576, budget.jsonPrimitive.int)
    }

    @Test
    fun CAP_RELAY_REASON_02_chat_without_model_facts_keeps_the_template_switch_and_only_adds_enable_thinking() = runTest {
        val model = AIModel(id = "local-chat-model", name = "Local")
        val provider = relay(RelayTransport.OpenAIChatCompletions, model = model)
        val verdict = CapabilityControlResolution.resolve(provider, model, "reasoning")
        val shape = ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Reasoning,
                presentation = CapabilityControlPresentationResolver.presentation(provider, model, "reasoning"),
                availableIntents = verdict.intents,
                selectedIntent = null,
                connection = ModelOptionsPanelInput.connectionCategory(provider.kind),
                customProtocol = ModelOptionsPanelInput.customProtocol(provider, model),
                chatTemplateThinking = false,
            ),
        )
        assertEquals(
            ModelOptionCapabilityShape.Toggle(false, ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking),
            shape,
        )
        val written = ChatTemplateThinking.write(LocalCapabilityCustomFragmentStore.AdditionalBody("", sendWithRequest = false), enable = true)
            as ChatTemplateThinking.Write.Written

        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val plain = send(provider, store, webSearchEnabled = false)
        val toggled = send(provider, store, webSearchEnabled = false, additionalBody = written.body.rawJSON)

        assertEquals(
            toggled.toString(),
            true,
            toggled.getValue("chat_template_kwargs").jsonObject.getValue("enable_thinking").jsonPrimitive.boolean,
        )
        assertEquals("Other fields unchanged", plain, JsonObject(toggled - "chat_template_kwargs"))
    }

    // ── ATTACH ──

    @Test
    fun CAP_RELAY_ATTACH_01_observed_messages_model_inherits_the_pdf_whitelist() = runTest {
        MetadataTestFixtures.applyRaw(ANTHROPIC_PDF_CATALOG)
        NativeFileFallback.resetForTest()
        val bodies = mutableListOf<String>()

        relayAnthropicStream(statusClient(bodies), RelayNegativeCache(RelayNegativeCache.MemoryStore()))

        assertTrue(bodies.first(), bodies.first().contains(""""type":"document""""))
    }

    @Test
    fun CAP_RELAY_ATTACH_02_document_rejected_before_output_is_resent_as_text_once() = runTest {
        MetadataTestFixtures.applyRaw(ANTHROPIC_PDF_CATALOG)
        NativeFileFallback.resetForTest()
        val bodies = mutableListOf<String>()

        relayAnthropicStream(statusClient(bodies, 400), RelayNegativeCache(RelayNegativeCache.MemoryStore()))

        assertEquals(bodies.toString(), 2, bodies.size)
        assertTrue(bodies[0], bodies[0].contains(""""type":"document""""))
        assertFalse("Resend carries no document block: ${bodies[1]}", bodies[1].contains(""""type":"document""""))
        assertTrue(bodies[1], bodies[1].contains(PDF_TEXT))
    }

    @Test
    fun CAP_RELAY_ATTACH_03_unknown_vision_shows_the_gallery_until_an_image_rejection_is_recorded() {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = { relayRuntimeConfig(image = true) },
            negativeCache = cache,
        )
        val model = AIModel(id = "relay-model", name = "Relay Model", capabilities = listOf(ModelCapability.Text))
        val provider = relay(RelayTransport.OpenAIChatCompletions, model = model)
        val identity = evidenceIdentity(provider)

        assertTrue("Vision unknown -> gallery entry visible", resolver.supportsImage(provider, model, identity))
        cache.record(RelayNegativeCache.keyFor(provider, model)!!, RelayNegativeCache.Kind.Image)
        assertFalse("Image negative cache recorded -> hidden", resolver.supportsImage(provider, model, identity))
    }

    // ── TOOL ──

    @Test
    fun CAP_RELAY_TOOL_01_tool_call_negative_cache_keeps_tools_off_the_first_leg() {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val model = AIModel(id = "relay-model", name = "Relay Model", toolCall = true)
        val provider = relay(RelayTransport.OpenAIChatCompletions, model = model)
        val identity = CapabilityEvidenceFacade.QueryIdentity(
            partitionId = "u1",
            connectionInstanceId = provider.id,
            connectionGeneration = "generation-1",
            credentialEpoch = "credential-1",
            providerKind = ProviderKind.Relay.rawValue,
            authMode = ProviderAuthMode.ApiKey.rawValue,
            modelId = model.id,
            effectiveTransport = "openai_chat",
            endpointFingerprint = "relay-endpoint",
        )

        assertTrue(
            CapabilityEvidenceProductionAdapter.toolCallProjection(provider, model, identity, negativeCache = cache).permitsOutbound("tool_call"),
        )
        cache.record(RelayNegativeCache.keyFor(provider, model)!!, RelayNegativeCache.Kind.ToolCall)
        assertFalse(
            "First leg carries no tools",
            CapabilityEvidenceProductionAdapter.toolCallProjection(provider, model, identity, negativeCache = cache).permitsOutbound("tool_call"),
        )
    }

    // ── helpers ──

    /** Cached by-model family table (production only reads the cache and sends no request); tests put it directly into the shared lookup. */
    private fun cacheFamilies(families: Map<String, String>?) {
        ai.oriveo.community.core.data.remote.RelayModelFamilyLookup::class.java.getDeclaredField("families")
            .apply { isAccessible = true }
            .set(ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared, families)
    }

    private fun relay(
        transport: RelayTransport,
        requested: RelayRequestedConfig = RelayRequestedConfig(transport = transport),
        model: AIModel = AIModel(id = "relay-model", name = "Relay Model"),
    ) = Provider(
        id = "relay-${transport.value}",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        apiKey = "relay-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = requested,
        models = listOf(model),
    )

    /** One production ChatRepository send; returns the first request body sent upstream. */
    private suspend fun send(
        provider: Provider,
        store: RelayWebFragmentStore,
        webSearchEnabled: Boolean,
        reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        additionalBody: String? = null,
        identity: CapabilityEvidenceIdentity? = null,
    ): JsonObject {
        var body: String? = null
        val client = HttpClient(MockEngine { request ->
            if (body == null) body = bodyText(request.body)
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns RelayService(client, json, TransportRegistry(json))
            every { it.toolCallMemoryVerdict(any(), any()) } returns null
            every { it.currentCapabilityPartitionId() } returns "u1"
        }
        val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            relayWebFragmentStore = store,
        )
        val modelId = provider.models.first().id
        runCatching {
            repository.sendMessage(
                conversation = Conversation(id = "conversation-1", title = "Relay", providerID = provider.id, providerKind = provider.kind, modelID = modelId),
                text = "hello",
                provider = provider,
                modelID = modelId,
                existingMessages = emptyList(),
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = ChatRequestOptions(additionalRequestBody = additionalBody, capabilityEvidenceIdentity = identity),
                outputs = ConversationStreamingOutputs(streamingText = MutableStateFlow(""), streamingMessageId = MutableStateFlow(null)),
            )
        }
        return json.parseToJsonElement(requireNotNull(body) { "${provider.id} did not issue a request" }).jsonObject
    }

    private fun template(transport: String): JsonObject = fixture.getValue("templates").jsonObject.getValue(transport).jsonObject

    private fun mergeCase(caseId: String): JsonObject = fixture.getValue("mergeCases").jsonArray
        .map { it.jsonObject }
        .single { (it["caseId"] as? kotlinx.serialization.json.JsonPrimitive)?.content == caseId }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun readJson(relativePath: String): JsonObject {
        val repoRoot = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private fun modelFactsMetadata(vararg facts: Pair<String, List<String>>): String = JsonObject(
        mapOf(
            "version" to JsonPrimitive(1),
            "providers" to JsonObject(emptyMap()),
            "modelFactsRevision" to JsonPrimitive("relay-tier-fixture"),
            "modelFacts" to JsonObject(
                facts.associate { (key, efforts) ->
                    key to JsonObject(mapOf("reasoningEfforts" to JsonArray(efforts.map(::JsonPrimitive))))
                },
            ),
        ),
    ).toString()

    private fun statusClient(bodies: MutableList<String>, vararg statuses: Int): HttpClient = HttpClient(MockEngine { request ->
        bodies += bodyText(request.body)
        val status = statuses.getOrNull(bodies.size - 1) ?: 200
        if (status == 200) {
            respond(ANTHROPIC_OK, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        } else {
            respond("""{"error":{"message":"document blocks are not accepted"}}""", HttpStatusCode.fromValue(status), headersOf(HttpHeaders.ContentType, "application/json"))
        }
    }).also { openClients += it }

    /** Production send entry (RelayTransportCoordinator.sendMessageStream); a Messages model with observed protocol source carries a text PDF. */
    private suspend fun relayAnthropicStream(client: HttpClient, cache: RelayNegativeCache) {
        val model = AIModel(
            id = PDF_MODEL,
            name = PDF_MODEL,
            relayTransport = RelayTransport.AnthropicMessages,
            relayTransportSource = RelayTransportSource.Observed,
        )
        val pdf = Attachment(
            id = "text-pdf",
            kind = AttachmentKind.File,
            fileName = "report.pdf",
            mimeType = "application/pdf",
            base64Data = Base64.getEncoder().encodeToString(PDF_TEXT.toByteArray()),
            extractedSizeBytes = 5_000,
            originalBase64Data = "VEVYVFBERg==",
        )
        runCatching {
            RelayTransportCoordinator(client = client, json = json, transportRegistry = TransportRegistry(json), negativeCache = cache)
                .sendMessageStream(
                    apiKey = "relay-key",
                    modelID = PDF_MODEL,
                    messages = listOf(ProviderTestFixtures.userMessage("read", ProviderKind.Relay, PDF_MODEL).copy(attachments = listOf(pdf))),
                    baseUrl = "https://relay.test/v1",
                    supportsImageGen = false,
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = ChatRequestOptions(
                        relayRequested = RelayRequestedConfig(transport = RelayTransport.AnthropicMessages),
                        activeModel = model,
                    ),
                ).toList()
        }
    }

    private fun evidenceIdentity(provider: Provider) = CapabilityEvidenceIdentity(
        partitionId = "u1",
        connectionInstanceId = provider.id,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
    )

    private fun relayRuntimeConfig(image: Boolean) = MetadataClient.RelayRuntimeConfig(
        version = "test",
        officialProviderWhitelist = emptyList(),
        transportEnvelopes = mapOf(
            "openai_chat_completions" to MetadataClient.RelayTransportEnvelope(image = image, textFileInline = true),
        ),
        transportRules = emptyMap(),
        verificationPolicy = MetadataClient.RelayVerificationPolicy(),
        featureGatingPolicy = MetadataClient.RelayFeatureGatingPolicy(),
    )

    private companion object {
        const val PDF_MODEL = "claude-sonnet-4-5"
        const val PDF_TEXT = "extracted report body"
        const val ANTHROPIC_PDF_CATALOG =
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"claude-sonnet-4-5":"claude-sonnet-4-5"},""" +
                """"models":{"claude-sonnet-4-5":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}"""
        const val ANTHROPIC_OK = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    }

}
