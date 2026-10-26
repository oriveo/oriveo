package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.AnthropicService
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
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.HttpRequestData
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import io.ktor.utils.io.ByteReadChannel
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Relay 2.0 (Android): the choke point dispatches per model, official providers dispatch by the delivered apiProtocol, and the trust table reads the delivered value.
 *
 * All outbound traffic goes through the production `ProviderRepository.serviceFor(provider, model)` -> real service / RelayService ->
 * the request builder of RelayTransportCoordinator, captured at the Ktor MockEngine seam (the same capture point as RL2-MIGRATE-01).
 */
class RelayU5ChokeAndTrustTest {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        coerceInputValues = true
    }
    private val captured = mutableListOf<Pair<HttpRequestData, String>>()
    private val client = HttpClient(
        MockEngine { request ->
            val body = String(request.body.toByteArray(), Charsets.UTF_8)
            synchronized(captured) { captured += request to body }
            respond(
                content = ByteReadChannel("data: [DONE]\n\n"),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        },
    ) {
        install(ContentNegotiation) { json(json) }
    }
    private val transportRegistry = TransportRegistry(json)
    private lateinit var repository: ProviderRepository

    @Before
    fun setUp() {
        MetadataTestFixtures.clear()
        repository = ProviderRepository(
            dao = mockk(relaxed = true),
            secureKeyStore = mockk(relaxed = true),
            openRouterService = OpenRouterService(client, json, transportRegistry),
            openAIService = OpenAIService(client, json, transportRegistry),
            deepSeekService = DeepSeekService(client, json),
            grokService = GrokService(client, json, transportRegistry),
            anthropicService = AnthropicService(client, json, transportRegistry),
            geminiService = GeminiService(client, json, transportRegistry),
            groqService = GroqService(client, json),
            togetherService = TogetherService(client, json),
            fireworksService = FireworksService(client, json),
            miniMaxService = MiniMaxService(client, json),
            zhipuService = ZhipuService(client, json, transportRegistry),
            qwenService = QwenService(client, json, transportRegistry),
            moonshotService = MoonshotService(client, json, transportRegistry),
            mistralService = MistralService(client, json, transportRegistry),
            siliconFlowService = SiliconFlowService(client, json),
            relayService = RelayService(client, json, transportRegistry),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = client,
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        client.close()
    }

    private class Captured(val url: String, val headers: Map<String, String>, val body: JsonObject)

    private fun send(provider: Provider, model: AIModel): Captured {
        val base = ChatRequestOptions(systemPrompt = "You are terse.", activeModel = model)
        val options = if (provider.kind == ProviderKind.Relay) base.copy(relayRequested = provider.relayRequested) else base
        synchronized(captured) { captured.clear() }
        runCatching {
            runBlocking {
                withTimeout(15_000) {
                    repository.serviceFor(provider, model).sendMessageStream(
                        apiKey = provider.apiKey,
                        modelID = model.id,
                        messages = listOf(
                            ChatMessage(
                                id = "u5-msg",
                                role = ChatRole.User,
                                text = "Hello",
                                providerKind = provider.kind,
                                providerName = provider.kind.displayName,
                                modelID = model.id,
                                modelName = model.id,
                                state = ChatMessageState.Delivered,
                            ),
                        ),
                        baseUrl = provider.baseUrlText,
                        supportsImageGen = false,
                        reasoningMode = ReasoningMode.Automatic,
                        webSearchEnabled = false,
                        requestOptions = options,
                    ).collect { }
                }
            }
        }
        val (request, body) = synchronized(captured) { captured.firstOrNull() }
            ?: error("no request issued for ${model.id}")
        val headers = request.headers.entries().associate { (name, values) -> name.lowercase() to values.joinToString(", ") }
        return Captured(request.url.toString(), headers, json.parseToJsonElement(body).jsonObject)
    }

    // ── A: two models under one connection go out with their own transports ─────────────────────────────

    @Test
    fun `RL2_RESOLVE_03 one connection sends Messages and Chat bodies for two models`() {
        val messagesModel = AIModel(
            id = "claude-like",
            name = "claude-like",
            relayTransport = RelayTransport.AnthropicMessages,
            relayTransportSource = RelayTransportSource.User,
        )
        val chatModel = AIModel(id = "gpt-like", name = "gpt-like")
        val provider = Provider(
            id = "u5-relay",
            kind = ProviderKind.Relay,
            models = listOf(messagesModel, chatModel),
            apiKey = "sk-u5",
            baseUrlText = "https://relay.example.com",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        )

        val messages = send(provider, messagesModel)
        assertEquals("https://relay.example.com/v1/messages", messages.url)
        assertEquals("sk-u5", messages.headers["x-api-key"])
        assertNotNull(messages.headers["anthropic-version"])
        assertTrue("Messages body carries max_tokens", "max_tokens" in messages.body)
        assertEquals("You are terse.", messages.body["system"]?.let { systemText(it) })
        assertTrue(messages.body.getValue("messages").jsonArray.none { it.jsonObject["role"]?.jsonPrimitive?.content == "system" })

        val chat = send(provider, chatModel)
        assertEquals("https://relay.example.com/v1/chat/completions", chat.url)
        assertEquals("Bearer sk-u5", chat.headers["authorization"])
        assertFalse("Chat body has no top-level system", "system" in chat.body)
        assertEquals("system", chat.body.getValue("messages").jsonArray.first().jsonObject["role"]?.jsonPrimitive?.content)

        // The connection itself was not rewritten
        assertEquals(RelayTransport.OpenAIChatCompletions, provider.relayRequested?.transport)
    }

    private fun systemText(element: kotlinx.serialization.json.JsonElement): String =
        runCatching { element.jsonPrimitive.content }.getOrElse {
            element.jsonArray.joinToString("") { it.jsonObject["text"]?.jsonPrimitive?.content.orEmpty() }
        }

    // ── B: official providers dispatch by the delivered apiProtocol ─────────────────────────────

    private fun applyProviderConfigs(vararg entries: String) {
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[${entries.joinToString(",")}]}""")
    }

    private fun miniMaxConfig(
        apiProtocol: String?,
        defaultBaseURL: String = "https://api.minimax.io/anthropic",
        trustedHosts: String? = null,
        regionOptions: String? = null,
    ): String = buildString {
        append("""{"kind":"miniMax","displayName":"MiniMax","defaultBaseURL":"$defaultBaseURL"""")
        apiProtocol?.let { append(""","apiProtocol":"$it"""") }
        trustedHosts?.let { append(""","trustedHosts":$it""") }
        regionOptions?.let { append(""","regionOptions":$it""") }
        append("}")
    }

    private val miniMaxModel = AIModel(id = "MiniMax-M2", name = "MiniMax-M2")
    private val miniMax = Provider(
        id = "u5-minimax",
        kind = ProviderKind.MiniMax,
        models = listOf(miniMaxModel),
        apiKey = "mm-key",
        baseUrlText = "api.minimax.io/v1",
    )

    @Test
    fun `E2_DISPATCH_01 miniMax with apiProtocol anthropic goes Messages shape with MiniMax auth`() {
        applyProviderConfigs(miniMaxConfig(apiProtocol = "anthropic"))

        val sent = send(miniMax, miniMaxModel)
        assertEquals("https://api.minimax.io/anthropic/v1/messages", sent.url)
        assertEquals("mm-key", sent.headers["x-api-key"])
        assertNull("no Bearer on the Anthropic-compatible route", sent.headers["authorization"])
        assertNotNull(sent.headers["anthropic-version"])
        assertFalse("official vendor is not a relay: no Codex identity", "originator" in sent.headers)
        assertEquals("MiniMax-M2", sent.body["model"]?.jsonPrimitive?.content)
        assertTrue("max_tokens" in sent.body)
        assertEquals("You are terse.", sent.body["system"]?.let { systemText(it) })
    }

    @Test
    fun `E2_DISPATCH_01 native family, missing or unknown apiProtocol keeps the per-vendor service`() {
        listOf("openai_compatible", null, "smoke_signals").forEach { protocol ->
            applyProviderConfigs(miniMaxConfig(apiProtocol = protocol, defaultBaseURL = "https://api.minimax.io/v1"))
            val sent = send(miniMax, miniMaxModel)
            assertEquals("apiProtocol=$protocol", "https://api.minimax.io/v1/chat/completions", sent.url)
            assertEquals("Bearer mm-key", sent.headers["authorization"])
        }
    }

    @Test
    fun `E2_DISPATCH_01 untrusted downloaded base falls back to the native service`() {
        applyProviderConfigs(miniMaxConfig(apiProtocol = "anthropic", defaultBaseURL = "https://api.evil.example/anthropic"))
        val sent = send(miniMax, miniMaxModel)
        assertEquals("https://api.minimax.io/v1/chat/completions", sent.url)
    }

    // ── C: trust table ─────────────────────────────────────────────────

    @Test
    fun `E2_TRUST_01 downloaded trustedHosts allow, reject and fall back`() {
        // Allowed: suffixes in the delivered table and their subdomains
        applyProviderConfigs(miniMaxConfig(apiProtocol = "openai_compatible", trustedHosts = """["minimax.io","minimaxi.com"]"""))
        assertEquals(setOf("minimax.io", "minimaxi.com"), EndpointResolver.trustedHostSuffixes(ProviderKind.MiniMax))
        assertEquals("https://api.minimaxi.com/v1", EndpointResolver.trustedOfficialBase(ProviderKind.MiniMax, "https://api.minimaxi.com/v1/"))
        assertNotNull(EndpointResolver.trustedOfficialBase(ProviderKind.MiniMax, "https://minimax.io"))

        // Rejected: hosts outside the table, http, suffix look-alikes
        assertNull(EndpointResolver.trustedOfficialBase(ProviderKind.MiniMax, "https://api.evil.example/v1"))
        assertNull(EndpointResolver.trustedOfficialBase(ProviderKind.MiniMax, "http://api.minimax.io/v1"))
        assertNull(EndpointResolver.trustedOfficialBase(ProviderKind.MiniMax, "https://notminimax.io/v1"))

        // Malformed items are dropped one by one; if none is left, fall back to the missing-field behavior
        val malformed = listOf("*.minimax.io", "MiniMax.io", "minimax.io:443", "1.2.3.4", "io", "https://minimax.io", "")
        malformed.forEach { assertFalse(it, EndpointResolver.isWellFormedTrustedHost(it)) }
        assertEquals(setOf("minimax.io"), EndpointResolver.trustedHostSuffixes(ProviderKind.MiniMax, malformed))
        assertEquals(
            setOf("minimaxi.com"),
            EndpointResolver.trustedHostSuffixes(ProviderKind.MiniMax, malformed + "minimaxi.com"),
        )

        // Missing field / empty table: only the last two labels of the built-in fallback hosts are trusted, the second registered domain is not trusted
        MetadataTestFixtures.clear()
        assertEquals(setOf("minimax.io"), EndpointResolver.trustedHostSuffixes(ProviderKind.MiniMax))
        assertEquals(setOf("minimax.io"), EndpointResolver.trustedHostSuffixes(ProviderKind.MiniMax, emptyList()))
        assertEquals(setOf("moonshot.ai"), EndpointResolver.trustedHostSuffixes(ProviderKind.Moonshot))
        assertNull(EndpointResolver.trustedOfficialBase(ProviderKind.Moonshot, "https://api.moonshot.cn/v1"))
        assertEquals(setOf("googleapis.com"), EndpointResolver.trustedHostSuffixes(ProviderKind.Gemini))
        assertEquals(setOf("bigmodel.cn"), EndpointResolver.trustedHostSuffixes(ProviderKind.Zhipu))
    }

    @Test
    fun `E2_TRUST_02 China region survives only when minimaxi_com is downloaded`() {
        val regions = """[
            {"id":"global","label":"Global","baseURL":"https://api.minimax.io/v1"},
            {"id":"cn","label":"China","baseURL":"https://api.minimaxi.com/v1"}
        ]"""

        applyProviderConfigs(
            miniMaxConfig(
                apiProtocol = "openai_compatible",
                defaultBaseURL = "https://api.minimax.io/v1",
                trustedHosts = """["minimax.io","minimaxi.com"]""",
                regionOptions = regions,
            ),
        )
        assertEquals(listOf("global", "cn"), miniMaxRegionIds())
        assertEquals(listOf("global", "cn"), ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.MiniMax).map { it.id })

        applyProviderConfigs(
            miniMaxConfig(apiProtocol = "openai_compatible", defaultBaseURL = "https://api.minimax.io/v1", regionOptions = regions),
        )
        assertEquals(listOf("global"), miniMaxRegionIds())
        assertEquals(listOf("global"), ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.MiniMax).map { it.id })
    }

    @Test
    fun `E2_TRUST_02 built-in fallback regions pass the same trust match`() {
        // No metadata: the whole table falls back to the built-in one; a missing field trusts only the last two labels of the fallback host
        MetadataTestFixtures.clear()
        val catalog = ProviderSetupCatalogResolver.current()
        assertEquals(listOf("global"), catalog.regionOptions(ProviderKind.MiniMax).map { it.id })
        assertEquals(listOf("intl"), catalog.regionOptions(ProviderKind.Moonshot).map { it.id })
        assertEquals(listOf("cn"), catalog.regionOptions(ProviderKind.SiliconFlow).map { it.id })
        listOf(ProviderKind.MiniMax, ProviderKind.Moonshot, ProviderKind.SiliconFlow, ProviderKind.Qwen).forEach { kind ->
            val trusted = EndpointResolver.trustedHostSuffixes(kind)
            catalog.regionOptions(kind).forEach { option ->
                assertTrue("$kind ${option.baseURL}", EndpointResolver.isTrustedHttpsUrl(option.baseURL, trusted))
            }
        }

        // The delivered table has minimaxi.com but no region options: the domestic site is kept on fallback to built-in
        applyProviderConfigs(
            miniMaxConfig(
                apiProtocol = "openai_compatible",
                defaultBaseURL = "https://api.minimax.io/v1",
                trustedHosts = """["minimax.io","minimaxi.com"]""",
            ),
        )
        assertEquals(listOf("global", "cn"), ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.MiniMax).map { it.id })

        // When all delivered region options are filtered out and it falls back to built-in, the fallback result likewise yields no trust table
        applyProviderConfigs(
            miniMaxConfig(
                apiProtocol = "openai_compatible",
                defaultBaseURL = "https://api.minimax.io/v1",
                regionOptions = """[{"id":"cn","label":"China","baseURL":"https://api.minimaxi.com/v1"}]""",
            ),
        )
        assertEquals(listOf("global"), ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.MiniMax).map { it.id })
    }

    @Test
    fun `E2_TRUST_03 deterministic provider id region lookup ignores the trust filter`() {
        // The trust table lacks minimaxi.com / moonshot.cn / siliconflow.com: selectable options are filtered, but the reverse-lookup table for deterministic ids is unchanged
        MetadataTestFixtures.clear()
        assertEquals(listOf("global"), ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.MiniMax).map { it.id })
        val cases = mapOf(
            ProviderKind.MiniMax to ("https://api.minimaxi.com/v1" to "cn"),
            ProviderKind.Moonshot to ("https://api.moonshot.cn/v1" to "cn"),
            ProviderKind.SiliconFlow to ("https://api.siliconflow.com/v1" to "intl"),
        )
        cases.forEach { (kind, pair) ->
            val (baseUrl, regionId) = pair
            // ProviderRepository.registerProvider and the SyncManager migration share this one reverse lookup (the unfiltered built-in table)
            assertEquals("$kind", regionId, kind.resolveRegionOption(baseUrl)?.id)
            assertEquals(
                ai.oriveo.community.core.util.DeterministicProviderId.forProvider(kind, regionId),
                ai.oriveo.community.core.util.DeterministicProviderId.forProvider(kind, kind.resolveRegionOption(baseUrl)?.id ?: ""),
            )
        }
    }

    @Test
    fun `E2_TRUST_04 stored region outside the trust table is still resolved as the current value`() {
        MetadataTestFixtures.clear()
        val catalog = ProviderSetupCatalogResolver.current()
        assertEquals("cn", catalog.resolveRegionOption(ProviderKind.MiniMax, "https://api.minimaxi.com/v1")?.id)
        assertEquals("cn", catalog.exactRegionOption(ProviderKind.MiniMax, "api.minimaxi.com/v1")?.id)
        assertEquals("global", catalog.resolveRegionOption(ProviderKind.MiniMax, null)?.id)
        assertNull(catalog.exactRegionOption(ProviderKind.MiniMax, "https://proxy.example/v1"))
    }

    private fun miniMaxRegionIds(): List<String> =
        MetadataClient.listPublicProviderConfigs().first { it.kind == "miniMax" }.regionOptions.orEmpty().map { it.id }
}
