package ai.oriveo.community.core.capability

import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.capability.truth.CapabilityTruthRegistry
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import java.io.File
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android assertions for the cross-platform `capability_truth_contract.v1.json`.
 *
 * The fixtures are read-only recordings of production responses and must go through the full production chain:
 * recorded JSON -> production decode and publish boundary -> capability projection -> chat-screen decision.
 * Hand-building a model object with Image only proves the consumer; it cannot prove the recording really reaches the projection.
 */
class CapabilityTruthContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val metadata = MetadataClient()
    private val contract by lazy { readJson("shared/model-contracts/capability_truth_contract.v1.json") }
    private val reasoningModes = ReasoningMode.entries.filter { it != ReasoningMode.Automatic }
    private val keys = setOf("vision_input", "web_search") +
        reasoningModes.map { "reasoning_level/${it.rawValue}" }

    @After
    fun clearObservations() {
        CapabilityEvidenceObservationBridge.resetForTesting()
        // The official request-body case loads the fixture into the singleton snapshot the production Service reads.
        MetadataTestFixtures.clear()
    }

    @Test
    fun `provider form follows the contract decision table row by row`() {
        val forms = contract.getObject("forms")
        // The enum declaration order is the evaluation order; when the contract order changes, this has to follow.
        assertEquals(
            forms.getValue("order").jsonArray.map { it.jsonPrimitive.content },
            ProviderForm.entries.map { it.name.lowercase() },
        )
        val cases = formCases()
        cases.forEach { case ->
            val kind = ProviderKind.entries.single { it.rawValue == case.string("kind") }
            val authMode = ProviderAuthMode.entries.single { it.rawValue == case.string("authMode") }
            val label = "${case.string("kind")}/${case.string("authMode")}"
            val expected = ProviderForm.entries.single { it.name.lowercase() == case.string("form") }
            assertEquals(label, expected, ProviderForm.of(kind, authMode))
            assertEquals(label, expected, ProviderForm.of(Provider(id = label, kind = kind, authMode = authMode)))
        }
    }

    @Test
    fun `registry hands every form to the adapter the contract names`() {
        val adapters = contract.getObject("forms").getObject("adapters")
        assertEquals(ProviderForm.entries.map { it.name.lowercase() }.toSet(), adapters.keys)
        ProviderForm.entries.forEach { form ->
            assertEquals(
                form.name,
                adapters.string(form.name.lowercase()),
                CapabilityTruthRegistry.adapterFor(form)::class.simpleName,
            )
        }
    }

    @Test
    fun `official metadata projects every recorded cell exactly as the contract expects`() {
        val expectedModels = expected("official").jsonObject
        val sources = expected("official_sources").jsonObject
        val etag = loadOfficialMetadata(metadata)
        assertTrue(expectedModels.isNotEmpty())

        expectedModels.forEach { (ref, row) ->
            val expected = row.jsonObject
            val (provider, model) = officialTarget(ref)
            // Pin the decision clock to the recording time: typed candidates carry expiresAt, so with the wall clock the fixture would go red a few days after recording.
            val projection = projection(provider, model, keys = keys + "tool_call", now = officialRecordedAt())
            // The official snapshot is the local lean metadata snapshot, and the identity revision is the response ETag.
            assertEquals(ref, etag, projection.identity?.metadataRevision)

            // Image input is decided only by capabilityControls.vision_input: when the recorded snapshot lacks this key it is unknown.
            val hasVisionControl = metadata.currentCapabilityEvidenceModel(model.id, provider.kind)
                ?.metadata?.capabilityControls?.containsKey("vision_input") == true
            listOf("vision_input", "web_search", "tool_call").forEach { key ->
                val resolution = projection.decision(key)!!.resolution
                val label = "$ref $key"
                val expectedSupport = if (key == "vision_input" && !hasVisionControl) "unknown" else expected.string(key)
                assertEquals(label, expectedSupport, resolution.support)
                if (resolution.support != "unknown") {
                    assertEquals(label, sources.getObject(key).string("source"), resolution.source)
                    assertEquals(label, sources.getObject(key).string("grade"), resolution.grade)
                }
            }

            val expectedTiers = expected.getValue("reasoning_tiers").jsonArray
                .map { it.jsonPrimitive.content }.toSet()
            val supportedTiers = reasoningModes
                .filter { projection.decision("reasoning_level/${it.rawValue}")?.resolution?.support == "supported" }
                .mapNotNull { it.intentValue }
                .toSet()
            assertEquals(ref, expectedTiers, supportedTiers)
        }
    }

    @Test
    fun `official request body carries web tooling only when the recipe verdict allows it`() = runTest {
        val wire = expected("official_wire").jsonArray.map { it.jsonObject }
        assertTrue(wire.isNotEmpty())
        // The production Service reads the singleton snapshot, so the fixture must be loaded through the same entry.
        loadOfficialMetadata(MetadataClient.instance)

        wire.forEach { case ->
            val ref = case.string("model")
            val body = captureOfficialBody(ref, case.string("web"))
            case["body_must_contain"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content }.forEach { needle ->
                assertTrue("$ref must contain $needle: $body", body.contains(needle))
            }
            case["body_must_not_contain"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content }.forEach { needle ->
                assertFalse("$ref must not contain $needle: $body", body.contains(needle))
            }
        }
    }

    @Test
    fun `official file input is the native file route decided by the attachment router`() {
        val expectedModels = expected("official").jsonObject
        loadOfficialMetadata(metadata)
        // A scanned PDF that carries its original: a text PDF defaults to local extraction (`pdfNativeDefault`), which is a delivery
        // preference rather than whether the model has a native file route; for a scanned PDF the only criterion left is a native route or no send at all.
        val pdf = Attachment(
            id = "contract-pdf",
            kind = AttachmentKind.File,
            fileName = "contract.pdf",
            mimeType = "application/pdf",
            originalBase64Data = "JVBERi0xLjQK",
            extractionErrorCode = "scanned_pdf",
        )

        expectedModels.forEach { (ref, row) ->
            val expected = row.jsonObject.string("file_input")
            assertTrue(ref, expected in setOf("supported", "unsupported"))
            val (provider, requested) = officialTarget(ref)
            val model = metadata.resolveAIModelForRouter(requested.id, provider.kind)
            assertNotNull(ref, model)
            val route = AttachmentRouter.decide(pdf, provider.kind, model!!)
            assertEquals(ref, expected == "supported", route == AttachmentRoute.Native)
        }
    }

    @Test
    fun `production identity carries the connection authMode for every form row`() = runTest {
        loadOfficialMetadata(metadata)
        val officialRefs = contract.getObject("expected").getObject("official").keys
        formCases().forEach { case ->
            val kind = ProviderKind.entries.single { it.rawValue == case.string("kind") }
            val authMode = ProviderAuthMode.entries.single { it.rawValue == case.string("authMode") }
            val label = "${kind.rawValue}/${authMode.rawValue}"
            val identity = when (ProviderForm.of(kind, authMode)) {
                ProviderForm.Subscription ->
                    projection(Provider(id = label, kind = kind, authMode = authMode), AIModel("m", "m")).identity
                ProviderForm.Official -> {
                    val modelId = officialRefs.first { it.startsWith("${kind.rawValue}/") }.substringAfter('/')
                    projection(Provider(id = label, kind = kind, authMode = authMode), AIModel(modelId, modelId))
                        .identity
                }
                // The Relay identity comes from the local identity held by the repository through the request-boundary constructor, and the projection carries it through unchanged.
                ProviderForm.Relay -> {
                    val provider = Provider(id = label, kind = kind, authMode = authMode)
                    val model = AIModel("m", "m")
                    val dispatch = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                        localIdentity = CapabilityEvidenceIdentity(
                            partitionId = "partition",
                            connectionInstanceId = "connection",
                            connectionGeneration = "generation",
                            credentialEpoch = "epoch",
                            providerKind = provider.kind.rawValue,
                            authMode = provider.authMode.rawValue,
                        ),
                        model = model,
                        effectiveTransport = RelayTransport.OpenAIChatCompletions,
                        finalUrl = "https://relay.example.test/v1/chat/completions",
                    )
                    CapabilityEvidenceProductionAdapter.capabilityProjection(
                        provider = provider,
                        model = model,
                        identity = dispatch,
                        keys = keys,
                        metadataClient = metadata,
                    ).identity
                }
            }
            assertNotNull(label, identity)
            assertEquals(label, case.string("authMode"), identity!!.authMode)
        }
    }

    private fun projection(
        provider: Provider,
        model: AIModel,
        explicitKeys: Set<String> = emptySet(),
        keys: Set<String> = this.keys,
        now: Long = System.currentTimeMillis(),
    ) = CapabilityEvidenceProductionAdapter.capabilityProjection(
        provider = provider,
        model = model,
        keys = keys,
        explicitKeys = explicitKeys,
        metadataClient = metadata,
        now = now,
    )

    private fun officialRecordedAt(): Long =
        java.time.Instant.parse(fixture("official_metadata").string("recorded_at")).toEpochMilli()

    private fun expected(name: String): JsonElement = contract.getObject("expected").getValue(name)

    private fun fixture(name: String): JsonObject = contract.getObject("fixtures").getObject(name)

    private fun formCases(): List<JsonObject> = contract.getObject("forms").getValue("cases").jsonArray
        .map { it.jsonObject }
        .also { assertTrue(it.isNotEmpty()) }

    /** Feeds the recorded lean metadata envelope through the production decode / publish boundary and returns the ETag at recording time. */
    private fun loadOfficialMetadata(client: MetadataClient): String {
        val recorded = fixture("official_metadata")
        val etag = recorded.string("etag")
        client.loadNetworkPayloadForTesting(recorded.getObject("response").toString(), etag)
        return etag
    }

    /** `"<providerKind>/<modelId>"` to the same minimal provider and model (`AIModel(id, name)`) the request side uses. */
    private fun officialTarget(ref: String): Pair<Provider, AIModel> {
        val kind = ProviderKind.entries.single { it.rawValue == ref.substringBefore('/') }
        val modelId = ref.substringAfter('/')
        return Provider(id = "official-${kind.rawValue}", kind = kind) to AIModel(id = modelId, name = modelId)
    }

    /** Sends one streaming request through the production Service; MockEngine captures only the first request body. */
    private suspend fun captureOfficialBody(ref: String, web: String): String {
        val (provider, model) = officialTarget(ref)
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                if (body == null) body = (request.body as? TextContent)?.text.orEmpty()
                respond(
                    content = "data: [DONE]\n\n",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            },
        )
        val wireJson = Json { ignoreUnknownKeys = true; isLenient = true }
        val service = when (provider.kind) {
            ProviderKind.OpenAI -> OpenAIService(client, wireJson, TransportRegistry(wireJson))
            ProviderKind.Anthropic -> AnthropicService(client, wireJson, TransportRegistry(wireJson))
            else -> error("official_wire provider not wired: ${provider.kind}")
        }
        val preference = when (web) {
            "force" -> CapabilityWebPreference.Force
            "automatic" -> CapabilityWebPreference.Automatic
            else -> error("official_wire web intent not wired: $web")
        }
        // The request body has already been captured in MockEngine; what the response decoding does afterwards is outside this contract.
        runCatching {
            service.sendMessageStream(
                apiKey = "contract-test-key",
                modelID = model.id,
                messages = listOf(ProviderTestFixtures.userMessage("hello", provider.kind, model.id)),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = true,
                requestOptions = ChatRequestOptions(capabilityPreferences = CapabilityPreferenceValues(web = preference)),
            ).toList()
        }
        return requireNotNull(body) { "$ref did not issue a request" }
    }

    private fun readJson(relativePath: String): JsonObject {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private fun JsonObject.getObject(key: String): JsonObject = getValue(key).jsonObject
    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
}
