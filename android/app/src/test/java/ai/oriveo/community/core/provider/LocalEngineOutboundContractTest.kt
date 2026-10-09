package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.buildLlamaCppNativeBody
import ai.oriveo.community.core.provider.relay.buildOpenAIChatBody
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Drives localEngineCases and llamacppMigrationCases through the production profiles, resolver and body builders. */
class LocalEngineOutboundContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `shared local engine cases match the production request bodies`() {
        val cases = contractCases()["localEngineCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(9, cases.size)
        val failures = mutableListOf<String>()
        cases.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val transport = transportOf(item["transport"]!!.jsonPrimitive.content)
            val model = modelFor(item["engine"]!!.jsonPrimitive.content, transport)
            val result = GenerationParameterResolver.applyWithResult(
                baseBody(model, transport),
                options(item["overrides"]!!.jsonObject, model),
                null,
                projection(model, transport),
            )
            val body = json.parseToJsonElement(result.body).jsonObject
            val expect = item["expect"]!!.jsonObject
            expect["bodyIncludes"]!!.jsonObject.forEach { (key, want) ->
                if (!sameValue(body[key], want)) failures += "$caseId: $key=${body[key]}, want $want"
            }
            expect["numericFields"]!!.jsonArray.map { it.jsonPrimitive.content }.forEach { key ->
                val actual = body[key] as? JsonPrimitive
                if (actual == null || actual.isString || actual.doubleOrNull == null) failures += "$caseId: $key=$actual is not a JSON number"
            }
            expect["bodyExcludes"]!!.jsonArray.map { it.jsonPrimitive.content }.forEach { key ->
                if (body.containsKey(key)) failures += "$caseId: $key must be omitted"
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
    fun `llama cpp chat builder body carries numeric sampling fields and no max tokens by default`() {
        val model = modelFor("llamacpp", RelayTransport.OpenAIChatCompletions)
        val withValues = chatBody(model, mapOf("mirostat_tau" to JsonPrimitive(7.5), "top_k" to JsonPrimitive(7)))
        assertEquals(7.5, withValues["mirostat_tau"]!!.jsonPrimitive.doubleOrNull)
        assertEquals(false, withValues["mirostat_tau"]!!.jsonPrimitive.isString)
        assertEquals(false, withValues["top_k"]!!.jsonPrimitive.isString)
        assertEquals("true", withValues["stream"]!!.jsonPrimitive.content)
        // The -1 default is display only: nothing writes it into the request.
        val untouched = chatBody(model, mapOf("top_k" to JsonPrimitive(7)))
        listOf("max_tokens", "n_predict", "max_completion_tokens").forEach { assertNull(it, untouched[it]) }
    }

    @Test
    fun `vllm builder body puts extension sampling fields at the top level`() {
        val model = modelFor("vllm", RelayTransport.OpenAIChatCompletions)
        val body = chatBody(model, mapOf(
            "top_k" to JsonPrimitive(20),
            "min_p" to JsonPrimitive(0.05),
            "repeat_penalty" to JsonPrimitive(1.1),
            "typical_p" to JsonPrimitive(0.9),
        ))
        assertEquals(20.0, body["top_k"]!!.jsonPrimitive.doubleOrNull)
        assertEquals(0.05, body["min_p"]!!.jsonPrimitive.doubleOrNull)
        assertEquals(1.1, body["repetition_penalty"]!!.jsonPrimitive.doubleOrNull)
        assertNull(body["extra_body"])
        assertNull(body["typical_p"])
        assertNull(body["repeat_penalty"])
    }

    @Test
    fun `llama cpp native builder body keeps the completion wire names`() {
        val model = modelFor("llamacpp", RelayTransport.LlamaCppNative)
        val values = options(JsonObject(mapOf(
            "mirostat_tau" to JsonObject(mapOf("state" to JsonPrimitive("value"), "value" to JsonPrimitive(7.5))),
        )), model)
        val body = json.parseToJsonElement(
            buildLlamaCppNativeBody(emptyList(), true, values, projection(model, RelayTransport.LlamaCppNative)),
        ).jsonObject
        assertEquals(7.5, body["mirostat_tau"]!!.jsonPrimitive.doubleOrNull)
        assertTrue(body.containsKey("prompt"))
    }

    @Test
    fun `shared llama cpp migration cases match the production migration`() {
        val cases = contractCases()["llamacppMigrationCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(5, cases.size)
        val failures = mutableListOf<String>()
        cases.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val before = item["before"]!!.jsonObject
            val outcome = LlamaCppChannelMigration.migrate(
                engineProfile = before["engineProfile"]?.jsonPrimitive?.contentOrNullValue(),
                transport = transportOf(before["transport"]!!.jsonPrimitive.content),
                resolvedAPIBaseURL = before["resolvedAPIBaseURL"]?.jsonPrimitive?.contentOrNullValue(),
                alreadyMigrated = item["alreadyMigrated"]!!.jsonPrimitive.content.toBoolean(),
            )
            val expect = item["expect"]!!.jsonObject
            if (outcome.transport.value != expect["transport"]!!.jsonPrimitive.content) failures += "$caseId: transport=${outcome.transport.value}"
            if (outcome.resolvedAPIBaseURL != expect["resolvedAPIBaseURL"]!!.jsonPrimitive.content) failures += "$caseId: base=${outcome.resolvedAPIBaseURL}"
            if (outcome.changed != expect["changed"]!!.jsonPrimitive.content.toBoolean()) failures += "$caseId: changed=${outcome.changed}"
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `stored vllm connection without strict reads back the current profile and sends strict`() {
        val current = LocalEngineGenerationProfiles.profile("vllm", RelayTransport.OpenAIChatCompletions)!!
        val stale = current.copy(parameters = current.parameters.map { it.copy(strict = null) })
        val stored = Provider(
            id = "8a4f9a52-6f43-4f8f-9a77-0d6c4f0b3a10",
            kind = ProviderKind.Relay,
            baseUrlText = "http://127.0.0.1:8000/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, engineProfile = "vllm"),
            models = listOf(AIModel(id = "local-model", name = "local-model", generationProfile = stale)),
        )
        // Production read path: the stored entity is read back through ProviderMapper.toDomain.
        val read = with(ai.oriveo.community.core.data.mapper.ProviderMapper) { stored.toEntity().toDomain() }
        val model = read.models.single()
        assertEquals(true, model.generationProfile!!.parameters.first { it.id == "json_schema" }.strict)
        val body = chatBody(model, mapOf("json_schema" to kotlinx.serialization.json.buildJsonObject {
            put("type", JsonPrimitive("object"))
        }))
        val schema = body["response_format"]!!.jsonObject["json_schema"]!!.jsonObject
        assertEquals("true", schema["strict"]!!.jsonPrimitive.content)
    }

    private fun chatBody(model: AIModel, values: Map<String, JsonElement>): JsonObject {
        val overrides = GenerationParameterOverrides(values.mapValues { GenerationParameterOverride(GenerationOverrideState.Value, it.value) })
        return json.parseToJsonElement(
            buildOpenAIChatBody(
                modelID = model.id,
                messages = emptyList(),
                stream = true,
                reasoningMode = ReasoningMode.Automatic,
                requestOptions = ChatRequestOptions(generationParameters = overrides, activeModel = model),
                capabilityProjection = projection(model, RelayTransport.OpenAIChatCompletions),
            ),
        ).jsonObject
    }

    private fun baseBody(model: AIModel, transport: RelayTransport): String =
        if (transport == RelayTransport.LlamaCppNative) {
            buildLlamaCppNativeBody(emptyList(), true, ChatRequestOptions(activeModel = model), projection(model, transport))
        } else {
            buildOpenAIChatBody(model.id, emptyList(), true, ReasoningMode.Automatic, ChatRequestOptions(activeModel = model), capabilityProjection = projection(model, transport))
        }

    private fun options(overrides: JsonObject, model: AIModel) = ChatRequestOptions(
        generationParameters = GenerationParameterOverrides(overrides.mapValues { (_, raw) ->
            val override = raw.jsonObject
            GenerationParameterOverride(GenerationOverrideState.Value, override["value"])
        }),
        activeModel = model,
    )

    private fun modelFor(engine: String, transport: RelayTransport) = AIModel(
        id = "local-model",
        name = "local-model",
        generationProfile = LocalEngineGenerationProfiles.profile(engine, transport),
    )

    private fun projection(model: AIModel, transport: RelayTransport): CapabilityEvidenceProductionAdapter.Projection {
        val provider = Provider(
            id = "local-engine",
            kind = ProviderKind.Relay,
            baseUrlText = "http://127.0.0.1:8080/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val finalUrl = if (transport == RelayTransport.LlamaCppNative) "http://127.0.0.1:8080/completion"
        else "http://127.0.0.1:8080/v1/chat/completions"
        val keys = model.generationProfile!!.parameters.mapNotNull { it.id }.map { "generation_parameter/$it" }.toSet()
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
                CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
                model,
                transport,
                finalUrl,
            ),
            keys = keys,
            explicitKeys = keys,
        )
    }

    private fun transportOf(value: String) = RelayTransport.entries.first { it.value == value }

    // Numbers compare by value so 2 and 2.0 are the same wire value; everything else compares structurally.
    private fun sameValue(actual: JsonElement?, want: JsonElement): Boolean {
        val wantNumber = (want as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
        return if (wantNumber != null) (actual as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull == wantNumber
        else actual == want
    }

    private fun JsonPrimitive.contentOrNullValue(): String? = if (this is kotlinx.serialization.json.JsonNull) null else content

    private fun contractCases(): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.cases.json") }
            .firstOrNull(Files::exists) ?: error("generation_parameter_contract.v1.cases.json not found")
        return json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }
}
