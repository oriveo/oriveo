package ai.oriveo.community.core.provider

import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Cross-platform contract for local-engine fingerprinting and per-model capability declarations.
 *
 * Expectations come from `shared/test-fixtures/local-engine/engine-expectations.v1.json`, and the raw responses come from the
 * `engine-declarations.v1.json` it points to (recorded from real engines, not hand-written). The objects under test are all results produced by the production [LocalEngineConnector]
 * against a fake HTTP server.
 */
class LocalEngineDeclarationContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun fixture(relativePath: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return Json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }

    private val expectations by lazy { fixture("shared/test-fixtures/local-engine/engine-expectations.v1.json") }
    private val recordings by lazy { fixture("shared/test-fixtures/local-engine/engine-declarations.v1.json") }

    private fun JsonObject.string(key: String): String? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    private fun engineRecording(engine: String): JsonObject = recordings.getValue("engines").jsonObject.getValue(engine).jsonObject

    private fun records(engine: String, instance: String?): List<JsonObject> {
        val recording = engineRecording(engine)
        val holder = if (instance == null) recording else recording.getValue("instances").jsonObject.getValue(instance).jsonObject
        return holder.getValue("records").jsonArray.map { it.jsonObject }
    }

    /** One recording: located by method + path (+ the model for Ollama /api/show). */
    private data class Recorded(val status: Int, val contentType: String, val body: String)

    private fun Recorded(record: JsonObject): Recorded {
        val response = record.getValue("response").jsonObject
        val body = response["body"]
        return Recorded(
            status = response.getValue("status").jsonPrimitive.content.toInt(),
            contentType = response.string("contentType") ?: "application/json",
            body = if (body == null || body is JsonNull) "404 page not found" else body.toString(),
        )
    }

    private fun recordKey(method: String, path: String, model: String?): String = "$method $path ${model.orEmpty()}"

    private fun recordKey(record: JsonObject): String {
        val request = record.getValue("request").jsonObject
        val model = (request["body"] as? JsonObject)?.string("model")
        return recordKey(request.getValue("method").jsonPrimitive.content, request.getValue("path").jsonPrimitive.content, model)
    }

    /** Fixture responses pointers -> fake server routing table; paths not listed answer 404 text/plain. */
    private fun routes(pointers: List<JsonObject>): Map<String, Recorded> = buildMap {
        pointers.forEach { pointer ->
            val engine = pointer.getValue("engine").jsonPrimitive.content
            val all = records(engine, pointer.string("instance"))
            if (pointer["all"]?.jsonPrimitive?.booleanOrNull == true) {
                all.forEach { put(recordKey(it), Recorded(it)) }
            } else {
                val path = pointer.getValue("path").jsonPrimitive.content
                val record = all.single { recordKey(it) == recordKey("GET", path, null) }
                put(recordKey(record), Recorded(record))
            }
        }
    }

    private fun client(routes: Map<String, Recorded>, unreachable: Boolean, requested: MutableList<String>) =
        HttpClient(
            MockEngine { request ->
                if (unreachable) throw ConnectException("Connection refused")
                val path = request.url.encodedPath
                if (request.method == HttpMethod.Get) requested += path
                val model = showModel(request)
                val hit = routes[recordKey(request.method.value, path, model)]
                    ?: Recorded(404, "text/plain", "404 page not found")
                respond(
                    content = hit.body,
                    status = HttpStatusCode.fromValue(hit.status),
                    headers = headersOf(HttpHeaders.ContentType, hit.contentType),
                )
            },
        )

    private fun showModel(request: HttpRequestData): String? {
        if (request.method != HttpMethod.Post) return null
        val text = (request.body as? TextContent)?.text ?: return null
        return runCatching { json.parseToJsonElement(text).jsonObject.string("model") }.getOrNull()
    }

    private fun connector(routes: Map<String, Recorded>, unreachable: Boolean = false, requested: MutableList<String> = mutableListOf()): LocalEngineConnector {
        val relayService = mockk<RelayService>()
        coEvery { relayService.pingRelay(any(), any(), any(), any(), any()) } returns Unit
        return LocalEngineConnector(client(routes, unreachable, requested), json, relayService)
    }

    private fun JsonElement?.flag(): Boolean? = (this as? kotlinx.serialization.json.JsonPrimitive)?.booleanOrNull

    @Test
    fun `RL2-ENGINE-01 fingerprint matches every caseId`() = runTest {
        assertEquals(1, expectations.getValue("version").jsonPrimitive.content.toInt())
        val fingerprint = expectations.getValue("fingerprint").jsonObject
        val requests = fingerprint.getValue("requests").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(requests, LocalEngineFingerprintRules.requests)
        val channels = expectations.getValue("channels").jsonObject
        val cases = fingerprint.getValue("cases").jsonArray.map { it.jsonObject }
        assertEquals(9, cases.size)
        for (case in cases) {
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val pointers = case.getValue("responses").jsonArray.map { it.jsonObject }
            if (case.string("status") == "pending") {
                // Engines without a recording stay pending: their responses are not hand-written.
                pointers.forEach { assertEquals(caseId, "pending", engineRecording(it.getValue("engine").jsonPrimitive.content).string("status")) }
                continue
            }
            val unreachable = case["unreachable"]?.jsonPrimitive?.booleanOrNull == true
            val requested = mutableListOf<String>()
            val result = connector(routes(pointers), unreachable, requested).fingerprint(
                rawEndpoint = "http://127.0.0.1:8080",
                securityMode = RelayConnectionSecurityMode.LocalHttp,
            )
            val expect = case.getValue("expect").jsonObject
            assertEquals(caseId, expect.getValue("outcome").jsonPrimitive.content, result.outcome.wireValue)
            assertEquals(caseId, expect.string("engineProfile"), result.engineProfile)
            val channel = expect.string("channel")?.let { channels.getValue(it).jsonPrimitive.content }
            assertEquals(caseId, channel, result.channel?.value)
            if (!unreachable) assertEquals(caseId, requests.toSet(), requested.toSet())
        }
    }

    private suspend fun connect(engine: String, instance: String?): LocalEngineConnection {
        val kind = when (engine) {
            "ollama" -> LocalEngineKind.Ollama
            "lmstudio" -> LocalEngineKind.LmStudio
            "llamacpp" -> LocalEngineKind.LlamaCpp
            else -> error("unrecorded engine $engine")
        }
        val pointer = JsonObject(
            buildMap {
                put("engine", kotlinx.serialization.json.JsonPrimitive(engine))
                instance?.let { put("instance", kotlinx.serialization.json.JsonPrimitive(it)) }
                put("all", kotlinx.serialization.json.JsonPrimitive(true))
            },
        )
        return connector(routes(listOf(pointer))).connect(
            engine = kind,
            rawEndpoint = "http://127.0.0.1:8080",
            securityMode = RelayConnectionSecurityMode.LocalHttp,
        )
    }

    @Test
    fun `RL2-ENGINE-02 connector declarations match every caseId`() = runTest {
        val cases = expectations.getValue("declarations").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
        assertEquals(11, cases.size)
        val connections = mutableMapOf<String, LocalEngineConnection>()
        for (case in cases) {
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val engine = case.getValue("engine").jsonPrimitive.content
            val modelId = case.getValue("modelId").jsonPrimitive.content
            val declaration = if (engineRecording(engine).string("status") == "pending") {
                // vLLM reads no response body: the declaration is decided by engineProfile alone, and any model has an empty declaration.
                LocalEngineDeclarations.parse(LocalEngineKind.Vllm, catalog = null, props = null, modelIds = listOf(modelId))[modelId]
            } else {
                val instance = case.string("instance")
                val connection = connections.getOrPut("$engine/$instance") { connect(engine, instance) }
                val inChat = case.getValue("inChatCatalog").jsonPrimitive.content.toBoolean()
                assertEquals(caseId, inChat, modelId in connection.modelIds)
                if (!inChat) {
                    assertFalse(caseId, modelId in connection.engineDeclarations)
                    continue
                }
                connection.engineDeclarations[modelId]
            }
            val expect = case.getValue("expect").jsonObject
            assertEquals("$caseId image", expect["image"].flag(), declaration?.image)
            assertEquals("$caseId toolCall", expect["toolCall"].flag(), declaration?.toolCall)
            assertEquals("$caseId thinking", expect["thinking"].flag(), declaration?.thinking)
        }
    }

    private val metadata = MetadataClient()

    private fun engineProvider(engineProfile: String?, models: List<AIModel>) = Provider(
        id = "local-engine",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = models,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            engineProfile = engineProfile,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            resolvedAPIBaseURL = "http://127.0.0.1:11434/v1",
        ),
    )

    private fun localIdentity(provider: Provider) = CapabilityEvidenceIdentity(
        partitionId = "partition",
        connectionInstanceId = "connection",
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
    )

    private fun scopedProjection(provider: Provider, model: AIModel) =
        CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                localIdentity = localIdentity(provider),
                model = model,
                effectiveTransport = RelayTransport.OpenAIChatCompletions,
                finalUrl = "http://127.0.0.1:11434/v1/chat/completions",
            ),
            keys = setOf("vision_input", "tool_call"),
            metadataClient = metadata,
        )

    @Test
    fun `RL2-ENGINE-02 declared image and tool call drive the facade and the composer photo entry`() = runTest {
        assertEquals(ProviderForm.Relay, ProviderForm.of(engineProvider("ollama", emptyList())))
        val connection = connect("ollama", null)
        // Model objects take the declarations the production connector produced against the recordings, attached to AIModel in the shape of the registration path.
        fun model(id: String) = AIModel(
            id = id,
            name = id,
            capabilities = listOf(ModelCapability.Text),
            engineDeclaration = connection.engineDeclarations.getValue(id),
        )
        val vision = model("oriveo-fixture-smolvlm:latest")
        val text = model("qwen3:0.6b")
        assertEquals(true, vision.engineDeclaration?.image)
        assertEquals(false, text.engineDeclaration?.image)
        val provider = engineProvider("ollama", listOf(vision, text))
        val resolver = ChatModelCapabilityResolver(metadata = metadata)

        val visionProjection = scopedProjection(provider, vision)
        assertEquals("supported", visionProjection.decision("vision_input")?.resolution?.support)
        assertTrue(visionProjection.decision("vision_input")!!.editable)
        assertEquals("unsupported", visionProjection.decision("tool_call")?.resolution?.support)
        // Photo-library entry: calls the same production criterion as the chat page, with the connection identity.
        assertTrue(resolver.supportsImage(provider, vision, localIdentity(provider)))
        // The declaration only replaces the source, not the route: when the current channel's attachment envelope cannot hold images the entry stays hidden.
        val noImageEnvelope = metadata.relayRuntimeConfig().let { config ->
            val key = RelayRuntimeSupport.envelopeKey(provider, vision)!!
            config.copy(
                transportEnvelopes = config.transportEnvelopes +
                    (key to (config.transportEnvelopes[key] ?: MetadataClient.RelayTransportEnvelope()).copy(image = false)),
            )
        }
        val envelopeGated = ChatModelCapabilityResolver(metadata = metadata, runtimeConfigProvider = { noImageEnvelope })
        assertFalse(envelopeGated.supportsImage(provider, vision, localIdentity(provider)))

        val textProjection = scopedProjection(provider, text)
        assertEquals("unsupported", textProjection.decision("vision_input")?.resolution?.support)
        assertFalse(textProjection.decision("vision_input")!!.editable)
        assertEquals("supported", textProjection.decision("tool_call")?.resolution?.support)
        assertFalse(resolver.supportsImage(provider, text, localIdentity(provider)))
        // The tool-call tri-state used by badges / filters likewise follows the engine declaration, overriding the old toolCall on the model.
        assertEquals(true, CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, text.copy(toolCall = false)))
        assertEquals(false, CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, vision.copy(toolCall = true)))
    }

    @Test
    fun `RL2-ENGINE-02 declaration is ignored on a connection without an engine profile`() {
        val model = AIModel(
            id = "m",
            name = "m",
            capabilities = listOf(ModelCapability.Text),
            engineDeclaration = EngineDeclaration(image = true, toolCall = false),
        )
        val projection = scopedProjection(engineProvider(null, listOf(model)), model)
        // No engineProfile: defer to the existing Relay rules; the declaration does not produce supported / unsupported.
        assertEquals("unknown", projection.decision("vision_input")?.resolution?.support)
        assertNull(projection.decision("vision_input")?.resolution?.takeIf { it.support == "supported" })
    }
}
