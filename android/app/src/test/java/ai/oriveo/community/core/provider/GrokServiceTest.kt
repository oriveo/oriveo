package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.data.remote.MetadataClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrokServiceTest {

    private val json = Json { ignoreUnknownKeys = true }

    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    private fun buildService(): GrokService = GrokService(
        client = HttpClient(MockEngine { respond("", HttpStatusCode.OK) }),
        json = json,
        transportRegistry = transportRegistry,
    )

    private fun invokeBuildChatRequest(
        service: GrokService,
        modelID: String,
        reasoningMode: ReasoningMode,
        resolved: MetadataClient.ResolvedModelMetadata? = null,
    ): String {
        val method = OpenAICompatibleService::class.java.getDeclaredMethod(
            "buildChatRequest",
            String::class.java,
            List::class.java,
            java.lang.Boolean.TYPE,
            ReasoningMode::class.java,
            java.lang.Boolean.TYPE,
            java.lang.Boolean.TYPE, // supportsImageGen
            ChatRequestOptions::class.java,
            MetadataClient.ResolvedModelMetadata::class.java,
        )
        method.isAccessible = true
        return method.invoke(
            service,
            modelID,
            listOf(sampleUserMessage()),
            true,
            reasoningMode,
            false,
            false, // supportsImageGen
            ChatRequestOptions(),
            resolved,
        ) as String
    }

    private fun sampleUserMessage(): ChatMessage = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = "ping",
        providerKind = ProviderKind.Grok,
        providerName = "Grok",
        modelID = "grok-4",
        modelName = "Grok 4",
        state = ChatMessageState.Delivered,
    )

    @org.junit.After
    fun tearDown() {
        UnsupportedParamCache.resetForTest()
        MetadataTestFixtures.clear()
    }

    /**
     * @param reasoningProfile keeps a legacy `profiles.reasoning` reference around so the same
     *   fixture also proves that when a runtime is present the recipe wins over the profile. Pass
     *   null for a model with no automatic reasoning configuration at all.
     */
    private fun resolveGrokMetadata(modelID: String, reasoningProfile: String?): MetadataClient.ResolvedModelMetadata? {
        val profileJson = reasoningProfile?.let { ""","profiles":{"reasoning":"$it"}""" }.orEmpty()
        // The reverse gate: an intent may only go out if it appears in availableIntents, and the
        // ladder has to stay ordered off < low < balanced < deep < max.
        val controlsJson = reasoningProfile?.let {
            ""","capabilityControls":${MetadataTestFixtures.capabilityControlsJson(
                MetadataTestFixtures.ControlSpec(
                    capability = "reasoning",
                    recipeRef = "grok.chat.reasoning.v1",
                    availableIntents = listOf("low", "balanced", "deep"),
                ),
            )}"""
        }.orEmpty()
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "capabilityRuntime": ${MetadataTestFixtures.capabilityRuntimeJson()},
              "profiles": {
                "reasoning": {
                  "oai_chat": {
                    "transport": "chat_completions",
                    "levels": ["fast", "balanced", "deep"],
                    "params": {
                      "fast": { "reasoning_effort": "legacy-must-not-win" },
                      "balanced": { "reasoning_effort": "legacy-must-not-win" },
                      "deep": { "reasoning_effort": "legacy-must-not-win" }
                    }
                  }
                }
              },
              "providers": {
                "grok": {
                  "defaultModelId": "$modelID",
                  "resolveMap": {
                    "$modelID": "$modelID"
                  },
                  "models": {
                    "$modelID": {
                      "canonicalModelId": "$modelID",
                      "displayName": "$modelID",
                      "transport": "openai_chat"$profileJson$controlsJson
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        return MetadataClient.resolveCatalogModel(modelID, ProviderKind.Grok)
    }

    // ── The catalog gate, which is what finally fixed the grok-4.20 incident ──
    // Grok no longer sends reasoning_effort based on a model id or a local optimistic guess: it is
    // injected only when the catalog carries an automatic configuration for that exact
    // provider/model/transport.
    // Since a missing runtime now means no automatic configuration at all, the authority behind this
    // gate moved from the legacy profiles to the exact recipe in capabilityRuntime
    // (`ProviderRequestProfiles.applyCapabilityRuntimeRecipes` sets authoritativeRuntime=true when
    // the runtime is missing and no longer falls back to a profile). So the cases below assert the
    // **result the recipe produces**: the level mapping low->low, balanced->medium and deep->high now
    // comes from the production registry's grok.chat.reasoning.v1, not from params hand-written in a
    // fixture.

    @Test
    fun `buildChatRequest omits reasoning_effort without backend reasoning profile`() {
        val body = invokeBuildChatRequest(buildService(), "grok-4", ReasoningMode.Deep)
        assertFalse(body.contains("reasoning_effort"))
    }

    @Test
    fun `buildChatRequest sends reasoning_effort when backend reasoning profile exists`() {
        val modelID = "grok-3-mini"
        val resolved = resolveGrokMetadata(modelID, reasoningProfile = "oai_chat")
        val body = invokeBuildChatRequest(buildService(), modelID, ReasoningMode.Deep, resolved)
        assertTrue(body.contains(""""reasoning_effort":"high""""))
    }

    @Test
    fun `buildChatRequest does not use provider-model runtime cache without exact identity`() {
        val modelID = "grok-3-mini"
        val resolved = resolveGrokMetadata(modelID, reasoningProfile = "oai_chat")
        val body = invokeBuildChatRequest(buildService(), modelID, ReasoningMode.Deep, resolved)
        assertTrue(body.contains("reasoning_effort"))
        // With a runtime present the legacy profile takes no part in building the request, so the
        // deliberately broken params in the fixture must never reach the wire.
        assertFalse(body.contains("legacy-must-not-win"))
    }

    @Test
    fun `buildChatRequest sends reasoning_effort low for Fast when backend reasoning profile exists`() {
        val modelID = "grok-3-mini"
        val resolved = resolveGrokMetadata(modelID, reasoningProfile = "oai_chat")
        val body = invokeBuildChatRequest(buildService(), modelID, ReasoningMode.Fast, resolved)
        assertTrue(body.contains(""""reasoning_effort":"low""""))
    }

    @Test
    fun `buildChatRequest sends reasoning_effort medium for Balanced when backend reasoning profile exists`() {
        val modelID = "grok-3-mini"
        val resolved = resolveGrokMetadata(modelID, reasoningProfile = "oai_chat")
        val body = invokeBuildChatRequest(buildService(), modelID, ReasoningMode.Balanced, resolved)
        assertTrue(body.contains(""""reasoning_effort":"medium""""))
    }

    @Test
    fun `buildChatRequest omits reasoning_effort under Automatic even when backend reasoning profile exists`() {
        val modelID = "grok-3-mini"
        val resolved = resolveGrokMetadata(modelID, reasoningProfile = "oai_chat")
        val body = invokeBuildChatRequest(buildService(), modelID, ReasoningMode.Automatic, resolved)
        assertFalse(body.contains("reasoning_effort"))
    }
}
