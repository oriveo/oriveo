package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.relayRouterModel
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Unit tests for enriching a relay catalog from the published model catalog.
 *
 * They read the shared fixture `shared/test-fixtures/relay/metadata-fixture.json` and inject
 * it into MetadataClient's in-memory snapshot by reflection, covering:
 *   - a model that matches the catalog merges display fields, capabilities and profiles
 *   - capabilities the transport envelope does not support are closed off
 *   - a model with no catalog entry keeps its local semantics untouched
 *   - RelayRuntimeSupport's transport-envelope queries
 */
class RelayOfficialCatalogResolverTest {

    @After
    fun tearDown() {
        clearTable()
    }

    private fun makeRelayProvider(
        transport: RelayTransport = RelayTransport.OpenAIResponses,
        catalogModels: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = emptyList(),
        catalogModels = catalogModels,
        apiKey = "",
        apiKeyPreview = "",
        relayRequested = RelayRequestedConfig(transport = transport),
    )

    private fun localModel(id: String) = AIModel(
        id = id,
        name = id,
        capabilities = listOf(ModelCapability.Text),
        reasoningModeAvailable = false,
        isAvailable = true,
        isDefault = false,
        priceTier = "",
    )

    @Test
    fun `a catalog hit on gpt-5_4 merges displayName capabilities and profiles`() {
        injectFixture()
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIResponses,
            catalogModels = listOf(localModel("gpt-5.4")),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = provider.catalogModels[0],
            provider = provider,
            runtimeConfig = runtime,
        )

        assertEquals("gpt-5.4", enriched.canonicalModelId)
        assertEquals("GPT-5.4", enriched.name)
        assertTrue(ModelCapability.Image in enriched.capabilities)
        assertTrue(ModelCapability.File in enriched.capabilities)
        assertTrue(ModelCapability.Web in enriched.capabilities)
        assertTrue(ModelCapability.Reasoning in enriched.capabilities)
        assertEquals("openaiReasoning", enriched.reasoningProfile)
        assertEquals("openaiWebSearch", enriched.webSearchProfile)
    }

    @Test
    fun `a manual model (bare id plus isManual=true) keeps user fields and inherits capabilities and pricing`() {
        injectFixture()
        val local = AIModel(
            id = "gpt-5.4",
            name = "gpt-5.4 (manual)",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            reasoningModeAvailable = false,
            isAvailable = true,
            isDefault = true,
            priceTier = "",
            isManual = true,
        )
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIResponses,
            catalogModels = listOf(local),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = runtime,
        )

        assertEquals("gpt-5.4", enriched.id)
        assertEquals("gpt-5.4 (manual)", enriched.name)
        // An exact manual hit inherits capabilities (union) the same way a catalog model does, not just pricing.
        assertEquals(
            setOf(ModelCapability.Text, ModelCapability.Image, ModelCapability.File, ModelCapability.Web, ModelCapability.Reasoning),
            enriched.capabilities.toSet(),
        )
        assertEquals("openaiReasoning", enriched.reasoningProfile)
        assertEquals("gpt-5.4", enriched.canonicalModelId)
        assertEquals(0.000002, enriched.promptPrice ?: 0.0, 0.0000000001)
        assertEquals(0.000008, enriched.completionPrice ?: 0.0, 0.0000000001)
        assertTrue(enriched.priceTier.isNotEmpty())
    }

    @Test
    fun `the older relay-manual- prefixed form still takes the manual path`() {
        injectFixture()
        val local = AIModel(
            id = "relay-manual-gpt-5.4",
            name = "gpt-5.4 (manual legacy)",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            reasoningModeAvailable = false,
            isAvailable = true,
            isDefault = true,
            priceTier = "",
        )
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIResponses,
            catalogModels = listOf(local),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = runtime,
        )

        assertEquals("gpt-5.4 (manual legacy)", enriched.name)
        // Inherited capabilities (union).
        assertTrue(ModelCapability.Reasoning in enriched.capabilities)
        assertTrue(ModelCapability.Image in enriched.capabilities)
        assertEquals("gpt-5.4", enriched.canonicalModelId)
    }

    @Test
    fun `the openai_chat_completions envelope closes off web search and image generation`() {
        injectFixture()
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIChatCompletions,
            catalogModels = listOf(localModel("gpt-5.4")),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = provider.catalogModels[0],
            provider = provider,
            runtimeConfig = runtime,
        )

        assertFalse(ModelCapability.Web in enriched.capabilities)
        assertNull(enriched.webSearchProfile)
        // textFileInline=true, so File survives.
        assertTrue(ModelCapability.File in enriched.capabilities)
        assertTrue(ModelCapability.Reasoning in enriched.capabilities)
        assertEquals("openaiReasoning", enriched.reasoningProfile)
    }

    @Test
    fun `a catalog hit keeps the locally declared model-level imageGen capability`() {
        injectFixture()
        val local = localModel("gpt-image-2").copy(
            capabilities = listOf(ModelCapability.Text, ModelCapability.ImageGen),
            imageGenProfile = "localImageGen",
        )
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIChatCompletions,
            catalogModels = listOf(local),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = runtime,
        )

        assertTrue(ModelCapability.ImageGen in enriched.capabilities)
        assertNotNull(enriched.imageGenProfile)
    }

    @Test
    fun `catalog hit clears stale profiles when official metadata removes them`() {
        injectJson(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "resolveMap": {
                    "gpt-authority": "gpt-authority"
                  },
                  "models": {
                    "gpt-authority": {
                      "canonicalModelId": "gpt-authority",
                      "displayName": "GPT Authority",
                      "capabilities": ["text", "reasoning", "web", "imageGeneration"],
                      "profiles": {}
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        val local = localModel("gpt-authority").copy(
            capabilities = listOf(
                ModelCapability.Text,
                ModelCapability.Reasoning,
                ModelCapability.Web,
                ModelCapability.ImageGen,
            ),
            reasoningModeAvailable = true,
            reasoningProfile = "old_reasoning",
            webSearchProfile = "old_web",
            imageGenProfile = "old_image",
        )
        val provider = makeRelayProvider(
            transport = RelayTransport.OpenAIResponses,
            catalogModels = listOf(local),
        )
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = runtime,
        )

        assertTrue(ModelCapability.Reasoning in enriched.capabilities)
        assertTrue(ModelCapability.Web in enriched.capabilities)
        assertTrue(ModelCapability.ImageGen in enriched.capabilities)
        assertFalse(enriched.reasoningModeAvailable)
        assertNull(enriched.reasoningProfile)
        assertNull(enriched.webSearchProfile)
        assertNull(enriched.imageGenProfile)
    }

    @Test
    fun `a model with no catalog entry is left exactly as it was`() {
        injectFixture()
        val local = localModel("my-internal-model")
        val provider = makeRelayProvider(catalogModels = listOf(local))
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = runtime,
        )
        assertEquals(local.id, enriched.id)
        assertEquals(local.name, enriched.name)
        assertEquals(local.capabilities, enriched.capabilities)
        assertNull(enriched.canonicalModelId)
        assertNull(enriched.webSearchProfile)
    }

    @Test
    fun `enrichCatalog preserves order and keeps the entries that did not match`() {
        injectFixture()
        val models = listOf(
            localModel("my-custom-model"),
            localModel("gpt-5.4"),
            localModel("claude-sonnet-4.5"),
        )
        val provider = makeRelayProvider(catalogModels = models)
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrichCatalog(provider, runtime)

        assertEquals(3, enriched.size)
        assertEquals("my-custom-model", enriched[0].id)
        assertNull(enriched[0].canonicalModelId)

        assertEquals("gpt-5.4", enriched[1].id)
        assertEquals("gpt-5.4", enriched[1].canonicalModelId)
        assertEquals("GPT-5.4", enriched[1].name)

        assertEquals("claude-sonnet-4.5", enriched[2].id)
        assertEquals("claude-sonnet-4.5", enriched[2].canonicalModelId)
        assertEquals("Claude Sonnet 4.5", enriched[2].name)
    }

    @Test
    fun `inherit 01 same-vendor hit carries capabilities, profile, pricing and the three whitelist fields, nulled when the envelope has no native file`() {
        injectInheritFixture(responsesNativeFile = true)
        val provider = makeRelayProvider(transport = RelayTransport.OpenAIResponses)
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = localModel("gpt-5.4"),
            provider = provider,
            runtimeConfig = MetadataClient.relayRuntimeConfig(),
        )
        assertTrue(ModelCapability.Image in enriched.capabilities)
        assertTrue(ModelCapability.File in enriched.capabilities)
        assertEquals("openaiReasoning", enriched.reasoningProfile)
        assertEquals(0.000002, enriched.promptPrice ?: 0.0, 1e-10)
        // The whitelist comes from the router model fetched at send time (the same function the production request-body builder uses).
        val router = relayRouterModel("gpt-5.4", ProviderKind.OpenAI, enriched)
        assertEquals(listOf("application/pdf"), router?.nativeFileMimes)
        assertTrue(router?.pdfNativeDefault == true)
        assertEquals(321, router?.attachmentExtraction?.maxLines)

        // This protocol's envelope has nativeFile=false: all three (including attachmentExtraction) are nulled together.
        injectInheritFixture(responsesNativeFile = false)
        val gated = relayRouterModel("gpt-5.4", ProviderKind.OpenAI, enriched)
        assertEquals(emptyList<String>(), gated?.nativeFileMimes)
        assertFalse(gated?.pdfNativeDefault == true)
        assertNull(gated?.attachmentExtraction)
    }

    @Test
    fun `inherit 02 cross-vendor hit carries capabilities, profile and pricing but empty whitelist, and an exact manual hit inherits the same way`() {
        injectInheritFixture(responsesNativeFile = true)
        val provider = makeRelayProvider(transport = RelayTransport.OpenAIResponses)
        val runtime = MetadataClient.relayRuntimeConfig()
        val enriched = RelayOfficialCatalogResolver.enrich(localModel("claude-sonnet-4.5"), provider, runtime)
        assertTrue(ModelCapability.Image in enriched.capabilities)
        assertEquals("anthropicReasoning", enriched.reasoningProfile)
        assertEquals(0.000003, enriched.promptPrice ?: 0.0, 1e-10)
        val router = relayRouterModel("claude-sonnet-4.5", ProviderKind.OpenAI, enriched)
        assertTrue(router?.nativeFileMimes.orEmpty().isEmpty())
        assertFalse(router?.pdfNativeDefault == true)
        assertNull(router?.attachmentExtraction)

        // A manual model matching exactly after stripping the date suffix inherits capabilities (union), profile and pricing
        // the same way a catalog model does, and keeps the user's name.
        val manual = AIModel(
            id = "claude-sonnet-4-5-2026-04-01",
            name = "my claude",
            capabilities = listOf(ModelCapability.Text, ModelCapability.ToolCall),
            isManual = true,
        )
        val manualEnriched = RelayOfficialCatalogResolver.enrich(manual, provider, runtime)
        assertEquals("my claude", manualEnriched.name)
        assertEquals("claude-sonnet-4-5-2026-04-01", manualEnriched.id)
        assertTrue(ModelCapability.Image in manualEnriched.capabilities)
        assertTrue(ModelCapability.Reasoning in manualEnriched.capabilities)
        assertTrue(ModelCapability.ToolCall in manualEnriched.capabilities)
        assertEquals("anthropicReasoning", manualEnriched.reasoningProfile)
        assertTrue(manualEnriched.reasoningModeAvailable)
        assertEquals(0.000003, manualEnriched.promptPrice ?: 0.0, 1e-10)
        assertTrue(
            relayRouterModel(manual.id, ProviderKind.OpenAI, manualEnriched)?.nativeFileMimes.orEmpty().isEmpty(),
        )
    }

    /** On top of the shared metadata fixture: add the three whitelist fields and cross-vendor pricing, and turn off native file for openai_responses on demand. */
    private fun injectInheritFixture(responsesNativeFile: Boolean) {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        val raw = Json.parseToJsonElement(
            File(repoRoot, "shared/test-fixtures/relay/metadata-fixture.json").readText(Charsets.UTF_8),
        ).jsonObject
        val whitelist = buildJsonObject {
            put("nativeFileMimes", buildJsonArray { add(JsonPrimitive("application/pdf")) })
            put("pdfNativeDefault", JsonPrimitive(true))
            put("attachmentExtraction", buildJsonObject { put("maxLines", JsonPrimitive(321)) })
        }
        fun patchModel(providers: JsonObject, provider: String, model: String, extra: JsonObject): JsonObject {
            val p = providers.getValue(provider).jsonObject
            val models = p.getValue("models").jsonObject
            val patched = JsonObject(models.getValue(model).jsonObject + extra)
            return JsonObject(providers + (provider to JsonObject(p + ("models" to JsonObject(models + (model to patched))))))
        }
        var providers = raw.getValue("providers").jsonObject
        providers = patchModel(providers, "openAI", "gpt-5.4", whitelist)
        providers = patchModel(
            providers,
            "anthropic",
            "claude-sonnet-4.5",
            JsonObject(
                whitelist + ("pricing" to buildJsonObject {
                    put("promptPerMToken", JsonPrimitive(3.0))
                    put("completionPerMToken", JsonPrimitive(15.0))
                }) + ("pricingStatus" to JsonPrimitive("priced")),
            ),
        )
        val relay = raw.getValue("relayRuntimeConfig").jsonObject
        val envelopes = relay.getValue("transportEnvelopes").jsonObject
        val responses = JsonObject(
            envelopes.getValue("openai_responses").jsonObject + ("nativeFile" to JsonPrimitive(responsesNativeFile)),
        )
        val patchedRelay = JsonObject(
            relay + ("transportEnvelopes" to JsonObject(envelopes + ("openai_responses" to responses))),
        )
        injectJson(JsonObject(raw + ("providers" to providers) + ("relayRuntimeConfig" to patchedRelay)).toString())
    }

    @Test
    fun `an id that differs from the official one inherits official capabilities by canonicalModelId match`() {
        injectFixture()
        val local = localModel("my-gpt-alias").copy(canonicalModelId = "gpt-5.4")
        val provider = makeRelayProvider(transport = RelayTransport.OpenAIResponses, catalogModels = listOf(local))
        val enriched = RelayOfficialCatalogResolver.enrich(
            localModel = local,
            provider = provider,
            runtimeConfig = MetadataClient.relayRuntimeConfig(),
        )

        assertEquals("my-gpt-alias", enriched.id)
        assertEquals("gpt-5.4", enriched.canonicalModelId)
        assertEquals("GPT-5.4", enriched.name)
        assertTrue(ModelCapability.Reasoning in enriched.capabilities)
    }

    @Test
    fun `RelayRuntimeSupport attachmentSupport reports nativeFile false for openai_chat_completions`() {
        injectFixture()
        val provider = makeRelayProvider(transport = RelayTransport.OpenAIChatCompletions)
        val runtime = MetadataClient.relayRuntimeConfig()
        val support = RelayRuntimeSupport.attachmentSupport(provider, runtime)
        assertNotNull(support)
        assertEquals(true, support!!.image)
        assertEquals(false, support.nativeFile)
        assertEquals(true, support.textFileInline)
    }

    @Test
    fun `RelayRuntimeSupport Auto transport lines up with openai_chat_completions`() {
        val provider = makeRelayProvider(transport = RelayTransport.Auto)
        val runtime = MetadataClient.FALLBACK_RELAY_RUNTIME_CONFIG
        val support = RelayRuntimeSupport.attachmentSupport(provider, runtime)

        assertNotNull(support)
        assertEquals(true, support!!.image)
        assertEquals(false, support.nativeFile)
        assertEquals(true, support.textFileInline)
        assertFalse(RelayRuntimeSupport.supportsWebSearch(provider, runtime))
    }

    @Test
    fun `RelayRuntimeSupport supportsWebSearch openai_responses true anthropic_messages false`() {
        injectFixture()
        val runtime = MetadataClient.relayRuntimeConfig()
        assertTrue(
            RelayRuntimeSupport.supportsWebSearch(
                makeRelayProvider(transport = RelayTransport.OpenAIResponses),
                runtime,
            )
        )
        assertFalse(
            RelayRuntimeSupport.supportsWebSearch(
                makeRelayProvider(transport = RelayTransport.AnthropicMessages),
                runtime,
            )
        )
        assertTrue(
            RelayRuntimeSupport.supportsWebSearch(
                makeRelayProvider(transport = RelayTransport.GeminiGenerateContent),
                runtime,
            )
        )
    }

    // Fixture injection helpers

    private fun injectFixture() {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        val fixturePath = File(repoRoot, "shared/test-fixtures/relay/metadata-fixture.json")
        require(fixturePath.exists()) { "fixture not found at: ${fixturePath.absolutePath}" }
        injectJson(fixturePath.readText(Charsets.UTF_8))
    }

    private fun injectJson(rawJson: String) {
        val clientClass = MetadataClient::class.java
        val jsonField = clientClass.getDeclaredField("json")
        jsonField.isAccessible = true
        val internalJson = jsonField.get(MetadataClient.instance) as Json
        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companionField = responseClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val serializer = serializerMethod.invoke(companion) as KSerializer<Any>
        val decoded = internalJson.decodeFromString(serializer, rawJson)
        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, decoded)
    }

    private fun clearTable() {
        val tableField = MetadataClient::class.java.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, null)
    }
}
