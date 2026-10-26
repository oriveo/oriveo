package ai.oriveo.community.core.capability.capabilitymatrix

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.core.provider.LocatedModelControlRejection
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.feature.chat.ChatSendCoordinator
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Capability matrix for the official BYOK form (cases CAP-BYOK-*).
 *
 * Metadata is always the official lean metadata recorded in the cross-platform contract
 * (`fixtures.official_metadata` of `capability_truth_contract.v1.json`) and goes through the production
 * decode / publish boundary; it is only ever trimmed, never fabricated.
 * Every request body is sent by the production Service; MockEngine only captures the bytes.
 */
class CapabilityMatrixByokTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val contract by lazy { readJson("shared/model-contracts/capability_truth_contract.v1.json") }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        CapabilityEvidenceObservationBridge.resetForTesting()
        ModelControlRejectionCache.clearForTesting()
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    // ── WEB ──

    @Test
    fun CAP_BYOK_WEB_01_recipe_web_control_writes_the_recipe_fields() = runTest {
        loadOfficialMetadata()
        assertEquals("auto_available", control(ANTHROPIC_MODEL, "anthropic", "web").string("state"))
        val recipeTool = recipe("anthropic.messages.web.v1").getValue("requestOps").jsonArray
            .single().jsonObject.getValue("value")

        val body = anthropicBody(ANTHROPIC_MODEL, web = CapabilityWebPreference.Automatic)

        val tools = body["tools"]?.jsonArray.orEmpty()
        assertTrue("the request body should contain the web tool written by the recipe: $body", recipeTool in tools)
    }

    @Test
    fun CAP_BYOK_WEB_02_no_web_recipe_sends_no_web_fields_even_when_preference_is_on() = runTest {
        // Same model, but the delivered web control is removed (no control = no recipe).
        loadOfficialMetadata { data -> data.withoutPath(listOf("providers", "anthropic", "models", ANTHROPIC_MODEL, "capabilityControls", "web")) }

        listOf(CapabilityWebPreference.Automatic, CapabilityWebPreference.Force).forEach { preference ->
            val body = anthropicBody(ANTHROPIC_MODEL, web = preference)
            assertFalse("$preference should not carry tools: $body", "tools" in body)
            assertFalse("$preference should not carry any web search field: $body", body.toString().contains("web_search"))
        }
    }

    // ── REASON ──

    @Test
    fun CAP_BYOK_REASON_01_selected_tier_is_written_with_the_recipe_value() = runTest {
        loadOfficialMetadata()
        val reasoning = control(ANTHROPIC_MODEL, "anthropic", "reasoning")
        val intents = reasoning.getValue("availableIntents").jsonArray.map { it.jsonPrimitive.content }
        assertTrue(intents.size > 1)
        val tier = "deep"
        assertTrue(tier in intents)
        val ops = recipe(reasoning.string("recipeRef")).getValue("requestOps").jsonArray.map { it.jsonObject }
            .filter { it["intent"]?.jsonPrimitive?.content == tier }
        assertTrue(ops.isNotEmpty())

        val body = anthropicBody(ANTHROPIC_MODEL, reasoningIntent = tier)

        ops.forEach { op ->
            val pointer = op.string("pointer")
            assertEquals("$pointer: $body", op.getValue("value"), body.at(pointer))
        }
    }

    @Test
    fun CAP_BYOK_REASON_02_rejected_tier_falls_back_to_the_nearest_tier_that_was_not_rejected() = runTest {
        loadOfficialMetadata()
        val reasoning = control(ANTHROPIC_MODEL, "anthropic", "reasoning")
        val recipeRef = reasoning.string("recipeRef")
        val effortOf = recipe(recipeRef).getValue("requestOps").jsonArray.map { it.jsonObject }
            .filter { it.string("pointer") == "/output_config/effort" }
            .associate { it.string("intent") to it.getValue("value") }
        val model = AIModel(id = ANTHROPIC_MODEL, name = ANTHROPIC_MODEL)
        val provider = Provider(id = "official-anthropic", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(model))
        val identity = requireNotNull(ModelControlRuntimeIdentityResolver.resolve(provider, model))
        var payload: String? = null
        val store = CapabilityPreferenceStore({ payload }, { payload = it })
        val coordinator = ChatSendCoordinator(
            chatStreamingManager = mockk<ChatStreamingManager>(relaxed = true),
            applicationScope = this,
            pinnedNotesResolver = { emptyList() },
            pendingPinnedNoteIds = { emptyList() },
            generationParameterSettingsStore = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
            capabilityPreferenceStore = store,
        )
        fun reject(tier: String) = ModelControlRejectionCache.recordLocated(
            identity,
            LocatedModelControlRejection("provider_recipe", "reasoning", recipeRef, listOf("/output_config/effort")),
            tier,
        )
        // Production send-side resolution (the same one launchSend hands to the streaming manager) -> production AnthropicService outbound.
        suspend fun sendWith(selected: String): JsonObject {
            store.setConversation(
                CapabilityPreferenceValues(CapabilityWebPreference.Off, selected),
                provider.id, identity.canonicalModelId, "conversation-1", identity.storageIdentity,
            )
            val dispatch = coordinator.resolveCapabilityDispatch(
                provider = provider,
                modelId = model.id,
                conversationId = "conversation-1",
                skillId = null,
                appendToAssistant = null,
            )
            return anthropicBody(
                ANTHROPIC_MODEL,
                reasoningIntent = dispatch.customTypedPreferences.reasoningIntent,
                dormantOwners = dispatch.dormantOwners,
            )
        }

        reject("max")
        assertEquals("max was rejected and max is selected -> falls to the nearest lower tier, deep", effortOf.getValue("deep"), sendWith("max").at("/output_config/effort"))

        ModelControlRejectionCache.clearForTesting()
        reject("deep")
        assertEquals("rejecting deep does not affect balanced", effortOf.getValue("balanced"), sendWith("balanced").at("/output_config/effort"))

        ModelControlRejectionCache.clearForTesting()
        reasoning.getValue("availableIntents").jsonArray.forEach { reject(it.jsonPrimitive.content) }
        val none = sendWith("max")
        assertFalse("the whole field is omitted only when every tier is rejected: $none", "thinking" in none || "output_config" in none)
    }

    // ── ATTACH ──

    @Test
    fun CAP_BYOK_ATTACH_01_native_pdf_goes_out_as_a_document_block() = runTest {
        loadOfficialMetadata()
        val model = officialModel("anthropic", ANTHROPIC_MODEL)
        assertTrue(model.getValue("nativeFileMimes").jsonArray.any { it.jsonPrimitive.content == "application/pdf" })
        // Scanned document: there is no text layer to fall back to, so only the native route remains or the send fails.
        val pdf = Attachment(
            id = "cap-pdf",
            kind = AttachmentKind.File,
            fileName = "byok-contract.pdf",
            mimeType = "application/pdf",
            originalBase64Data = PDF_BASE64,
            extractionErrorCode = "scanned_pdf",
        )

        val body = anthropicBody(ANTHROPIC_MODEL, attachments = listOf(pdf))

        val content = body.getValue("messages").jsonArray.last().jsonObject.getValue("content").jsonArray.map { it.jsonObject }
        val document = content.single { it.string("type") == "document" }
        assertEquals("application/pdf", document.getValue("source").jsonObject.string("media_type"))
        assertEquals(PDF_BASE64, document.getValue("source").jsonObject.string("data"))
        assertFalse("should not fall back to text: $body", body.toString().contains("byok-contract.pdf"))
    }

    @Test
    fun CAP_BYOK_ATTACH_02_unknown_vision_keeps_the_image_entry_editable() {
        val metadata = loadOfficialMetadata()
        val (provider, model) = officialTarget(OPENAI_UNKNOWN_MODEL)
        assertEquals("unknown", expectedOfficial(OPENAI_UNKNOWN_MODEL).string("vision_input"))
        assertFalse(officialModel("openAI", "chat-latest").getValue("capabilities").jsonArray.any { it.jsonPrimitive.content == "image" })

        val resolver = ChatModelCapabilityResolver(metadata = metadata)

        // The entry reads the editable flag of the vision_input projection, so unknown can still be attached (the disabled reason is shown by the hint layer).
        assertTrue(resolver.supportsImage(provider, model))
        // Contrast: an official model with positive image evidence in the same snapshot shows the entry as usual.
        val (o3Provider, o3) = officialTarget("openAI/o3")
        assertTrue(resolver.supportsImage(o3Provider, o3))
    }

    // ── helpers ──

    /** Sends one streaming request through the production AnthropicService and returns the first request body. */
    private suspend fun anthropicBody(
        modelId: String,
        web: CapabilityWebPreference = CapabilityWebPreference.Off,
        reasoningIntent: String? = null,
        attachments: List<Attachment> = emptyList(),
        dormantOwners: Set<String> = emptySet(),
    ): JsonObject {
        var body: String? = null
        val client = HttpClient(MockEngine { request ->
            if (body == null) body = bodyText(request.body)
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        val message = ProviderTestFixtures.userMessage("hello", ProviderKind.Anthropic, modelId)
            .copy(attachments = attachments.takeIf { it.isNotEmpty() })
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "byok-key",
                modelID = modelId,
                messages = listOf(message),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.fromIntent(reasoningIntent),
                webSearchEnabled = web != CapabilityWebPreference.Off,
                requestOptions = ChatRequestOptions(
                    capabilityPreferences = CapabilityPreferenceValues(web = web, reasoningIntent = reasoningIntent),
                    dormantCapabilityOwners = dormantOwners,
                ),
            ).toList()
        }
        return json.parseToJsonElement(requireNotNull(body) { "$modelId did not issue a request" }).jsonObject
    }

    /** Loads the recorded official lean metadata (trim-only) into the production singleton snapshot and returns that singleton. */
    private fun loadOfficialMetadata(edit: (JsonObject) -> JsonObject = { it }): MetadataClient {
        val recorded = contract.getObject("fixtures").getObject("official_metadata")
        val response = recorded.getObject("response")
        val edited = JsonObject(response + ("data" to edit(response.getObject("data"))))
        MetadataClient.instance.loadNetworkPayloadForTesting(edited.toString(), recorded.string("etag"))
        return MetadataClient.instance
    }

    private fun JsonObject.withoutPath(path: List<String>): JsonObject {
        if (path.size == 1) return JsonObject(this - path.single())
        val child = getValue(path.first()).jsonObject
        return JsonObject(this + (path.first() to child.withoutPath(path.drop(1))))
    }

    private fun officialModel(providerKind: String, modelId: String): JsonObject =
        contract.getObject("fixtures").getObject("official_metadata").getObject("response").getObject("data")
            .getObject("providers").getObject(providerKind).getObject("models").getObject(modelId)

    private fun control(modelId: String, providerKind: String, capability: String): JsonObject =
        officialModel(providerKind, modelId).getObject("capabilityControls").getObject(capability)

    private fun recipe(ref: String): JsonObject =
        contract.getObject("fixtures").getObject("official_metadata").getObject("response").getObject("data")
            .getObject("capabilityRuntime").getObject("recipes").getObject(ref)

    private fun expectedOfficial(ref: String): JsonObject = contract.getObject("expected").getObject("official").getObject(ref)

    /** `"<providerKind>/<modelId>"` to an official API-key connection and `AIModel(id, name)`. */
    private fun officialTarget(ref: String): Pair<Provider, AIModel> {
        val kind = ProviderKind.entries.single { it.rawValue == ref.substringBefore('/') }
        val modelId = ref.substringAfter('/')
        return Provider(id = "official-${kind.rawValue}", kind = kind, apiKey = "byok-key") to AIModel(id = modelId, name = modelId)
    }

    private fun JsonObject.at(pointer: String): JsonElement? =
        pointer.trim('/').split('/').fold(this as JsonElement?) { node, key -> (node as? JsonObject)?.get(key) }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun readJson(relativePath: String): JsonObject {
        val repoRoot = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private fun JsonObject.getObject(key: String): JsonObject = getValue(key).jsonObject
    private fun JsonObject.string(key: String): String = getValue(key).let { (it as? JsonArray)?.toString() ?: it.jsonPrimitive.content }

    private companion object {
        const val ANTHROPIC_MODEL = "claude-opus-5-5"
        const val OPENAI_UNKNOWN_MODEL = "openAI/chat-latest"
        const val MANUAL_MODEL = "my-handfilled-model"
        const val PARTITION = "user-1"
        const val PDF_BASE64 = "JVBERi0xLjQKJWJ5b2stY29udHJhY3QK"
    }
}
