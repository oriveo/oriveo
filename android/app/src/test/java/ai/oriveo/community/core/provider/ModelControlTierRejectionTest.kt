package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.GenerationParameterOutboundContractTest.Companion.OFFICIAL_MODEL
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * An upstream rejection is recorded per thinking tier: when one tier is rejected with a 400, only that tier is removed; legacy entries and a rejection of every tier still make the whole group dormant.
 * The recipe is the real registry's (Anthropic official reasoning), plus a single locator rule so the production locator recognizes `/thinking`.
 */
class ModelControlTierRejectionTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val provider = Provider(id = "anthropic-tier", kind = ProviderKind.Anthropic)
    private val model = AIModel(id = OFFICIAL_MODEL, name = OFFICIAL_MODEL)
    private val recipeRef = "anthropic.messages.reasoning.v1"

    @Before
    fun setUp() {
        ModelControlRejectionCache.clearForTesting()
        MetadataTestFixtures.applyRaw(metadataWithLocator().toString())
    }

    @After
    fun tearDown() {
        ModelControlRejectionCache.clearForTesting()
        MetadataTestFixtures.clear()
    }

    @Test
    fun `a tier rejected upstream is recorded with that tier from the production send chain`() = runTest {
        val body = rejectTier("deep")
        // The real request body carries the thinking setting of this tier.
        assertEquals(16384, body["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertEquals(
            ModelControlRejectionCache.TierRejections(untiered = false, tiers = setOf("deep")),
            ModelControlRejectionCache.tierRejections(identity(), "reasoning", "provider_recipe", recipeRef),
        )
    }

    @Test
    fun `panel input drops only the rejected tier and explains it`() = runTest {
        rejectTier("deep")
        val verdict = CapabilityControlResolution.resolve(provider, model, "reasoning")
        assertEquals("auto_available", verdict.state)
        assertEquals(setOf("deep"), verdict.rejectedIntents)
        val shape = ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Reasoning,
                presentation = CapabilityControlPresentationResolver.presentation(provider, model, "reasoning"),
                availableIntents = verdict.intents,
                selectedIntent = "deep",
                connection = ModelOptionCapabilityShape.ConnectionCategory.Other,
                rejectedIntents = verdict.rejectedIntents,
            ),
        ) as ModelOptionCapabilityShape.Tiers
        assertEquals(listOf("off", "low", "balanced"), shape.tiers)
        assertEquals("deep", shape.rejected?.tier)
    }

    @Test
    fun `switching to a tier that was not rejected still sends the thinking setting`() = runTest {
        rejectTier("deep")
        val identity = identity()
        assertTrue(ModelControlRejectionCache.blocksSelection(identity, "reasoning", "provider_recipe", recipeRef, selectedTier = "deep"))
        assertFalse(ModelControlRejectionCache.blocksSelection(identity, "reasoning", "provider_recipe", recipeRef, selectedTier = "low"))
        val dormant = setOfNotNull(
            "reasoning".takeIf {
                ModelControlRejectionCache.blocksSelection(identity, "reasoning", "provider_recipe", recipeRef, selectedTier = "low")
            },
        )
        val body = send(ReasoningMode.Fast, "low", dormant) { respond("data: [DONE]\n\n", HttpStatusCode.OK) }
        assertEquals(2048, body["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun `legacy entries without a tier still put the whole group to sleep`() {
        val identity = identity()
        val legacy = buildJsonObject {
            put("connectionId", identity.connectionId)
            put("canonicalModelId", identity.canonicalModelId)
            put("finalTransport", identity.finalTransport)
            put("runtimeRevision", identity.runtimeRevision)
            put("owner", "reasoning")
            put("source", "provider_recipe")
            put("recipeRef", recipeRef)
            put("setting", "/thinking")
            put("observedAt", System.currentTimeMillis())
            put("expiresAt", System.currentTimeMillis() + 60_000)
        }
        ModelControlRejectionCache.configurePersistenceForTesting(read = { JsonArray(listOf(legacy)).toString() }, write = {})
        val verdict = CapabilityControlResolution.resolve(provider, model, "reasoning")
        assertEquals("upstream_setting_dormant", verdict.reasonCode)
        assertTrue(ModelControlRejectionCache.blocksSelection(identity, "reasoning", "provider_recipe", recipeRef, selectedTier = "low"))
    }

    @Test
    fun `every tier rejected puts the whole group to sleep`() = runTest {
        listOf("low", "balanced", "deep").forEach { rejectTier(it) }
        val verdict = CapabilityControlResolution.resolve(provider, model, "reasoning")
        assertEquals("upstream_setting_dormant", verdict.reasonCode)
        assertEquals(emptySet<String>(), verdict.rejectedIntents)
    }

    @Test
    fun `automatic selections and custom fields record without a tier`() {
        val recipe = LocatedModelControlRejection("provider_recipe", "reasoning", recipeRef, listOf("/thinking"))
        assertNull(ModelControlRejectionCache.rejectedTier(recipe, null))
        assertNull(ModelControlRejectionCache.rejectedTier(recipe, "automatic"))
        assertEquals("deep", ModelControlRejectionCache.rejectedTier(recipe, "deep"))
        assertNull(ModelControlRejectionCache.rejectedTier(recipe.copy(source = "custom", recipeRef = null), "deep"))
        assertNull(ModelControlRejectionCache.rejectedTier(recipe.copy(owner = "web"), "deep"))
    }

    /** Production send, MockEngine 400, production locator, then the same persistence entry as ChatRepository. Returns the real body of the rejected request. */
    private suspend fun rejectTier(tier: String): JsonObject {
        val collector = CapabilityExecutionCollector()
        val options = ChatRequestOptions(
            capabilityExecutionCollector = collector,
            capabilityPreferences = CapabilityPreferenceValues(reasoningIntent = tier),
        )
        var error: ProviderServiceError.Upstream? = null
        val body = send(ReasoningMode.fromIntent(tier), tier, emptySet(), collector = collector, onError = { error = it }) {
            respond(
                """{"type":"error","error":{"type":"invalid_request_error","param":"thinking"}}""",
                HttpStatusCode.BadRequest,
                headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val upstream = requireNotNull(error) { "400 must surface as Upstream" }
        val located = collector.locateProviderRecipeRejection(upstream.statusCode, upstream.rejectedParameter)
            ?: throw AssertionError("production locator must resolve /thinking")
        val rejection = LocatedModelControlRejection(located.source, located.owner, located.recipeRef, located.locatedPointers)
        ModelControlRejectionCache.recordLocated(
            identity(),
            rejection,
            ModelControlRejectionCache.rejectedTier(rejection, options.capabilityPreferences?.reasoningIntent),
        )
        return body
    }

    private suspend fun send(
        mode: ReasoningMode,
        intent: String,
        dormant: Set<String>,
        collector: CapabilityExecutionCollector? = null,
        onError: (ProviderServiceError.Upstream) -> Unit = {},
        reply: suspend io.ktor.client.engine.mock.MockRequestHandleScope.() -> io.ktor.client.request.HttpResponseData,
    ): JsonObject {
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            reply()
        })
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "tier-test-key",
                modelID = OFFICIAL_MODEL,
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Anthropic, OFFICIAL_MODEL)),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = mode,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    capabilityExecutionCollector = collector,
                    capabilityPreferences = CapabilityPreferenceValues(reasoningIntent = intent),
                    dormantCapabilityOwners = dormant,
                ),
            ).toList()
        }.exceptionOrNull()?.let { (it as? ProviderServiceError.Upstream)?.let(onError) }
        return json.parseToJsonElement(requireNotNull(requestBody) { "Anthropic did not build a request" }).jsonObject
    }

    private fun identity(): ModelControlRuntimeIdentity =
        requireNotNull(ModelControlRuntimeIdentityResolver.resolve(provider, model)) { "runtime identity must resolve" }

    private fun metadataWithLocator(): JsonObject {
        val base = GenerationParameterOutboundContractTest().officialMetadata()
        val runtime = base["capabilityRuntime"]!!.jsonObject
        val recipes = runtime["recipes"]!!.jsonObject
        val recoveryRef = "fixture.anthropic.reasoning.tier"
        val patchedRecipes = JsonObject(recipes + (recipeRef to JsonObject(recipes[recipeRef]!!.jsonObject + mapOf(
            "errorRecoveryRef" to JsonPrimitive(recoveryRef),
        ))))
        val recoveries = (runtime["errorRecoveryDefinitions"] as? JsonObject).orEmpty() + (recoveryRef to buildJsonObject {
            put("capability", "reasoning")
            put("protocol", "anthropic_messages")
            put("responseParserKind", "anthropic_thinking_v1")
            put("locatorRules", JsonArray(listOf(buildJsonObject {
                put("status", 400)
                put("owner", "reasoning")
                put("pointers", JsonArray(listOf(JsonPrimitive("/thinking"))))
                put("errorFields", buildJsonObject { put("/error/param", "thinking") })
            })))
        })
        val patchedRuntime = JsonObject(runtime + mapOf(
            "recipes" to patchedRecipes,
            "errorRecoveryDefinitions" to JsonObject(recoveries),
        ))
        return JsonObject(base + ("capabilityRuntime" to patchedRuntime))
    }
}
