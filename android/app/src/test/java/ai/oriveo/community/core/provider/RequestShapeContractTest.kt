package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.provider.transport.TransportKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Android side of the shared request-shape contract in
 * `shared/model-contracts/request_shape_contract.v1.json`.
 *
 * The fixture pins the endpoint, headers, query and body (dot-path includes plus excludes)
 * that each built-in provider is expected to send, so every client that reads the same
 * fixture must produce the same wire shape. fixture.metadata is loaded into the
 * MetadataClient singleton, each case is dispatched to the ProviderService for its
 * providerKind, and a MockEngine captures the first upstream request that actually goes out.
 */
class RequestShapeContractTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val transportRegistry = TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        UnsupportedParamCache.resetForTest()
    }

    @Test
    fun `shared request shape contract matches Android provider requests`() = runTest {
        val contract = loadContract()
        // Pinning the case count to the fixture is the insurance against silently skipping
        // part of the matrix.
        assertEquals("fixture cases count", 74, contract.cases.size)
        MetadataTestFixtures.applyRaw(contract.metadata.toString())

        val representative = requireNotNull(
            MetadataClient.instance.currentCapabilityEvidenceModel("gpt-5-mini", ProviderKind.OpenAI),
        ) { "gpt-5-mini legacy metadata was not published" }
        val representativeModel = CatalogModelBuilder.buildCatalogModel(
            ProviderKind.OpenAI, "gpt-5-mini", "gpt-5-mini",
        )
        val representativeProjection = officialRequestCapabilityProjection(
            ProviderKind.OpenAI,
            "gpt-5-mini",
            ChatRequestOptions(activeModel = representativeModel, temperature = 0.31f),
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        assertEquals("legacy evidence must not be malformed", null, representative.metadata.capabilityEvidenceViewMalformed)
        assertEquals("legacy reasoning profile must declare deep", true, "deep" in representative.declaredReasoningLevels)
        assertEquals("legacy generation profile must publish", true, representative.metadata.profiles.generation != null)
        listOf("reasoning_level/deep", "web_search", "generation_parameter/temperature").forEach { key ->
            assertFalse(
                "legacy $key must remain a reader-only hint without exact runtime: ${representativeProjection.decision(key)}",
                representativeProjection.permitsOutbound(key),
            )
        }
        val mismatchedTransportProjection = officialRequestCapabilityProjection(
            ProviderKind.OpenAI,
            "gpt-5-mini",
            ChatRequestOptions(activeModel = representativeModel, temperature = 0.31f),
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            finalTransport = TransportKind.OpenAIChat.wireValue,
        )
        assertEquals(
            "a responses declaration must not authorise the final chat branch",
            false,
            mismatchedTransportProjection.permitsOutbound("reasoning_level/deep"),
        )
        // The legacy v1 Gemini fixture intentionally omits model.transport. The actual
        // generate branch must supply its transport, rather than treating the model as unknown.
        val gemini = requireNotNull(
            MetadataClient.instance.currentCapabilityEvidenceModel("gemini-3.1-flash-preview", ProviderKind.Gemini),
        )
        val geminiProjection = officialRequestCapabilityProjection(
            ProviderKind.Gemini,
            "gemini-3.1-flash-preview",
            ChatRequestOptions(),
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            finalTransport = TransportKind.GeminiGenerate.wireValue,
        )
        listOf("reasoning_level/deep", "web_search").forEach { key ->
            assertFalse(
                "Gemini legacy $key must not authorize an automatic field without exact runtime: " +
                    "${geminiProjection.decision(key)}; metadata=$gemini",
                geminiProjection.permitsOutbound(key),
            )
        }

        // The v1 fixture still covers the endpoint, header, query, image-only and plain-body
        // readers, but it carries no capabilityRuntime, so its older reasoning, web and
        // generation expectations can no longer prove that a send automatically injects those
        // fields. For those intents the production request must come out exactly equivalent to
        // the neutral baseline for the same model.
        val failures = mutableListOf<String>()
        contract.cases.forEach { contractCase ->
            val captured = captureRequest(contractCase)
            val hasModelControlIntent = contractCase.intent.hasModelControlIntent()
            collectMismatches(
                contractCase.caseId,
                captured,
                contractCase.expect,
                failures,
                checkBody = !hasModelControlIntent,
            )
            if (hasModelControlIntent) {
                val baseline = captureRequest(contractCase.withNeutralModelControls())
                collectNeutralBaselineMismatches(contractCase.caseId, captured, baseline, failures)
            }
        }
        if (failures.isNotEmpty()) {
            fail("request shape contract mismatched in ${failures.size} place(s):\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun `legacy-only controls stay unknown and hidden without an exact runtime`() = runTest {
        val contract = loadContract()
        assertEquals("fixture uiCases count", 2, contract.uiCases.size)
        MetadataTestFixtures.applyRaw(contract.metadata.toString())

        val resolver = ChatModelCapabilityResolver()
        contract.uiCases.forEach { uiCase ->
            val kind = providerKind(uiCase.intent.providerKind)
            val model = CatalogModelBuilder.buildCatalogModel(
                providerKind = kind,
                runtimeModelId = uiCase.intent.modelId,
                fallbackName = uiCase.intent.modelId,
            )
            // Two conditions gate visibility: the capability and its matching profile both
            // have to be present (see ChatModelCapabilityResolver).
            val visible = when (uiCase.intent.capability) {
                "web" -> resolver.supportsWeb(Provider(id = "ui", kind = kind), model)
                "reasoning" -> resolver.supportsReasoning(Provider(id = "ui", kind = kind), model)
                else -> error("uiCase capability is not wired into the harness: ${uiCase.intent.capability}")
            }
            assertEquals("${uiCase.caseId} visible gate", uiCase.expect.visible, visible)
        }

        var legacyProfileCases = 0
        contract.metadata["providers"]!!.jsonObject.forEach { (rawKind, providerRaw) ->
            val kind = providerKind(rawKind)
            providerRaw.jsonObject["models"]!!.jsonObject.forEach modelLoop@{ (modelId, modelRaw) ->
                val profiles = modelRaw.jsonObject["profiles"]?.jsonObject ?: return@modelLoop
                val model = CatalogModelBuilder.buildCatalogModel(kind, modelId, modelId)
                profiles["webSearch"]?.takeUnless { it is JsonNull }?.let {
                    legacyProfileCases += 1
                    assertFalse(
                        "$rawKind/$modelId legacy web profile must not make the new UI auto-visible",
                        resolver.supportsWeb(Provider(id = "ui-$rawKind", kind = kind), model),
                    )
                }
                profiles["reasoning"]?.takeUnless { it is JsonNull }?.let {
                    legacyProfileCases += 1
                    assertFalse(
                        "$rawKind/$modelId legacy reasoning profile must not make the new UI auto-visible",
                        resolver.supportsReasoning(Provider(id = "ui-$rawKind", kind = kind), model),
                    )
                }
            }
        }
        assertTrue("v1 fixture must exercise at least one reader-only legacy profile", legacyProfileCases > 0)
    }

    /**
     * Two guards over image-generation dispatch, both deciding route and requestDefaults
     * through the same resolver the production code uses.
     *
     * The first guard requires every imageGen profile in the metadata to be exercised by at
     * least one case, which catches a route that was never wired up and a fixture that is
     * missing a case.
     *
     * The second guard requires every key in a route-style profile's requestDefaults to be
     * asserted in the matching case's bodyIncludes (dashscope_multimodal nests them under
     * parameters.<key>, everything else puts them at the top level). Combined with the main
     * contract's rule that whatever is in bodyIncludes must appear in the body, that proves the
     * fields the catalog publishes are actually consumed, and catches a client-side hard-coded
     * value quietly overriding requestDefaults.
     */
    @Test
    fun `every imageGen profile is exercised and its requestDefaults asserted`() = runTest {
        val contract = loadContract()
        MetadataTestFixtures.applyRaw(contract.metadata.toString())

        val declaredProfiles = contract.metadata["profiles"]?.jsonObject
            ?.get("imageGen")?.jsonObject?.keys.orEmpty().toSet()

        // Map each case to the name of its imageGen profile, resolved through the same lookup
        // used when dispatching to the service.
        val caseProfile: List<Pair<ContractCase, String>> = contract.cases.mapNotNull { contractCase ->
            val kind = providerKind(contractCase.intent.providerKind)
            MetadataClient.resolveCatalogModel(contractCase.intent.modelId, kind)
                ?.profiles?.imageGen
                ?.let { contractCase to it }
        }

        // First guard.
        val exercised = caseProfile.map { it.second }.toSet()
        val missing = declaredProfiles - exercised
        assertEquals("imageGen profiles with no case covering them: $missing", emptySet<String>(), missing)

        // Second guard.
        val failures = mutableListOf<String>()
        caseProfile.forEach { (contractCase, profile) ->
            val route = MetadataClient.imageGenRoute(profile) ?: return@forEach
            val defaults = MetadataClient.imageGenRequestDefaults(profile) ?: return@forEach
            val prefix = if (route == "dashscope_multimodal") "parameters." else ""
            defaults.keys.forEach { key ->
                val path = "$prefix$key"
                if (!contractCase.expect.bodyIncludes.containsKey(path)) {
                    failures += "${contractCase.caseId} requestDefaults key '$key' is not asserted in bodyIncludes (expected path=$path)"
                }
            }
        }
        if (failures.isNotEmpty()) {
            fail("requestDefaults consumption unasserted in ${failures.size} place(s):\n" + failures.joinToString("\n"))
        }
    }

    /**
     * The v1 reader's generation intent and provider universe still have to be complete, so
     * older stored data can be recognised on upgrade. It does not prove that the production
     * builder injects those fields; exact generation on the wire is covered by the runtime
     * fixture instead.
     */
    @Test
    fun `legacy generation reader covers every ProviderKind or records an exemption`() {
        val contract = loadContract()
        val universeRaw = contract.generationProviderKindUniverse
        // The fixture's universe has to line up one-for-one with the production enum,
        // otherwise the exemption list can be slipped past by simply omitting a kind.
        assertEquals("universe must not contain duplicates", universeRaw.size, universeRaw.toSet().size)
        assertEquals(
            "generationProviderKindUniverse must equal the full production ProviderKind set",
            ProviderKind.entries.toSet(),
            universeRaw.map { providerKind(it) }.toSet(),
        )

        val exemptions = contract.generationOutboundExemptions.associateBy { it.providerKind }
        val covered = contract.cases
            .filter { it.intent.generationOverrides.isNotEmpty() }
            .map { it.intent.providerKind }
            .toSet()

        val failures = mutableListOf<String>()
        exemptions.forEach { (kind, exemption) ->
            if (kind !in universeRaw) failures += "exempted $kind is not part of the ProviderKind set"
            if (exemption.reason.isBlank()) failures += "$kind has an empty exemption reason"
        }
        universeRaw.forEach { kind ->
            val isCovered = kind in covered
            val isExempt = kind in exemptions
            if (isCovered && isExempt) failures += "$kind has both a generation case and an exemption; pick one"
            if (!isCovered && !isExempt) failures += "$kind has neither a generation case nor an explicit exemption"
        }
        if (failures.isNotEmpty()) {
            fail("generation outbound coverage gate failed in ${failures.size} place(s):\n" + failures.joinToString("\n"))
        }
    }

    /** Reader-only legacy values still have to decode against their historical profile schema. */
    @Test
    fun `legacy generation cases reference parameters the reader can still decode`() {
        val contract = loadContract()
        MetadataTestFixtures.applyRaw(contract.metadata.toString())

        val generationCases = contract.cases.filter { it.intent.generationOverrides.isNotEmpty() }
        if (generationCases.isEmpty()) fail("the fixture has no generation case at all, so nothing consumes this contract")

        val failures = mutableListOf<String>()
        generationCases.forEach { contractCase ->
            val kind = providerKind(contractCase.intent.providerKind)
            val profile = MetadataClient.resolveCatalogModel(contractCase.intent.modelId, kind)
                ?.profiles?.generation
            if (profile == null) {
                failures += "${contractCase.caseId}: the production resolution chain produced no generation profile"
                return@forEach
            }
            val shipped = profile.parameters.mapNotNull { it.id }.toSet()
            contractCase.intent.generationOverrides.keys.forEach { id ->
                if (id !in shipped) failures += "${contractCase.caseId}: parameter $id is not in the model's profile.parameters"
                if (profile.wire[id].isNullOrBlank()) {
                    failures += "${contractCase.caseId} template=${profile.template} has no wire mapping for $id"
                }
            }
        }
        if (failures.isNotEmpty()) {
            fail("generation cases disagree with the published profile in ${failures.size} place(s):\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun `legacy generation publication remains dormant without an exact runtime recipe`() {
        fun payload(wire: String?, includeTemperature: Boolean): String {
            val parameter = if (includeTemperature) {
                "\"parameters\":[{\"id\":\"temperature\",\"support\":\"supported\",\"source\":\"authoritative_metadata\"}]"
            } else "\"parameters\":[]"
            val wires = wire?.let { "\"temperature\":\"$it\"" }.orEmpty()
            return """{"version":1,"profiles":{"generation":{"parameters":{"temperature":{"valueSchema":"number"}},"templates":{"openai_responses":{"wire":{$wires},"transport":"openai_responses"}}}},"providers":{"openAI":{"resolveMap":{"model-a":"model-a"},"models":{"model-a":{"canonicalModelId":"model-a","transport":"openai_responses","profiles":{"generation":{"template":"openai_responses",$parameter}}}}}}}"""
        }
        val stale = GenerationProfileRef(
            template = "openai_responses",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
            wire = mapOf("temperature" to "stale_temperature"),
        )
        val options = ChatRequestOptions(
            activeModel = AIModel(id = "model-a", name = "Model A", generationProfile = stale),
            generationParameters = GenerationParameterOverrides(
                mapOf("temperature" to GenerationParameterOverride(
                    ai.oriveo.community.core.model.GenerationOverrideState.Value,
                    JsonPrimitive(0.4),
                )),
            ),
        )
        MetadataTestFixtures.applyRaw(payload("current_temperature", includeTemperature = true))
        fun projection() = officialRequestCapabilityProjection(
            ProviderKind.OpenAI,
            "model-a",
            options,
            finalTransport = TransportKind.OpenAIResponses.wireValue,
        )
        val resolved = MetadataClient.resolveCatalogModel("model-a", ProviderKind.OpenAI)
        assertFalse(
            "legacy generation candidate must not authorize an explicit override",
            projection().permitsOutbound("generation_parameter/temperature"),
        )
        assertEquals("current_temperature", resolved?.profiles?.generation?.wire?.get("temperature"))
        val currentBody = json.parseToJsonElement(
            GenerationParameterResolver.apply("{}", options, resolved, projection()),
        ).jsonObject
        assertEquals(null, currentBody["current_temperature"]?.jsonPrimitive?.doubleOrNull)
        assertEquals(null, currentBody["stale_temperature"])

        MetadataTestFixtures.applyRaw(payload(null, includeTemperature = false))
        val removed = json.parseToJsonElement(GenerationParameterResolver.apply(
            "{}",
            options,
            MetadataClient.resolveCatalogModel("model-a", ProviderKind.OpenAI),
            projection(),
        )).jsonObject
        assertEquals(null, removed["current_temperature"])
        assertEquals(null, removed["stale_temperature"])
    }

    private suspend fun captureRequest(contractCase: ContractCase): CapturedRequest {
        var captured: CapturedRequest? = null
        val client = HttpClient(
            MockEngine { request ->
                // Only the first request is recorded: a moonshot web tool loop, a qwen image
                // generation follow-up GET and a Responses 404 fallback all send more than one.
                if (captured == null) {
                    captured = CapturedRequest(
                        url = request.url.toString(),
                        headers = request.headers.names().associateWith { name -> request.headers[name].orEmpty() },
                        body = (request.body as? TextContent)?.text.orEmpty(),
                    )
                }
                respond(
                    content = mockResponse(
                        providerKind = contractCase.intent.providerKind,
                        path = java.net.URI(request.url.toString()).rawPath,
                    ),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )
        val kind = providerKind(contractCase.intent.providerKind)
        val service = buildService(kind, client)
        val modelID = contractCase.intent.modelId
        val message = ProviderTestFixtures.userMessage(
            text = "hello",
            providerKind = kind,
            modelName = modelID,
        )
        val mode = reasoningMode(contractCase.intent.reasoningMode)
        // Non-streaming image generation cases (the images_api and dashscope_multimodal
        // routes) list "stream" in bodyExcludes, so they go through sendMessage; chat_api image
        // generation (or_chat, gem_content) and all text go through sendMessageStream.
        val useSendMessage = contractCase.expect.bodyExcludes.contains("stream")
        // Only the intent the panel produced is fed in. The profile and wire mapping are
        // resolved by the production chain (MetadataClient.resolveCatalogModel into
        // GenerationParameterResolver) from the same fixture metadata; the test never writes a
        // profile by hand.
        val requestOptions = if (contractCase.intent.generationOverrides.isEmpty()) {
            ChatRequestOptions()
        } else {
            ChatRequestOptions(
                generationParameters = GenerationParameterOverrides(contractCase.intent.generationOverrides),
            )
        }

        // The request was already captured inside the MockEngine lambda, so a decode failure
        // or empty-response error afterwards is tolerable: this contract only pins the request
        // shape.
        runCatching {
            if (useSendMessage) {
                service.sendMessage(
                    apiKey = "contract-test-key",
                    modelID = modelID,
                    messages = listOf(message),
                    baseUrl = null,
                    supportsImageGen = contractCase.intent.imageGen,
                    reasoningMode = mode,
                    webSearchEnabled = contractCase.intent.webSearch,
                    requestOptions = requestOptions,
                )
            } else {
                service.sendMessageStream(
                    apiKey = "contract-test-key",
                    modelID = modelID,
                    messages = listOf(message),
                    baseUrl = null,
                    supportsImageGen = contractCase.intent.imageGen,
                    reasoningMode = mode,
                    webSearchEnabled = contractCase.intent.webSearch,
                    requestOptions = requestOptions,
                ).toList()
            }
        }
        return requireNotNull(captured) { "case ${contractCase.caseId} did not issue a request" }
    }

    /** Build the ProviderService for a providerKind; the three-argument constructors need the transportRegistry, while the OpenAICompatible subclasses take two. */
    private fun buildService(kind: ProviderKind, client: HttpClient): ProviderService = when (kind) {
        ProviderKind.OpenAI -> OpenAIService(client, json, transportRegistry)
        ProviderKind.Anthropic -> AnthropicService(client, json, transportRegistry)
        ProviderKind.Gemini -> GeminiService(client, json, transportRegistry)
        ProviderKind.Grok -> GrokService(client, json, transportRegistry)
        ProviderKind.Moonshot -> MoonshotService(client, json, transportRegistry)
        ProviderKind.Mistral -> MistralService(client, json, transportRegistry)
        ProviderKind.Qwen -> QwenService(client, json, transportRegistry)
        ProviderKind.Zhipu -> ZhipuService(client, json, transportRegistry)
        ProviderKind.OpenRouter -> OpenRouterService(client, json, transportRegistry)
        ProviderKind.DeepSeek -> DeepSeekService(client, json)
        ProviderKind.MiniMax -> MiniMaxService(client, json)
        ProviderKind.SiliconFlow -> SiliconFlowService(client, json)
        ProviderKind.Groq -> GroqService(client, json)
        ProviderKind.Together -> TogetherService(client, json)
        ProviderKind.Fireworks -> FireworksService(client, json)
        else -> error("Request-shape contract harness does not support $kind")
    }

    private fun collectMismatches(
        caseId: String,
        captured: CapturedRequest,
        expectation: Expectation,
        out: MutableList<String>,
        checkBody: Boolean = true,
    ) {
        val uri = java.net.URI(captured.url)
        if (uri.rawPath != expectation.endpointPath) {
            out += "$caseId endpointPath expected=${expectation.endpointPath} actual=${uri.rawPath}"
        }

        val headers = captured.headers.mapKeys { it.key.lowercase() }
        expectation.headersInclude.forEach { (name, expected) ->
            val actual = headers[name.lowercase()]
            if (isWildcard(expected)) {
                if (actual.isNullOrBlank()) out += "$caseId header $name missing"
            } else if (expected.jsonPrimitive.contentOrNull != actual) {
                out += "$caseId header $name expected=${expected.jsonPrimitive.contentOrNull} actual=$actual"
            }
        }

        val queryNames = uri.rawQuery.orEmpty()
            .split("&")
            .filter { it.isNotBlank() }
            .map { it.substringBefore("=") }
            .toSet()
        expectation.queryExcludes.forEach { name ->
            if (queryNames.contains(name)) out += "$caseId query $name must be absent"
        }

        if (checkBody) {
            val body = json.parseToJsonElement(captured.body)
            expectation.bodyIncludes.forEach { (path, expected) ->
                val actual = valueAtPath(body, path)
                if (isWildcard(expected)) {
                    if (actual == null) out += "$caseId body $path missing"
                } else if (actual != expected) {
                    out += "$caseId body $path expected=$expected actual=$actual"
                }
            }
            expectation.bodyExcludes.forEach { path ->
                val actual = valueAtPath(body, path)
                if (actual != null) out += "$caseId body $path must be absent, actual=$actual"
            }
        }
    }

    private fun collectNeutralBaselineMismatches(
        caseId: String,
        requested: CapturedRequest,
        baseline: CapturedRequest,
        out: MutableList<String>,
    ) {
        val requestedUri = java.net.URI(requested.url)
        val baselineUri = java.net.URI(baseline.url)
        if (requestedUri.rawPath != baselineUri.rawPath) {
            out += "$caseId legacy intent changed endpoint: requested=${requestedUri.rawPath} baseline=${baselineUri.rawPath}"
        }
        if (requestedUri.rawQuery != baselineUri.rawQuery) {
            out += "$caseId legacy intent changed query: requested=${requestedUri.rawQuery} baseline=${baselineUri.rawQuery}"
        }
        if (requested.headers != baseline.headers) {
            out += "$caseId legacy intent changed headers: requested=${requested.headers} baseline=${baseline.headers}"
        }
        val requestedBody = runCatching { json.parseToJsonElement(requested.body) }.getOrNull()
        val baselineBody = runCatching { json.parseToJsonElement(baseline.body) }.getOrNull()
        if (requestedBody == null || baselineBody == null || requestedBody != baselineBody) {
            out += "$caseId legacy intent changed final body: requested=$requestedBody baseline=$baselineBody"
        }
    }

    private fun loadContract(): ContractFile {
        val path = contractCandidates()
            .firstOrNull { Files.exists(it) }
            ?: error("request_shape_contract.v1.json not found")
        return json.decodeFromString(path.toFile().readText())
    }

    private fun contractCandidates(): Sequence<Path> = sequence {
        var current = Paths.get(System.getProperty("user.dir")).toAbsolutePath()
        while (true) {
            yield(current.resolve("shared/model-contracts/request_shape_contract.v1.json"))
            val parent = current.parent ?: break
            current = parent
        }
    }

    /**
     * The mock response only guarantees HTTP 200 plus a terminating event so the stream ends;
     * it makes no promise about semantic correctness. This contract pins the request shape, the
     * request is already captured inside the lambda, and a decode failure during consumption is
     * swallowed by runCatching.
     *
     * The shape differs per transport: OpenAI Responses needs `event:` lines, Grok Responses a
     * `type` field, and OpenAI-compatible chat `data:` lines.
     */
    private fun mockResponse(providerKind: String, path: String): String = when {
        providerKind == "anthropic" -> ANTHROPIC_MOCK
        providerKind == "gemini" -> GEMINI_MOCK
        providerKind == "grok" -> GROK_RESPONSES_MOCK
        path.endsWith("/responses") -> OPENAI_RESPONSES_MOCK
        path.contains("/images") ||
            path.contains("/image_generation") ||
            path.contains("multimodal-generation") -> IMAGE_MOCK
        else -> OPENAI_CHAT_MOCK
    }

    /** The fixture's providerKind uses the catalog's key (togetherAI / fireworksAI) while the enum rawValue is together / fireworks. */
    private fun providerKind(raw: String): ProviderKind = when (raw) {
        "togetherAI" -> ProviderKind.Together
        "fireworksAI" -> ProviderKind.Fireworks
        else -> ProviderKind.fromRawValue(raw) ?: error("Unknown providerKind $raw")
    }

    private fun reasoningMode(raw: String?): ReasoningMode = when (raw) {
        "fast" -> ReasoningMode.Fast
        "balanced" -> ReasoningMode.Balanced
        "deep" -> ReasoningMode.Deep
        "max" -> ReasoningMode.Max
        else -> ReasoningMode.Automatic
    }

    private fun isWildcard(value: JsonElement): Boolean =
        (value as? JsonPrimitive)?.contentOrNull == "*"

    private fun valueAtPath(source: JsonElement, path: String): JsonElement? {
        var current: JsonElement? = source
        path.split(".").forEach { segment ->
            current = when (val value = current) {
                is JsonObject -> value[segment]
                is JsonArray -> segment.toIntOrNull()?.let { value.getOrNull(it) }
                else -> null
            }
        }
        return current
    }

    @Serializable
    private data class ContractFile(
        val version: Int,
        val metadata: JsonObject,
        val cases: List<ContractCase>,
        val uiCases: List<UiCase> = emptyList(),
        val generationProviderKindUniverse: List<String> = emptyList(),
        val generationOutboundExemptions: List<GenerationExemption> = emptyList(),
    )

    @Serializable
    private data class GenerationExemption(
        val providerKind: String,
        val reason: String,
    )

    @Serializable
    private data class ContractCase(
        val caseId: String,
        val intent: Intent,
        val expect: Expectation,
    ) {
        fun withNeutralModelControls(): ContractCase = copy(
            caseId = "$caseId.neutral",
            intent = intent.copy(
                reasoningMode = "automatic",
                webSearch = false,
                generationOverrides = emptyMap(),
            ),
        )
    }

    @Serializable
    private data class Intent(
        val providerKind: String,
        val modelId: String,
        val reasoningMode: String? = null,
        val webSearch: Boolean = false,
        val imageGen: Boolean = false,
        /** The generation parameters the panel produced. The harness feeds them into the production send path unchanged; the profile comes from the production resolution chain. */
        val generationOverrides: Map<String, GenerationParameterOverride> = emptyMap(),
    ) {
        fun hasModelControlIntent(): Boolean =
            webSearch || generationOverrides.isNotEmpty() ||
                (!reasoningMode.isNullOrBlank() && (reasoningMode != "automatic" || !imageGen))
    }

    @Serializable
    private data class Expectation(
        val endpointPath: String,
        val headersInclude: Map<String, JsonElement> = emptyMap(),
        val queryExcludes: List<String> = emptyList(),
        val bodyIncludes: Map<String, JsonElement> = emptyMap(),
        val bodyExcludes: List<String> = emptyList(),
    )

    @Serializable
    private data class UiCase(
        val caseId: String,
        val intent: UiIntent,
        val expect: UiExpect,
    )

    @Serializable
    private data class UiIntent(
        val providerKind: String,
        val modelId: String,
        val capability: String,
    )

    @Serializable
    private data class UiExpect(val visible: Boolean)

    private data class CapturedRequest(
        val url: String,
        val headers: Map<String, String>,
        val body: String,
    )

    private companion object {
        val OPENAI_CHAT_MOCK = """
            data: {"choices":[{"delta":{"content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
            data: [DONE]
        """.trimIndent()

        val OPENAI_RESPONSES_MOCK = """
            event: response.completed
            data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}
        """.trimIndent()

        val GROK_RESPONSES_MOCK = """
            data: {"type":"response.output_text.delta","delta":"hi"}
            data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}
            data: [DONE]
        """.trimIndent()

        val ANTHROPIC_MOCK = """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

            event: content_block_delta
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

            event: message_delta
            data: {"type":"message_delta","usage":{"output_tokens":1}}

            event: message_stop
            data: {"type":"message_stop"}
        """.trimIndent()

        val GEMINI_MOCK = """
            data: {"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}
        """.trimIndent()

        val IMAGE_MOCK = "{}"
    }
}
