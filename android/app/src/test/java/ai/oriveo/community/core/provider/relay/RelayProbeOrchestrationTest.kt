package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataTransportResponse
import ai.oriveo.community.core.data.remote.ModelFactsTransport
import ai.oriveo.community.core.data.remote.RelayModelFamilyLookup
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.providers.relay.RelaySetupStep
import ai.oriveo.community.feature.providers.relay.RelaySetupViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Collections
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * Relay per-model probe orchestration (`shared/test-fixtures/relay/probe-orchestration.v1.json` and
 * `gateway-models.v1.json`). Each case / scenario is driven by its caseId.
 *
 * Catalog parsing uses the production [RelayDiscoveryService]; probe requests use the production ping primitive ([RelayService.verifyGeneration])
 * against a fake server; orchestration uses the production [RelaySetupViewModel]; persisted fields round-trip through the production [RelayModelProbe.applyingPass]
 * and [ProviderMapper] (the registration function's own writes are locked separately by RL2-PROBE-03 in ProviderRepositoryTest).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayProbeOrchestrationTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun fixture(name: String): JsonObject {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/$name")
            if (Files.exists(candidate)) {
                return Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("$name not found")
    }

    private val orchestration: JsonObject by lazy { fixture("probe-orchestration.v1.json") }

    /** Short name (chat / responses / messages / gemini) <-> wire protocol. */
    private val shortToTransport: Map<String, RelayTransport> by lazy {
        orchestration.getValue("transports").jsonObject.mapValues { (_, wire) ->
            RelayTransport.entries.single { it.value == wire.jsonPrimitive.content }
        }
    }
    private val transportToShort: Map<RelayTransport, String> by lazy {
        shortToTransport.entries.associate { (short, transport) -> transport to short }
    }

    private fun JsonObject.strings(key: String): List<String>? =
        (this[key] as? JsonArray)?.map { it.jsonPrimitive.content }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    // ── RL2-PROBE-01: candidate order reads the gateway catalog's supported_endpoint_types ──

    @Test
    fun `RL2-PROBE-01 candidate order from recorded new-api catalog endpoint types`() = runTest {
        val gateway = fixture("gateway-models.v1.json").getValue("gateways").jsonObject.getValue("new_api").jsonObject
        val record = gateway.getValue("records").jsonArray.first().jsonObject
        val body = record.getValue("response").jsonObject.getValue("body").toString()
        val expected = gateway.getValue("expected").jsonObject.getValue("candidates").jsonObject
        val service = RelayDiscoveryService(
            client = HttpClient(
                MockEngine { request ->
                    if (request.url.encodedPath == "/v1/models") {
                        respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
                    } else {
                        respond("", HttpStatusCode.NotFound)
                    }
                },
            ),
            json = json,
            retryBackoffMs = emptyList(),
        )

        val detection = service.discover("https://relay.test/v1", "sk-test", null, includeGenerationProbe = false)
            .detections.first()

        assertEquals(expected.keys, detection.modelIDs.toSet())
        for ((modelID, candidates) in expected) {
            val types = detection.supportedEndpointTypes[modelID]
            assertEquals("$modelID: in-memory cache matches this catalog", types, service.cachedSupportedEndpointTypes("https://relay.test/v1/", modelID))
            val actual = RelayProbeCandidates.candidates(types, modelID) { fail("$modelID: family must not be looked up when endpoint types suffice"); null }
            assertEquals(modelID, candidates.jsonArray.map { it.jsonPrimitive.content }, actual.map(transportToShort::getValue))
        }
    }

    // ── RL2-PROBE-02: family path + fake by-model service ──

    private class FakeByModel(private val body: String?, private val status: Int) : ModelFactsTransport {
        var fetches = 0
        override suspend fun fetch(ifNoneMatch: String?): MetadataTransportResponse {
            fetches += 1
            return MetadataTransportResponse(statusCode = status, eTag = null, body = body, responseBytes = 0)
        }
    }

    @Test
    fun `RL2-PROBE-02 family cases through the by-model view`() = runTest {
        val byModelBody = orchestration.getValue("byModelResponse").toString()
        val cases = orchestration.getValue("familyCases").jsonArray.map { it.jsonObject }
        assertEquals(9, cases.size)
        for (case in cases) {
            val caseId = case.string("caseId")
            val unavailable = case["byModelUnavailable"]?.jsonPrimitive?.booleanOrNull == true
            val fake = if (unavailable) FakeByModel(null, 503) else FakeByModel(byModelBody, 200)
            val lookup = RelayModelFamilyLookup(fake)
            val types = case.strings("supportedEndpointTypes")

            val actual = RelayProbeCandidates.candidates(types, case.string("modelId"), lookup::family)

            assertEquals(caseId, case.strings("expect"), actual.map(transportToShort::getValue))
            if (RelayProbeCandidates.fromEndpointTypes(types).isNotEmpty()) {
                assertEquals("$caseId: by-model is not fetched when endpoint types win", 0, fake.fetches)
            }
        }
    }

    // ── RD2-ROUTE: verification candidates for the first selected model when the protocol was found only via the generation route (generationRouteCases) ──

    @Test fun `RD2-ROUTE-unknown_family_route_then_default`() = routeCase("unknown_family_route_then_default")
    @Test fun `RD2-ROUTE-route_first_then_family_capped_at_two`() = routeCase("route_first_then_family_capped_at_two")
    @Test fun `RD2-ROUTE-route_already_in_family_is_not_repeated`() = routeCase("route_already_in_family_is_not_repeated")

    @Test
    fun `every generation route case has a named test`() {
        val ids = orchestration.getValue("generationRouteCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject.string("caseId") }
        val named = RelayProbeOrchestrationTest::class.java.declaredMethods.map { it.name }.filter { it.startsWith("RD2-ROUTE-") }
        assertEquals(ids.map { "RD2-ROUTE-$it" }.toSet(), named.toSet())
    }

    private fun routeCase(caseId: String) = runTest {
        val case = orchestration.getValue("generationRouteCases").jsonObject.getValue("cases").jsonArray
            .map { it.jsonObject }.single { it.string("caseId") == caseId }
        val lookup = RelayModelFamilyLookup(FakeByModel(orchestration.getValue("byModelResponse").toString(), 200))
        val actual = RelayProbeCandidates.withGenerationRoute(
            route = shortToTransport.getValue(case.string("route")),
            supportedEndpointTypes = null,
            modelID = case.string("modelId"),
            family = lookup::family,
        )
        assertEquals(caseId, case.strings("expect"), actual.map(transportToShort::getValue))
    }

    @Test
    fun `RL2-PROBE-02 by-model view is fetched lazily once and failures are not cached`() = runTest {
        val ok = FakeByModel(orchestration.getValue("byModelResponse").toString(), 200)
        val lookup = RelayModelFamilyLookup(ok)
        assertEquals("anthropic", lookup.family("claude-sonnet-4-5"))
        assertEquals("google", lookup.family("gemini-2.5-pro"))
        assertEquals(1, ok.fetches)

        val down = FakeByModel(null, 404)
        val failing = RelayModelFamilyLookup(down)
        assertEquals(null, failing.family("claude-sonnet-4-5"))
        assertEquals(null, failing.family("claude-sonnet-4-5"))
        assertEquals(2, down.fetches)
    }

    // ── RL2-PROBE-03: add flow ──

    private class Registration(
        val baseUrl: String,
        val requested: RelayRequestedConfig,
        val catalogIDs: List<String>,
        val preferredModelID: String?,
        val verified: Boolean,
        val pass: RelayModelProbePass?,
    )

    private fun catalogBody(models: List<JsonObject>): String = buildJsonObject {
        put("object", "list")
        put(
            "data",
            buildJsonArray {
                models.forEach { model ->
                    add(
                        buildJsonObject {
                            put("id", model.string("id"))
                            put("object", "model")
                            model.strings("supportedEndpointTypes")?.let { types ->
                                put("supported_endpoint_types", buildJsonArray { types.forEach { add(JsonPrimitive(it)) } })
                            }
                        },
                    )
                }
            },
        )
    }.toString()

    private fun probeShortName(path: String): String? = when {
        path.endsWith("/chat/completions") -> "chat"
        path.endsWith("/responses") -> "responses"
        path.endsWith("/messages") -> "messages"
        path.endsWith(":generateContent") -> "gemini"
        else -> null
    }

    /** All outcome names in `probeOutcomeRules` (three groups); guards that every outcome in the fixture is known to the fake server. */
    private val knownOutcomes: Set<String> by lazy {
        val rules = orchestration.getValue("probeOutcomeRules").jsonObject
        listOf("pass", "routeRejected", "inconclusive").flatMap { rules.strings(it).orEmpty() }.toSet()
    }

    /** Response body for `http_403_route`: carries a registered phrase from negative-cache.v1.json `protocolFallbackRules.phrases` (case scrambled). */
    private val routePhraseBody: String by lazy {
        val phrase = fixture("negative-cache.v1.json").getValue("protocolFallbackRules").jsonObject.strings("phrases")!!.first()
        buildJsonObject {
            put("error", buildJsonObject { put("type", "permission_error"); put("message", "This group ${phrase.uppercase()}") })
        }.toString()
    }

    /** A probe outcome name -> the fake server's response this time (null = network error, thrown by the caller). Unlisted outcome names fail immediately. */
    private fun outcomeReply(outcome: String): Pair<HttpStatusCode, String>? {
        assertTrue("Unknown probe outcome $outcome", outcome in knownOutcomes)
        return when (outcome) {
            "ok" -> HttpStatusCode.OK to """{"id":"x","choices":[{"message":{"content":"p"}}]}"""
            "network" -> null
            "http_400" -> HttpStatusCode.BadRequest to "{}"
            "http_401" -> HttpStatusCode.Unauthorized to "{}"
            "http_403" -> HttpStatusCode.Forbidden to """{"error":{"message":"forbidden"}}"""
            "http_403_route" -> HttpStatusCode.Forbidden to routePhraseBody
            "http_404" -> HttpStatusCode.NotFound to "{}"
            "http_405" -> HttpStatusCode.MethodNotAllowed to "{}"
            "http_415" -> HttpStatusCode.UnsupportedMediaType to "{}"
            "http_422" -> HttpStatusCode.UnprocessableEntity to "{}"
            "http_429" -> HttpStatusCode.TooManyRequests to "{}"
            "http_5xx" -> HttpStatusCode.InternalServerError to "{}"
            // Gateway SPA fallback page: 200 + HTML (production recognizes it by body prefix / Content-Type; here the body is used).
            "html_200" -> HttpStatusCode.OK to "<!doctype html><html><head><title>Relay</title></head><body></body></html>"
            else -> error("probeOutcomeRules added outcome $outcome but the fake server has no matching response yet")
        }
    }

    @Test
    fun `RL2-PROBE-03 add scenarios probe only the default model and never change the connection protocol`() {
        val scenarios = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }
            .filter { it.string("test") == "RL2-PROBE-03" }
        assertEquals(5, scenarios.size)
        assertTrue(scenarios.any { it.string("caseId") == "add_stops_at_an_inconclusive_first_candidate_and_is_not_verified" })
        Dispatchers.setMain(Dispatchers.Unconfined)
        for (scenario in scenarios) runAddScenario(scenario)
    }

    private fun runAddScenario(scenario: JsonObject) = runBlocking {
        val caseId = scenario.string("caseId")
        val connection = scenario.getValue("connection").jsonObject
        val baseURL = connection.string("baseURL")
        val connectionTransport = RelayTransport.entries.single { it.value == connection.string("transport") }
        val models = scenario.getValue("models").jsonArray.map { it.jsonObject }
        val defaultModel = scenario.string("defaultModel")
        val pingOutcomes = scenario.getValue("ping").jsonObject.mapValues { it.value.jsonPrimitive.content }
        val expect = scenario.getValue("expect").jsonObject
        val catalog = catalogBody(models)

        val pings = Collections.synchronizedList(mutableListOf<List<String>>())
        val bodies = Collections.synchronizedList(mutableListOf<String>())
        val engine = MockEngine { request ->
            bodies += (request.body as? TextContent)?.text.orEmpty()
            if (request.method == HttpMethod.Get) {
                // With auto-detect the fake catalog only accepts OpenAI-style Bearer: discovered protocol = chat, discovered root goes into the single-value field,
                // consistent with the fixture's resolvedAPIBaseURLs containing only the probe-passed entry; when the user picks a protocol the catalog is fetched with that protocol.
                val bearer = request.headers[HttpHeaders.Authorization]?.startsWith("Bearer ") == true
                val served = bearer || connectionTransport != RelayTransport.Auto
                return@MockEngine if (served && request.url.encodedPath == "/v1/models") {
                    respond(catalog, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
                } else {
                    respond("", HttpStatusCode.NotFound)
                }
            }
            val path = request.url.encodedPath
            val short = probeShortName(path) ?: return@MockEngine respond("", HttpStatusCode.NotFound)
            val model = if (short == "gemini") {
                path.substringAfter("/models/").substringBefore(":")
            } else {
                Json.parseToJsonElement((request.body as TextContent).text).jsonObject.string("model")
            }
            pings += listOf(model, short)
            val (status, body) = outcomeReply(pingOutcomes["$model@$short"] ?: "http_404") ?: throw IOException("connection reset")
            respond(body, status, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
        }
        val relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json))
        val discovery = RelayDiscoveryService(HttpClient(engine), json, retryBackoffMs = emptyList())
        val repository = mockk<ProviderRepository>()
        coEvery { repository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } coAnswers {
            relayService.verifyGeneration(arg(0), arg(1), arg(2), arg(3), arg(4), arg(5))
        }
        var registration: Registration? = null
        coEvery {
            repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            registration = Registration(
                baseUrl = arg(1),
                requested = arg(4),
                catalogIDs = arg(5),
                preferredModelID = arg(6),
                verified = arg(9),
                pass = arg(11),
            )
            Provider(id = "relay-$caseId", kind = ProviderKind.Relay)
        }
        val context = mockk<Context>()
        every { context.getString(any()) } answers { "string-${firstArg<Int>()}" }
        val viewModel = RelaySetupViewModel(context, repository, discovery, cachedModelFamily = { fail("$caseId: family lookup must not be called"); null })

        suspend fun settle() = withTimeout(10_000) {
            while (viewModel.isDiscovering || viewModel.isValidatingManual || viewModel.isSubmitting) delay(5)
        }

        val verified = expect.getValue("verified").jsonPrimitive.booleanOrNull == true
        if (connectionTransport == RelayTransport.Auto) {
            // Step 1 only detects without probing; step 2 selects that model, and saving probes only the first selected model.
            viewModel.updateEndpoint(baseURL)
            viewModel.updateApiKey("sk-test")
            viewModel.next()
            settle()
            if (viewModel.step != RelaySetupStep.Models) viewModel.next()
            if (models.any { it.string("id") == defaultModel }) viewModel.toggleModel(defaultModel) else viewModel.addManualModel(defaultModel)
            viewModel.save()
            settle()
            if (!verified) {
                assertEquals(caseId, RelaySetupStep.Models, viewModel.step)
                assertNotNull("$caseId: a failed probe keeps the existing ping-failure message", viewModel.modelsBoard.saveFailure)
            }
        } else {
            // Manual setup merged into one page: the chosen protocol sends exactly one 1-token request, no probing; a failure is not persisted.
            viewModel.showManualSetup()
            viewModel.selectManualTransport(connectionTransport)
            viewModel.updateEndpoint(baseURL)
            viewModel.updateApiKey("sk-test")
            viewModel.updateDefaultModel(defaultModel)
            viewModel.validateManual()
            settle()
        }

        val expectedPings = expect.getValue("pings").jsonArray.map { pair -> pair.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals("$caseId: probe requests", expectedPings, pings.toList())
        assertNoCapabilityTestRequests(caseId, bodies)

        if (!verified) {
            coVerify(exactly = 0) {
                repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
            }
            return@runBlocking
        }
        val saved = requireNotNull(registration) { "$caseId: no registration" }
        assertEquals("$caseId: verified", verified, saved.verified)
        assertEquals("$caseId: default model", defaultModel, saved.preferredModelID)
        assertEquals("$caseId: connection default protocol", expect.string("connectionTransport"), saved.requested.transport.value)

        // The same production function the registration uses to write, then a local-storage round-trip.
        val registered = Provider(
            id = "11111111-1111-4111-8111-111111111111",
            kind = ProviderKind.Relay,
            baseUrlText = saved.baseUrl,
            relayRequested = saved.requested,
            // Manual setup does not fetch the catalog and only enables the entered model; quick setup still uses the catalog + selection.
            models = (saved.catalogIDs + defaultModel).distinct().map { AIModel(id = it, name = it) },
            catalogModels = saved.catalogIDs.map { AIModel(id = it, name = it) },
        ).let { provider -> saved.pass?.let { RelayModelProbe.applyingPass(provider, defaultModel, it) } ?: provider }
        val stored = with(ProviderMapper) { registered.toEntity().toDomain() }

        val expectedRoots = expect.getValue("resolvedAPIBaseURLs").jsonObject.mapValues { it.value.jsonPrimitive.content }
        assertEquals("$caseId: resolvedAPIBaseURLs", expectedRoots, stored.relayRequested?.resolvedAPIBaseURLs.orEmpty())
        assertEquals("$caseId: connection default protocol (storage round-trip)", expect.string("connectionTransport"), stored.relayRequested?.transport?.value)
        for ((modelID, fields) in expect.getValue("models").jsonObject) {
            val model = stored.models.single { it.id == modelID }
            val expected = fields.jsonObject
            assertEquals("$caseId/$modelID: relayTransport", expected["relayTransport"]?.jsonPrimitive?.content, model.relayTransport?.value)
            assertEquals(
                "$caseId/$modelID: relayTransportSource",
                expected["relayTransportSource"]?.jsonPrimitive?.content,
                model.relayTransportSource?.value,
            )
        }
    }

    // ── RL2-PROBE-04 / 05: lazy verification on enable, reachable promoted to observed, re-detection (via the production ProviderRepository) ──

    private val connectionID = "22222222-2222-4222-8222-222222222222"
    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

    /**
     * Production [ProviderRepository] + production [RelayService] against a fake server; the DAO keeps only Room's minimal read/write semantics,
     * persisted objects are encoded/decoded by the production ProviderMapper. Negative caches use the production [ai.oriveo.community.core.provider.ToolCallMemoryStore]
     * and [ai.oriveo.community.core.provider.ModelControlRejectionCache] (in-memory persistence hooks).
     */
    private inner class RepositoryHarness(
        catalogModels: List<JsonObject>,
        pingOutcomes: Map<String, String>,
        initial: Provider,
        val family: suspend (String) -> String? = { null },
    ) {
        val pings: MutableList<List<String>> = Collections.synchronizedList(mutableListOf())
        /** Raw body of every outbound request (RL2-PROBE-06: no capability-test request without a button press). */
        val bodies: MutableList<String> = Collections.synchronizedList(mutableListOf())
        var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(accountID) }
        /** API key and an "on every probe request arrival" hook: tests use it to simulate the connection being edited during probing. */
        var apiKey = "sk-test"
        var onPing: () -> Unit = {}
        /** Persisted tool-call memory content (minimal SharedPreferences semantics), used to count entries per connection. */
        val prefsData = mutableMapOf<String, String?>()
        private val prefs = mockk<android.content.SharedPreferences>().also { prefs ->
            val editor = mockk<android.content.SharedPreferences.Editor>()
            every { editor.putString(any(), any()) } answers { prefsData[firstArg()] = secondArg(); editor }
            every { editor.apply() } returns Unit
            every { prefs.edit() } returns editor
            every { prefs.getString(any(), any()) } answers { prefsData[firstArg()] ?: secondArg() }
        }
        val toolCallMemory = ai.oriveo.community.core.provider.ToolCallMemoryStore({ prefs }, json)

        private val engine = MockEngine { request ->
            bodies += (request.body as? TextContent)?.text.orEmpty()
            if (request.method == HttpMethod.Get) {
                return@MockEngine if (request.url.encodedPath == "/v1/models") {
                    respond(
                        catalogBody(catalogModels),
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                    )
                } else {
                    respond("", HttpStatusCode.NotFound)
                }
            }
            val path = request.url.encodedPath
            val short = probeShortName(path) ?: return@MockEngine respond("", HttpStatusCode.NotFound)
            val model = if (short == "gemini") {
                path.substringAfter("/models/").substringBefore(":")
            } else {
                Json.parseToJsonElement((request.body as TextContent).text).jsonObject.string("model")
            }
            pings += listOf(model, short)
            onPing()
            val (status, body) = outcomeReply(pingOutcomes["$model@$short"] ?: "http_404") ?: throw IOException("connection reset")
            respond(body, status, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>()
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            // A single-key catalog refresh writing the primary key's state materializes a list; non-primary key values are persisted here as usual (none when there is only one).
            every { keys.saveRelayKeySecrets(any(), any(), any()) } returns Unit
            ProviderRepository(
                dao = dao,
                secureKeyStore = keys,
                openRouterService = mockk(relaxed = true),
                openAIService = mockk(relaxed = true),
                deepSeekService = mockk(relaxed = true),
                grokService = mockk(relaxed = true),
                anthropicService = mockk(relaxed = true),
                geminiService = mockk(relaxed = true),
                groqService = mockk(relaxed = true),
                togetherService = mockk(relaxed = true),
                fireworksService = mockk(relaxed = true),
                miniMaxService = mockk(relaxed = true),
                zhipuService = mockk(relaxed = true),
                qwenService = mockk(relaxed = true),
                moonshotService = mockk(relaxed = true),
                mistralService = mockk(relaxed = true),
                siliconFlowService = mockk(relaxed = true),
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                toolCallMemoryStore = toolCallMemory,
                relayModelFamily = family,
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) }
    }

    /** Fixture model (with optional model-level fields) -> local model; override values go through the production decoder. */
    private fun fixtureModel(item: JsonObject): AIModel = AIModel(
        id = item.string("id"),
        name = item.string("id"),
        relayTransport = item["relayTransport"]?.jsonPrimitive?.content?.let { wire ->
            RelayTransport.entries.single { it.value == wire }
        },
        relayTransportSource = item["relayTransportSource"]?.jsonPrimitive?.content?.let { wire ->
            ai.oriveo.community.core.model.RelayTransportSource.entries.single { it.value == wire }
        },
        relayCapabilityOverrides = item["relayCapabilityOverrides"]?.let {
            json.decodeFromJsonElement(ai.oriveo.community.core.model.RelayCapabilityOverridesSerializer, it)
        },
    )

    private fun relayConnection(connection: JsonObject, models: List<AIModel>, enabled: List<AIModel>, defaultID: String?) = Provider(
        id = connectionID,
        kind = ProviderKind.Relay,
        baseUrlText = connection.string("baseURL"),
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.entries.single { it.value == connection.string("transport") },
        ),
        models = enabled.map { it.copy(isDefault = it.id == defaultID) },
        catalogModels = models,
    )

    private fun assertModelFields(caseId: String, stored: Provider, expectedModels: JsonObject) {
        for ((modelID, fields) in expectedModels) {
            val model = stored.models.single { it.id == modelID }
            val expected = fields.jsonObject
            assertEquals("$caseId/$modelID: relayTransport", expected["relayTransport"]?.jsonPrimitive?.content, model.relayTransport?.value)
            assertEquals(
                "$caseId/$modelID: relayTransportSource",
                expected["relayTransportSource"]?.jsonPrimitive?.content,
                model.relayTransportSource?.value,
            )
            val expectedOverrides = expected["relayCapabilityOverrides"]
                ?.let { json.decodeFromJsonElement(ai.oriveo.community.core.model.RelayCapabilityOverridesSerializer, it) }
            assertEquals("$caseId/$modelID: relayCapabilityOverrides", expectedOverrides, model.relayCapabilityOverrides)
        }
    }

    /**
     * RL2-PROBE-06 (capability-test.v1.json `noAutomaticRequests`): request bodies sent by add / enable / re-detect
     * contain neither the built-in image base64 nor the built-in tool name; capability-test requests are sent only when the user presses the button.
     */
    private fun assertNoCapabilityTestRequests(caseId: String, bodies: List<String>) {
        val builtins = fixture("capability-test.v1.json").getValue("builtins").jsonObject
        val image = builtins.string("imagePNGBase64")
        val tool = builtins.getValue("tool").jsonObject.string("name")
        assertTrue("$caseId: there are requests to inspect", bodies.isNotEmpty())
        for (body in bodies.toList()) {
            assertFalse("$caseId: RL2-PROBE-06 no vision test request without a button press", image in body)
            assertFalse("$caseId: RL2-PROBE-06 no tool test request without a button press", tool in body)
        }
    }

    private fun expectedPings(expect: JsonObject): List<List<String>> =
        expect.getValue("pings").jsonArray.map { pair -> pair.jsonArray.map { it.jsonPrimitive.content } }

    @Test
    fun `RL2-PROBE-04 enable scenarios lazily probe the enabled model after it is persisted`() {
        val scenarios = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }
            .filter { it.string("step") == "enable_model" }
        assertEquals(
            setOf(
                "enable_probes_the_enabled_model_and_stores_reachable",
                "enable_with_every_candidate_failing_still_enables_and_follows_the_connection",
                "enable_on_a_user_chosen_connection_protocol_sends_no_probe_and_pins_nothing",
                "enable_stops_at_an_inconclusive_first_candidate_and_pins_nothing",
                "enable_moves_on_after_a_route_level_403",
            ),
            scenarios.map { it.string("caseId") }.toSet(),
        )
        val ran = mutableListOf<String>()
        for (scenario in scenarios) {
            val caseId = scenario.string("caseId")
            val pings = scenario.getValue("ping").jsonObject.mapValues { it.value.jsonPrimitive.content }
            when (caseId) {
                // Per the scenario $comment: each outcome in inconclusive is run once, replacing the first candidate's http_429.
                "enable_stops_at_an_inconclusive_first_candidate_and_pins_nothing" -> {
                    val first = pings.entries.single { it.value == "http_429" }.key
                    val inconclusive = orchestration.getValue("probeOutcomeRules").jsonObject.strings("inconclusive")!!
                    assertTrue("http_429" in inconclusive && inconclusive.size >= 7)
                    for (outcome in inconclusive) {
                        runEnableScenario(scenario, pings + (first to outcome), "$caseId[$outcome]")
                        ran += "$caseId[$outcome]"
                    }
                }
                // Each outcome in routeRejected (including the 2xx HTML page html_200) replaces the first candidate's http_403_route: all continue to the next candidate.
                "enable_moves_on_after_a_route_level_403" -> {
                    val first = pings.entries.single { it.value == "http_403_route" }.key
                    val routeRejected = orchestration.getValue("probeOutcomeRules").jsonObject.strings("routeRejected")!!
                    assertTrue("http_403_route" in routeRejected && "html_200" in routeRejected)
                    for (outcome in routeRejected) {
                        runEnableScenario(scenario, pings + (first to outcome), "$caseId[$outcome]")
                        ran += "$caseId[$outcome]"
                    }
                }
                else -> {
                    runEnableScenario(scenario, pings, caseId)
                    ran += caseId
                }
            }
        }
        assertEquals("every enable scenario actually ran: $ran", scenarios.size - 2 + 7 + 5, ran.size)
    }

    private fun runEnableScenario(scenario: JsonObject, pingOutcomes: Map<String, String>, caseId: String) = runBlocking {
        val connection = scenario.getValue("connection").jsonObject
        val items = scenario.getValue("models").jsonArray.map { it.jsonObject }
        val catalog = items.map { fixtureModel(it) }
        val enable = scenario.string("enable")
        val familyCalls = mutableListOf<String>()
        val harness = RepositoryHarness(
            catalogModels = items,
            pingOutcomes = pingOutcomes,
            // The model was already written by the single enable action (the production ViewModel persists the enable first, then calls lazy verification; see ProviderDetailViewModelTest).
            initial = relayConnection(connection, catalog, catalog.filter { it.id == enable }, enable),
            family = { id -> familyCalls += id; null },
        )
        // Catalog refresh parses the raw /models body via the production RelayService and fills the endpoint types cache.
        assertTrue("$caseId: catalog refresh", harness.repository.refreshRelayCatalogOnly(connectionID).catalogSucceeded)

        harness.repository.probeEnabledRelayModel(connectionID, enable)

        val expect = scenario.getValue("expect").jsonObject
        val expectedPings = expectedPings(expect)
        assertEquals("$caseId: probe requests", expectedPings, harness.pings.toList())
        val stored = harness.current()
        assertEquals(
            "$caseId: enabled",
            expect.getValue("enabled").jsonArray.map { it.jsonPrimitive.content },
            stored.models.map { it.id },
        )
        assertEquals("$caseId: connection default protocol", expect.string("connectionTransport"), stored.relayRequested?.transport?.value)
        assertEquals(
            "$caseId: resolvedAPIBaseURLs",
            expect.getValue("resolvedAPIBaseURLs").jsonObject.mapValues { it.value.jsonPrimitive.content },
            stored.relayRequested?.resolvedAPIBaseURLs.orEmpty(),
        )
        assertModelFields(caseId, stored, expect.getValue("models").jsonObject)
        // The family is looked up only when a probe is really needed and endpoint types cannot map to a protocol; if the user chose the connection protocol, neither probe nor lookup happens.
        val needsFamily = expectedPings.isNotEmpty() &&
            items.single { it.string("id") == enable }.strings("supportedEndpointTypes").isNullOrEmpty()
        assertEquals("$caseId: family lookup", if (needsFamily) listOf(enable) else emptyList<String>(), familyCalls)
        assertNoCapabilityTestRequests(caseId, harness.bodies)

        // Row state for this session: probes were sent but none passed -> not connected (with reason); passed or none sent -> no state kept.
        val pinned = stored.models.single { it.id == enable }.relayTransport != null
        val probeState = harness.repository.relayModelProbeStates(connectionID)[enable]
        if (expectedPings.isNotEmpty() && !pinned) {
            assertTrue("$caseId: an inconclusive probe is still recorded as not connected", probeState is ProviderRepository.RelayModelProbeState.Failed)
        } else {
            assertEquals("$caseId: no lazy-verification state is kept", null, probeState)
        }

        // Models that already have a protocol (any source) and models whose connection protocol the user chose are not probed again: calling once more sends 0 requests.
        val before = harness.pings.size
        harness.repository.probeEnabledRelayModel(connectionID, enable)
        if (pinned || expectedPings.isEmpty()) {
            assertEquals("$caseId: not probed again", before, harness.pings.size)
        }
    }

    @Test
    fun `RL2-PROBE-04 lazy probe skips local engines and models that are not enabled`() = runBlocking {
        val items = listOf(buildJsonObject { put("id", "o3-pro"); put("supportedEndpointTypes", buildJsonArray { add(JsonPrimitive("openai-response")) }) })
        val connection = buildJsonObject { put("baseURL", "https://relay.example.com/v1"); put("transport", "auto") }
        val catalog = items.map { fixtureModel(it) }
        val local = relayConnection(connection, catalog, catalog, "o3-pro").let {
            it.copy(relayRequested = it.relayRequested?.copy(engineProfile = "llama_cpp"))
        }
        val engineHarness = RepositoryHarness(items, mapOf("o3-pro@responses" to "ok"), local)
        engineHarness.repository.probeEnabledRelayModel(connectionID, "o3-pro")
        assertEquals("local engine is not probed", emptyList<List<String>>(), engineHarness.pings.toList())

        val notEnabled = RepositoryHarness(items, mapOf("o3-pro@responses" to "ok"), relayConnection(connection, catalog, emptyList(), null))
        notEnabled.repository.probeEnabledRelayModel(connectionID, "o3-pro")
        assertEquals("a model that is not enabled is not probed", emptyList<List<String>>(), notEnabled.pings.toList())
    }

    @Test
    fun `RL2-PROBE-04 a delivered send upgrades reachable to observed`() = runBlocking {
        val scenario = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }
            .single { it.string("caseId") == "a_delivered_send_upgrades_reachable_to_observed" }
        val connection = buildJsonObject { put("baseURL", "https://relay.example.com/v1"); put("transport", "openai_chat_completions") }
        for (row in scenario.getValue("before").jsonArray.map { it.jsonObject }) {
            val caseId = "a_delivered_send/${row.string("id")}"
            val model = fixtureModel(row)
            val harness = RepositoryHarness(emptyList(), emptyMap(), relayConnection(connection, listOf(model), listOf(model), model.id))
            val sendStart = harness.current()
            val startModel = sendStart.models.single { it.id == model.id }
            // Production decision: snapshot at send start + outcome; when a write-back is needed, the production repository compares against the value currently in the database.
            val delivered = row.string("outcome") == "delivered"
            ai.oriveo.community.core.data.repository.relayObservedPromotionTransport(sendStart, startModel, delivered)
                ?.let { harness.repository.promoteRelayModelToObserved(connectionID, startModel.id, it) }

            assertModelFields(caseId, harness.current(), buildJsonObject { put(model.id, row.getValue("after")) })
        }

        // Following the connection (chat) at start, then written as same-protocol reachable by lazy verification mid-send: promoted to observed on completion per the contract;
        // written as another protocol -> no write. Both the decision and the write-back use production functions.
        for ((pinnedTo, expected) in listOf(
            RelayTransport.OpenAIChatCompletions to ai.oriveo.community.core.model.RelayTransportSource.Observed,
            RelayTransport.OpenAIResponses to ai.oriveo.community.core.model.RelayTransportSource.Reachable,
        )) {
            val following = AIModel(id = "f", name = "f")
            val h = RepositoryHarness(emptyList(), emptyMap(), relayConnection(connection, listOf(following), listOf(following), "f"))
            val start = h.current()
            val sent = ai.oriveo.community.core.data.repository.relayObservedPromotionTransport(
                start, start.models.single(), delivered = true,
            )
            assertEquals(RelayTransport.OpenAIChatCompletions, sent)
            h.stored = with(ProviderMapper) {
                RelayModelProbe.applyingPass(start, "f", RelayModelProbePass(pinnedTo, "https://relay.example.com/v1")).toEntity(accountID)
            }
            h.repository.promoteRelayModelToObserved(connectionID, "f", requireNotNull(sent))
            val after = h.current().models.single()
            assertEquals("pinned to ${pinnedTo.value} mid-send", pinnedTo, after.relayTransport)
            assertEquals("pinned to ${pinnedTo.value} mid-send", expected, after.relayTransportSource)
        }

        // If the protocol changed mid-send (differs from the start), nothing is written.
        val model = AIModel(
            id = "a", name = "a",
            relayTransport = RelayTransport.OpenAIResponses,
            relayTransportSource = ai.oriveo.community.core.model.RelayTransportSource.Reachable,
        )
        val harness = RepositoryHarness(emptyList(), emptyMap(), relayConnection(connection, listOf(model), listOf(model), "a"))
        val entityBefore = harness.stored
        harness.repository.promoteRelayModelToObserved(connectionID, "a", RelayTransport.OpenAIChatCompletions)
        assertTrue("protocol changed, no database write", entityBefore === harness.stored)
    }

    @Test
    fun `RL2-PROBE-05 redetect clears reachable and negative caches and re-probes only the default model`() = runBlocking {
        val scenario = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }
            .single { it.string("caseId") == "redetect_clears_reachable_and_negative_cache_and_keeps_stronger_sources" }
        val caseId = scenario.string("caseId")
        val connection = scenario.getValue("connection").jsonObject
        val items = scenario.getValue("models").jsonArray.map { it.jsonObject }
        val models = items.map { fixtureModel(it) }
        val defaultID = scenario.string("defaultModel")
        val initial = relayConnection(connection, models, models, defaultID).let {
            // An earlier probe already wrote a reachable root; re-detection does not delete it (only adds / overwrites the entry that passed this time).
            it.copy(relayRequested = it.relayRequested?.copy(resolvedAPIBaseURLs = mapOf("openai_responses" to "https://relay.example.com/v1")))
        }
        val harness = RepositoryHarness(
            catalogModels = items,
            pingOutcomes = scenario.getValue("ping").jsonObject.mapValues { it.value.jsonPrimitive.content },
            initial = initial,
        )
        // One existing negative-cache entry of each kind for this connection.
        val provider = harness.current()
        val toolModel = provider.models.single { it.id == "gpt-4o-mini" }
        harness.toolCallMemory.record(accountID, provider, toolModel, observedToolCall = false, reason = "upstream_rejected")
        assertEquals(false, harness.toolCallMemory.lookup(accountID, provider, toolModel))
        val rejection = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity(
            connectionId = connectionID,
            canonicalModelId = "o3-pro",
            finalTransport = "openai_responses",
            runtimeRevision = "rev-1",
        )
        var rejectionPayload: String? = null
        ai.oriveo.community.core.provider.ModelControlRejectionCache.configurePersistenceForTesting(
            { rejectionPayload },
            { rejectionPayload = it },
        )
        /** Number of entries belonging to this connection in the persisted content of both negative caches (reads the real persisted payload, not a constant). */
        fun negativeCacheEntries(): Int = listOfNotNull(rejectionPayload, *harness.prefsData.values.toTypedArray())
            .sumOf { payload -> countConnectionEntries(Json.parseToJsonElement(payload)) }
        try {
            ai.oriveo.community.core.provider.ModelControlRejectionCache.record(rejection, "reasoning", "custom", "/reasoning/effort")
            assertTrue(ai.oriveo.community.core.provider.ModelControlRejectionCache.isRejected(rejection, "reasoning", "custom"))
            assertEquals("$caseId: negative-cache entries of this connection before re-detection", 2, negativeCacheEntries())

            harness.repository.redetectRelayModels(connectionID)

            val expect = scenario.getValue("expect").jsonObject
            assertEquals("$caseId: probe requests", expectedPings(expect), harness.pings.toList())
            assertNoCapabilityTestRequests(caseId, harness.bodies)
            val stored = harness.current()
            assertEquals(
                "$caseId: enabled",
                expect.getValue("enabled").jsonArray.map { it.jsonPrimitive.content },
                stored.models.map { it.id },
            )
            assertEquals("$caseId: connection default protocol", expect.string("connectionTransport"), stored.relayRequested?.transport?.value)
            assertModelFields(caseId, stored, expect.getValue("models").jsonObject)
            assertEquals(
                "$caseId: negative-cache entries",
                expect.getValue("negativeCacheEntriesForConnection").jsonPrimitive.content.toInt(),
                negativeCacheEntries(),
            )
            assertEquals("$caseId: tool-call memory", null, harness.toolCallMemory.lookup(accountID, stored, stored.models.single { it.id == "gpt-4o-mini" }))
            assertFalse(
                "$caseId: capability rejection cache",
                ai.oriveo.community.core.provider.ModelControlRejectionCache.isRejected(rejection, "reasoning", "custom"),
            )
        } finally {
            ai.oriveo.community.core.provider.ModelControlRejectionCache.clearForTesting()
        }
    }

    @Test
    fun `RL2-PROBE-05 redetect on a user chosen connection protocol clears reachable and sends no probe`() = runBlocking {
        val redetects = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }.filter { it.string("step") == "redetect" }
        assertEquals("each re-detect scenario has a test", 2, redetects.size)
        val scenario = redetects.single {
            it.string("caseId") == "redetect_on_a_user_chosen_connection_protocol_clears_reachable_and_sends_no_probe"
        }
        val caseId = scenario.string("caseId")
        val items = scenario.getValue("models").jsonArray.map { it.jsonObject }
        val models = items.map { fixtureModel(it) }
        val harness = RepositoryHarness(
            catalogModels = items,
            pingOutcomes = scenario.getValue("ping").jsonObject.mapValues { it.value.jsonPrimitive.content },
            initial = relayConnection(scenario.getValue("connection").jsonObject, models, models, null),
        )
        assertEquals("$caseId: precondition - there is a reachable entry to clear", RelayTransport.OpenAIResponses, harness.current().models.first().relayTransport)

        harness.repository.redetectRelayModels(connectionID)

        val expect = scenario.getValue("expect").jsonObject
        assertEquals("$caseId: probe requests", expectedPings(expect), harness.pings.toList())
        assertNoCapabilityTestRequests(caseId, harness.bodies)
        val stored = harness.current()
        assertEquals("$caseId: enabled", expect.getValue("enabled").jsonArray.map { it.jsonPrimitive.content }, stored.models.map { it.id })
        assertEquals("$caseId: connection default protocol", expect.string("connectionTransport"), stored.relayRequested?.transport?.value)
        assertModelFields(caseId, stored, expect.getValue("models").jsonObject)
    }

    @Test
    fun `RL2-PROBE-04 reachable does not authorize the native file whitelist`() {
        val scenario = orchestration.getValue("scenarios").jsonArray.map { it.jsonObject }
            .single { it.string("caseId") == "reachable_does_not_authorize_the_native_file_whitelist" }
        val modelID = "claude-sonnet-4-5"
        // S0 official Anthropic catalog entry: carries the native-PDF allowlist and pdfNativeDefault.
        ai.oriveo.community.core.provider.MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$modelID":"$modelID"},
               "models":{"$modelID":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true,
               "attachmentExtraction":{"maxLines":321}}}}}}""",
        )
        try {
            val pdf = ai.oriveo.community.core.model.Attachment(
                id = "pdf",
                kind = ai.oriveo.community.core.model.AttachmentKind.File,
                fileName = "report.pdf",
                mimeType = "application/pdf",
                base64Data = java.util.Base64.getEncoder().encodeToString("extracted text".toByteArray()),
                extractedSizeBytes = 5_000,
                originalBase64Data = java.util.Base64.getEncoder().encodeToString("%PDF-1.7".toByteArray()),
            )
            val messages = listOf(
                ai.oriveo.community.core.provider.ProviderTestFixtures.userMessage("read", ProviderKind.Relay, modelID)
                    .copy(attachments = listOf(pdf)),
            )
            val official = requireNotNull(
                ai.oriveo.community.core.data.remote.MetadataClient.resolveAIModelForRouter(modelID, ProviderKind.Anthropic),
            )
            for ((sourceWire, verdict) in scenario.getValue("sources").jsonObject) {
                val source = ai.oriveo.community.core.model.RelayTransportSource.entries.single { it.value == sourceWire }
                val model = AIModel(
                    id = modelID,
                    name = modelID,
                    relayTransport = RelayTransport.AnthropicMessages,
                    relayTransportSource = source,
                )
                val inherited = verdict.jsonPrimitive.content == "inherited"
                val provider = Provider(
                    id = connectionID,
                    kind = ProviderKind.Relay,
                    baseUrlText = "https://relay.example.com/v1",
                    relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
                    models = listOf(model),
                )
                // Production request body builder: with reachable the PDF does not use a native document block; observed / user follow S0.
                val body = buildAnthropicBody(
                    modelID = modelID,
                    messages = messages,
                    stream = true,
                    reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                    requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(
                        relayRequested = provider.relayRequested,
                        activeModel = model,
                    ),
                )
                assertEquals("$sourceWire: native document block", inherited, "\"type\":\"document\"" in body)
                // Attachment route resolution before sending uses the same function as the request body.
                val route = ai.oriveo.community.core.provider.AttachmentTransportResolver.routesFor(
                    provider,
                    model,
                    webSearchEnabled = false,
                    reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                    toolLoopPossible = false,
                )?.single()?.model
                val routed = requireNotNull(route) { "$sourceWire: route" }
                assertEquals("$sourceWire: nativeFileMimes", if (inherited) official.nativeFileMimes else emptyList<String>(), routed.nativeFileMimes)
                assertEquals("$sourceWire: pdfNativeDefault", inherited && official.pdfNativeDefault, routed.pdfNativeDefault)
                assertEquals("$sourceWire: attachmentExtraction is carried over", official.attachmentExtraction, routed.attachmentExtraction)
            }
            // Following the connection (nil) follows S0.
            assertEquals(official, relayRouterModel(modelID, ProviderKind.Anthropic, AIModel(id = modelID, name = modelID)))
        } finally {
            ai.oriveo.community.core.provider.MetadataTestFixtures.clear()
        }
    }

    private fun countConnectionEntries(element: kotlinx.serialization.json.JsonElement): Int = when (element) {
        is JsonObject -> (if (element["connectionId"]?.jsonPrimitive?.content == connectionID) 1 else 0) +
            element.values.sumOf(::countConnectionEntries)
        is JsonArray -> element.sumOf(::countConnectionEntries)
        else -> 0
    }

    @Test
    fun `RL2-PROBE-04 a lazy probe is not written back when the connection changed while probing`() = runBlocking {
        val items = listOf(
            buildJsonObject {
                put("id", "o3-pro")
                put("supportedEndpointTypes", buildJsonArray { add(JsonPrimitive("openai-response")) })
            },
        )
        val connection = buildJsonObject { put("baseURL", "https://relay.example.com/v1"); put("transport", "auto") }
        val catalog = items.map { fixtureModel(it) }
        val changes: List<Pair<String, (RepositoryHarness) -> Unit>> = listOf(
            "API key" to { h -> h.apiKey = "sk-rotated" },
            "auth mode" to { h ->
                h.stored = with(ProviderMapper) {
                    h.current().let { it.copy(relayRequested = it.relayRequested?.copy(authMode = ai.oriveo.community.core.model.RelayAuthMode.XApiKey)) }
                        .toEntity(accountID)
                }
            },
            "safe mode" to { h ->
                h.stored = with(ProviderMapper) {
                    h.current().let {
                        it.copy(relayRequested = it.relayRequested?.copy(securityMode = ai.oriveo.community.core.model.RelayConnectionSecurityMode.LocalHttp))
                    }.toEntity(accountID)
                }
            },
        )
        for ((label, change) in changes) {
            val harness = RepositoryHarness(items, mapOf("o3-pro@responses" to "ok"), relayConnection(connection, catalog, catalog, "o3-pro"))
            assertTrue(harness.repository.refreshRelayCatalogOnly(connectionID).catalogSucceeded)
            harness.onPing = { change(harness) }
            harness.repository.probeEnabledRelayModel(connectionID, "o3-pro")
            assertEquals("$label: probed", listOf(listOf("o3-pro", "responses")), harness.pings.toList())
            val stored = harness.current()
            assertEquals("$label: protocol is not written back", null, stored.models.single().relayTransport)
            assertEquals("$label: root is not written back", null, stored.relayRequested?.resolvedAPIBaseURLs?.get("openai_responses"))
        }
    }
}
