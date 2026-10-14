package ai.oriveo.community.core.provider.relay

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
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.security.SecureKeyStore
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
import io.mockk.mockkObject
import io.mockk.unmockkObject
import io.mockk.confirmVerified
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * RL2-MIGRATE-01: golden for existing outbound requests (the byte-for-byte baseline before the chokepoint replacement).
 *
 * The input manifest is the shared `relay/request-golden/cases.v1.json` fixture used by all clients; this client produces
 * `android.v1.json`. The 15 official providers use the real service selected by `ProviderRepository.serviceFor`; Relay goes through
 * `serviceFor(provider, model)` -> RelayService -> RelayTransportCoordinator, with the same parameters as ChatRepository outbound.
 *
 * The capture point is the Ktor MockEngine (the HTTP seam of each service): requests never leave the process, and the URL is exactly the original address built by production,
 * so there is no host/port to restore as with MockWebServer. Content-Type / Content-Length hang on the body rather than in
 * `HttpRequestData.headers`; here they are merged into headers the way the OkHttp engine does on the wire. User-Agent is rewritten by an OkHttp interceptor in the DI layer
 * outside the seam (`NativeUserAgent`, including the version number), so it is not part of this baseline.
 *
 * Recording: with `ORIVEO_GOLDEN_RECORD=1` android.v1.json is rewritten; otherwise cases are compared one by one, and a missing file or a mismatch fails.
 */
class RelayRequestGoldenTest {

    // Same configuration as the production Json of NetworkModule: encodeDefaults directly affects body bytes
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        coerceInputValues = true
    }
    private val prettyJson = Json { prettyPrint = true }

    private val captured = mutableListOf<HttpRequestData>()
    private val capturedBodies = mutableListOf<ByteArray>()

    // Install ContentNegotiation as the production HttpClient does (it writes the Accept header); the other plugins only look at responses or only act on our own backend origin
    private val client = HttpClient(
        MockEngine { request ->
            val bytes = request.body.toByteArray()
            synchronized(captured) {
                captured += request
                capturedBodies += bytes
            }
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

    private val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>(relaxed = true)
    private val secureKeyStore = mockk<SecureKeyStore>(relaxed = true)
    private lateinit var repository: ProviderRepository

    @Before
    fun setUp() {
        MetadataTestFixtures.clear()
        // The session_id of the Codex identity headers is a fresh UUID.randomUUID() each time (RelayHeaderBuilder.codexIdentityHeaders).
        // The JDK module cannot intercept the UUID static method, so production's return value is kept and only this one random value is pinned; the header itself is still recorded
        mockkObject(RelayHeaderBuilder)
        every { RelayHeaderBuilder.codexIdentityHeaders(any(), any()) } answers {
            callOriginal().mapValues { (name, value) -> if (name == "session_id") FIXED_SESSION_ID else value }
        }
        repository = ProviderRepository(
            dao = dao,
            conversationDao = mockk(relaxed = true),
            secureKeyStore = secureKeyStore,
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
        unmockkObject(RelayHeaderBuilder)
        MetadataTestFixtures.clear()
        client.close()
    }

    // ── Manifest ─────────────────────────────────────────────────────────

    private fun goldenDir(): Path {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/request-golden")
            if (Files.exists(candidate.resolve("cases.v1.json"))) return candidate
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("request-golden/cases.v1.json not found")
    }

    private val manifest: JsonObject by lazy {
        json.parseToJsonElement(
            String(Files.readAllBytes(goldenDir().resolve("cases.v1.json")), Charsets.UTF_8),
        ).jsonObject
    }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.strOrNull(key: String): String? = get(key)?.jsonPrimitive?.content

    // The manifest uses iOS rawValue; Android's SerialName differs only for together / fireworks
    private fun providerKindOf(raw: String): ProviderKind = when (raw) {
        "togetherAI" -> ProviderKind.Together
        "fireworksAI" -> ProviderKind.Fireworks
        else -> ProviderKind.entries.firstOrNull { it.rawValue == raw }
            ?: error("unknown providerKind $raw")
    }

    private fun relayTransportOf(raw: String): RelayTransport =
        RelayTransport.entries.firstOrNull { it.value == raw } ?: error("unknown transport $raw")

    /** system goes into ChatRequestOptions.systemPrompt (Android ChatRole has no system, and production does the same); the rest become messages in order. */
    private fun conversation(kind: ProviderKind, modelID: String): Pair<String, List<ChatMessage>> {
        var systemPrompt = ""
        val messages = mutableListOf<ChatMessage>()
        manifest.getValue("conversation").jsonArray.forEachIndexed { index, element ->
            val turn = element.jsonObject
            val content = turn.str("content")
            when (turn.str("role")) {
                "system" -> systemPrompt = content
                "user", "assistant" -> messages += ChatMessage(
                    id = "golden-msg-$index",
                    role = if (turn.str("role") == "user") ChatRole.User else ChatRole.Assistant,
                    text = content,
                    providerKind = kind,
                    providerName = kind.displayName,
                    modelID = modelID,
                    modelName = modelID,
                    state = ChatMessageState.Delivered,
                )
                else -> error("unknown role ${turn.str("role")}")
            }
        }
        return systemPrompt to messages
    }

    // ── Send and capture ───────────────────────────────────────────────────

    private class Built(val provider: Provider, val model: AIModel)

    private fun officialCase(case: JsonObject): Built {
        val kind = providerKindOf(case.str("providerKind"))
        val modelID = case.str("model")
        val model = AIModel(id = modelID, name = modelID)
        return Built(
            Provider(id = "golden-${kind.rawValue}", kind = kind, models = listOf(model), apiKey = manifest.str("apiKey")),
            model,
        )
    }

    private fun relayCase(case: JsonObject): Built {
        val requested = case.getValue("relayRequested").jsonObject
        val modelID = manifest.str("relayModel")
        val model = AIModel(id = modelID, name = modelID)
        return Built(
            Provider(
                id = "golden-relay",
                kind = ProviderKind.Relay,
                models = listOf(model),
                apiKey = manifest.str("apiKey"),
                baseUrlText = case.str("baseURL"),
                relayRequested = RelayRequestedConfig(
                    transport = relayTransportOf(requested.str("transport")),
                    resolvedAPIBaseURL = requested.strOrNull("resolvedAPIBaseURL"),
                ),
            ),
            model,
        )
    }

    /** Same parameters as ChatRepository outbound: baseUrl = provider.baseUrlText, and Relay additionally carries provider.relayRequested. */
    private fun send(built: Built): Pair<HttpRequestData, ByteArray>? {
        val provider = built.provider
        val (systemPrompt, messages) = conversation(provider.kind, built.model.id)
        val base = ChatRequestOptions(systemPrompt = systemPrompt, activeModel = built.model)
        val options = if (provider.kind == ProviderKind.Relay) {
            base.copy(relayRequested = provider.relayRequested, relayImage = provider.relayImage)
        } else {
            base
        }
        synchronized(captured) {
            captured.clear()
            capturedBodies.clear()
        }
        val failure = runCatching {
            runBlocking {
                withTimeout(15_000) {
                    repository.serviceFor(provider, built.model).sendMessageStream(
                        apiKey = provider.apiKey,
                        modelID = built.model.id,
                        messages = messages,
                        baseUrl = provider.baseUrlText,
                        supportsImageGen = false,
                        reasoningMode = ReasoningMode.Automatic,
                        webSearchEnabled = false,
                        requestOptions = options,
                    ).collect { }
                }
            }
        }.exceptionOrNull()
        return synchronized(captured) {
            if (captured.isEmpty()) {
                lastFailure = failure
                null
            } else {
                captured.first() to capturedBodies.first()
            }
        }
    }

    private var lastFailure: Throwable? = null

    private fun record(caseId: String, request: HttpRequestData, body: ByteArray): JsonObject {
        val headers = sortedMapOf<String, String>()
        request.headers.entries().forEach { (name, values) -> headers[name.lowercase()] = values.joinToString(", ") }
        // The two entity headers on the body are written to the wire by the OkHttp engine; here they are merged the same way
        request.body.contentType?.let { headers.putIfAbsent("content-type", it.toString()) }
        request.body.contentLength?.let { headers.putIfAbsent("content-length", it.toString()) }
        return buildJsonObject {
            put("caseId", caseId)
            put("method", request.method.value)
            put("url", request.url.toString())
            put("headers", JsonObject(headers.mapValues { JsonPrimitive(it.value) }))
            put("body", String(body, Charsets.UTF_8))
        }
    }

    private fun recordAll(): List<JsonObject> {
        val cases = manifest.getValue("official").jsonArray.map { it.jsonObject to ::officialCase } +
            manifest.getValue("relay").jsonArray.map { it.jsonObject to ::relayCase }
        return cases.map { (case, build) ->
            val caseId = case.str("caseId")
            val captured = send(build(case))
            if (captured == null) {
                val reason = lastFailure?.let { "${it::class.simpleName}: ${it.message}" } ?: "no request issued"
                buildJsonObject {
                    put("caseId", caseId)
                    put("unsupported", reason)
                }
            } else {
                record(caseId, captured.first, captured.second)
            }
        }
    }

    // ── Tests ─────────────────────────────────────────────────────────

    @Test
    fun `RL2_MIGRATE_01 outbound request bytes match recorded golden`() {
        val actual = recordAll()
        assertEquals(
            "case count must equal official + relay in cases.v1.json",
            manifest.getValue("official").jsonArray.size + manifest.getValue("relay").jsonArray.size,
            actual.size,
        )
        val goldenFile = goldenDir().resolve("android.v1.json")
        val recording = System.getenv("ORIVEO_GOLDEN_RECORD") == "1"
        // Re-recording also goes through the same comparison first: any change other than the registered difference refuses to write to disk
        val existing = if (Files.exists(goldenFile)) diffAgainst(goldenFile, actual) else null
        if (recording && existing != null && existing.isNotEmpty()) {
            fail("RL2_MIGRATE_01 refuses to re-record over unregistered diffs (${existing.size}):\n" + existing.joinToString("\n"))
        }

        if (recording) {
            val document = buildJsonObject {
                put("version", manifest.getValue("version"))
                put("end", "android")
                put("cases", JsonArray(actual))
            }
            Files.write(goldenFile, (prettyJson.encodeToString(JsonElement.serializer(), document) + "\n").toByteArray(Charsets.UTF_8))
            println("[RL2_MIGRATE_01] recorded ${actual.size} cases → $goldenFile")
            return
        }

        if (existing == null) fail("golden missing: $goldenFile (record with ORIVEO_GOLDEN_RECORD=1)")
        if (existing!!.isNotEmpty()) fail("RL2_MIGRATE_01 golden mismatch (${existing.size}):\n" + existing.joinToString("\n"))
    }

    /** Compared case by case and field by field; the three registered cells only allow one kind of difference: the URL changing from the old value to the new value with /v1 added. */
    private fun diffAgainst(goldenFile: Path, actual: List<JsonObject>): List<String> {
        val expected = json.parseToJsonElement(String(Files.readAllBytes(goldenFile), Charsets.UTF_8))
            .jsonObject.getValue("cases").jsonArray.associateBy { it.jsonObject.str("caseId") }

        val diffs = mutableListOf<String>()
        actual.forEach { got ->
            val caseId = got.str("caseId")
            val want = expected[caseId]?.jsonObject
            if (want == null) {
                diffs += "$caseId: missing in golden"
                return@forEach
            }
            (want.keys + got.keys).toSortedSet().forEach { key ->
                // The recorded golden is shared with the private build, whose OpenRouter HTTP-Referer is the product site; the community edition sends its repository URL.
                val wantValue = want[key]?.let {
                    if (key == "headers") {
                        json.parseToJsonElement(it.toString().replace("\"https://oriveoai.com\"", "\"https://github.com/oriveo/oriveo\""))
                    } else {
                        it
                    }
                }
                if (wantValue == got[key]) return@forEach
                val allowed = D33_BARE_HOST_V1[caseId]
                if (key == "url" && allowed != null &&
                    wantValue?.jsonPrimitive?.content == allowed.first &&
                    got[key]?.jsonPrimitive?.content == allowed.second
                ) {
                    return@forEach
                }
                diffs += "$caseId.$key\n  golden: $wantValue\n  actual: ${got[key]}"
            }
        }
        (expected.keys - actual.map { it.str("caseId") }.toSet()).forEach { diffs += "$it: in golden but not in cases" }
        return diffs
    }

    @Test
    fun `RL2_MIGRATE_01 relay send does not write back relayRequested or model`() {
        manifest.getValue("relay").jsonArray.forEach { element ->
            val case = element.jsonObject
            val built = relayCase(case)
            val providerBefore = built.provider.copy()
            val modelBefore = built.model.copy()
            send(built)
            assertEquals("${case.str("caseId")}: relayRequested written back", providerBefore.relayRequested, built.provider.relayRequested)
            assertEquals("${case.str("caseId")}: provider mutated", providerBefore, built.provider)
            assertEquals("${case.str("caseId")}: model mutated", modelBefore, built.model)
            assertTrue("${case.str("caseId")}: model gained relayTransport", built.model.relayTransport == null)
        }
        // The outbound path must not persist any provider (relayRequested / model protocol write-back would go through the dao)
        confirmVerified(dao)
    }

    private companion object {
        const val FIXED_SESSION_ID = "00000000-0000-4000-8000-000000000000"

        /**
         * The only registered difference on Android. When a connection has only a bare host and no probed root address, Chat / Auto / Responses
         * append `/v1` per effectiveAPIRoot (consistent with iOS and the fixture resolveCases); only the URL may change, headers and body
         * stay byte-identical. caseId -> (URL recorded before the change, URL after the change).
         */
        val D33_BARE_HOST_V1: Map<String, Pair<String, String>> = mapOf(
            "relay_chat_bare_host" to
                ("https://relay.example.com/chat/completions" to "https://relay.example.com/v1/chat/completions"),
            "relay_auto_bare_host" to
                ("https://relay.example.com/chat/completions" to "https://relay.example.com/v1/chat/completions"),
            "relay_responses_bare_host" to
                ("https://relay.example.com/responses" to "https://relay.example.com/v1/responses"),
        )
    }
}
