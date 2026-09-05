package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.HttpHeaders
import io.ktor.http.headersOf
import io.ktor.http.content.TextContent
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
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
import org.junit.Test
import java.io.File

/** Two layers of evidence over the shared recipe fixture: the production compiler, then the real provider request builders. */
class CapabilityRecipeRequestCompilerTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `shared recipe fixture compiles registry recipes and redacts previews`() {
        val fixture = json.parseToJsonElement(load("shared/model-contracts/provider_recipe_request_compiler.v1.json")).jsonObject
        val runtime = json.parseToJsonElement(load(fixture["registryPath"]!!.toString().trim('"'))).jsonObject

        fixture["cases"]!!.jsonArray.forEach { element ->
            val case = element.jsonObject
            val result = ProviderRecipeRequestCompiler.compile(
                runtime = runtime,
                input = ProviderRecipeRequestCompiler.Input(
                    providerKind = case.string("providerKind")!!,
                    transport = case.string("transport")!!,
                    recipeRef = case.string("recipeRef")!!,
                    capability = case.string("capability")!!,
                    selectedIntent = case.string("selectedIntent"),
                    availableIntents = case.string("selectedIntent")?.let(::listOf),
                    baseOwnedArrays = (case["baseOwnedArrays"] as? JsonObject)?.orEmptyArrays().orEmpty(),
                ),
            )
            assertTrue("${case.string("caseId")}: ${result.reason}", result.accepted)
            assertEquals(case["expectedDelta"], result.delta)
            assertNotNull("${case.string("caseId")} needs a redacted production preview", result.redactedPreview)
        }
        fixture["negativeCases"]!!.jsonArray.forEach { element ->
            val case = element.jsonObject
            val result = ProviderRecipeRequestCompiler.compile(
                runtime = runtime,
                input = ProviderRecipeRequestCompiler.Input(
                    providerKind = case.string("providerKind")!!,
                    transport = case.string("transport")!!,
                    recipeRef = case.string("recipeRef")!!,
                    capability = case.string("capability")!!,
                    selectedIntent = case.string("selectedIntent"),
                    availableIntents = case.string("selectedIntent")?.let(::listOf),
                ),
            )
            assertFalse("${case.string("caseId")} must fail", result.accepted)
            assertEquals(case.string("expectReason"), result.reason)
        }

        val recipes = runtime["recipes"]!!.jsonObject
        val generation = recipes["openai.responses.generation.v1"]!!.jsonObject
        val mixedGeneration = JsonObject(generation + ("requestOps" to JsonArray(
            generation["requestOps"]!!.jsonArray + buildJsonObject {
                put("op", "set"); put("pointer", "/temperature"); put("value", 0.8)
            },
        )))
        val malformedRuntime = JsonObject(runtime + ("recipes" to JsonObject(
            recipes + ("openai.responses.generation.v1" to mixedGeneration),
        )))
        val malformed = ProviderRecipeRequestCompiler.compile(
            malformedRuntime,
            ProviderRecipeRequestCompiler.Input(
                "openAI", "openai_responses", "openai.responses.generation.v1", "generation",
            ),
        )
        assertFalse("mixed legacy generation ops must be a zero-delta rejection", malformed.accepted)
        assertEquals(null, malformed.delta)
    }

    @Test
    fun `selected intent must also be present in the model control allowlist`() {
        val fixture = json.parseToJsonElement(load("shared/model-contracts/provider_recipe_request_compiler.v1.json")).jsonObject
        val runtime = json.parseToJsonElement(load(fixture["registryPath"]!!.toString().trim('"'))).jsonObject
        val case = fixture["cases"]!!.jsonArray.first { it.jsonObject.string("selectedIntent") != null }.jsonObject

        val result = ProviderRecipeRequestCompiler.compile(
            runtime,
            ProviderRecipeRequestCompiler.Input(
                providerKind = case.string("providerKind")!!,
                transport = case.string("transport")!!,
                recipeRef = case.string("recipeRef")!!,
                capability = case.string("capability")!!,
                selectedIntent = case.string("selectedIntent"),
                availableIntents = listOf("different-intent"),
            ),
        )

        assertFalse(result.accepted)
        assertEquals("intent_not_available", result.reason)
        assertEquals(null, result.delta)
    }

    @Test
    fun `malformed mixed generation template cannot authorize typed production wire`() = runTest {
        val execution = json.parseToJsonElement(load("shared/model-contracts/provider_recipe_execution.v1.json")).jsonObject
        val registry = json.parseToJsonElement(load(execution.string("registryPath")!!)).jsonObject
        val recipes = registry["recipes"]!!.jsonObject
        val generation = recipes["openai.responses.generation.v1"]!!.jsonObject
        val mixed = JsonObject(generation + ("requestOps" to JsonArray(
            generation["requestOps"]!!.jsonArray + JsonPrimitive("junk"),
        )))
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:mixed-generation"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
            "recipes" to JsonObject(recipes + ("openai.responses.generation.v1" to mixed)),
        ))
        val coverage = execution["providerCoverage"]!!.jsonArray
            .map { it.jsonObject }
            .filter { it.string("recipeRef") == "openai.responses.generation.v1" }
        MetadataTestFixtures.applyRaw(matrixMetadataPayload(runtime, coverage).toString())

        val captured = captureMatrix(
            ProviderKind.OpenAI, coverage.single().string("modelId")!!, true,
            ChatRequestOptions(temperature = 0.31f),
        )
        assertEquals(null, captured.error)
        assertEquals("ok", captured.done?.result?.text)
        assertEquals(null, captured.body!!.jsonObject["temperature"])
    }

    @Test
    fun `runtime recipes reach four actual provider request builders and suppress legacy fallback`() = runTest {
        val registry = json.parseToJsonElement(load("shared/capabilityrecipe/capability_runtime.v1.json")).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:fixture"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(metadataPayload(runtime).toString())
        assertNotNull(MetadataClient.resolveCatalogModel("gpt-5-mini", ProviderKind.OpenAI))
        assertEquals(
            "apply_recipe",
            RequestPreferenceResolver.resolveControls(
                providerKind = "openAI",
                capabilityControls = mapOf(
                    "web" to RequestPreferenceResolver.ControlEntry("auto_available", "openai.responses.web.v1"),
                    "reasoning" to RequestPreferenceResolver.ControlEntry("auto_available", "openai.responses.reasoning.v1"),
                ),
                recipes = (runtime["recipes"] as JsonObject).keys.toList(),
                sourceIndexKeys = (runtime["sourceIndex"] as JsonObject).keys,
            ).results["web"]?.action,
        )
        val openAISelection = MetadataClient.capabilityRuntimeRequest(
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-5-mini",
            finalTransport = "openai_responses",
            webRequested = true,
            reasoningMode = ReasoningMode.Deep,
        )
        assertEquals(setOf("web", "reasoning"), openAISelection?.selections?.map { it.capability }?.toSet())

        val openAI = capture(
            service = { client -> OpenAIService(client, json, TransportRegistry(json)) },
            kind = ProviderKind.OpenAI,
            modelID = "gpt-5-mini",
            reasoning = ReasoningMode.Deep,
            web = true,
        ).jsonObject
        assertEquals("web_search", openAI["tools"]!!.jsonArray.single().jsonObject.string("type"))
        assertEquals("high", openAI["reasoning"]!!.jsonObject.string("effort"))

        val anthropic = capture(
            service = { client -> AnthropicService(client, json, TransportRegistry(json)) },
            kind = ProviderKind.Anthropic,
            modelID = "claude-sonnet-4-5",
            reasoning = ReasoningMode.Max,
            web = true,
        ).jsonObject
        assertEquals("web_search_20250305", anthropic["tools"]!!.jsonArray.single().jsonObject.string("type"))
        assertEquals("adaptive", anthropic["thinking"]!!.jsonObject.string("type"))
        assertEquals("max", anthropic["output_config"]!!.jsonObject.string("effort"))

        val gemini = capture(
            service = { client -> GeminiService(client, json, TransportRegistry(json)) },
            kind = ProviderKind.Gemini,
            modelID = "gemini-3.1-flash-preview",
            reasoning = ReasoningMode.Balanced,
            web = true,
        ).jsonObject
        assertTrue(gemini["tools"]!!.jsonArray.single().jsonObject.containsKey("google_search"))
        assertEquals(
            "medium",
            gemini["generationConfig"]!!.jsonObject["thinkingConfig"]!!.jsonObject.string("thinkingLevel"),
        )

        val deepSeek = capture(
            service = { client -> DeepSeekService(client, json) },
            kind = ProviderKind.DeepSeek,
            modelID = "deepseek-v4-flash",
            reasoning = ReasoningMode.Max,
            web = true,
        ).jsonObject
        assertEquals("max", deepSeek.string("reasoning_effort"))
        assertFalse("unavailable web must not revive legacy search fields", deepSeek.containsKey("enable_search"))

        val modelRoute = capture(
            service = { client -> OpenAIService(client, json, TransportRegistry(json)) },
            kind = ProviderKind.OpenAI,
            modelID = "gpt-5-search-api",
            reasoning = ReasoningMode.Automatic,
            web = true,
        ).jsonObject
        assertFalse("exact model route is an empty body delta", modelRoute.containsKey("tools"))
        assertEquals("gpt-5-search-api", modelRoute.string("model"))
    }

    @Test
    fun `shared R3 final body cases reach the OpenAI production builder and dispatch latch`() = runTest {
        val shared = json.parseToJsonElement(
            load("shared/model-contracts/model_control_runtime.v1.json"),
        ).jsonObject
        val cases = shared["finalBodyCases"]!!.jsonArray.associateBy { it.jsonObject.string("caseId")!! }
        val registry = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_runtime.v1.json"),
        ).jsonObject

        val exact = cases.getValue("exact_recipe_all_owners").jsonObject
        val exactRuntime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive(exact["identity"]!!.jsonObject.string("runtimeRevision")!!),
            "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(r3FinalBodyMetadata(exactRuntime, exact).toString())
        val dispatched = mutableListOf<ai.oriveo.community.core.model.CapabilityExecutionResult>()
        val collector = ai.oriveo.community.core.model.CapabilityExecutionCollector { dispatched += it }
        val exactCapture = captureMatrix(
            kind = ProviderKind.OpenAI,
            modelID = exact["identity"]!!.jsonObject.string("canonicalModelId")!!,
            streaming = true,
            options = ChatRequestOptions(
                temperature = 0.2f,
                capabilityPreferences = ai.oriveo.community.core.model.CapabilityPreferenceValues(
                    web = ai.oriveo.community.core.model.CapabilityWebPreference.Automatic,
                    reasoningIntent = "deep",
                ),
                capabilityExecutionCollector = collector,
            ),
            reasoning = ReasoningMode.Deep,
            web = true,
        )
        assertEquals(null, exactCapture.error)
        assertEquals(exact["expectedFinalBody"], exactCapture.body)
        assertEquals(
            exact["expectedDispatch"]!!.jsonObject.stringList("requestedOwners").toSet(),
            dispatched.map { it.owner }.toSet(),
        )
        assertFalse(dispatched.any { it.owner == "generation" })

        val unknown = cases.getValue("unknown_or_killed_runtime_plain_chat_remains_valid").jsonObject
        val unknownRuntime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive(unknown["identity"]!!.jsonObject.string("runtimeRevision")!!),
            "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(r3FinalBodyMetadata(unknownRuntime, unknown).toString())
        val unknownCollector = ai.oriveo.community.core.model.CapabilityExecutionCollector()
        val unknownCapture = captureMatrix(
            kind = ProviderKind.OpenAI,
            modelID = unknown["identity"]!!.jsonObject.string("canonicalModelId")!!,
            streaming = true,
            options = ChatRequestOptions(
                temperature = 0.2f,
                capabilityPreferences = ai.oriveo.community.core.model.CapabilityPreferenceValues(
                    web = ai.oriveo.community.core.model.CapabilityWebPreference.Automatic,
                    reasoningIntent = "deep",
                ),
                capabilityExecutionCollector = unknownCollector,
            ),
            reasoning = ReasoningMode.Deep,
            web = true,
        )
        assertEquals(null, unknownCapture.error)
        assertEquals(unknown["expectedFinalBody"], unknownCapture.body)
        assertTrue(unknownCollector.requestedResults().isEmpty())
    }

    @Test
    fun `unknown runtime never revives legacy controls in every production builder family`() = runTest {
        val registry = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_runtime.v1.json"),
        ).jsonObject
        fun unknownModel(id: String, transport: String) = buildJsonObject {
            put("canonicalModelId", id)
            put("transport", transport)
            put("profiles", buildJsonObject {
                put("reasoning", "legacy_reasoning")
                put("webSearch", "legacy_web")
            })
            put("capabilityControls", buildJsonObject {
                put("web", noAutoControl("unknown"))
                put("reasoning", noAutoControl("unknown"))
                put("generation", noAutoControl("unknown"))
            })
        }
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", JsonObject(registry + mapOf(
                "revision" to JsonPrimitive("runtime-unknown-builders"),
                "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
            )))
            put("profiles", buildJsonObject {
                put("reasoning", buildJsonObject {
                    put("legacy_reasoning", buildJsonObject {
                        put("levels", JsonArray(listOf(JsonPrimitive("deep"))))
                        put("params", buildJsonObject {
                            put("deep", buildJsonObject { put("legacy_reasoning_marker", true) })
                        })
                    })
                })
                put("webSearch", buildJsonObject {
                    put("legacy_web", buildJsonObject {
                        put("mergeParams", buildJsonObject { put("legacy_web_marker", true) })
                    })
                })
            })
            put("providers", buildJsonObject {
                put("openAI", provider("unknown-openai" to unknownModel("unknown-openai", "openai_responses")))
                put("anthropic", provider("unknown-anthropic" to unknownModel("unknown-anthropic", "anthropic_messages")))
                put("gemini", provider("unknown-gemini" to unknownModel("unknown-gemini", "gemini_generate_content")))
                put("qwen", provider("unknown-qwen" to unknownModel("unknown-qwen", "openai_chat")))
                put("openRouter", provider("unknown-openrouter" to unknownModel("unknown-openrouter", "openai_chat")))
                put("grok", provider("unknown-compatible" to unknownModel("unknown-compatible", "openai_chat")))
                put("moonshot", provider("unknown-moonshot" to unknownModel("unknown-moonshot", "openai_chat")))
                put("mistral", provider("unknown-mistral" to unknownModel("unknown-mistral", "openai_chat")))
                put("zhipu", provider("unknown-zhipu" to unknownModel("unknown-zhipu", "openai_chat")))
                put("deepseek", provider("unknown-deepseek" to unknownModel("unknown-deepseek", "openai_chat")))
                put("miniMax", provider("unknown-minimax" to unknownModel("unknown-minimax", "openai_chat")))
                put("siliconFlow", provider("unknown-siliconflow" to unknownModel("unknown-siliconflow", "openai_chat")))
                put("groq", provider("unknown-groq" to unknownModel("unknown-groq", "openai_chat")))
                put("togetherAI", provider("unknown-together" to unknownModel("unknown-together", "openai_chat")))
                put("fireworksAI", provider("unknown-fireworks" to unknownModel("unknown-fireworks", "openai_chat")))
            })
        }.toString())

        listOf(
            Triple(ProviderKind.OpenAI, "unknown-openai", "openai_responses"),
            Triple(ProviderKind.Anthropic, "unknown-anthropic", "anthropic_messages"),
            Triple(ProviderKind.Gemini, "unknown-gemini", "gemini_generate_content"),
            Triple(ProviderKind.Qwen, "unknown-qwen", "openai_chat"),
            Triple(ProviderKind.OpenRouter, "unknown-openrouter", "openai_chat"),
            Triple(ProviderKind.Grok, "unknown-compatible", "openai_chat"),
            Triple(ProviderKind.Moonshot, "unknown-moonshot", "openai_chat"),
            Triple(ProviderKind.Mistral, "unknown-mistral", "openai_chat"),
            Triple(ProviderKind.Zhipu, "unknown-zhipu", "openai_chat"),
            Triple(ProviderKind.DeepSeek, "unknown-deepseek", "openai_chat"),
            Triple(ProviderKind.MiniMax, "unknown-minimax", "openai_chat"),
            Triple(ProviderKind.SiliconFlow, "unknown-siliconflow", "openai_chat"),
            Triple(ProviderKind.Groq, "unknown-groq", "openai_chat"),
            Triple(ProviderKind.Together, "unknown-together", "openai_chat"),
            Triple(ProviderKind.Fireworks, "unknown-fireworks", "openai_chat"),
        ).forEach { (kind, modelID, _) ->
            val capture = captureMatrix(
                kind = kind,
                modelID = modelID,
                streaming = true,
                options = ChatRequestOptions(temperature = 0.2f),
                reasoning = ReasoningMode.Deep,
                web = true,
            )
            assertEquals("$kind ordinary chat must complete", null, capture.error)
            val body = capture.body!!.jsonObject
            assertFalse("$kind must not inject legacy reasoning: $body", body.containsKey("legacy_reasoning_marker"))
            assertFalse("$kind must not inject legacy web: $body", body.containsKey("legacy_web_marker"))
            assertFalse("$kind unknown generation must not inject temperature: $body", body.containsKey("temperature"))
            listOf("reasoning", "thinking", "output_config", "web_search_options", "tools", "plugins", "enable_search", "reasoning_effort")
                .forEach { key -> assertFalse("$kind unknown auto field /$key body=$body", body.containsKey(key)) }
        }
    }

    @Test
    fun `shared structured recipe rejection uses production compiler parser latch and exact resend`() = runTest {
        val shared = json.parseToJsonElement(
            load("shared/model-contracts/model_control_runtime.v1.json"),
        ).jsonObject
        val case = shared["rejectionCases"]!!.jsonArray.map(JsonElement::jsonObject)
            .single { it.string("caseId") == "structured_exact_recipe_locator_offers_explicit_resend" }
        val recipeFixture = case["recipe"]!!.jsonObject
        val recipeRef = recipeFixture.string("recipeRef")!!
        val recoveryRef = recipeFixture.string("errorRecoveryRef")!!
        val runtime = buildJsonObject {
            put("schemaVersion", 2)
            put("revision", "runtime-rejection")
            put("generatedAt", "2026-08-14T00:00:00Z")
            put("recipes", buildJsonObject {
                put(recipeRef, JsonObject(recipeFixture + mapOf(
                    "id" to JsonPrimitive(recipeRef),
                    "providerKind" to JsonPrimitive("openAI"),
                    "executionKind" to JsonPrimitive("request_overlay"),
                    "transport" to buildJsonObject { put("protocol", recipeFixture.string("protocol")!!) },
                    "responseEvidenceRef" to JsonPrimitive(recoveryRef),
                )))
            })
            put("controlDefinitions", buildJsonObject { })
            put("sourceIndex", buildJsonObject { })
            put("responseEvidenceDefinitions", buildJsonObject {
                put(recoveryRef, buildJsonObject {
                    put("capability", "web")
                    put("protocol", "openai_responses")
                    put("responseParserKind", recipeFixture.string("responseParserKind")!!)
                    put("signals", JsonArray(emptyList()))
                })
            })
            put("errorRecoveryDefinitions", buildJsonObject {
                put(recoveryRef, case["errorRecoveryDefinition"]!!)
            })
            put("sourceRefreshPolicy", buildJsonObject { put("defaultTtlSeconds", 3600) })
        }
        MetadataTestFixtures.applyRaw(r3RejectionMetadata(runtime, recipeRef).toString())
        val collector = ai.oriveo.community.core.model.CapabilityExecutionCollector()
        var rejectedBody: JsonElement? = null
        val errorClient = HttpClient(MockEngine { request ->
            rejectedBody = (request.body as TextContent).text.let(json::parseToJsonElement)
            respond(
                case["error"]!!.toString(),
                HttpStatusCode.BadRequest,
                headersOf(HttpHeaders.ContentType, "application/json"),
            )
        })
        val error: ai.oriveo.community.core.model.ProviderServiceError.Upstream = runCatching {
            OpenAIService(errorClient, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "test",
                modelID = "fixture-r3",
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "fixture-r3")),
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = true,
                requestOptions = ChatRequestOptions(capabilityExecutionCollector = collector),
            ).toList()
        }.exceptionOrNull() as? ai.oriveo.community.core.model.ProviderServiceError.Upstream
            ?: throw AssertionError("structured production 400 must surface as Upstream")
        assertTrue(rejectedBody!!.jsonObject.containsKey("web_search_options"))
        assertTrue(rejectedBody!!.jsonObject.containsKey("include"))
        val located = collector.locateProviderRecipeRejection(error.statusCode, error.rejectedParameter)
            ?: throw AssertionError("dispatched production recipe must resolve the reviewed locator")
        assertEquals("provider_recipe", located.source)
        assertEquals(recipeRef, located.recipeRef)
        assertEquals(setOf("/web_search_options"), located.locatedPointers.toSet())

        var normalBody: JsonElement? = null
        val normalClient = HttpClient(MockEngine { request ->
            normalBody = (request.body as TextContent).text.let(json::parseToJsonElement)
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        OpenAIService(normalClient, json, TransportRegistry(json)).sendMessageStream(
            apiKey = "test",
            modelID = "fixture-r3",
            messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "fixture-r3")),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(dormantCapabilityOwners = setOf("web")),
        ).toList()
        assertEquals(case["expected"]!!.jsonObject["normalSendAutomaticFields"], buildJsonObject {
            listOf("web_search_options", "include").forEach { key -> normalBody!!.jsonObject[key]?.let { put(key, it) } }
        })

        var resendBody: JsonElement? = null
        val resendClient = HttpClient(MockEngine { request ->
            resendBody = (request.body as TextContent).text.let(json::parseToJsonElement)
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        OpenAIService(resendClient, json, TransportRegistry(json)).sendMessageStream(
            apiKey = "test",
            modelID = "fixture-r3",
            messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "fixture-r3")),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(
                rejectedRecipeSettings = mapOf("web" to mapOf(recipeRef to located.locatedPointers.toSet())),
            ),
        ).toList()
        assertFalse(resendBody!!.jsonObject.containsKey("web_search_options"))
        assertEquals(case["recipe"]!!.jsonObject["requestOps"]!!.jsonArray[1].jsonObject["value"], resendBody!!.jsonObject["include"])
    }

    @Test
    fun `exact nested omission prunes only the newly empty branch in the production final body`() = runTest {
        val registry = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_runtime.v1.json"),
        ).jsonObject
        val recipeRef = "openai.responses.reasoning.v1"
        val recipe = registry["recipes"]!!.jsonObject[recipeRef]!!.jsonObject
        val nestedRecipe = JsonObject(recipe + mapOf(
            "requestOps" to JsonArray(listOf(
                buildJsonObject {
                    put("op", "set")
                    put("pointer", "/reasoning/effort")
                    put("value", "high")
                },
                buildJsonObject {
                    put("op", "set")
                    put("pointer", "/reasoning/summary")
                    put("value", "auto")
                },
            )),
        ))
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("runtime-nested-omission"),
            "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
            "recipes" to JsonObject(registry["recipes"]!!.jsonObject + (recipeRef to nestedRecipe)),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("providers", buildJsonObject {
                put("openAI", provider("fixture-nested" to buildJsonObject {
                    put("canonicalModelId", "fixture-nested")
                    put("transport", "openai_responses")
                    put("capabilityControls", buildJsonObject {
                        put("reasoning", JsonObject(autoControl(recipeRef) + (
                            "availableIntents" to JsonArray(listOf("off", "low", "balanced", "deep", "max").map { JsonPrimitive(it) })
                        )))
                    })
                }))
            })
        }.toString())

        val capture = captureMatrix(
            kind = ProviderKind.OpenAI,
            modelID = "fixture-nested",
            streaming = true,
            options = ChatRequestOptions(
                capabilityPreferences = ai.oriveo.community.core.model.CapabilityPreferenceValues(reasoningIntent = "deep"),
                rejectedRecipeSettings = mapOf("reasoning" to mapOf(recipeRef to setOf("/reasoning/effort"))),
            ),
            reasoning = ReasoningMode.Deep,
        )
        assertEquals(null, capture.error)
        assertEquals(null, capture.body!!.jsonObject["reasoning"]!!.jsonObject["effort"])
        assertEquals("auto", capture.body!!.jsonObject["reasoning"]!!.jsonObject.string("summary"))
    }

    @Test
    fun `all fifteen production services enforce selector stream and safe custom boundaries`() = runTest {
        val execution = json.parseToJsonElement(load("shared/model-contracts/provider_recipe_execution.v1.json")).jsonObject
        val registry = json.parseToJsonElement(load(execution.string("registryPath")!!)).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:matrix"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        val coverage = execution["providerCoverage"]!!.jsonArray.map { it.jsonObject }
        assertEquals(17, coverage.size)
        assertEquals(15, coverage.map { it.string("providerKind") }.toSet().size)
        MetadataTestFixtures.applyRaw(matrixMetadataPayload(runtime, coverage).toString())

        coverage.forEach { item ->
            val kind = providerKind(item.string("providerKind")!!)
            val modelID = item.string("modelId")!!
            val transport = item.string("transport")!!
            val hit = MetadataClient.capabilityRuntimeRequest(kind, modelID, transport, false, ReasoningMode.Automatic)
            assertEquals("$kind selector hit", item.string("recipeRef"), hit?.selections?.singleOrNull { it.capability == "generation" }?.id)
            val miss = MetadataClient.capabilityRuntimeRequest(kind, "$modelID-miss", transport, false, ReasoningMode.Automatic)
            assertTrue("$kind selector miss", miss != null && miss.selections.isEmpty())

            listOf(true, false).forEach { streaming ->
                val omitted = captureMatrix(kind, modelID, streaming, ChatRequestOptions())
                assertNotNull("$kind stream=$streaming did not reach production request", omitted.body)
                assertEquals("$kind stream=$streaming response parser", null, omitted.error)
                assertEquals("$kind stream=$streaming completion", "ok", omitted.done?.result?.text)
                assertEquals("$kind default must omit temperature", null, temperatureValueOrNull(kind, omitted.body!!.jsonObject))
                assertMatrixWire(kind, streaming, omitted)

                // Frozen ruling: the only writable custom paths are the customControlRefs the catalog publishes, and the
                // whole set of controlDefinitions has just three entries (web, reasoning, generation), none of which points
                // at temperature. So a temperature fragment with a perfectly valid shape must be rejected before the socket
                // is opened, for every provider alike. The positive side of those three coordinates is covered by
                // `three frozen custom controls ...`, which pulls its caseIds from the shared fixture.
                val unauthorizedFragment = if (kind == ProviderKind.Gemini) "{\"generationConfig\":{\"temperature\":0.2}}" else "{\"temperature\":0.2}"
                val unauthorized = captureMatrix(kind, modelID, streaming, ChatRequestOptions(localCustomFragment = unauthorizedFragment))
                assertEquals("$kind stream=$streaming unauthorized custom must not open socket", null, unauthorized.body)
                assertTrue("$kind stream=$streaming unauthorized custom must fail explicitly",
                    unauthorized.error is ai.oriveo.community.core.model.ProviderServiceError.InvalidConfiguration)

                val rejected = captureMatrix(kind, modelID, streaming, ChatRequestOptions(localCustomFragment = "{\"model\":\"evil\"}"))
                assertEquals("$kind rejected custom must not open socket", null, rejected.body)
                assertTrue("$kind rejected custom must fail explicitly", rejected.error is ai.oriveo.community.core.model.ProviderServiceError.InvalidConfiguration)

                val conflict = captureMatrix(kind, modelID, streaming, ChatRequestOptions(
                    temperature = 0.7f,
                    localCustomFragment = "{\"temperature\":0.2}",
                    localCustomOwner = "reasoning",
                ))
                assertEquals("$kind forged owner/conflict must not open socket", null, conflict.body)
                val undeclared = captureMatrix(kind, modelID, streaming, ChatRequestOptions(localCustomFragment = "{\"seed\":1}"))
                assertEquals("$kind profile-undeclared custom leaf must not open socket", null, undeclared.body)
            }

            // A generation owner does not enter the execution-fact state machine. This assertion runs through the real
            // Service into applyCapabilityRuntimeRecipes and on to the collector, so it proves two things at once: no badge
            // is produced (the collector sees not a single fact) and the parameter is still sent (temperature really is on
            // the wire).
            val collector = ai.oriveo.community.core.model.CapabilityExecutionCollector()
            val typedHit = captureMatrix(
                kind, modelID, true,
                ChatRequestOptions(temperature = 0.31f, capabilityExecutionCollector = collector),
            )
            collector.confirmDispatched()
            assertEquals(
                "$kind generation recipe must not produce a P5 execution fact",
                emptyList<String>(),
                collector.successfulTerminalResults().map { it.owner },
            )
            val typedTemperature = temperatureValueOrNull(kind, typedHit.body!!.jsonObject)
            assertNotNull("$kind/$transport typed generation body=${typedHit.body}", typedTemperature)
            assertEquals("$kind runtime recipe overrides missing legacy evidence", 0.31,
                typedTemperature!!, 0.0001)
            val typedMiss = captureMatrix(kind, "$modelID-miss", true, ChatRequestOptions(temperature = 0.31f))
            assertEquals("$kind runtime miss ordinary response parser", null, typedMiss.error)
            assertEquals("$kind runtime miss remains ordinary chat", "ok", typedMiss.done?.result?.text)
            assertEquals("$kind runtime miss is zero generation delta", null, temperatureValueOrNull(kind, typedMiss.body!!.jsonObject))

            val missFragment = if (kind == ProviderKind.Gemini) "{\"generationConfig\":{\"temperature\":0.2}}" else "{\"temperature\":0.2}"
            val missRejected = captureMatrix(kind, "$modelID-miss", true, ChatRequestOptions(localCustomFragment = missFragment))
            assertEquals("$kind transport/model miss must not open socket", null, missRejected.body)
        }

        val wrongTransportSelection = MetadataClient.capabilityRuntimeRequest(
            ProviderKind.OpenAI, "matrix-wrong-transport", "openai_chat", false, ReasoningMode.Automatic,
        )
        assertTrue("wrong-transport control is authoritative but selects no recipe",
            wrongTransportSelection != null && wrongTransportSelection.selections.isEmpty())
        val wrongTransport = captureMatrix(
            ProviderKind.OpenAI, "matrix-wrong-transport", true, ChatRequestOptions(temperature = 0.31f),
        )
        assertEquals(null, wrongTransport.error)
        assertEquals("ok", wrongTransport.done?.result?.text)
        assertEquals("wrong transport remains plain chat", null,
            temperatureValueOrNull(ProviderKind.OpenAI, wrongTransport.body!!.jsonObject))
        val templateMismatch = captureMatrix(
            ProviderKind.OpenAI, "matrix-template-mismatch", true,
            ChatRequestOptions(localCustomFragment = "{\"temperature\":0.2}"),
        )
        assertEquals("runtime/profile template mismatch blocks before socket", null, templateMismatch.body)
    }

    /**
     * The positive side: the writable paths for a custom fragment come exclusively from the controlDefinitions the
     * catalog publishes. The three coordinates (qwen/openai_chat/web and openAI/openai_responses/reasoning|generation)
     * are pulled by caseId from the shared fixture, and controlDefinitions is loaded straight from
     * capability_custom_controls.v2.json, so the test never invents its own mental model of which fields are
     * customisable.
     */
    @Test
    fun `three frozen custom controls reach production bodies at their exact server coordinates`() = runTest {
        val execution = json.parseToJsonElement(load("shared/model-contracts/provider_recipe_execution.v1.json")).jsonObject
        val registry = json.parseToJsonElement(load(execution.string("registryPath")!!)).jsonObject
        val definitions = json.parseToJsonElement(load(
            "shared/capabilityrecipe/capability_custom_controls.v2.json",
        )).jsonObject
        val cases = execution["safeCustomCases"]!!.jsonArray.map { it.jsonObject }
            .filter { it.string("configurationMode") == "custom" }
            .associateBy { it.string("caseId")!! }
        assertEquals(
            setOf("custom.web_owner_allowed", "custom.reasoning_owner_allowed", "custom.generation_owner_selected"),
            cases.keys,
        )
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:custom-owner"),
            "generatedAt" to JsonPrimitive("2026-08-12T00:00:00Z"),
            "controlDefinitions" to definitions,
        ))

        val web = cases.getValue("custom.web_owner_allowed")
        MetadataTestFixtures.applyRaw(customOwnerMetadataPayload(
            runtime, "qwen", "qwen-custom", "openai_chat",
            mapOf("web" to ("qwen.chat.web.v1" to web.stringList("controlRefs"))),
        ).toString())
        assertCustomDelta(web, captureMatrix(
            ProviderKind.Qwen, "qwen-custom", false,
            ChatRequestOptions(localCustomFragment = web.string("raw")!!, localCustomOwner = web.string("owner")!!),
        ))
        // The risk tier behind the cost and privacy warnings comes only from controlDefinitions.riskTier as published;
        // qwen.web.enable_search is declared privacy_impacting there.
        assertEquals(
            listOf("privacy_impacting"),
            MetadataClient.instance
                .capabilityCustomControlAuthority(ProviderKind.Qwen, "qwen-custom", "openai_chat", "web")
                ?.riskTiers,
        )

        val reasoning = cases.getValue("custom.reasoning_owner_allowed")
        val generation = cases.getValue("custom.generation_owner_selected")
        MetadataTestFixtures.applyRaw(customOwnerMetadataPayload(
            runtime, "openAI", "openai-custom", "openai_responses",
            mapOf(
                "reasoning" to ("openai.responses.reasoning.v1" to reasoning.stringList("controlRefs")),
                "generation" to ("openai.responses.generation.v1" to generation.stringList("controlRefs")),
            ),
        ).toString())
        // Two owners sent together: each has its owner/pointer checked independently, and neither may be overwritten by the
        // other's automatic recipe.
        val openAI = captureMatrix(
            ProviderKind.OpenAI, "openai-custom", false,
            ChatRequestOptions(localCustomFragments = mapOf(
                reasoning.string("owner")!! to reasoning.string("raw")!!,
                generation.string("owner")!! to generation.string("raw")!!,
            )),
        )
        assertCustomDelta(reasoning, openAI)
        assertCustomDelta(generation, openAI)
        // openai.reasoning.effort and openai.generation.max_output_tokens are both cost_impacting.
        listOf("reasoning", "generation").forEach { owner ->
            assertEquals(
                "$owner riskTiers",
                listOf("cost_impacting"),
                MetadataClient.instance
                    .capabilityCustomControlAuthority(ProviderKind.OpenAI, "openai-custom", "openai_responses", owner)
                    ?.riskTiers,
            )
        }
        // Fail-safe for an unknown tier: one extra enum value only means this single control shows no warning, it must never
        // make the whole group of controls disappear.
        val mutated = JsonObject(definitions.mapValues { (id, raw) ->
            if (id == "openai.reasoning.effort") {
                JsonObject((raw as JsonObject) + mapOf("riskTier" to JsonPrimitive("quantum_impacting")))
            } else raw
        })
        MetadataTestFixtures.applyRaw(customOwnerMetadataPayload(
            JsonObject(runtime + mapOf("controlDefinitions" to mutated)),
            "openAI", "openai-custom", "openai_responses",
            mapOf("reasoning" to ("openai.responses.reasoning.v1" to reasoning.stringList("controlRefs"))),
        ).toString())
        val unknownTier = MetadataClient.instance
            .capabilityCustomControlAuthority(ProviderKind.OpenAI, "openai-custom", "openai_responses", "reasoning")
        assertNotNull("unknown riskTier must not drop the control", unknownTier)
        assertEquals(emptyList<String>(), unknownTier!!.riskTiers)
    }

    @Test
    fun `shared custom rejection is located from production applied pointers and structured parser`() = runTest {
        val shared = json.parseToJsonElement(
            load("shared/model-contracts/model_control_runtime.v1.json"),
        ).jsonObject
        val case = shared["rejectionCases"]!!.jsonArray.map(JsonElement::jsonObject)
            .single { it.string("caseId") == "custom_exact_400_offers_explicit_resend" }
        val registry = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_runtime.v1.json"),
        ).jsonObject
        val controlRef = "fixture.generation.temperature"
        val definitions = JsonObject(registry["controlDefinitions"]!!.jsonObject + mapOf(
            controlRef to buildJsonObject {
                put("id", controlRef)
                put("owner", "generation")
                put("kind", "number_range")
                put("min", 0)
                put("max", 2)
                put("labelKey", "control.generation.temperature")
                put("descriptionKey", "control.generation.temperature.desc")
                put("targetPointer", "/temperature")
                put("defaultBehavior", "provider_default")
                put("riskTier", "cost_impacting")
                put("sourceRefs", JsonArray(listOf(JsonPrimitive("openai.reasoning"))))
            },
        ))
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("runtime-custom-rejection"),
            "generatedAt" to JsonPrimitive("2026-08-14T00:00:00Z"),
            "controlDefinitions" to definitions,
        ))
        MetadataTestFixtures.applyRaw(customOwnerMetadataPayload(
            runtime = runtime,
            providerKind = "openAI",
            modelID = "custom-rejection",
            transport = "openai_responses",
            controls = mapOf(
                "generation" to ("openai.responses.generation.v1" to listOf(controlRef)),
            ),
        ).toString())
        val collector = ai.oriveo.community.core.model.CapabilityExecutionCollector()
        var body: JsonObject? = null
        val client = HttpClient(MockEngine { request ->
            body = (request.body as TextContent).text.let(json::parseToJsonElement).jsonObject
            respond(
                case["error"]!!.toString(),
                HttpStatusCode.BadRequest,
                headersOf(HttpHeaders.ContentType, "application/json"),
            )
        })
        val failure: ai.oriveo.community.core.model.ProviderServiceError.Upstream = runCatching {
            OpenAIService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "test",
                modelID = "custom-rejection",
                messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "custom-rejection")),
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    localCustomFragments = mapOf("generation" to "{\"temperature\":0.2}"),
                    capabilityExecutionCollector = collector,
                ),
            ).toList()
        }.exceptionOrNull() as? ai.oriveo.community.core.model.ProviderServiceError.Upstream
            ?: throw AssertionError("custom production 400 must surface")
        assertEquals(JsonPrimitive(0.2), body!!["temperature"])
        val located = collector.locateCustomRejection(failure.statusCode, failure.rejectedParameter)
            ?: throw AssertionError("structured param must match production customAppliedPointers")
        assertEquals("custom", located.source)
        assertEquals("generation", located.owner)
        assertEquals(setOf("/temperature"), located.locatedPointers.toSet())
        assertEquals(null, collector.locateCustomRejection(400, "top_p"))
        assertEquals(null, collector.locateCustomRejection(400, null))

        var normalBody: JsonObject? = null
        val normalClient = HttpClient(MockEngine { request ->
            normalBody = (request.body as TextContent).text.let(json::parseToJsonElement).jsonObject
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        OpenAIService(normalClient, json, TransportRegistry(json)).sendMessageStream(
            apiKey = "test",
            modelID = "custom-rejection",
            messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "custom-rejection")),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                localCustomFragments = mapOf("generation" to "{\"temperature\":0.2}"),
                dormantCapabilityOwners = setOf("generation"),
            ),
        ).toList()
        assertEquals(case["expected"]!!.jsonObject["normalSendAutomaticFields"], buildJsonObject {
            normalBody!!["temperature"]?.let { put("temperature", it) }
        })

        var resendBody: JsonObject? = null
        val resendClient = HttpClient(MockEngine { request ->
            resendBody = (request.body as TextContent).text.let(json::parseToJsonElement).jsonObject
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        OpenAIService(resendClient, json, TransportRegistry(json)).sendMessageStream(
            apiKey = "test",
            modelID = "custom-rejection",
            messages = listOf(ProviderTestFixtures.userMessage("hello", ProviderKind.OpenAI, "custom-rejection")),
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                localCustomFragments = mapOf("generation" to "{\"temperature\":0.2}"),
                rejectedCustomSettings = mapOf("generation" to setOf("/temperature")),
                dormantCapabilityOwners = setOf("generation"),
            ),
        ).toList()
        assertEquals(null, resendBody!!["temperature"])
    }

    private fun assertCustomDelta(case: JsonObject, capture: MatrixCapture) {
        val caseId = case.string("caseId")
        assertEquals("$caseId production parser", null, capture.error)
        val body = capture.body?.jsonObject
        assertNotNull("$caseId did not reach a production request", body)
        assertEquals("$caseId completion", "ok", capture.done?.result?.text)
        case["expectedDelta"]!!.jsonObject.forEach { (key, value) ->
            assertEquals("$caseId delta at /$key body=$body", value, body!![key])
        }
    }

    private fun customOwnerMetadataPayload(
        runtime: JsonObject,
        providerKind: String,
        modelID: String,
        transport: String,
        controls: Map<String, Pair<String, List<String>>>,
    ) = buildJsonObject {
        put("version", 1)
        put("capabilityRuntime", runtime)
        put("providers", buildJsonObject {
            put(providerKind, provider(modelID to buildJsonObject {
                put("transport", transport)
                put("capabilityControls", buildJsonObject {
                    controls.forEach { (owner, spec) ->
                        val (recipeRef, refs) = spec
                        put(owner, buildJsonObject {
                            put("state", "auto_available")
                            put("recipeRef", recipeRef)
                            put("customControlRefs", JsonArray(refs.map { JsonPrimitive(it) }))
                        })
                    }
                })
            }))
        })
    }

    private data class MatrixCapture(
        val body: JsonElement?,
        val error: Throwable?,
        val done: StreamEvent.Done?,
        val url: String?,
    )

    private suspend fun captureMatrix(
        kind: ProviderKind,
        modelID: String,
        streaming: Boolean,
        options: ChatRequestOptions,
        reasoning: ReasoningMode = ReasoningMode.Automatic,
        web: Boolean = false,
    ): MatrixCapture {
        var requestBody: String? = null
        var requestUrl: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            requestUrl = request.url.toString()
            val path = request.url.encodedPath
            val content = when {
                !streaming && path.endsWith("/responses") -> """{"id":"resp-matrix","status":"completed","output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}"""
                !streaming && kind == ProviderKind.Anthropic -> """{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}"""
                !streaming && kind == ProviderKind.Gemini -> """{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}"""
                !streaming -> """{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"""
                path.endsWith("/responses") -> """
                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"ok"}

                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp-matrix","usage":{"input_tokens":1,"output_tokens":1}}}

                    data: [DONE]
                """.trimIndent()
                kind == ProviderKind.Anthropic -> """
                    event: content_block_delta
                    data: {"index":0,"delta":{"type":"text_delta","text":"ok"}}

                    event: message_delta
                    data: {"usage":{"output_tokens":1}}

                    event: message_stop
                    data: {}
                """.trimIndent()
                kind == ProviderKind.Gemini -> """
                    data: {"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]}}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1}}

                """.trimIndent()
                else -> """
                    data: {"choices":[{"delta":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

                    data: [DONE]
                """.trimIndent()
            }
            respond(content, HttpStatusCode.OK)
        })
        val service = buildService(kind, client)
        var done: StreamEvent.Done? = null
        val error = runCatching {
            if (streaming) {
                val events = service.sendMessageStream(
                "matrix-key", modelID, listOf(ProviderTestFixtures.userMessage("hello", kind, modelID)),
                reasoningMode = reasoning, webSearchEnabled = web, requestOptions = options,
                ).toList()
                done = events.filterIsInstance<StreamEvent.Done>().lastOrNull()
            } else done = service.sendMessage(
                "matrix-key", modelID, listOf(ProviderTestFixtures.userMessage("hello", kind, modelID)),
                reasoningMode = reasoning, webSearchEnabled = web, requestOptions = options,
            )
        }.exceptionOrNull()
        return MatrixCapture(requestBody?.let(json::parseToJsonElement), error, done, requestUrl)
    }

    private fun assertMatrixWire(kind: ProviderKind, streaming: Boolean, capture: MatrixCapture) {
        val body = capture.body!!.jsonObject
        if (kind == ProviderKind.Gemini) {
            val marker = if (streaming) ":streamGenerateContent" else ":generateContent"
            assertTrue("Gemini stream=$streaming endpoint=${capture.url}", capture.url.orEmpty().contains(marker))
            assertEquals("Gemini stream endpoint alone owns streaming", null, body["stream"])
            return
        }
        assertEquals("$kind stream flag", streaming, body["stream"]?.jsonPrimitive?.content?.toBooleanStrictOrNull())
        if (!streaming) assertEquals("$kind nonstream omits stream_options", null, body["stream_options"])
    }

    private fun buildService(kind: ProviderKind, client: HttpClient): ProviderService = when (kind) {
        ProviderKind.OpenAI -> OpenAIService(client, json, TransportRegistry(json))
        ProviderKind.Anthropic -> AnthropicService(client, json, TransportRegistry(json))
        ProviderKind.Gemini -> GeminiService(client, json, TransportRegistry(json))
        ProviderKind.Grok -> GrokService(client, json, TransportRegistry(json))
        ProviderKind.Moonshot -> MoonshotService(client, json, TransportRegistry(json))
        ProviderKind.Mistral -> MistralService(client, json, TransportRegistry(json))
        ProviderKind.Qwen -> QwenService(client, json, TransportRegistry(json))
        ProviderKind.Zhipu -> ZhipuService(client, json, TransportRegistry(json))
        ProviderKind.OpenRouter -> OpenRouterService(client, json, TransportRegistry(json))
        ProviderKind.DeepSeek -> DeepSeekService(client, json)
        ProviderKind.MiniMax -> MiniMaxService(client, json)
        ProviderKind.SiliconFlow -> SiliconFlowService(client, json)
        ProviderKind.Groq -> GroqService(client, json)
        ProviderKind.Together -> TogetherService(client, json)
        ProviderKind.Fireworks -> FireworksService(client, json)
        else -> error("unsupported matrix provider $kind")
    }

    private fun matrixMetadataPayload(runtime: JsonObject, coverage: List<JsonObject>) = buildJsonObject {
        put("version", 1)
        put("capabilityRuntime", runtime)
        val runtimeRecipes = runtime["recipes"]!!.jsonObject
        put("profiles", buildJsonObject { put("generation", buildJsonObject {
            put("version", 1)
            put("parameters", buildJsonObject { put("temperature", buildJsonObject {
                put("valueSchema", "number")
            }) })
            put("templates", buildJsonObject {
                coverage.forEach { item ->
                    val recipe = runtimeRecipes[item.string("recipeRef")!!]!!.jsonObject
                    val template = recipe["requestOps"]!!.jsonArray.mapNotNull { it as? JsonObject }
                        .first { it.string("op") == "legacy_generation_template" }.string("template")!!
                    put(template, buildJsonObject {
                        put("transport", item.string("transport")!!)
                        put("wire", buildJsonObject {
                            put("temperature", if (item.string("providerKind") == "gemini") "generationConfig.temperature" else "temperature")
                        })
                    })
                }
            })
        }) })
        put("providers", buildJsonObject {
            coverage.groupBy { it.string("providerKind")!! }.forEach { (wireKind, items) ->
                val models = items.flatMap { item ->
                    val id = item.string("modelId")!!
                    val selector = item.string("selectorTransport") ?: item.string("transport")!!
                    val recipe = runtimeRecipes[item.string("recipeRef")!!]!!.jsonObject
                    val template = recipe["requestOps"]!!.jsonArray.mapNotNull { it as? JsonObject }
                        .first { it.string("op") == "legacy_generation_template" }.string("template")!!
                    val hit = model(selector, generationRecipe = item.string("recipeRef"), generationTemplate = template)
                    val miss = model(selector)
                    listOf(id to hit, "$id-miss" to miss)
                }.toMutableList()
                if (wireKind == "openAI") {
                    models += "matrix-wrong-transport" to model(
                        "openai_chat", generationRecipe = "openai.responses.generation.v1",
                    )
                    models += "matrix-template-mismatch" to model(
                        "openai_responses", generationRecipe = "openai.responses.generation.v1",
                        generationTemplate = "openai_chat_completions",
                    )
                }
                put(wireKind, provider(*models.toTypedArray()))
            }
        })
    }

    private fun r3FinalBodyMetadata(runtime: JsonObject, case: JsonObject): JsonObject {
        val modelID = case["identity"]!!.jsonObject.string("canonicalModelId")!!
        val exact = case.string("caseId") == "exact_recipe_all_owners"
        val generationRecipe = "openai.responses.generation.v1"
        val generationTemplate = (runtime["recipes"]!!.jsonObject[generationRecipe]!!.jsonObject["requestOps"]!!
            .jsonArray.mapNotNull { it as? JsonObject }
            .single { it.string("op") == "legacy_generation_template" }.string("template"))
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            put("profiles", buildJsonObject {
                put("generation", buildJsonObject {
                    put("version", 1)
                    put("parameters", buildJsonObject {
                        put("temperature", buildJsonObject { put("valueSchema", "number") })
                    })
                    put("templates", buildJsonObject {
                        put(generationTemplate!!, buildJsonObject {
                            put("transport", "openai_responses")
                            put("wire", buildJsonObject { put("temperature", "temperature") })
                        })
                    })
                })
                // Deliberately present legacy profiles: the unknown/kill case must still stay plain.
                put("reasoning", buildJsonObject {
                    put("legacy_reasoning", buildJsonObject {
                        put("levels", JsonArray(listOf(JsonPrimitive("deep"))))
                        put("params", buildJsonObject { put("deep", buildJsonObject {
                            put("reasoning", buildJsonObject { put("effort", "high") })
                        }) })
                    })
                })
                put("webSearch", buildJsonObject {
                    put("legacy_web", buildJsonObject {
                        put("mergeParams", buildJsonObject { put("web_search_options", buildJsonObject { put("enabled", true) }) })
                    })
                })
            })
            put("providers", buildJsonObject {
                put("openAI", provider(modelID to buildJsonObject {
                    put("canonicalModelId", modelID)
                    put("transport", "openai_responses")
                    put("profiles", buildJsonObject {
                        put("generation", buildJsonObject {
                            put("template", generationTemplate)
                            put("parameters", JsonArray(listOf(buildJsonObject {
                                put("id", "temperature"); put("support", "supported")
                            })))
                        })
                        put("reasoning", "legacy_reasoning")
                        put("webSearch", "legacy_web")
                    })
                    put("capabilityControls", buildJsonObject {
                        if (exact) {
                            put("web", autoControl("openai.responses.web.v1"))
                            put("reasoning", JsonObject(autoControl("openai.responses.reasoning.v1") + (
                                "availableIntents" to JsonArray(listOf("off", "low", "balanced", "deep", "max").map(::JsonPrimitive))
                            )))
                            put("generation", autoControl(generationRecipe))
                        } else {
                            put("web", noAutoControl("unknown"))
                            put("reasoning", noAutoControl("unknown"))
                            put("generation", noAutoControl("unknown"))
                        }
                    })
                }))
            })
        }
    }

    private fun r3RejectionMetadata(runtime: JsonObject, recipeRef: String) = buildJsonObject {
        put("version", 1)
        put("capabilityRuntime", runtime)
        put("providers", buildJsonObject {
            put("openAI", provider("fixture-r3" to buildJsonObject {
                put("canonicalModelId", "fixture-r3")
                put("transport", "openai_responses")
                put("capabilityControls", buildJsonObject { put("web", autoControl(recipeRef)) })
            }))
        })
    }

    private fun providerKind(raw: String): ProviderKind = when (raw) {
        "togetherAI" -> ProviderKind.Together
        "fireworksAI" -> ProviderKind.Fireworks
        else -> ProviderKind.fromRawValue(raw) ?: error("unknown provider $raw")
    }

    private fun temperatureValueOrNull(kind: ProviderKind, body: JsonObject): Double? {
        val value = if (kind == ProviderKind.Gemini) {
            (body["generationConfig"] as? JsonObject)?.get("temperature")
        } else body["temperature"]
        return value?.toString()?.toDoubleOrNull()
    }

    private suspend fun capture(
        service: (HttpClient) -> ProviderService,
        kind: ProviderKind,
        modelID: String,
        reasoning: ReasoningMode,
        web: Boolean,
    ): JsonElement {
        var requestBody: String? = null
        val client = HttpClient(MockEngine { request ->
            requestBody = (request.body as? TextContent)?.text
            respond("data: [DONE]\n\n", HttpStatusCode.OK)
        })
        runCatching {
            service(client).sendMessageStream(
                apiKey = "recipe-test-key",
                modelID = modelID,
                messages = listOf(ProviderTestFixtures.userMessage("hello", kind, modelID)),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = reasoning,
                webSearchEnabled = web,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }
        return json.parseToJsonElement(requireNotNull(requestBody) { "$kind did not build a request" })
    }

    private fun metadataPayload(runtime: JsonObject): JsonObject = buildJsonObject {
        put("version", 1)
        put("capabilityRuntime", runtime)
        put("providers", buildJsonObject {
            put("openAI", provider(
                "gpt-5-mini" to model("openai_responses", webRecipe = "openai.responses.web.v1", reasoningRecipe = "openai.responses.reasoning.v1"),
                "gpt-5-search-api" to model("openai_chat", webRecipe = "openai.chat.web_model.v1"),
            ))
            put("anthropic", provider(
                "claude-sonnet-4-5" to model("anthropic_messages", webRecipe = "anthropic.messages.web.v1", reasoningRecipe = "anthropic.messages.reasoning.v2"),
            ))
            put("gemini", provider(
                "gemini-3.1-flash-preview" to model("gemini_generate_content", webRecipe = "gemini.generate_content.web.v1", reasoningRecipe = "gemini.generate_content.reasoning.v2"),
            ))
            put("deepseek", provider(
                "deepseek-v4-flash" to model("openai_chat", reasoningRecipe = "deepseek.chat.reasoning.v1"),
            ))
        })
    }

    private fun provider(vararg models: Pair<String, JsonObject>) = buildJsonObject {
        put("resolveMap", buildJsonObject { models.forEach { (id, _) -> put(id, id) } })
        put("models", buildJsonObject { models.forEach { (id, model) -> put(id, model) } })
    }

    private fun model(
        transport: String,
        webRecipe: String? = null,
        reasoningRecipe: String? = null,
        generationRecipe: String? = null,
        generationTemplate: String? = null,
    ) = buildJsonObject {
        put("transport", transport)
        if (generationTemplate != null) put("profiles", buildJsonObject { put("generation", buildJsonObject {
            put("template", generationTemplate)
            put("parameters", JsonArray(listOf(buildJsonObject { put("id", "temperature"); put("support", "supported") })))
        }) })
        put("capabilityControls", buildJsonObject {
            if (webRecipe != null) put("web", autoControl(webRecipe)) else put("web", noAutoControl("unavailable"))
            if (reasoningRecipe != null) put("reasoning", JsonObject(autoControl(reasoningRecipe) + (
                "availableIntents" to JsonArray(listOf("off", "low", "balanced", "deep", "max").map(::JsonPrimitive))
            ))) else put("reasoning", noAutoControl("unknown"))
            if (generationRecipe != null) put("generation", autoControl(generationRecipe))
        })
    }

    private fun autoControl(recipeRef: String) = buildJsonObject {
        put("state", "auto_available")
        put("recipeRef", recipeRef)
    }

    private fun noAutoControl(state: String) = buildJsonObject {
        put("state", state)
        put("reasonCode", "fixture_no_auto")
        put("sourceRefs", JsonArray(listOf(JsonPrimitive("openai.web_search"))))
    }

    /**
     * The intent semantics of `requestOps` used to be undefined, so every client guessed differently and the `force` tier
     * compiled into three mutually inconsistent wires, none of them right. This consumes the `mergeCases` block of the
     * shared fixture and pins last-specific-wins plus stableJson de-duplication onto the production compiler.
     */
    @Test
    fun `shared merge cases pin last specific wins on the production compiler`() {
        val fixture = json.parseToJsonElement(
            load("shared/model-contracts/provider_recipe_request_compiler.v1.json"),
        ).jsonObject
        val cases = fixture["mergeCases"]!!.jsonArray
        assertTrue("mergeCases fixture must not be empty", cases.isNotEmpty())

        cases.forEach { element ->
            val case = element.jsonObject
            val caseId = case.string("caseId")!!
            val requestOps = case["recipeSnapshot"]!!.jsonObject["requestOps"]!!.jsonArray
            val recipeRef = case.string("recipeRef")!!
            // Only the fixture's requestOps go in as the recipe body; the remaining fields are the minimum shell needed to
            // clear the provider, transport and capability checks.
            val runtime = buildJsonObject {
                put("recipes", buildJsonObject {
                    put(recipeRef, buildJsonObject {
                        put("id", recipeRef)
                        put("providerKind", case.string("providerKind")!!)
                        put("capability", case.string("capability")!!)
                        put("executionKind", "server_tool")
                        put("transport", buildJsonObject { put("protocol", case.string("transport")!!) })
                        put("requestOps", requestOps)
                    })
                })
            }

            val result = ProviderRecipeRequestCompiler.compile(
                runtime = runtime,
                input = ProviderRecipeRequestCompiler.Input(
                    providerKind = case.string("providerKind")!!,
                    transport = case.string("transport")!!,
                    recipeRef = recipeRef,
                    capability = case.string("capability")!!,
                    selectedIntent = case.string("selectedIntent"),
                    availableIntents = case.string("selectedIntent")?.let(::listOf),
                    baseOwnedArrays = (case["baseOwnedArrays"] as? JsonObject)?.orEmptyArrays().orEmpty(),
                ),
            )

            assertTrue("$caseId: ${result.reason}", result.accepted)
            // The fixture's expectedBody is the final body rather than a delta: array elements the builder already owns are
            // in the body regardless, and the delta rewrites an array wholesale only when it takes that array over.
            val baseBody = (case["baseOwnedArrays"] as? JsonObject).orEmpty()
            assertEquals(caseId, case["expectedBody"], JsonObject(baseBody + result.delta!!))
        }
    }

    /**
     * The array roots an append may target have to be decided by the shared contract, not hard-coded per client.
     * Before this was pinned down every client disagreed: one accepted only `/tools/-`, another accepted `/tools/-` and
     * `/plugins/-`, and this one stripped the `/-` suffix before comparing, which meant a bare `/tools` was accepted too.
     * Every recipe published so far happens to use `/tools/-` only, so nothing has blown up yet; what this test pins down
     * is precisely that the behaviour must not depend on that coincidence.
     */
    @Test
    fun `append targets come from the shared contract owned array roots`() {
        val contract = json.parseToJsonElement(
            load("shared/model-contracts/request_preference_contract.v2.json"),
        ).jsonObject
        val roots = (contract["safeOverlay"] as JsonObject).stringList("typedContributionOnlyRoots")
        assertTrue("the contract must declare at least the tools and plugins roots", roots.size >= 2)
        assertTrue(roots.contains("tools"))

        roots.forEach { root ->
            val accepted = compileAppend("/$root/-")
            assertTrue("a root declared by the contract must be accepted: ${accepted.reason}", accepted.accepted)
            assertEquals(
                "an append on $root must land on the array of the same name",
                buildJsonObject {
                    put(root, buildJsonArray { add(buildJsonObject { put("type", "probe") }) })
                },
                accepted.delta,
            )

            // Without the "/-" suffix the contract reads the pointer as the whole array rather than as appending one element,
            // so it has to be rejected.
            val bare = compileAppend("/$root")
            assertFalse("$root: an append missing the /- suffix must be rejected", bare.accepted)
            assertEquals("invalid_request_ops", bare.reason)
        }

        // Any array root outside the contract is rejected, so a recipe can never gain the ability to push elements into an
        // arbitrary field.
        val foreign = compileAppend("/messages/-")
        assertFalse(foreign.accepted)
        assertEquals("invalid_request_ops", foreign.reason)
    }

    private fun compileAppend(pointer: String): ProviderRecipeRequestCompiler.Result {
        val recipeRef = "synthetic.append_root"
        val runtime = buildJsonObject {
            put("recipes", buildJsonObject {
                put(recipeRef, buildJsonObject {
                    put("id", recipeRef)
                    put("providerKind", "openAI")
                    put("capability", "web")
                    put("executionKind", "server_tool")
                    put("transport", buildJsonObject { put("protocol", "openai_chat") })
                    put("requestOps", buildJsonArray {
                        add(buildJsonObject {
                            put("op", "append")
                            put("pointer", pointer)
                            put("value", buildJsonObject { put("type", "probe") })
                        })
                    })
                })
            })
        }
        return ProviderRecipeRequestCompiler.compile(
            runtime = runtime,
            input = ProviderRecipeRequestCompiler.Input(
                providerKind = "openAI", transport = "openai_chat",
                recipeRef = recipeRef, capability = "web",
            ),
        )
    }

    private fun JsonObject.orEmptyArrays(): Map<String, List<JsonElement>> = entries.associate { (key, value) ->
        key to ((value as? JsonArray)?.toList().orEmpty())
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.content

    private fun JsonObject.stringList(key: String): List<String> =
        (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()

    private fun load(path: String): String {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val root = moduleDir.parentFile!!.parentFile!!
        return File(root, path).readText(Charsets.UTF_8)
    }
}
