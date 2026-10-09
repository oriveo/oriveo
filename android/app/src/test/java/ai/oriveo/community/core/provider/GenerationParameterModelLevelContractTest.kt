package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Drives modelLevelResolveCases through the metadata decode path and modelLevelOutboundCases through the resolver. */
class GenerationParameterModelLevelContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val cases by lazy { json.parseToJsonElement(repoText(CASES_PATH)).jsonObject }

    @Before
    fun setUp() = GenerationParameterResolver.clearWireDiagnostics()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        GenerationParameterResolver.clearWireDiagnostics()
    }

    @Test
    fun `model level resolve cases match the metadata decode path`() {
        val items = cases["modelLevelResolveCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(11, items.size)
        val failures = mutableListOf<String>()
        items.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val model = item["model"]!!.jsonObject
            GenerationParameterResolver.clearWireDiagnostics()
            MetadataTestFixtures.applyRaw(metadataFor(MODEL_ID, model).toString())
            val profile = MetadataClient.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.profiles?.generation
            if (profile == null) {
                failures += "$caseId: profile did not resolve"
                return@forEach
            }
            val expect = item["expect"]!!.jsonObject
            val byId = profile.parameters.associateBy { it.id }
            expect["parameters"]!!.jsonObject.forEach { (id, want) ->
                val actual = byId[id] ?: return@forEach run { failures += "$caseId: $id missing" }
                val fields = want.jsonObject
                fields["range"]?.let {
                    val wantRange = json.decodeFromJsonElement(GenerationParameterRange.serializer(), it)
                    if (actual.range != wantRange) failures += "$caseId: $id range=${actual.range}, want $wantRange"
                }
                fields["conflictsWith"]?.let { raw ->
                    val wantConflicts = raw.jsonArray.map { it.jsonPrimitive.content }
                    if (actual.conflictsWith != wantConflicts) failures += "$caseId: $id conflictsWith=${actual.conflictsWith}, want $wantConflicts"
                }
                fields["strict"]?.let {
                    if ((actual.strict == true) != it.jsonPrimitive.booleanOrNull) failures += "$caseId: $id strict=${actual.strict}, want $it"
                }
                fields["enumValues"]?.let {
                    if (actual.enumValues != it.jsonArray.toList()) failures += "$caseId: $id enumValues=${actual.enumValues}, want $it"
                }
            }
            expect["parameterIds"]?.let { raw ->
                val want = raw.jsonArray.map { it.jsonPrimitive.content }
                if (profile.parameters.mapNotNull { it.id } != want) failures += "$caseId: parameterIds=${profile.parameters.map { it.id }}, want $want"
            }
            val wantWire = expect["wire"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
            model["parameters"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content }.forEach { id ->
                if (profile.wire[id] != wantWire[id]) failures += "$caseId: wire[$id]=${profile.wire[id]}, want ${wantWire[id]}"
            }
            val wantRejections = (expect["wireRejections"] as? JsonArray).orEmpty().map {
                it.jsonObject["parameterId"]!!.jsonPrimitive.content to it.jsonObject["reason"]!!.jsonPrimitive.content
            }
            val actualRejections = GenerationParameterResolver.readWireDiagnostics().map { it.parameterId to it.reason.wireName }.distinct()
            if (actualRejections != wantRejections) failures += "$caseId: wireRejections=$actualRejections, want $wantRejections"
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `model level outbound cases match the production per item resolver`() {
        val items = cases["modelLevelOutboundCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(15, items.size)
        val failures = mutableListOf<String>()
        items.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val result = runOutboundCase(item)
            val expect = item["expect"]!!.jsonObject
            val actualBody = json.parseToJsonElement(result.body).jsonObject
            if (actualBody != expect["body"]) failures += "$caseId: body=$actualBody, want ${expect["body"]}"
            (expect["bodyExcludes"] as? JsonArray).orEmpty().map { it.jsonPrimitive.content }.forEach { key ->
                if (key in actualBody) failures += "$caseId: body must not contain $key"
            }
            val wantDropped = expect["dropped"]!!.jsonArray.map {
                it.jsonObject["parameterId"]!!.jsonPrimitive.content to it.jsonObject["reason"]!!.jsonPrimitive.content
            }
            val actualDropped = result.dropped.map { it.parameterId to it.reason.wireName }
            if (actualDropped != wantDropped) failures += "$caseId: dropped=$actualDropped, want $wantDropped"
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `relay chat body built from decoded metadata writes max_completion_tokens and strict`() {
        val definitions = cases["modelLevelResolveDefinitions"]!!.jsonObject
        MetadataTestFixtures.applyRaw(metadataFor(MODEL_ID, buildJsonObject {
            put("template", "openai_chat_completions")
            put("parameters", JsonArray(listOf(
                buildJsonObject { put("id", "max_output_tokens"); put("support", "supported"); put("wire", "max_completion_tokens") },
                buildJsonObject { put("id", "json_schema"); put("support", "supported"); put("strict", true) },
            )))
        }, definitions).toString())
        val profile = requireNotNull(MetadataClient.resolveCatalogModel(MODEL_ID, ProviderKind.OpenAI)?.profiles?.generation)
        assertEquals("max_completion_tokens", profile.wire["max_output_tokens"])
        assertEquals(true, profile.parameters.first { it.id == "json_schema" }.strict)

        val model = AIModel(id = MODEL_ID, name = MODEL_ID, generationProfile = profile)
        val projection = relayProjection(model, RelayTransport.OpenAIChatCompletions, profile.parameters.mapNotNull { it.id })
        val schema = buildJsonObject { put("type", "object") }
        val inherited = json.parseToJsonElement(buildOpenAIChatBody(
            MODEL_ID, emptyList(), false, ReasoningMode.Fast,
            ChatRequestOptions(maxTokens = 4096, activeModel = model),
            capabilityProjection = projection,
        )).jsonObject
        assertEquals("4096", inherited["max_completion_tokens"]!!.jsonPrimitive.content)
        assertFalse("max_tokens" in inherited)

        val withSchema = json.parseToJsonElement(buildOpenAIChatBody(
            MODEL_ID, emptyList(), false, ReasoningMode.Fast,
            ChatRequestOptions(
                maxTokens = 4096,
                generationParameters = GenerationParameterOverrides(mapOf(
                    "max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(2048)),
                    "json_schema" to GenerationParameterOverride(GenerationOverrideState.Value, schema),
                )),
                activeModel = model,
            ),
            capabilityProjection = projection,
        )).jsonObject
        assertEquals("2048", withSchema["max_completion_tokens"]!!.jsonPrimitive.content)
        assertFalse("max_tokens" in withSchema)
        val jsonSchema = withSchema["response_format"]!!.jsonObject["json_schema"]!!.jsonObject
        assertEquals("true", jsonSchema["strict"]!!.jsonPrimitive.content)
        assertEquals(schema, jsonSchema["schema"])
    }

    @Test
    fun `relay anthropic body writes json schema to output_config format`() {
        val profile = GenerationProfileRef(
            template = "anthropic_messages",
            parameters = listOf(
                GenerationParameterRef(id = "max_output_tokens", support = "supported", valueSchema = "integer"),
                GenerationParameterRef(id = "json_schema", support = "supported", valueSchema = "json-schema"),
            ),
            wire = mapOf("max_output_tokens" to "max_tokens", "json_schema" to "output_config.format"),
        )
        val model = AIModel(id = "claude-sonnet-4-5", name = "claude-sonnet-4-5", generationProfile = profile)
        val schema = buildJsonObject { put("type", "object") }
        val body = json.parseToJsonElement(buildAnthropicBody(
            model.id, emptyList(), false, ReasoningMode.Fast,
            ChatRequestOptions(
                generationParameters = GenerationParameterOverrides(mapOf(
                    "json_schema" to GenerationParameterOverride(GenerationOverrideState.Value, schema),
                )),
                activeModel = model,
            ),
            capabilityProjection = relayProjection(model, RelayTransport.AnthropicMessages, listOf("max_output_tokens", "json_schema")),
        )).jsonObject
        assertNull(body["output_format"])
        val format = body["output_config"]!!.jsonObject["format"]!!.jsonObject
        assertEquals(setOf("type", "schema"), format.keys)
        assertEquals("json_schema", format["type"]!!.jsonPrimitive.content)
        assertEquals(schema, format["schema"])
        assertTrue("max_tokens" in body)
    }

    private fun runOutboundCase(item: JsonObject): GenerationParameterResolver.Result {
        val profileJson = item["profile"]!!.jsonObject
        val template = profileJson["template"]!!.jsonPrimitive.content
        val parameters = json.decodeFromJsonElement(ListSerializer(GenerationParameterRef.serializer()), profileJson["parameters"]!!)
            .map { it.copy(support = "supported") }
        val profile = GenerationProfileRef(
            template = template,
            parameters = parameters,
            wire = profileJson["wire"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
        )
        val model = AIModel(id = "fixture-chat", name = "fixture-chat", generationProfile = profile)
        val values = item["overrides"]!!.jsonObject.mapValues { (_, raw) ->
            val override = raw.jsonObject
            when (override["state"]!!.jsonPrimitive.content) {
                "value" -> GenerationParameterOverride(GenerationOverrideState.Value, override["value"])
                "omit" -> GenerationParameterOverride(GenerationOverrideState.Omit)
                else -> GenerationParameterOverride(GenerationOverrideState.Inherit)
            }
        }
        val transport = RelayTransport.entries.first { it.value == template }
        return GenerationParameterResolver.applyWithResult(
            item["body"]!!.jsonObject.toString(),
            ChatRequestOptions(generationParameters = GenerationParameterOverrides(values), activeModel = model),
            null,
            relayProjection(model, transport, parameters.mapNotNull { it.id }),
        )
    }

    /** One OpenAI model whose generation profile is the case's model-level reference over the shared definitions. */
    private fun metadataFor(
        modelId: String,
        generation: JsonObject,
        definitions: JsonObject = cases["modelLevelResolveDefinitions"]!!.jsonObject,
    ): JsonObject = buildJsonObject {
        put("version", 1)
        put("profiles", buildJsonObject {
            put("generation", JsonObject(definitions + ("version" to JsonPrimitive(1))))
        })
        put("providers", buildJsonObject {
            put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { put(modelId, modelId) })
                put("models", buildJsonObject {
                    put(modelId, buildJsonObject {
                        put("transport", "openai_chat")
                        put("profiles", buildJsonObject { put("generation", generation) })
                    })
                })
            })
        })
    }

    private fun relayProjection(
        model: AIModel,
        transport: RelayTransport,
        parameterIds: List<String>,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val keys = parameterIds.map { "generation_parameter/$it" }.toSet()
        val provider = Provider(
            id = "relay-model-level",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val finalUrl = when (transport) {
            RelayTransport.AnthropicMessages -> "https://relay.example/v1/messages"
            RelayTransport.OpenAIChatCompletions -> "https://relay.example/v1/chat/completions"
            RelayTransport.OpenAIResponses -> "https://relay.example/v1/responses"
            else -> error("unsupported transport $transport")
        }
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
            model,
            transport,
            finalUrl,
        )
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = keys,
        )
    }

    private fun repoText(relative: String): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relative) }
            .firstOrNull(Files::exists)
            ?: error("$relative not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private companion object {
        const val CASES_PATH = "shared/model-contracts/generation_parameter_contract.v1.cases.json"
        const val MODEL_ID = "fixture-model-level"
    }
}
