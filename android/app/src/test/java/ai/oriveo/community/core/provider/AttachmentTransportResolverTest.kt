package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pre-send route resolution: one case per outbound route.
 *
 * Cases whose route depends on metadata go through [MetadataTestFixtures] and the production decode and publish boundary;
 * the Service calls the same verdict functions when sending, so what is measured here is the route that will actually be chosen.
 */
class AttachmentTransportResolverTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun model(id: String, vararg capabilities: ModelCapability = arrayOf(ModelCapability.Text)) =
        AIModel(id = id, name = id, capabilities = capabilities.toList())

    private fun provider(
        kind: ProviderKind,
        baseUrl: String? = null,
        authMode: ProviderAuthMode = ProviderAuthMode.ApiKey,
        relay: RelayTransport? = null,
    ) = Provider(
        id = "p-${kind.name}",
        kind = kind,
        apiKey = "key",
        baseUrlText = baseUrl,
        authMode = authMode,
        relayRequested = relay?.let { RelayRequestedConfig(transport = it) },
    )

    private fun resolve(
        provider: Provider,
        model: AIModel,
        web: Boolean = false,
        mode: ReasoningMode = ReasoningMode.Automatic,
    ) = AttachmentTransportResolver.resolve(provider, model, web, mode)

    private fun catalog(kind: ProviderKind, modelId: String, transport: String?) {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = kind,
                defaultModelId = modelId,
                resolveMap = mapOf(modelId to modelId),
                models = listOf(MetadataTestFixtures.ModelSpec(id = modelId, transport = transport)),
            ),
        )
    }

    // ── Relay: reads only the connection config ──

    @Test
    fun `relay chat completions and auto use the relay wrapper with the selected model`() {
        val m = model("local")
        for (transport in listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.Auto, null)) {
            assertEquals(
                AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.Relay), m),
                resolve(provider(ProviderKind.Relay, relay = transport), m),
            )
        }
    }

    @Test
    fun `relay llama cpp native folds everything into the prompt`() {
        val m = model("local")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.LlamaCppNative, m),
            resolve(provider(ProviderKind.Relay, relay = RelayTransport.LlamaCppNative), m),
        )
    }

    @Test
    fun `relay native protocols read the model from the matching official catalog`() {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{
              "openAI":{"resolveMap":{"gpt-x":"gpt-x"},"models":{"gpt-x":{"nativeFileMimes":["application/pdf"]}}},
              "anthropic":{"resolveMap":{},"models":{}},
              "gemini":{"resolveMap":{},"models":{}}
            }}""",
        )
        val responses = resolve(provider(ProviderKind.Relay, relay = RelayTransport.OpenAIResponses), model("gpt-x"))
        assertEquals(AttachmentTransportProfile.RelayOpenAIResponses, responses?.transport)
        assertEquals(listOf("application/pdf"), responses?.model?.nativeFileMimes)

        val anthropic = resolve(provider(ProviderKind.Relay, relay = RelayTransport.AnthropicMessages), model("unknown"))
        assertEquals(AttachmentTransportProfile.RelayAnthropicMessages, anthropic?.transport)
        assertNull("For a model missing from the catalog the builder gets no model either", anthropic?.model)

        val gemini = resolve(provider(ProviderKind.Relay, relay = RelayTransport.GeminiGenerateContent), model("unknown"))
        assertEquals(AttachmentTransportProfile.RelayGeminiGenerateContent, gemini?.transport)
    }

    @Test
    fun `relay native protocols cannot be resolved before metadata is loaded`() {
        MetadataTestFixtures.clear()
        assertNull(resolve(provider(ProviderKind.Relay, relay = RelayTransport.OpenAIResponses), model("gpt-x")))
        // A text-injection Relay route does not look at metadata.
        assertTrue(resolve(provider(ProviderKind.Relay, relay = RelayTransport.LlamaCppNative), model("x")) != null)
    }

    // ── Official OpenAI ──

    @Test
    fun `official openai defaults to responses and follows a catalog chat transport`() {
        catalog(ProviderKind.OpenAI, "gpt-r", transport = null)
        assertEquals(
            AttachmentTransportProfile.OpenAIResponses,
            resolve(provider(ProviderKind.OpenAI), model("gpt-r"))?.transport,
        )
        catalog(ProviderKind.OpenAI, "gpt-c", transport = "openai_chat")
        val chatModel = model("gpt-c")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.OpenAI), chatModel),
            resolve(provider(ProviderKind.OpenAI), chatModel),
        )
    }

    @Test
    fun `openai with a custom endpoint is chat completions without consulting metadata`() {
        MetadataTestFixtures.clear()
        val m = model("anything")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.OpenAI), m),
            resolve(provider(ProviderKind.OpenAI, baseUrl = "https://proxy.example/v1"), m),
        )
    }

    @Test
    fun `official openai cannot be resolved before metadata is loaded`() {
        MetadataTestFixtures.clear()
        assertNull(resolve(provider(ProviderKind.OpenAI), model("gpt-r")))
    }

    @Test
    fun `chatgpt subscription is locked to responses and uses the selected model`() {
        MetadataTestFixtures.clear()
        val m = model("gpt-codex")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.SubscriptionResponses, m),
            resolve(provider(ProviderKind.OpenAI, authMode = ProviderAuthMode.Subscription), m),
        )
    }

    // ── OpenAI compatible ──

    @Test
    fun `grok follows the catalog transport`() {
        catalog(ProviderKind.Grok, "grok-r", transport = "openai_responses")
        assertEquals(
            AttachmentTransportProfile.OpenAIResponses,
            resolve(provider(ProviderKind.Grok), model("grok-r"))?.transport,
        )
        catalog(ProviderKind.Grok, "grok-c", transport = "openai_chat")
        assertEquals(
            AttachmentTransportProfile.ChatCompletions(ProviderKind.Grok),
            resolve(provider(ProviderKind.Grok), model("grok-c"))?.transport,
        )
    }

    @Test
    fun `grok subscription follows the backend declared on the model`() {
        MetadataTestFixtures.clear()
        val subscription = provider(ProviderKind.Grok, authMode = ProviderAuthMode.Subscription)
        val responses = model("grok-sub").copy(upstreamApiBackend = "responses")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.SubscriptionResponses, responses),
            resolve(subscription, responses),
        )
        val chat = model("grok-sub").copy(upstreamApiBackend = "chat")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.Grok), chat),
            resolve(subscription, chat),
        )
    }

    @Test
    fun `deepseek folds attachments into string content`() {
        catalog(ProviderKind.DeepSeek, "deepseek-chat", transport = "openai_chat")
        val m = model("deepseek-chat")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.DeepSeekChat, m),
            resolve(provider(ProviderKind.DeepSeek), m),
        )
    }

    @Test
    fun `plain openai compatible providers are chat completions under their own wrapper`() {
        for (kind in listOf(
            ProviderKind.Groq, ProviderKind.Together, ProviderKind.Fireworks, ProviderKind.Zhipu,
            ProviderKind.Mistral, ProviderKind.SiliconFlow,
        )) {
            catalog(kind, "m", transport = "openai_chat")
            assertEquals(
                kind.name,
                AttachmentTransportProfile.ChatCompletions(kind),
                resolve(provider(kind), model("m"))?.transport,
            )
        }
    }

    @Test
    fun `qwen and openrouter never leave chat completions`() {
        MetadataTestFixtures.clear()
        for (kind in listOf(ProviderKind.Qwen, ProviderKind.OpenRouter)) {
            val m = model("m")
            assertEquals(
                kind.name,
                AttachmentTransportResolver.Route(AttachmentTransportResolver.chatCompletions(kind), m),
                resolve(provider(kind), m),
            )
        }
    }

    @Test
    fun `moonshot web search runs the tool loop over chat completions`() {
        catalog(ProviderKind.Moonshot, "kimi", transport = "openai_chat")
        val m = model("kimi")
        val expected = AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.Moonshot), m)
        assertEquals(expected, resolve(provider(ProviderKind.Moonshot), m, web = true))
        assertEquals(expected, resolve(provider(ProviderKind.Moonshot), m, web = false))
    }

    // ── Anthropic / Gemini / MiniMax ──

    @Test
    fun `anthropic is messages with the catalog model`() {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"claude-x":"claude-x"},
               "models":{"claude-x":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        val route = resolve(provider(ProviderKind.Anthropic), model("claude-x"))
        assertEquals(AttachmentTransportProfile.AnthropicMessages, route?.transport)
        assertEquals(listOf("application/pdf"), route?.model?.nativeFileMimes)
        assertEquals(true, route?.model?.pdfNativeDefault)
    }

    @Test
    fun `gemini is generateContent unless the web recipe routes to interactions`() {
        applyGeminiInteractionsFixture()
        val m = model("gemini-3-flash")
        assertEquals(
            AttachmentTransportProfile.GeminiGenerateContent,
            resolve(provider(ProviderKind.Gemini), m, web = false)?.transport,
        )
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.GeminiInteractions, m),
            resolve(provider(ProviderKind.Gemini), m, web = true),
        )
        // Outbound dispatch asks the same function.
        assertTrue(GeminiService.interactionsRoute("gemini-3-flash", true, ReasoningMode.Automatic) != null)
        assertNull(GeminiService.interactionsRoute("gemini-3-flash", false, ReasoningMode.Automatic))
    }

    @Test
    fun `minimax is chat completions unless the web recipe routes to the anthropic endpoint`() {
        applyMiniMaxWebFixture()
        val m = model("MiniMax-M3")
        assertEquals(
            AttachmentTransportResolver.Route(AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax), m),
            resolve(provider(ProviderKind.MiniMax), m, web = false),
        )
        assertEquals(
            AttachmentTransportProfile.MiniMaxAnthropicMessages,
            resolve(provider(ProviderKind.MiniMax), m, web = true)?.transport,
        )
        // A model without a web search recipe stays on Chat Completions even with web search on.
        assertEquals(
            AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax),
            resolve(provider(ProviderKind.MiniMax), model("MiniMax-M2"), web = true)?.transport,
        )
    }

    // ── Route from this turn's actual options ──

    @Test
    fun `routes for the actual send options are one transport plus the tool loop leg only when it may run`() {
        applyGeminiInteractionsFixture()
        val m = model("gemini-3-flash")
        val gemini = provider(ProviderKind.Gemini)
        fun transports(web: Boolean, toolLoop: Boolean) =
            AttachmentTransportResolver.routesFor(gemini, m, web, ReasoningMode.Automatic, toolLoop)!!.map { it.transport }

        assertEquals(listOf<AttachmentTransportProfile>(AttachmentTransportProfile.GeminiInteractions), transports(web = true, toolLoop = false))
        assertEquals(listOf<AttachmentTransportProfile>(AttachmentTransportProfile.GeminiGenerateContent), transports(web = false, toolLoop = false))
        assertEquals(
            listOf(AttachmentTransportProfile.GeminiGenerateContent, AttachmentTransportProfile.ChatCompletions(ProviderKind.Gemini)),
            transports(web = false, toolLoop = true),
        )
        // An unresolvable route is still null.
        MetadataTestFixtures.clear()
        assertNull(AttachmentTransportResolver.routesFor(gemini, m, false, ReasoningMode.Automatic, false))
    }

    /**
     * The same two files: without web search the PDF goes up natively through generateContent and fits; with web search it goes through Interactions,
     * can only send text, and does not fit. Knowing this turn's options, the send should be blocked up front instead of letting it through because "another route fits" and ending on a failure card.
     */
    @Test
    fun `preflight with the actual send options blocks what only another route could have fit`() {
        applyGeminiInteractionsFixture(nativePdf = true)
        val m = model("gemini-3-flash")
        val gemini = provider(ProviderKind.Gemini)
        fun textFile(name: String) = ai.oriveo.community.core.model.Attachment(
            id = name, kind = ai.oriveo.community.core.model.AttachmentKind.File, fileName = name, mimeType = "text/plain",
            base64Data = java.util.Base64.getEncoder().encodeToString("x".repeat(150 * 1024).toByteArray()),
        )
        val pdf = textFile("paper.pdf").copy(mimeType = "application/pdf", originalBase64Data = "JVBERi0=", extractedSizeBytes = 8)
        val files = listOf(textFile("a.txt"), pdf)
        fun preflight(options: AttachmentSendPreflight.SendOptions?) =
            AttachmentSendPreflight.undeliverable(gemini, m, "read", files, options)

        // Options unknown: do not block as long as one possible route fits (kept for entry points that cannot obtain the options).
        assertNull(preflight(null))
        assertNull(preflight(AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = false, toolLoopPossible = false)))
        assertEquals(
            ai.oriveo.community.core.model.ProviderServiceError.AttachmentTextOverLimit(listOf("paper.pdf")),
            preflight(AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = true, toolLoopPossible = false)),
        )
        // When the tool loop may take over, the leg route still counts as a possibility: block only if both fail to fit.
        assertNull(preflight(AttachmentSendPreflight.SendOptions(ReasoningMode.Automatic, webSearchEnabled = false, toolLoopPossible = true)))
    }

    // ── Cases that cannot be decided ──

    @Test
    fun `image generation models are never resolved`() {
        val m = model("img", ModelCapability.Text, ModelCapability.ImageGen)
        assertNull(resolve(provider(ProviderKind.OpenRouter), m))
        assertNull(resolve(provider(ProviderKind.Relay, relay = RelayTransport.OpenAIChatCompletions), m))
        assertNull(AttachmentTransportResolver.possibleRoutes(provider(ProviderKind.OpenRouter), m))
    }

    @Test
    fun `possible routes cover every request option and the tool loop leg`() {
        applyGeminiInteractionsFixture()
        val m = model("gemini-3-flash")
        val routes = AttachmentTransportResolver.possibleRoutes(provider(ProviderKind.Gemini), m)!!
        assertEquals(
            setOf(
                AttachmentTransportProfile.GeminiGenerateContent,
                AttachmentTransportProfile.GeminiInteractions,
                AttachmentTransportProfile.ChatCompletions(ProviderKind.Gemini),
            ),
            routes.map { it.transport }.toSet(),
        )
        MetadataTestFixtures.clear()
        assertNull(AttachmentTransportResolver.possibleRoutes(provider(ProviderKind.Gemini), m))
    }

    // ── The verdicts the Service uses outbound ──

    @Test
    fun `openai compatible transport keeps the subscription lock ahead of the catalog`() {
        val f = AttachmentTransportResolver::openAICompatibleTransport
        assertEquals(TransportKindAlias.Responses, f("openai_responses", "openai_chat"))
        assertEquals(TransportKindAlias.Chat, f("openai_chat", "openai_responses"))
        assertEquals(TransportKindAlias.Responses, f(null, "openai_responses"))
        assertEquals(TransportKindAlias.Chat, f(null, null))
        assertEquals(TransportKindAlias.Chat, f(null, "something_new"))
    }

    @Test
    fun `relay transport treats auto and missing config as chat completions`() {
        assertEquals(RelayTransport.OpenAIChatCompletions, AttachmentTransportResolver.relayTransport(null))
        assertEquals(
            RelayTransport.OpenAIChatCompletions,
            AttachmentTransportResolver.relayTransport(RelayRequestedConfig(transport = RelayTransport.Auto)),
        )
        assertEquals(
            RelayTransport.LlamaCppNative,
            AttachmentTransportResolver.relayTransport(RelayRequestedConfig(transport = RelayTransport.LlamaCppNative)),
        )
    }

    private object TransportKindAlias {
        val Responses = ai.oriveo.community.core.provider.transport.TransportKind.OpenAIResponses
        val Chat = ai.oriveo.community.core.provider.transport.TransportKind.OpenAIChat
    }

    private fun applyGeminiInteractionsFixture(nativePdf: Boolean = false) {
        val native = if (nativePdf) """"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true,""" else ""
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val registry = Json.parseToJsonElement(
            File(root, "shared/capabilityrecipe/capability_runtime.v1.json").readText(),
        ).jsonObject
        val runtime = JsonObject(
            registry + mapOf(
                "revision" to JsonPrimitive("sha256:resolver-test"),
                "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
            ),
        )
        MetadataTestFixtures.applyRaw(
            """{"version":1,"capabilityRuntime":$runtime,"providers":{"gemini":{
              "resolveMap":{"gemini-3-flash":"gemini-3-flash"},
              "models":{"gemini-3-flash":{$native"transport":"gemini_generate",
                "capabilityControls":{"web":{"state":"auto_available","recipeRef":"gemini.interactions.web.v1"}}}}}}}""",
        )
    }

    private fun applyMiniMaxWebFixture() {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version":1,
              "providers":{"miniMax":{"resolveMap":{"MiniMax-M3":"MiniMax-M3","MiniMax-M2":"MiniMax-M2"},"models":{
                "MiniMax-M3":{"canonicalModelId":"MiniMax-M3","transport":"openai_chat","capabilities":["text","web"],"capabilityControls":{"web":{"state":"auto_available","recipeRef":"minimax.messages.web.v1"}}},
                "MiniMax-M2":{"canonicalModelId":"MiniMax-M2","transport":"openai_chat","capabilities":["text"],"capabilityControls":{"web":{"state":"unknown","reasonCode":"model_capability_absent"}}}
              }}},
              "capabilityRuntime":{"schemaVersion":2,"revision":"minimax-web-test","generatedAt":"2026-08-23T00:00:00Z","controlDefinitions":{},
                "sourceIndex":{"minimax.server_tools":{"kind":"official_doc","url":"https://platform.minimax.io/docs/guides/server-tools","reviewedAt":"2026-08-23"}},
                "recipes":{"minimax.messages.web.v1":{"id":"minimax.messages.web.v1","providerKind":"miniMax","transport":{"protocol":"openai_chat"},"capability":"web","executionKind":"endpoint_route","requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"web_search_20250305","name":"web_search"}}],"route":{"sourceProtocol":"openai_chat","protocol":"anthropic_messages","endpointClass":"messages","path":"/anthropic/v1/messages","method":"POST","authMode":"x_api_key","authHeader":"x-api-key","headers":{"Content-Type":"application/json","anthropic-version":"2023-06-01"},"requestMapper":"minimax_anthropic_messages_v1"},"responseParserKind":"minimax_anthropic_web_v1","continuationKind":"replay_blocks","fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["minimax.server_tools"]}}
              }
            }
            """.trimIndent(),
        )
    }
}
