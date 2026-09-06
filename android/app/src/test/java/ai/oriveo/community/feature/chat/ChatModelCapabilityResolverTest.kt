package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ChatModelCapabilityResolverTest {

    private val resolver = ChatModelCapabilityResolver(
        metadata = MetadataClient(),
        runtimeConfigProvider = {
            MetadataClient.RelayRuntimeConfig(
                version = "test",
                officialProviderWhitelist = emptyList(),
                transportEnvelopes = mapOf(
                    "openai_responses" to MetadataClient.RelayTransportEnvelope(
                        image = true,
                        nativeFile = true,
                        textFileInline = true,
                        webSearch = true,
                        reasoning = true,
                    ),
                    "openai_chat_completions" to MetadataClient.RelayTransportEnvelope(
                        image = true,
                        nativeFile = false,
                        textFileInline = true,
                        webSearch = false,
                        reasoning = true,
                    ),
                ),
                transportRules = emptyMap(),
                verificationPolicy = MetadataClient.RelayVerificationPolicy(),
                featureGatingPolicy = MetadataClient.RelayFeatureGatingPolicy(),
            )
        },
    )

    @Test
    fun `relay file support follows runtime envelope instead of model file capability`() {
        val provider = relayProvider(RelayTransport.OpenAIResponses)
        val model = AIModel(
            id = "gpt-4o",
            name = "GPT-4o",
            capabilities = listOf(ModelCapability.Text),
        )

        assertTrue(resolver.supportsFile(provider, model))
    }

    @Test
    fun `relay declaration without final identity stays fail closed`() {
        val model = AIModel(
            id = "gpt-4o",
            name = "GPT-4o",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web),
        )

        assertFalse(resolver.supportsWeb(relayProvider(RelayTransport.OpenAIResponses), model))
        assertFalse(resolver.supportsWeb(relayProvider(RelayTransport.OpenAIChatCompletions), model))
        assertFalse(
            resolver.supportsWeb(
                relayProvider(RelayTransport.OpenAIResponses),
                model.copy(capabilities = listOf(ModelCapability.Text)),
            ),
        )
    }

    @Test
    fun `official raw capability and profile do not bypass evidence projection`() {
        val provider = Provider(id = "openai", kind = ProviderKind.OpenAI)
        val withCapabilityAndProfile = AIModel(
            id = "gpt",
            name = "GPT",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web),
            webSearchProfile = "oai_responses_web",
        )
        val withCapabilityOnly = withCapabilityAndProfile.copy(webSearchProfile = null)

        assertFalse(resolver.supportsWeb(provider, withCapabilityAndProfile))
        assertFalse(resolver.supportsWeb(provider, withCapabilityOnly))
    }

    @Test
    fun `normalized capability selection clamps unsupported reasoning and web search`() {
        val reasoningModel = AIModel(
            id = "reasoning",
            name = "Reasoning",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web),
            reasoningModeAvailable = true,
            webSearchProfile = "oai_responses_web",
        )
        val plainModel = AIModel(
            id = "plain",
            name = "Plain",
            capabilities = listOf(ModelCapability.Text),
            reasoningModeAvailable = false,
        )

        assertEquals(
            ChatModelCapabilityResolver.CapabilitySelection(
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
            ),
            resolver.normalizedCapabilitySelection(
                provider = Provider(id = "openai", kind = ProviderKind.OpenAI),
                model = reasoningModel,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = true,
            ),
        )
        assertEquals(
            ChatModelCapabilityResolver.CapabilitySelection(
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
            ),
            resolver.normalizedCapabilitySelection(
                provider = Provider(id = "openai", kind = ProviderKind.OpenAI),
                model = plainModel,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = true,
            ),
        )
    }

    @Test
    fun `metadata evidence cannot promote missing exact controls through legacy profiles`() {
        // Keep publication state local to this test: the resolver receives this client directly
        // and MetadataClient.instance is neither read nor mutated.
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"profiles":{"reasoning":{"reasoning":{"levels":["fast","deep"]}}},
             "providers":{"openAI":{"resolveMap":{"gpt":"gpt"},"models":{"gpt":{
               "canonicalModelId":"gpt","transport":"openai_chat",
               "profiles":{"reasoning":"reasoning","webSearch":"web"},
               "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[
                 {"key":"vision_input","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"},
                 {"key":"web_search","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"},
                 {"key":"reasoning_level/fast","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"},
                 {"key":"reasoning_level/deep","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"}
               ]}
             }}}}}
            """.trimIndent(),
            "etag-feature-chain",
        )
        val resolver = ChatModelCapabilityResolver(metadata = client)
        val provider = Provider(id = "openai", kind = ProviderKind.OpenAI)
        val model = AIModel(
            id = "gpt",
            name = "GPT",
            // Persisted catalog capabilities are stale/missing; the published evidence candidate
            // remains the sole governed authority for the image control.
            capabilities = listOf(ModelCapability.Text),
            reasoningProfile = "reasoning",
        )

        assertTrue(resolver.supportsImage(provider, model))
        assertFalse(resolver.supportsWeb(provider, model))
        assertEquals(
            listOf(ReasoningMode.Automatic),
            resolver.supportedReasoningModes(provider, model),
        )
    }

    @Test
    fun `reasoning normalization ignores current and stale legacy profiles without exact control`() {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"profiles":{"reasoning":{"current":{"levels":["fast"]}}},
             "providers":{"openAI":{"resolveMap":{"gpt":"gpt"},"models":{"gpt":{
               "canonicalModelId":"gpt","transport":"openai_chat",
               "profiles":{"reasoning":"current"},
               "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[
                 {"key":"reasoning_level/fast","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"},
                 {"key":"reasoning_level/deep","support":"supported","source":"server_profile","grade":"effect_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"gpt","transport":"openai_chat"}
               ]}
             }}}}}
            """.trimIndent(),
            "etag-current-profile",
        )
        val resolver = ChatModelCapabilityResolver(metadata = client)
        val stalePersistedModel = AIModel(
            id = "gpt",
            name = "GPT",
            reasoningProfile = "stale-profile-that-keeps-deep",
        )

        assertEquals(
            ReasoningMode.Automatic,
            resolver.normalizedCapabilitySelection(
                provider = Provider(id = "openai", kind = ProviderKind.OpenAI),
                model = stalePersistedModel,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
            ).reasoningMode,
        )
    }

    @Test
    fun `model controls require the exact final transport and preserve server state`() {
        val client = MetadataClient()
        // The shared registry is the production P3 compiler input. It proves that the UI is
        // reading the same runtime object rather than a hand-built presentation fixture.
        val registry = workspaceFile("shared/capabilityrecipe/capability_runtime.v1.json")
        val rawRuntime = registry.readText().trim().removeSuffix("}") +
            ",\"revision\":\"fixture-controls\",\"generatedAt\":\"2026-08-12T00:00:00Z\"}"
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"capabilityRuntime":$rawRuntime,"providers":{"openAI":{"resolveMap":{"gpt":"gpt"},"models":{"gpt":{
              "canonicalModelId":"gpt","transport":"openai_responses","capabilityControls":{
                "web":{"state":"auto_available","recipeRef":"openai.responses.web.v1","availableIntents":["force"]},
                "reasoning":{"state":"custom_only","reasonCode":"fixture_custom","sourceRefs":["openai.web_search"]},
                "generation":{"state":"unavailable","reasonCode":"fixture_unavailable","sourceRefs":["openai.web_search"]}
              }
            }}}}}
            """.trimIndent(),
            "etag-controls",
        )
        val resolver = ChatModelCapabilityResolver(metadata = client)
        val provider = Provider(id = "openai", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "gpt", name = "GPT")

        val exact = resolver.modelControls(provider, model, "openai_responses")
        assertTrue(exact.webAvailable)
        assertTrue(exact.webForceAvailable)
        assertEquals("custom_only", exact.reasoningState)
        assertEquals("fixture_custom", exact.reasoningReasonCode)
        assertEquals("unavailable", exact.generationState)

        val wrongCarrier = resolver.modelControls(provider, model, "openai_chat")
        assertFalse(wrongCarrier.webAvailable)
        assertEquals("unknown", wrongCarrier.webState)
    }

    @Test
    fun `unknown exact control never falls back to legacy tiers`() {
        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(
            """
            {"version":1,"profiles":{"reasoning":{"declared":{"levels":["fast","deep"]}}},
             "providers":{"openAI":{"resolveMap":{"silent":"silent","declared":"declared"},"models":{
               "silent":{"canonicalModelId":"silent","transport":"openai_chat",
                 "capabilityControls":{"reasoning":{"state":"unknown","reasonCode":"official_source_insufficient"}}},
               "declared":{"canonicalModelId":"declared","transport":"openai_chat",
                 "profiles":{"reasoning":"declared"},
                 "capabilityControls":{"reasoning":{"state":"unknown","reasonCode":"official_source_insufficient"}}}
             }}}}
            """.trimIndent(),
            "etag-legacy-reasoning",
        )
        val resolver = ChatModelCapabilityResolver(metadata = client)
        val provider = Provider(id = "openai", kind = ProviderKind.OpenAI)

        val silent = resolver.modelControls(provider, AIModel(id = "silent", name = "Silent"), "openai_chat")
        assertEquals(emptyList<String>(), silent.reasoningIntents)
        assertEquals("unknown", silent.reasoningState)

        val declared = resolver.modelControls(provider, AIModel(id = "declared", name = "Declared"), "openai_chat")
        assertEquals(emptyList<String>(), declared.reasoningIntents)
        assertEquals("unknown", declared.reasoningState)
    }

    private fun relayProvider(transport: RelayTransport): Provider = Provider(
        id = "relay",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        relayRequested = RelayRequestedConfig(
            transport = transport,
        ),
    )

    private fun workspaceFile(relativePath: String): File = generateSequence(
        File(System.getProperty("user.dir") ?: ".").absoluteFile,
    ) { it.parentFile }
        .map { File(it, relativePath) }
        .firstOrNull { it.isFile }
        ?: error("workspace file missing: $relativePath")
}
