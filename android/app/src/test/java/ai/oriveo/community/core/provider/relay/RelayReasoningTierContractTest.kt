package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.providers.detail.RelayModelAdvancedBoard
import ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import java.io.File
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay reasoning tiers (fixture `shared/test-fixtures/relay/reasoning-tier.v1.json`):
 * effortCases -> automatic set, classifyCases -> tier rejection verdict, fallbackCases -> nearest tier fallback;
 * plus in-send tier fallback resend, tier fallback before later sends go out, the panel marking the rejected tier, and the clearing points.
 */
class RelayReasoningTierContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture by lazy { readJson("shared/test-fixtures/relay/reasoning-tier.v1.json") }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        cacheFamilies(null)
        RelayNegativeCache.shared.clearConnection(CONNECTION)
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun RELAY_TIER_effort_cases() {
        cases("effortCases").forEach { case ->
            val caseId = "RELAY-TIER-effort-${case.string("caseId")}"
            val efforts = case.getValue("efforts").jsonArray.map { it.jsonPrimitive.content }
            val expect = case.getValue("expect").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(caseId, expect, RelayReasoningTiers.tiers(efforts).map { it.rawValue })
        }
    }

    @Test
    fun RELAY_TIER_classify_cases() {
        cases("classifyCases").forEach { case ->
            val caseId = "RELAY-TIER-classify-${case.string("caseId")}"
            val actual = RelayReasoningTiers.classify(
                status = case.getValue("status").jsonPrimitive.int,
                body = case.string("body"),
                sentTier = case.string("sentTier"),
                outputStarted = case.getValue("outputStarted").jsonPrimitive.boolean,
            )
            assertEquals(caseId, case.string("expect"), actual)
        }
    }

    @Test
    fun RELAY_TIER_fallback_cases() {
        cases("fallbackCases").forEach { case ->
            val caseId = "RELAY-TIER-fallback-${case.string("caseId")}"
            val actual = RelayReasoningTiers.fallback(
                available = case.getValue("available").jsonArray.map { it.jsonPrimitive.content },
                rejected = case.getValue("rejected").jsonArray.map { it.jsonPrimitive.content }.toSet(),
                selected = case.string("selected"),
            )
            assertEquals(caseId, case.string("expect"), actual)
        }
    }

    @Test
    fun RELAY_TIER_in_send_retry() = runTest {
        MetadataTestFixtures.applyRaw(modelFacts("openAI/gpt-5.5" to listOf("low", "medium", "high", "xhigh")))
        cacheFamilies(mapOf("gpt-5.5" to "openai"))
        val rejection = cases("classifyCases").first()
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val bodies = mutableListOf<JsonObject>()
        val client = client(bodies, rejection.getValue("status").jsonPrimitive.int to rejection.string("body")!!)

        stream(client, cache, ReasoningMode.Max)

        assertEquals("the same send is resent once：$bodies", 2, bodies.size)
        assertEquals("xhigh", effort(bodies[0]))
        assertEquals("the second request body falls to the deep tier：${bodies[1]}", "high", effort(bodies[1]))
        assertEquals(
            listOf(RelayNegativeCache.Kind.ReasoningMax),
            cache.entries().filter { it.key == KEY_RESPONSES }.map { it.kind },
        )

        // Later sends apply the same function before going out: sent once, directly at deep.
        stream(client, cache, ReasoningMode.Max)
        assertEquals(3, bodies.size)
        assertEquals("high", effort(bodies[2]))
    }

    @Test
    fun RELAY_TIER_connection_effort_is_not_a_sent_tier() = runTest {
        // Connection-level reasoning tiers are obsolete: a stored xhigh never goes out, so there is no resend after rejection or tier recording.
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val bodies = mutableListOf<JsonObject>()
        val rejection = cases("classifyCases").first().string("body")!!

        val error = stream(client(bodies, 400 to rejection), cache, ReasoningMode.Automatic, connectionEffort = RelayReasoningEffort.XHigh)

        assertTrue("the original error is reported as-is：$error", error != null)
        assertEquals("connection-level effort is not resent because of it", 1, bodies.size)
        assertEquals("connection-level effort does not go out", null, effort(bodies[0]))
        assertTrue("no tier recorded", cache.entries().isEmpty())
    }

    @Test
    fun RELAY_TIER_empty_panel_set_retries_without_thinking() = runTest {
        // No model-facts -> the panel available set is empty -> fallback is null, and the resend carries no thinking field.
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val bodies = mutableListOf<JsonObject>()
        val rejection = cases("classifyCases").first().string("body")!!

        stream(client(bodies, 400 to rejection), cache, ReasoningMode.Max)

        assertEquals(2, bodies.size)
        assertEquals("xhigh", effort(bodies[0]))
        assertEquals("the resend carries no thinking tier：${bodies[1]}", null, effort(bodies[1]))
    }

    @Test
    fun RELAY_TIER_retry_failure_shows_the_original_error_and_unrelated_400_is_not_retried() = runTest {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val bodies = mutableListOf<JsonObject>()
        val rejection = cases("classifyCases").first().string("body")!!
        val client = client(bodies, 400 to rejection, 400 to """{"error":{"message":"second failure"}}""")

        val error = stream(client, cache, ReasoningMode.Max)

        assertEquals(2, bodies.size)
        assertTrue("shown as the original error：$error", error.toString().contains("xhigh") || error.toString().contains("Unsupported"))

        val unrelated = mutableListOf<JsonObject>()
        stream(client(unrelated, 400 to """{"error":{"message":"messages: content must not be empty"}}"""), cache, ReasoningMode.Deep)
        assertEquals("a 400 unrelated to thinking is not resent", 1, unrelated.size)
    }

    @Test
    fun RELAY_TIER_automatic_set_comes_from_model_facts_family_and_override_narrows() {
        MetadataTestFixtures.applyRaw(modelFacts("gemini/gemini-2.5-pro" to listOf("none", "low", "medium", "high", "xhigh")))
        val model = AIModel(id = "gemini-2.5-pro", name = "Gemini 2.5 Pro")
        val provider = relay(RelayTransport.GeminiGenerateContent, model)
        assertEquals("by-model family not cached -> do not guess by id, no tiers", emptyList<String>(), CapabilityControlResolution.resolveAutomatic(provider, model, "reasoning").intents)
        cacheFamilies(mapOf("gemini-2.5-pro" to "google"))

        val automatic = CapabilityControlResolution.resolveAutomatic(provider, model, "reasoning")
        assertEquals("auto_available", automatic.state)
        assertEquals("automatic comes first", listOf("automatic", "low", "balanced", "deep", "max"), automatic.intents)
        assertEquals(
            "the Model > Advanced page reads the same function",
            listOf(ReasoningMode.Fast, ReasoningMode.Balanced, ReasoningMode.Deep, ReasoningMode.Max),
            RelayModelAdvancedBoard.automaticReasoning(provider, model),
        )

        val narrowed = model.copy(relayCapabilityOverrides = RelayCapabilityOverrides(reasoningLevels = listOf("fast", "deep")))
        assertEquals(listOf("automatic", "low", "deep"), CapabilityControlResolution.resolve(provider.withModel(narrowed), narrowed, "reasoning").intents)

        val unknown = AIModel(id = "totally-unknown-model", name = "Unknown")
        assertEquals("no model-facts available -> empty", emptyList<String>(), CapabilityControlResolution.resolveAutomatic(relay(RelayTransport.GeminiGenerateContent, unknown), unknown, "reasoning").intents)
    }

    @Test
    fun RELAY_TIER_panel_marks_the_rejected_tier() {
        MetadataTestFixtures.applyRaw(modelFacts("gemini/gemini-2.5-pro" to listOf("low", "medium", "high", "xhigh")))
        val model = AIModel(id = "gemini-2.5-pro", name = "Gemini 2.5 Pro")
        val provider = relay(RelayTransport.GeminiGenerateContent, model)
        cacheFamilies(mapOf("gemini-2.5-pro" to "google"))
        RelayNegativeCache.shared.record(RelayNegativeCache.keyFor(provider, model)!!, RelayNegativeCache.Kind.ReasoningMax)

        val verdict = CapabilityControlResolution.resolve(provider, model, "reasoning")
        val shape = ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Reasoning,
                presentation = CapabilityControlPresentationResolver.presentation(provider, model, "reasoning"),
                availableIntents = verdict.intents,
                selectedIntent = "max",
                connection = ModelOptionsPanelInput.connectionCategory(provider.kind),
                protocolUndecided = ModelOptionsPanelInput.protocolUndecided(provider, model),
                customProtocol = ModelOptionsPanelInput.customProtocol(provider, model),
                rejectedIntents = verdict.rejectedIntents,
            ),
        ) as? ModelOptionCapabilityShape.Tiers

        assertEquals(listOf("automatic", "low", "balanced", "deep"), shape?.tiers)
        assertEquals("max", shape?.rejected?.tier)
    }

    @Test
    fun RELAY_TIER_override_change_and_redetect_clear_the_tier_records() {
        val model = AIModel(id = "gemini-2.5-pro", name = "Gemini 2.5 Pro")
        val provider = relay(RelayTransport.GeminiGenerateContent, model)
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        val key = RelayNegativeCache.keyFor(provider, model)!!
        cache.record(key, RelayNegativeCache.Kind.ReasoningMax)
        cache.record(key.copy(transport = "openai_responses"), RelayNegativeCache.Kind.ReasoningDeep)
        cache.record(key, RelayNegativeCache.Kind.Image)
        assertEquals(setOf("max"), cache.rejectedReasoningTiers(key))

        // The write transform stays pure: it does not touch the negative cache; clearing happens at the call site that actually saves the override (ProviderRepository.setRelayReasoningLevels).
        RelayModelAdvancedEdits.settingReasoningLevels(provider, model.id, listOf("fast"))
        assertEquals(3, cache.entries().size)
        RelayModelAdvancedEdits.clearingReasoningTierRecords(provider, model.id, cache)

        assertEquals(
            "changing the override only clears tier records of the currently effective protocol",
            setOf(RelayNegativeCache.Kind.Image, RelayNegativeCache.Kind.ReasoningDeep),
            cache.entries().map { it.kind }.toSet(),
        )

        cache.record(key, RelayNegativeCache.Kind.ReasoningFast)
        cache.clearConnection(CONNECTION)
        assertTrue("re-detection clears everything for that connection", cache.entries().isEmpty())
    }

    // ── helpers ──

    /** Cached by-model family table (production reads the cache only and sends no request); tests put it straight into the shared lookup. */
    private fun cacheFamilies(families: Map<String, String>?) {
        ai.oriveo.community.core.data.remote.RelayModelFamilyLookup::class.java.getDeclaredField("families")
            .apply { isAccessible = true }
            .set(ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared, families)
    }

    private suspend fun stream(
        client: HttpClient,
        cache: RelayNegativeCache,
        mode: ReasoningMode,
        connectionEffort: RelayReasoningEffort? = null,
    ): Throwable? {
        val model = AIModel(id = "gpt-5.5", name = "gpt-5.5")
        return runCatching {
            RelayTransportCoordinator(client = client, json = json, transportRegistry = TransportRegistry(json), negativeCache = cache)
                .sendMessageStream(
                    apiKey = "relay-key",
                    modelID = model.id,
                    messages = listOf(ProviderTestFixtures.userMessage("hi", ProviderKind.Relay, model.id)),
                    baseUrl = "https://relay.test/v1",
                    supportsImageGen = false,
                    reasoningMode = mode,
                    webSearchEnabled = false,
                    requestOptions = ChatRequestOptions(
                        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses, reasoningEffort = connectionEffort),
                        activeModel = model,
                        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                            partitionId = "u1",
                            connectionInstanceId = CONNECTION,
                            connectionGeneration = "g",
                            credentialEpoch = "e",
                            providerKind = ProviderKind.Relay.rawValue,
                            authMode = "apiKey",
                        ),
                    ),
                ).toList()
        }.exceptionOrNull()
    }

    /** [errors] supplies failures for the first few requests in order; every request succeeds afterwards. */
    private fun client(bodies: MutableList<JsonObject>, vararg errors: Pair<Int, String>): HttpClient = HttpClient(MockEngine { request ->
        bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
        val error = errors.getOrNull(bodies.size - 1)
        if (error == null) {
            respond(RESPONSES_OK, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        } else {
            respond(error.second, HttpStatusCode.fromValue(error.first), headersOf(HttpHeaders.ContentType, "application/json"))
        }
    }).also { openClients += it }

    private fun effort(body: JsonObject): String? =
        (body["reasoning"] as? JsonObject)?.get("effort")?.jsonPrimitive?.contentOrNull

    private fun relay(transport: RelayTransport, model: AIModel) = Provider(
        id = CONNECTION,
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        apiKey = "relay-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = transport),
        models = listOf(model),
    )

    private fun Provider.withModel(model: AIModel) = copy(models = listOf(model))

    private fun modelFacts(vararg facts: Pair<String, List<String>>): String = JsonObject(
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

    private fun cases(name: String): List<JsonObject> = fixture.getValue(name).jsonArray.map { it.jsonObject }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun readJson(relativePath: String): JsonObject {
        val repoRoot = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private companion object {
        const val CONNECTION = "relay-tier-connection"
        val KEY_RESPONSES = RelayNegativeCache.Key(CONNECTION, "gpt-5.5", "openai_responses")
        const val RESPONSES_OK =
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
    }
}
