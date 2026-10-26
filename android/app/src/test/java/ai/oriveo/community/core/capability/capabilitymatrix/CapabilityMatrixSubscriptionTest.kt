package ai.oriveo.community.core.capability.capabilitymatrix

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.attachments.NativeFileFallback
import ai.oriveo.community.core.attachments.NativeFileMode
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.AttachmentTransportResolver
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.SiliconFlowService
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRequestContext
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRuntime
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRequestContext
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRuntime
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.Capability
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import java.io.File
import java.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Capability matrix: subscription form (CAP-SUB-*).
 *
 * Upstream `/models` always comes from the cross-platform fixture `subscription-models.v1.json`, handed through MockEngine to the production
 * `ProviderRepository.registerProvider` (production decoding of the subscription client plus catalog mapping); the request context comes from the
 * production `prepare*Subscription`; outbound goes through the production `GrokService` / `OpenAIService`,
 * and MockEngine captures the request bodies.
 */
class CapabilityMatrixSubscriptionTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture by lazy { readJson("shared/test-fixtures/provider-catalog/subscription-models.v1.json") }
    private val expected by lazy { fixture.getValue("expected").jsonObject }

    @Before
    fun setUp() {
        MetadataTestFixtures.applyRaw(METADATA)
        NativeFileFallback.resetForTest()
    }

    @After
    fun tearDown() {
        NativeFileFallback.resetForTest()
        MetadataTestFixtures.clear()
    }

    // ── WEB ──

    @Test
    fun CAP_SUB_WEB_01_codex_web_follows_the_preference() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.codexProvider()
        val sol = provider.model(SOL)
        val solExpected = expected.getValue(SOL).jsonObject.getValue("web").jsonObject
        val verdict = CapabilityControlResolution.resolve(provider, sol, "web")
        assertEquals(solExpected.string("state"), verdict.state)
        assertEquals(solExpected.strings("intents"), verdict.intents)
        assertEquals(solExpected.string("reasonCode"), verdict.reasonCode)
        assertEquals(
            CapabilityControlPresentation.AutomaticAvailable,
            CapabilityControlPresentationResolver.presentation(provider, sol, "web"),
        )
        // Codex is still a switch.
        assertEquals(ModelOptionCapabilityShape.Toggle(isOn = false), shape(provider, sol, Capability.Web, selectedIntent = "off"))

        harness.sendCodex(provider, sol, webSearchEnabled = false)
        harness.sendCodex(provider, sol, webSearchEnabled = true)

        val (off, on) = harness.bodies.map { json.parseToJsonElement(it).jsonObject }
        assertFalse("web_search must not be sent when the preference is off: $off", off.webSearchTool())
        assertTrue("web_search must be sent when the preference is on: $on", on.webSearchTool())
    }

    @Test
    fun CAP_SUB_WEB_02_grok_web_is_an_always_on_notice_and_always_sends_web_search() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.grokProvider()
        val grok = provider.model(GROK)
        val grokExpected = expected.getValue(GROK).jsonObject
        val web = grokExpected.getValue("web").jsonObject

        val verdict = CapabilityControlResolution.resolve(provider, grok, "web")
        assertEquals(web.string("state"), verdict.state)
        assertEquals(web.strings("intents"), verdict.intents)
        assertEquals(web.string("reasonCode"), verdict.reasonCode)
        val presentation = CapabilityControlPresentationResolver.presentation(provider, grok, "web")
        assertEquals(CapabilityControlPresentation.AlwaysOn, presentation)
        assertFalse(presentation.isConfigurable)

        // The same holds when "off" was stored: a read-only notice, not tappable, no chevron, and the stored value is not rewritten.
        val shape = shape(provider, grok, Capability.Web, selectedIntent = "off")
        assertEquals(
            ModelOptionCapabilityShape.Notice(
                ModelOptionCapabilityShape.NoticeStatus.AlwaysOn,
                ModelOptionCapabilityShape.NoticeBody.SubscriptionAlwaysSearches,
                escape = null,
            ),
            shape,
        )
        val tile = ModelOptionsTiles.capabilityTile(Capability.Web, shape)
        assertEquals(R.string.model_options_always_on, tile.statusRes)
        assertEquals(R.string.model_options_subscription_always_searches, tile.bodyRes)
        assertFalse(tile.tappable)
        assertEquals(ModelOptionsTiles.Corner.None, tile.corner)
        val row = grokExpected.getValue("webRow").jsonObject
        assertEquals(row.string("status"), englishString("model_options_always_on"))
        assertEquals(row.string("body"), englishString("model_options_subscription_always_searches"))
        // It is not the user's choice: it does not count as actually sent this turn.
        assertTrue(ModelOptionsTiles.summary(shape, ModelOptionCapabilityShape.Disclosure(
            ModelOptionCapabilityShape.DisclosureStatus.FixedLevel,
        )).isEmpty())

        // Grok on the Chat backend still cannot search the web.
        val chat = provider.model(GROK_CHAT)
        val chatWeb = expected.getValue(GROK_CHAT).jsonObject.getValue("web").jsonObject
        val chatVerdict = CapabilityControlResolution.resolve(provider, chat, "web")
        assertEquals(chatWeb.string("state"), chatVerdict.state)
        assertEquals(chatWeb.string("reasonCode"), chatVerdict.reasonCode)

        harness.sendGrok(provider, grok, webSearchEnabled = false)
        val body = json.parseToJsonElement(harness.bodies.single()).jsonObject
        assertEquals(
            grokExpected.getValue("outboundToolsWithWebPreferenceOff").jsonArray.map { it.jsonObject.string("type") },
            body.getValue("tools").jsonArray.map { it.jsonObject.string("type") },
        )
    }

    // ── REASON ──

    @Test
    fun CAP_SUB_REASON_01_codex_intents_and_effort_mapping_follow_the_declaration() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.codexProvider()
        val sol = provider.model(SOL)
        val solExpected = expected.getValue(SOL).jsonObject
        assertEquals(
            solExpected.strings("reasoningIntents"),
            CapabilityControlResolution.resolve(provider, sol, "reasoning").intents,
        )

        harness.sendCodex(provider, sol, reasoningMode = ReasoningMode.fromIntent("balanced"))
        harness.sendCodex(provider, sol, reasoningMode = ReasoningMode.fromIntent("max"))

        val mapping = solExpected.getValue("effortForIntent").jsonObject
        val (balanced, max) = harness.bodies.map { json.parseToJsonElement(it).jsonObject.effort() }
        assertEquals(mapping.string("balanced"), balanced)
        assertEquals(mapping.string("max"), max)
    }

    @Test
    fun CAP_SUB_REASON_02_codex_automatic_sends_no_effort() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.codexProvider()
        val sol = provider.model(SOL)
        assertTrue(expected.getValue(SOL).jsonObject.getValue("automaticEffort").let { it is kotlinx.serialization.json.JsonNull })

        harness.sendCodex(provider, sol, reasoningMode = ReasoningMode.Automatic)

        val body = json.parseToJsonElement(harness.bodies.single()).jsonObject
        assertNull("the automatic tier must not carry reasoning.effort: $body", body.effort())
    }

    /** Grok subscription automatic tier sends only the tier that upstream `/models` marks as default. */
    @Test
    fun SUB_REASON_grok_automatic_sends_declared_default() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.grokProvider()
        val grok = provider.model(GROK)

        harness.sendGrok(provider, grok)

        val body = json.parseToJsonElement(harness.bodies.single()).jsonObject
        assertEquals(expected.getValue(GROK).jsonObject.string("automaticEffort"), body.effort())
    }

    // ── ATTACH ──

    @Test
    fun CAP_SUB_ATTACH_01_grok_responses_line_sends_input_file() = runTest {
        val harness = SubscriptionHarness()
        val provider = harness.grokProvider()
        val grok = provider.model(GROK).withNativePdf()
        val line = expected.getValue(GROK).jsonObject.getValue("fileLine").jsonObject

        val route = AttachmentTransportResolver.resolve(provider, grok, webSearchEnabled = false, reasoningMode = ReasoningMode.Automatic)
        assertEquals(AttachmentTransportProfile.SubscriptionResponses, route?.transport)
        assertTrue(route!!.transport.hasNativeFileBlocks)
        assertEquals(NativeFileMode.AlwaysWithTextFallback, route.transport.nativeFiles)
        assertEquals("alwaysWithTextFallback", line.string("nativeFiles"))

        harness.sendGrok(provider, grok, attachment = textPdf())

        val body = harness.bodies.single()
        assertTrue("the first request must carry ${line.string("nativeFileBlock")}; body: $body", body.contains("\"${line.string("nativeFileBlock")}\""))
    }

    @Test
    fun CAP_SUB_ATTACH_02_rejected_input_file_is_resent_once_as_text() = runTest {
        val harness = SubscriptionHarness(grokStatuses = listOf(400))
        val provider = harness.grokProvider()
        val grok = provider.model(GROK).withNativePdf()

        val events = harness.sendGrok(provider, grok, attachment = textPdf())

        assertTrue("the text resend must succeed: $events", events.last() is StreamEvent.Done)
        assertEquals(2, harness.bodies.size)
        assertTrue(harness.bodies[0], harness.bodies[0].contains("\"input_file\""))
        assertFalse("the resend must not carry the file block again: ${harness.bodies[1]}", harness.bodies[1].contains("\"input_file\""))
        assertTrue(harness.bodies[1], harness.bodies[1].contains(EXTRACTED))
    }

    // ── harness ──

    /**
     * Registers the subscription instance through the production ProviderRepository (/models is answered from the fixture by MockEngine); outbound services share one
     * MockEngine that captures request bodies. [grokStatuses] gives status codes in outbound request order; once used up, always 200.
     */
    private inner class SubscriptionHarness(private val grokStatuses: List<Int> = emptyList()) {
        val bodies = mutableListOf<String>()
        private val credentials = mutableMapOf<String, String>()
        private val secureKeyStore = mockk<SecureKeyStore>()
        private val dao = mockk<ProviderDao>()
        val repository: ProviderRepository

        private val upstream = HttpClient(
            MockEngine { request ->
                bodies += when (val body = request.body) {
                    is TextContent -> body.text
                    is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
                    else -> error("unexpected request body ${body::class}")
                }
                val status = grokStatuses.getOrNull(bodies.size - 1) ?: 200
                if (status == 200) {
                    respond(RESPONSES_SSE, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                } else {
                    respond(
                        """{"error":{"message":"input_file is not supported"}}""",
                        HttpStatusCode.fromValue(status),
                        headersOf(HttpHeaders.ContentType, "application/json"),
                    )
                }
            },
        )

        init {
            coEvery { dao.getAll(any()) } returns emptyList()
            coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
            every { secureKeyStore.saveApiKey(any(), any(), any()) } returns Unit
            every { secureKeyStore.beginCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg", "ce")
            val payload = slot<String>()
            val savedId = slot<String>()
            every { secureKeyStore.saveSubscriptionCredential(any(), capture(savedId), capture(payload)) } answers {
                credentials[savedId.captured] = payload.captured
            }
            every { secureKeyStore.loadSubscriptionCredential(any(), any()) } answers { credentials[secondArg()] }
            val persisted = mutableMapOf<String, ProviderEntity>()
            coEvery { dao.getById(any(), any()) } answers { persisted[secondArg()] }
            coEvery { dao.upsert(any()) } answers { firstArg<ProviderEntity>().let { persisted[it.id] = it } }
            repository = ProviderRepository(
                dao = dao,
                secureKeyStore = secureKeyStore,
                openRouterService = mockk<OpenRouterService>(),
                openAIService = mockk<OpenAIService>(),
                deepSeekService = mockk<DeepSeekService>(),
                grokService = mockk<GrokService>(),
                anthropicService = mockk<AnthropicService>(),
                geminiService = mockk<GeminiService>(),
                groqService = mockk<GroqService>(),
                togetherService = mockk<TogetherService>(),
                fireworksService = mockk<FireworksService>(),
                miniMaxService = mockk<MiniMaxService>(),
                zhipuService = mockk<ZhipuService>(),
                qwenService = mockk<QwenService>(),
                moonshotService = mockk<MoonshotService>(),
                mistralService = mockk<MistralService>(),
                siliconFlowService = mockk<SiliconFlowService>(),
                relayService = mockk<RelayService>(),
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(
                    MockEngine { request ->
                        val models = when {
                            request.url.toString().startsWith(GROK_MODELS_URL) -> fixture.getValue("grok_models")
                            request.url.toString().startsWith(CODEX_MODELS_URL) -> fixture.getValue("codex_models")
                            else -> error("unexpected catalog request ${request.url}")
                        }
                        respond(models.toString(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
                    },
                ),
            )
        }

        suspend fun grokProvider(): Provider = repository.registerProvider(
            kind = ProviderKind.Grok,
            apiKey = "grok-access",
            baseUrl = "https://api.x.ai/v1",
            authMode = ProviderAuthMode.Subscription,
            subscriptionTokens = GrokSubscriptionTokens(
                accessToken = "grok-access",
                refreshToken = "grok-refresh",
                expiresAt = System.currentTimeMillis() + 6 * 3600 * 1000L,
            ),
        )

        suspend fun codexProvider(): Provider = repository.registerProvider(
            kind = ProviderKind.OpenAI,
            apiKey = "codex-access",
            authMode = ProviderAuthMode.Subscription,
            openAISubscriptionTokens = OpenAISubscriptionTokens(
                accessToken = "codex-access",
                expiresAt = System.currentTimeMillis() + 6 * 3600 * 1000L,
                accountId = "acct-1",
            ),
        )

        /** Production prepare, plus the same "final transport by model" step ChatRepository uses. */
        private suspend fun grokContext(provider: Provider, model: AIModel): GrokSubscriptionRequestContext {
            val prepared = repository.prepareGrokSubscription(provider.id) as GrokSubscriptionRuntime.PrepareResult.Success
            return prepared.prepared.context.withTransport(
                requireNotNull(CapabilityControlResolution.subscriptionFinalTransport(provider, model)),
            )
        }

        private suspend fun codexContext(provider: Provider): OpenAISubscriptionRequestContext {
            val prepared = repository.prepareOpenAISubscription(provider.id) as OpenAISubscriptionRuntime.PrepareResult.Success
            return prepared.prepared.context
        }

        suspend fun sendGrok(
            provider: Provider,
            model: AIModel,
            webSearchEnabled: Boolean = false,
            attachment: Attachment? = null,
        ): List<StreamEvent> = GrokService(upstream, json, TransportRegistry(json)).sendMessageStream(
            apiKey = "grok-access",
            modelID = model.id,
            messages = listOf(userMessage(ProviderKind.Grok, model.id, attachment)),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = webSearchEnabled,
            requestOptions = ChatRequestOptions(grokSubscription = grokContext(provider, model), activeModel = model),
        ).toList()

        suspend fun sendCodex(
            provider: Provider,
            model: AIModel,
            webSearchEnabled: Boolean = false,
            reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        ): List<StreamEvent> = OpenAIService(client = upstream, json = json, transportRegistry = TransportRegistry(json))
            .sendMessageStream(
                apiKey = "codex-access",
                modelID = model.id,
                messages = listOf(userMessage(ProviderKind.OpenAI, model.id, null)),
                reasoningMode = reasoningMode,
                webSearchEnabled = webSearchEnabled,
                requestOptions = ChatRequestOptions(openAISubscription = codexContext(provider), activeModel = model),
            ).toList()
    }

    // ── helpers ──

    /** Production verdict -> presentation -> shape function; a subscription connection counts as an ordinary, writable connection, same as the panel. */
    private fun shape(
        provider: Provider,
        model: AIModel,
        capability: Capability,
        selectedIntent: String?,
    ): ModelOptionCapabilityShape {
        val key = if (capability == Capability.Web) "web" else "reasoning"
        return ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = capability,
                presentation = CapabilityControlPresentationResolver.presentation(provider, model, key),
                availableIntents = CapabilityControlResolution.resolve(provider, model, key).intents,
                selectedIntent = selectedIntent,
                connection = ModelOptionsPanelInput.connectionCategory(provider.kind),
                isWritable = true,
            ),
        )
    }

    /** The two ATTACH cases explicitly set a native PDF allowlist on the model in the test (the production path does not produce it). */
    private fun AIModel.withNativePdf(): AIModel = copy(nativeFileMimes = listOf(PDF), pdfNativeDefault = true)

    private fun textPdf() = Attachment(
        id = "text-pdf",
        kind = AttachmentKind.File,
        fileName = "report.pdf",
        mimeType = PDF,
        base64Data = Base64.getEncoder().encodeToString(EXTRACTED.toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = Base64.getEncoder().encodeToString("%PDF-1.7 original".toByteArray()),
    )

    private fun userMessage(kind: ProviderKind, modelId: String, attachment: Attachment?) = ChatMessage(
        id = "user-1",
        role = ChatRole.User,
        text = "hello",
        providerKind = kind,
        providerName = kind.rawValue,
        modelID = modelId,
        modelName = modelId,
        state = ChatMessageState.Delivered,
        attachments = attachment?.let(::listOf),
    )

    private fun Provider.model(id: String): AIModel = models.single { it.id == id }

    private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.contentOrNull

    private fun JsonObject.strings(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.webSearchTool(): Boolean =
        get("tools")?.jsonArray?.any { it.jsonObject.string("type") == "web_search" } == true

    private fun JsonObject.effort(): String? = (get("reasoning") as? JsonObject)?.string("effort")

    /** Verbatim English source string: read res/values/strings.xml directly (unit tests have no resource table). */
    private fun englishString(name: String): String? {
        val xml = File(repoRoot(), "android/app/src/main/res/values/strings.xml").readText()
        return Regex("""<string name="$name">(.*?)</string>""").find(xml)?.groupValues?.get(1)
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    private companion object {
        const val ACCOUNT = "test-account"
        const val GROK = "grok-4.6"
        const val GROK_CHAT = "grok-4.6-chat"
        const val SOL = "gpt-5.6-sol"
        const val PDF = "application/pdf"
        const val EXTRACTED = "Quarterly plan extracted text"
        const val GROK_MODELS_URL = "https://cli-chat-proxy.grok.com/v1/models"
        const val CODEX_MODELS_URL = "https://chatgpt.com/backend-api/codex/models"

        val RESPONSES_SSE = buildString {
            append("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n")
            append("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}\n\n")
            append("data: [DONE]\n\n")
        }

        /** The providerConfigs section for the two subscription logins (same shape as production `/api/metadata`). */
        val METADATA = """
        {
          "version": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "grok",
              "displayName": "Grok",
              "defaultBaseURL": "https://api.x.ai/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "enabled": true,
                  "flow": "oauth_device_code",
                  "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
                  "scopes": "openid profile email offline_access grok-cli:access api:access",
                  "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                  "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                  "revocationEndpoint": "https://auth.x.ai/oauth2/revoke",
                  "trustedAuthHosts": ["auth.x.ai"],
                  "trustedVerificationHosts": ["accounts.x.ai", "x.ai"],
                  "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
                  "requiredHeaders": {"x-grok-client-version": "1.0.4"},
                  "modelsPath": "/models",
                  "chatPath": "/chat/completions"
                }
              }
            },
            {
              "kind": "openAI",
              "displayName": "OpenAI",
              "defaultBaseURL": "https://api.openai.com/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "chatPath": "/responses",
                  "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
                  "deviceAuthorizationEndpoint": "https://auth.openai.com/api/accounts/deviceauth/usercode",
                  "deviceTokenEndpoint": "https://auth.openai.com/api/accounts/deviceauth/token",
                  "disabledNotice": null,
                  "enabled": true,
                  "flow": "codex_device_code",
                  "minAppVersion": {"ios":"1.2.6"},
                  "modelsPath": "/models",
                  "pollIntervalSeconds": 5,
                  "pollTimeoutSeconds": 900,
                  "redirectURI": "https://auth.openai.com/deviceauth/callback",
                  "requiredHeaders": {"OpenAI-Beta": "responses=experimental", "originator": "oriveo", "version": "0.148.0"},
                  "resourceBaseURL": "https://chatgpt.com/backend-api/codex",
                  "tokenEndpoint": "https://auth.openai.com/oauth/token",
                  "trustedAuthHosts": ["auth.openai.com"],
                  "trustedVerificationHosts": ["auth.openai.com"],
                  "verificationURL": "https://auth.openai.com/codex/device"
                }
              }
            }
          ]
        }
        """.trimIndent()
    }
}
