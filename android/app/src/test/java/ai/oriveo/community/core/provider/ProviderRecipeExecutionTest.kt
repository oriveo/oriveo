package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.CapabilityExecutionResult
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RequestPreferenceResolver
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Frozen continuation plus lossless custom fixtures; every input is a local JSON file. */
class ProviderRecipeExecutionTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test fun `continuation fixture maps exact protocol wire or restarts clean`() {
        val fixture = fixture()
        fixture["continuationCases"]!!.jsonArray.forEach { raw ->
            val case = raw.jsonObject
            val state = case["state"] as? JsonObject
            val intent = state?.let {
                RequestPreferenceResolver.ContinuationIntent(
                    kind = case.string("kind")!!,
                    variant = case.string("variant"),
                    step = (case["step"] as? JsonPrimitive)?.content?.toInt() ?: 0,
                    state = it,
                )
            }
            val wire = ProviderRecipeExecution.continuation(
                case.string("kind")!!,
                case.string("variant"),
                case.string("targetProtocol") ?: "any",
                case.string("targetResponseParserKind"),
                intent,
            )
            val expected = case["expectedWire"] as? JsonObject
            if (state == null) {
                // Missing/corrupt local state deliberately restarts as an ordinary request.
                // The fixture's reason is lifecycle diagnostics, while the wire mapper must
                // decline continuation rather than manufacture a previous-id/body delta.
                assertEquals("invalid_continuation", (wire as? ProviderRecipeExecution.ContinuationWire.Rejected)?.reason)
            } else if (expected != null) when (wire) {
                is ProviderRecipeExecution.ContinuationWire.Body -> assertEquals(expected["bodyDelta"] ?: JsonObject(emptyMap()), wire.delta)
                is ProviderRecipeExecution.ContinuationWire.Messages -> assertEquals(expected["messageAppend"], wire.append)
                is ProviderRecipeExecution.ContinuationWire.Contents -> assertEquals(expected["contentsAppend"], wire.append)
                is ProviderRecipeExecution.ContinuationWire.Rejected -> throw AssertionError("${case.string("caseId")}: ${wire.reason}")
            }
        }
    }

    @Test fun `mistral replay accepts only exact assistant content shapes and matching parser`() {
        val message = buildJsonObject {
            put("role", "assistant")
            put("content", JsonArray(listOf(
                buildJsonObject {
                    put("type", "thinking")
                    put("thinking", JsonArray(listOf(buildJsonObject { put("type", "text"); put("text", "opaque") })))
                    put("closed", true)
                },
                buildJsonObject { put("type", "text"); put("text", "answer") },
            )))
        }
        val state = JsonObject(mapOf("assistantMessages" to JsonArray(listOf(message))))
        val intent = RequestPreferenceResolver.ContinuationIntent("replay_reasoning", step = 1, state = state)
        assertTrue(RequestPreferenceResolver.validateContinuation(intent).accepted)
        assertTrue(ProviderRecipeExecution.continuation(
            "replay_reasoning", null, "openai_chat", "mistral_reasoning_v1", intent,
        ) is ProviderRecipeExecution.ContinuationWire.Messages)
        assertEquals("invalid_continuation", (ProviderRecipeExecution.continuation(
            "replay_reasoning", null, "openai_chat", "unknown_reasoning_v1", intent,
        ) as ProviderRecipeExecution.ContinuationWire.Rejected).reason)

        val unknownField = JsonObject(message + mapOf("provider_payload" to JsonPrimitive("opaque")))
        val invalid = RequestPreferenceResolver.ContinuationIntent(
            "replay_reasoning", step = 1,
            state = mapOf("assistantMessages" to JsonArray(listOf(unknownField))),
        )
        assertEquals("invalid_reasoning_replay_state", RequestPreferenceResolver.validateContinuation(invalid).reason)
    }

    @Test fun `mistral nonstream accumulator preserves string and block array content`() {
        val stringAccumulator = ProviderRecipeExecution.ReasoningAssistantAccumulator("mistral_reasoning_v1")
        stringAccumulator.ingest(buildJsonObject { put("content", "complete answer") }, completeMessage = true)
        assertEquals(
            Json.parseToJsonElement("""{"assistantMessages":[{"role":"assistant","content":"complete answer"}]}"""),
            stringAccumulator.stateOrNull(),
        )

        val blocks = Json.parseToJsonElement(
            """[{"type":"thinking","thinking":[{"type":"text","text":"complete thought"}],"closed":true},{"type":"text","text":"complete answer"}]""",
        )
        val blockAccumulator = ProviderRecipeExecution.ReasoningAssistantAccumulator("mistral_reasoning_v1")
        blockAccumulator.ingest(buildJsonObject { put("content", blocks) }, completeMessage = true)
        assertEquals(
            JsonObject(mapOf("assistantMessages" to JsonArray(listOf(buildJsonObject {
                put("role", "assistant"); put("content", blocks)
            })))),
            blockAccumulator.stateOrNull(),
        )
    }

    @Test fun `moonshot accumulator preserves an explicitly empty reasoning echo`() {
        val accumulator = ProviderRecipeExecution.ReasoningAssistantAccumulator("moonshot_reasoning_v1")
        accumulator.ingest(json.parseToJsonElement("""{
          "content":"",
          "reasoning_content":"",
          "tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]
        }""").jsonObject)

        assertEquals(
            json.parseToJsonElement("""{"assistantMessages":[{"role":"assistant","content":"","reasoning_content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]}]}"""),
            accumulator.stateOrNull(),
        )
    }

    @Test fun `MiniMax stream accumulator and mapper preserve exact opaque assistant state`() {
        val accumulator = ProviderRecipeExecution.ReasoningAssistantAccumulator("minimax_reasoning_v1")
        accumulator.ingest(json.parseToJsonElement("""{
          "content":"",
          "reasoning_details":[{"index":0,"type":"reasoning.encrypted","data":"opaque-"}],
          "tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\""}}]
        }""").jsonObject)
        accumulator.ingest(json.parseToJsonElement("""{
          "content":"answer",
          "reasoning_details":[{"index":0,"type":"reasoning.encrypted","data":"state"}],
          "tool_calls":[{"index":0,"function":{"arguments":":\"news\"}"}}]
        }""").jsonObject)
        val state = accumulator.stateOrNull()
        assertNotNull(state)
        val exactState = state!!
        assertEquals(
            json.parseToJsonElement("""{"assistantMessages":[{"role":"assistant","content":"answer","reasoning_details":[{"index":0,"type":"reasoning.encrypted","data":"opaque-state"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"news\"}"}}]}]}"""),
            exactState,
        )
        val intent = RequestPreferenceResolver.ContinuationIntent("replay_reasoning", step = 1, state = exactState)
        val wire = ProviderRecipeExecution.continuation(
            "replay_reasoning", null, "openai_chat", "minimax_reasoning_v1", intent,
        ) as ProviderRecipeExecution.ContinuationWire.Messages
        assertEquals(exactState["assistantMessages"], wire.append)
    }

    @Test fun `MiniMax nonstream preserves null content and malformed shapes fail closed`() {
        val valid = ProviderRecipeExecution.ReasoningAssistantAccumulator("minimax_reasoning_v1")
        valid.ingest(json.parseToJsonElement("""{
          "content":null,
          "reasoning_details":[{"type":"reasoning.encrypted","data":"opaque"}],
          "tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]
        }""").jsonObject, completeMessage = true)
        assertEquals(
            json.parseToJsonElement("""{"assistantMessages":[{"role":"assistant","content":null,"reasoning_details":[{"type":"reasoning.encrypted","data":"opaque"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]}]}"""),
            valid.stateOrNull(),
        )

        listOf(
            """{"content":1,"reasoning_details":[{"data":"opaque"}]}""",
            """{"content":"","reasoning_details":["opaque"]}""",
            """{"content":"","reasoning_details":[{"index":"0","data":"opaque"}]}""",
            """{"content":"","reasoning_details":[{"data":"opaque"}],"tool_calls":[{"index":"0","id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]}""",
            """{"content":"","reasoning_details":[{"data":"opaque"}],"tool_calls":[{"id":1,"type":"function","function":{"name":"lookup","arguments":"{}"}}]}""",
            """{"content":"","reasoning_details":[{"data":"opaque"}],"tool_calls":[{"id":"call_1","type":"function","function":{"name":"","arguments":"{}"}}]}""",
        ).forEach { raw ->
            val invalid = ProviderRecipeExecution.ReasoningAssistantAccumulator("minimax_reasoning_v1")
            invalid.ingest(json.parseToJsonElement(raw).jsonObject, completeMessage = true)
            assertEquals(null, invalid.stateOrNull())
        }
    }

    @Test fun `safe custom fixture rejects losslessly and previews actual deltas`() {
        fixture()["safeCustomCases"]!!.jsonArray.forEach { raw ->
            val case = raw.jsonObject
            if (case.string("configurationMode") == "auto") return@forEach
            val rawJson = case.string("raw") ?: when {
                case["generatedUtf8Bytes"] != null -> "{\"x\":\"${"a".repeat((case["generatedUtf8Bytes"] as JsonPrimitive).content.toInt())}\"}"
                case["generatedDepth"] != null -> nested((case["generatedDepth"] as JsonPrimitive).content.toInt())
                case["generatedNodes"] != null -> "{" + (0 until (case["generatedNodes"] as JsonPrimitive).content.toInt()).joinToString(",") { "\"n$it\":0" } + "}"
                else -> error("fixture raw missing")
            }
            val owners = (case["declaredOwners"] as? JsonObject)?.mapValues { it.value as JsonPrimitive }?.mapValues { it.value.content }
                ?: controlOwners(case)
            val result = ProviderRecipeExecution.compileSafeCustom(rawJson, case.string("owner") ?: "generation", owners)
            val reason = case.string("expectReason")
            if (reason != null) assertEquals(case.string("caseId"), reason, result.reason)
            else {
                assertTrue(case.string("caseId"), result.accepted)
                assertEquals(case["expectedDelta"], result.delta)
                assertTrue("production preview", result.preview != null)
            }
        }
    }

    @Test fun `configuration mode fixture defines owner mutual exclusion contract`() {
        fixture()["safeCustomCases"]!!.jsonArray.forEach { raw ->
            val case = raw.jsonObject
            val mode = case.string("configurationMode") ?: return@forEach
            val owner = case.string("owner")!!
            val expectRecipe = (case["expectRecipeSelected"] as? JsonPrimitive)?.content?.toBooleanStrict()
            val expectCustom = (case["expectCustomApplied"] as? JsonPrimitive)?.content?.toBooleanStrict()
            val expectTypedOmitted = (case["expectTypedOwnerOmitted"] as? JsonPrimitive)?.content?.toBooleanStrict()
            when (mode) {
                "custom" -> {
                    assertEquals(case.string("caseId"), false, expectRecipe)
                    assertEquals(case.string("caseId"), true, expectCustom)
                    assertEquals(case.string("caseId"), true, expectTypedOmitted)
                }
                "auto" -> {
                    assertEquals(case.string("caseId"), true, expectRecipe)
                    assertEquals(case.string("caseId"), false, expectCustom)
                    assertEquals(case.string("caseId"), false, expectTypedOmitted)
                }
                else -> throw AssertionError("${case.string("caseId")}: unsupported mode for $owner")
            }
        }
    }

    @Test fun `custom numeric literals preserve integer precision and reject non finite values`() {
        val owners = mapOf("/max_output_tokens" to "generation", "/temperature" to "generation")
        val integer = ProviderRecipeExecution.compileSafeCustom("{\"max_output_tokens\":256}", "generation", owners)
        assertTrue(integer.accepted)
        assertEquals(JsonObject(mapOf("max_output_tokens" to JsonPrimitive(256L))), integer.delta)

        val decimal = ProviderRecipeExecution.compileSafeCustom("{\"temperature\":0.2}", "generation", owners)
        assertTrue(decimal.accepted)
        assertEquals(JsonObject(mapOf("temperature" to JsonPrimitive(0.2))), decimal.delta)

        listOf("{\"max_output_tokens\":9223372036854775808}", "{\"temperature\":1e999}", "{\"temperature\":NaN}").forEach { raw ->
            assertEquals("invalid_json", ProviderRecipeExecution.compileSafeCustom(raw, "generation", owners).reason)
        }
    }

    /**
     * Authorize on r3, let an r4 refresh land, then settle the dispatch: the request has to keep
     * r3's revision and must never start reading r4.
     *
     * This check used to be a four-line source grep asserting on literals such as
     * `CapabilityCustomControlAuthority(it, runtimeRevision)`. Adding riskTiers turned that
     * constructor into multi-line named arguments and the test went red on the spot: the text
     * shape had changed while the behaviour had not moved at all. Everything now goes through
     * production objects instead. The owners and revision come from what
     * [MetadataClient.capabilityCustomControlAuthority] returns, and the execution facts come
     * from what the production [applyCapabilityRuntimeCustomFragment] writes into the collector.
     */
    @Test fun `custom authorization freezes revision with owners before a metadata refresh can race`() = runTest {
        val case = fixture()["safeCustomCases"]!!.jsonArray.map { it.jsonObject }
            .single { it.string("caseId") == "custom.web_owner_allowed" }
        applyCustomOwnerRuntime("sha256:r3", case)

        // owners and revision are the same immutable result from one snapshot read, not two
        // independent reads.
        val r3 = MetadataClient.instance
            .capabilityCustomControlAuthority(ProviderKind.Qwen, CUSTOM_MODEL, "openai_chat", "web")
        assertNotNull("r3 authority", r3)
        assertEquals("sha256:r3", r3!!.runtimeRevision)
        assertEquals(mapOf("/enable_search" to "web"), r3.owners)

        // The production outbound path authorizes on r3, writes the delta and records the
        // execution fact.
        var dispatched: List<CapabilityExecutionResult> = emptyList()
        val collector = CapabilityExecutionCollector { dispatched = it }
        val body = applyCapabilityRuntimeCustomFragment(
            "{}",
            ProviderKind.Qwen,
            CUSTOM_MODEL,
            "openai_chat",
            ChatRequestOptions(
                localCustomFragments = mapOf("web" to case.string("raw")!!),
                capabilityExecutionCollector = collector,
            ),
        )
        assertEquals(case["expectedDelta"], json.parseToJsonElement(body).jsonObject)

        // The r4 refresh replaces the whole table before the dispatch settles. The assertion
        // right below first proves the new snapshot really took effect; without it, "still r3"
        // could just mean the refresh never happened.
        applyCustomOwnerRuntime("sha256:r4", case)
        assertEquals(
            "sha256:r4",
            MetadataClient.instance
                .capabilityCustomControlAuthority(ProviderKind.Qwen, CUSTOM_MODEL, "openai_chat", "web")
                ?.runtimeRevision,
        )

        collector.confirmDispatched()
        assertEquals(listOf("web" to "sha256:r3"), dispatched.map { it.owner to it.revision })
    }

    @Test fun `all typed execution cases are registry backed and external connectors never execute`() {
        val fixture = fixture()
        val runtime = json.parseToJsonElement(File(root(), fixture.string("registryPath")!!).readText()).jsonObject
        assertEquals(5, fixture["executionCases"]!!.jsonArray.size)
        fixture["executionCases"]!!.jsonArray.forEach { raw ->
            val case = raw.jsonObject
            if (case.string("executionKind") == "external_connector") {
                assertEquals(true, case["expected"]!!.jsonObject["noExecute"]!!.toString().toBoolean())
                assertEquals(null, case.string("recipeRef"))
                return@forEach
            }
            val recipe = runtime["recipes"]!!.jsonObject[case.string("recipeRef")]!!.jsonObject
            assertEquals(case.string("executionKind"), recipe.string("executionKind"))
            assertEquals(case.string("providerKind"), recipe.string("providerKind"))
            // Alternate routes are selected against the model's source transport; targetProtocol
            // is the post-selection production mapper/parser transport.
            val selectorTransport = case["expected"]!!.jsonObject.string("sourceProtocol")
                ?: case["expected"]!!.jsonObject.string("targetTransport")
                ?: case.string("transport")!!
            val compiled = ProviderRecipeRequestCompiler.compile(runtime, ProviderRecipeRequestCompiler.Input(
                providerKind = case.string("providerKind")!!,
                transport = selectorTransport,
                recipeRef = case.string("recipeRef")!!,
                capability = case.string("capability")!!,
            ))
            assertTrue("${case.string("caseId")}: ${compiled.reason}", compiled.accepted)
            case["expected"]!!.jsonObject["bodyDelta"]?.let { assertEquals(it, compiled.delta) }
        }
    }

    /**
     * Uses the published runtime rather than a made-up one: both the registry and the
     * controlDefinitions are read from the real files and only the revision is swapped. That
     * way "r3 to r4" really does change the published generation instead of swapping in a
     * runtime the test invented for itself.
     */
    private fun applyCustomOwnerRuntime(revision: String, case: JsonObject) {
        val registry = json.parseToJsonElement(File(root(), fixture().string("registryPath")!!).readText()).jsonObject
        val definitions = json.parseToJsonElement(File(
            root(),
            "shared/capabilityrecipe/capability_custom_controls.v2.json",
        ).readText()).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive(revision),
            "generatedAt" to JsonPrimitive("2026-08-12T00:00:00Z"),
            "controlDefinitions" to definitions,
        ))
        val controlRefs = (case["controlRefs"] as JsonArray).map { it.jsonPrimitive.content }
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put("qwen", buildJsonObject {
                    put("resolveMap", buildJsonObject { put(CUSTOM_MODEL, CUSTOM_MODEL) })
                    put("models", buildJsonObject {
                        put(CUSTOM_MODEL, buildJsonObject {
                            put("transport", "openai_chat")
                            put("capabilityControls", buildJsonObject {
                                put("web", buildJsonObject {
                                    put("state", "auto_available")
                                    put("recipeRef", "qwen.chat.web.v1")
                                    put("customControlRefs", JsonArray(controlRefs.map(::JsonPrimitive)))
                                })
                            })
                        })
                    })
                })
            })
        }.toString())
    }

    private fun nested(depth: Int): String = buildString { repeat(depth) { append("{\"nested\":") }; append("0"); repeat(depth) { append('}') } }
    private fun fixture(): JsonObject = json.parseToJsonElement(File(root(), "shared/model-contracts/provider_recipe_execution.v1.json").readText()).jsonObject
    /** The shared fixture names authoritative refs; resolve them from the Server's shipped
     * controlDefinitions source rather than inventing a second client pointer table. */
    private fun controlOwners(case: JsonObject): Map<String, String> {
        val refs = (case["controlRefs"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
        if (refs.isEmpty()) return emptyMap()
        val definitions = json.parseToJsonElement(File(root(), "shared/capabilityrecipe/capability_custom_controls.v2.json").readText()).jsonObject
        return refs.associate { ref ->
            val definition = definitions[ref]!!.jsonObject
            definition["targetPointer"]!!.jsonPrimitive.content to definition["owner"]!!.jsonPrimitive.content
        }
    }
    private fun root(): File {
        val userDir: String = System.getProperty("user.dir") ?: error("user.dir unavailable")
        val moduleDir: File = File(userDir).absoluteFile
        return moduleDir.parentFile?.parentFile ?: error("Android test root unavailable")
    }
    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.content

    private companion object {
        const val CUSTOM_MODEL = "qwen-custom"
    }
}
