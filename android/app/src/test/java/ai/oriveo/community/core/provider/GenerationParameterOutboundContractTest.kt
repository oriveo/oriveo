package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.builtins.ListSerializer
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
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Drives the shared outboundCases through the production resolver and real Anthropic body builders. */
class GenerationParameterOutboundContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `shared outbound cases match the production per item resolver`() {
        val contract = json.parseToJsonElement(contractText()).jsonObject
        val reasons = contract["outboundRules"]!!.jsonObject["dropReasons"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(reasons, GenerationParameterResolver.DropReason.entries.map { it.wireName })
        val cases = contract["outboundCases"]!!.jsonArray.map { it.jsonObject }
        assertEquals(21, cases.size)

        val failures = mutableListOf<String>()
        cases.forEach { item ->
            val caseId = item["caseId"]!!.jsonPrimitive.content
            val result = runCase(item)
            val expect = item["expect"]!!.jsonObject
            val actualBody = json.parseToJsonElement(result.body).jsonObject
            if (actualBody != expect["body"]) failures += "$caseId: body=$actualBody, want ${expect["body"]}"
            val wantDropped = expect["dropped"]!!.jsonArray.map {
                it.jsonObject["parameterId"]!!.jsonPrimitive.content to it.jsonObject["reason"]!!.jsonPrimitive.content
            }
            val actualDropped = result.dropped.map { it.parameterId to it.reason.wireName }
            if (actualDropped != wantDropped) failures += "$caseId: dropped=$actualDropped, want $wantDropped"
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `relay anthropic thinking body drops sampling and lifts max tokens above the budget`() {
        val model = anthropicModel("claude-sonnet-4-5")
        val projection = relayProjection(
            model, RelayTransport.AnthropicMessages,
            keys = setOf("reasoning_level/deep", "generation_parameter/temperature", "generation_parameter/max_output_tokens"),
        )
        val withOverrides = json.parseToJsonElement(buildAnthropicBody(
            model.id, emptyList(), true, ReasoningMode.Deep,
            ChatRequestOptions(generationParameters = overrides("temperature" to 0.3, "max_output_tokens" to 10000), activeModel = model),
            capabilityProjection = projection,
        )).jsonObject
        assertEquals(16384, withOverrides["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertNull(withOverrides["temperature"])
        assertEquals("20480", withOverrides["max_tokens"]!!.jsonPrimitive.content)

        val builderOnly = json.parseToJsonElement(buildAnthropicBody(
            model.id, emptyList(), true, ReasoningMode.Deep,
            ChatRequestOptions(activeModel = model),
            capabilityProjection = projection,
        )).jsonObject
        assertEquals("20480", builderOnly["max_tokens"]!!.jsonPrimitive.content)
    }

    @Test
    fun `official anthropic thinking body drops sampling and lifts max tokens above the budget`() = runTest {
        MetadataTestFixtures.applyRaw(officialMetadata().toString())
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "outbound-test-key",
                modelID = OFFICIAL_MODEL,
                messages = emptyList(),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Deep,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    generationParameters = overrides("temperature" to 0.3, "max_output_tokens" to 10000),
                ),
            ).toList()
        }
        val body = json.parseToJsonElement(requireNotNull(requestBody) { "Anthropic did not build a request" }).jsonObject
        assertEquals("enabled", body["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals(16384, body["thinking"]!!.jsonObject["budget_tokens"]!!.jsonPrimitive.content.toInt())
        assertNull(body["temperature"])
        assertEquals("20480", body["max_tokens"]!!.jsonPrimitive.content)
    }

    @Test
    fun `relay anthropic thinking drops builder written legacy temperature too`() {
        val model = anthropicModel("claude-sonnet-4-5")
        val projection = relayProjection(
            model, RelayTransport.AnthropicMessages,
            keys = setOf("reasoning_level/deep", "generation_parameter/temperature", "generation_parameter/max_output_tokens"),
        )
        val thinking = json.parseToJsonElement(buildAnthropicBody(
            model.id, emptyList(), true, ReasoningMode.Deep,
            ChatRequestOptions(temperature = 0.7f, activeModel = model),
            capabilityProjection = projection,
        )).jsonObject
        assertEquals("enabled", thinking["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertNull(thinking["temperature"])

        val plain = json.parseToJsonElement(buildAnthropicBody(
            model.id, emptyList(), true, ReasoningMode.Fast,
            ChatRequestOptions(temperature = 0.7f, activeModel = model),
            capabilityProjection = relayProjection(
                model, RelayTransport.AnthropicMessages,
                keys = setOf("generation_parameter/temperature", "generation_parameter/max_output_tokens"),
            ),
        )).jsonObject
        assertNull(plain["thinking"])
        assertEquals("0.7", plain["temperature"]!!.jsonPrimitive.content)
    }

    @Test
    fun `official anthropic thinking drops builder written legacy temperature too`() = runTest {
        MetadataTestFixtures.applyRaw(officialMetadata().toString())
        val thinking = officialAnthropicBody(ReasoningMode.Deep, ChatRequestOptions(temperature = 0.7f))
        assertEquals("enabled", thinking["thinking"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertNull(thinking["temperature"])
    }

    private suspend fun officialAnthropicBody(mode: ReasoningMode, options: ChatRequestOptions): JsonObject {
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "outbound-test-key",
                modelID = OFFICIAL_MODEL,
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.Anthropic, OFFICIAL_MODEL)),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = mode,
                webSearchEnabled = false,
                requestOptions = options,
            ).toList()
        }
        return json.parseToJsonElement(requireNotNull(requestBody) { "Anthropic did not build a request" }).jsonObject
    }

    private fun runCase(item: JsonObject): GenerationParameterResolver.Result {
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
        // Android writes capability fields before the resolver runs, so the fixture's writes go into the base body.
        val body = JsonObject(item["body"]!!.jsonObject + (item["capabilityWrites"] as? JsonObject).orEmpty())
        val transport = RelayTransport.entries.first { it.value == template }
        return GenerationParameterResolver.applyWithResult(
            body.toString(),
            ChatRequestOptions(generationParameters = GenerationParameterOverrides(values), activeModel = model),
            null,
            relayProjection(model, transport, parameters.mapNotNull { it.id }.map { "generation_parameter/$it" }.toSet()),
        )
    }

    private fun anthropicModel(id: String) = AIModel(
        id = id,
        name = id,
        generationProfile = GenerationProfileRef(
            template = "anthropic_messages",
            parameters = listOf(
                GenerationParameterRef(id = "max_output_tokens", support = "supported", valueSchema = "integer"),
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number"),
            ),
            wire = mapOf("max_output_tokens" to "max_tokens", "temperature" to "temperature"),
        ),
    )

    private fun overrides(vararg values: Pair<String, Number>) = GenerationParameterOverrides(
        values.associate { (id, value) -> id to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(value)) },
    )

    private fun relayProjection(
        model: AIModel,
        transport: RelayTransport,
        keys: Set<String>,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val provider = Provider(
            id = "relay-outbound",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val finalUrl = when (transport) {
            RelayTransport.AnthropicMessages -> "https://relay.example/v1/messages"
            RelayTransport.OpenAIChatCompletions -> "https://relay.example/v1/chat/completions"
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

    /** Also reused by AdditionalRequestBodySendChainTest for the official Anthropic send chain. */
    internal fun officialMetadata(): JsonObject {
        val registry = json.parseToJsonElement(repoText(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        )).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:fixture"),
            "generatedAt" to JsonPrimitive("2026-10-08T00:00:00Z"),
        ))
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("profiles", buildJsonObject { put("generation", buildJsonObject {
                put("version", 1)
                put("parameters", buildJsonObject {
                    put("temperature", buildJsonObject { put("valueSchema", "number") })
                    put("max_output_tokens", buildJsonObject { put("valueSchema", "integer") })
                })
                put("templates", buildJsonObject {
                    put("anthropic_messages", buildJsonObject {
                        put("transport", "anthropic_messages")
                        put("wire", buildJsonObject {
                            put("temperature", "temperature")
                            put("max_output_tokens", "max_tokens")
                        })
                    })
                })
            }) })
            put("providers", buildJsonObject {
                put("anthropic", buildJsonObject {
                    put("resolveMap", buildJsonObject { put(OFFICIAL_MODEL, OFFICIAL_MODEL) })
                    put("models", buildJsonObject {
                        put(OFFICIAL_MODEL, buildJsonObject {
                            put("transport", "anthropic_messages")
                            put("profiles", buildJsonObject { put("generation", buildJsonObject {
                                put("template", "anthropic_messages")
                                put("parameters", JsonArray(listOf("temperature", "max_output_tokens").map { id ->
                                    buildJsonObject { put("id", id); put("support", "supported") }
                                }))
                            }) })
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "unavailable")
                                    put("reasonCode", "fixture_no_auto")
                                    put("sourceRefs", JsonArray(listOf(JsonPrimitive("anthropic.web_search"))))
                                })
                                put("reasoning", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", "anthropic.messages.reasoning.v1")
                                    put("availableIntents", JsonArray(listOf("off", "low", "balanced", "deep").map(::JsonPrimitive)))
                                })
                                put("generation", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", "anthropic.messages.generation.v1")
                                })
                            })
                        })
                    })
                })
            })
        }
    }

    /** Rules and cases live in two sibling files; merge them the same way GenerationParameterContractTest does. */
    private fun contractText(): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.json") }
            .firstOrNull(Files::exists)
            ?: error("generation_parameter_contract.v1.json not found")
        val casesPath = path.resolveSibling("generation_parameter_contract.v1.cases.json")
        val rules = json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
        val cases = json.parseToJsonElement(String(Files.readAllBytes(casesPath), Charsets.UTF_8)).jsonObject
        return JsonObject(rules + cases.filterKeys { it != "\$comment" }).toString()
    }

    private fun repoText(relative: String): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relative) }
            .firstOrNull(Files::exists)
            ?: error("$relative not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    internal companion object {
        const val OFFICIAL_MODEL = "claude-sonnet-4-5"
    }
}
