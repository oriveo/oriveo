package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.GenerationAccess
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterEntryScope
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.MetadataTestFixtures
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.After
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Reads the same generation fixture as Web/iOS/Server and drives production Relay body builders. */
class GenerationParameterContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `shared generation contract matches Android production Relay bodies`() {
        val contract = loadContract()
        assertEquals(1, contract.version)
        assertEquals(12, contract.cases.size)

        val failures = mutableListOf<String>()
        contract.cases.forEach { item ->
            val body = json.parseToJsonElement(buildBody(item)).jsonObject
            item.expect.bodyIncludes.forEach { (path, expected) ->
                val actual = valueAtPath(body, path)
                val expectedNumber = expected.jsonPrimitive.doubleOrNull
                val actualNumber = actual?.jsonPrimitive?.doubleOrNull
                if (expectedNumber != null && actualNumber != expectedNumber) {
                    failures += "${item.caseId}: $path=$actualNumber, want $expectedNumber"
                } else if (expectedNumber == null && actual != expected) {
                    failures += "${item.caseId}: $path=$actual, want $expected"
                }
            }
            item.expect.bodyExcludes.forEach { path ->
                if (valueAtPath(body, path) != null) failures += "${item.caseId}: $path must be omitted"
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `llama cpp native body uses completion wire mapping including explicit zero`() {
        val model = AIModel(
            id = "local", name = "local",
            generationProfile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles.profile("llamacpp"),
        )
        val projection = relayProjection(
            model, RelayTransport.LlamaCppNative,
            keys = setOf("generation_parameter/temperature"),
            explicitKeys = setOf("generation_parameter/temperature"),
        )
        val body = json.parseToJsonElement(
            buildLlamaCppNativeBody(
                messages = emptyList(),
                stream = true,
                requestOptions = ChatRequestOptions(
                    generationParameters = GenerationParameterOverrides(
                        mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.0)))
                    ),
                    activeModel = model,
                ),
                capabilityProjection = projection,
            ),
        ).jsonObject
        assertEquals(0.0, body["temperature"]?.jsonPrimitive?.doubleOrNull)
        assertEquals(true, body["stream"]?.jsonPrimitive?.content?.toBoolean())
        assertEquals("assistant:", body["prompt"]?.jsonPrimitive?.content)
    }

    @Test
    fun `generation resolver rejects out of range values before writing the body`() {
        val model = AIModel(
            id = "model-a", name = "model-a",
            generationProfile = GenerationProfileRef(
                template = "openai_chat_completions",
                parameters = listOf(GenerationParameterRef(
                    id = "max_output_tokens", support = "supported", valueSchema = "integer",
                    range = GenerationParameterRange(min = 1.0),
                )),
                wire = mapOf("max_output_tokens" to "max_tokens"),
            ),
        )
        val projection = relayProjection(
            model, RelayTransport.OpenAIChatCompletions,
            keys = setOf("generation_parameter/max_output_tokens"),
            explicitKeys = setOf("generation_parameter/max_output_tokens"),
        )
        val body = json.parseToJsonElement(
            buildOpenAIChatBody(
                modelID = "model-a",
                messages = emptyList(),
                stream = true,
                reasoningMode = ReasoningMode.Automatic,
                requestOptions = ChatRequestOptions(
                    generationParameters = GenerationParameterOverrides(mapOf(
                        "max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0)),
                    )),
                    activeModel = model,
                ),
                capabilityProjection = projection,
            ),
        ).jsonObject
        assertEquals(null, body["max_tokens"])
    }

    @Test
    fun `relay body requires a complete dispatch identity before an explicit generation value leaves`() {
        val model = AIModel(
            id = "identity-model",
            name = "identity-model",
            generationProfile = GenerationProfileRef(
                template = "openai_chat_completions",
                parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
                wire = mapOf("temperature" to "temperature"),
            ),
        )
        val options = ChatRequestOptions(
            activeModel = model,
            generationParameters = GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
        )
        val missingIdentity = CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            identity = null,
            keys = setOf("generation_parameter/temperature"),
            explicitKeys = setOf("generation_parameter/temperature"),
        )
        val missingBody = json.parseToJsonElement(buildOpenAIChatBody(
            "identity-model", emptyList(), true, ReasoningMode.Automatic, options,
            capabilityProjection = missingIdentity,
        )).jsonObject
        assertEquals(null, missingBody["temperature"])

        val completeBody = json.parseToJsonElement(buildOpenAIChatBody(
            "identity-model", emptyList(), true, ReasoningMode.Automatic, options,
            capabilityProjection = relayProjection(
                model,
                RelayTransport.OpenAIChatCompletions,
                setOf("generation_parameter/temperature"),
                setOf("generation_parameter/temperature"),
            ),
        )).jsonObject
        assertEquals(0.4, completeBody["temperature"]?.jsonPrimitive?.doubleOrNull)
    }

    @Test
    fun `persisted relay High effort is gated by the same final reasoning projection`() {
        val model = AIModel(
            id = "reasoning-model",
            name = "reasoning-model",
            reasoningModeAvailable = true,
            reasoningProfile = "openai_chat",
            toolCall = true,
        )
        val options = ChatRequestOptions(
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                reasoningEffort = RelayReasoningEffort.High,
            ),
        )
        val missing = json.parseToJsonElement(buildOpenAIChatBody(
            "reasoning-model", emptyList(), true, ReasoningMode.Automatic, options,
            capabilityProjection = null,
        )).jsonObject
        assertEquals(null, missing["reasoning_effort"])

        val completeProjection = relayProjection(
            model,
            RelayTransport.OpenAIChatCompletions,
            setOf("reasoning_level/deep"),
            setOf("reasoning_level/deep"),
        )
        val complete = json.parseToJsonElement(buildOpenAIChatBody(
            "reasoning-model", emptyList(), true, ReasoningMode.Automatic, options,
            capabilityProjection = completeProjection,
        )).jsonObject
        assertEquals("high", complete["reasoning_effort"]?.jsonPrimitive?.content)

        val responsesMissing = json.parseToJsonElement(buildResponsesBody(
            "reasoning-model", emptyList(), true, false, ReasoningMode.Automatic, false, options,
            capabilityProjection = null,
        )).jsonObject
        assertEquals(null, responsesMissing["reasoning"]?.jsonObject?.get("effort"))
        assertEquals("auto", responsesMissing["reasoning"]?.jsonObject?.get("summary")?.jsonPrimitive?.content)
    }

    @Test
    fun `json schema uses dedicated wire and conflicts with active tools`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(
                id = "json_schema",
                support = "supported",
                valueSchema = "json-schema",
                conflictsWith = listOf("tools"),
            )),
            wire = mapOf("json_schema" to "response_format"),
        )
        val options = ChatRequestOptions(
            generationParameters = GenerationParameterOverrides(mapOf(
                "json_schema" to GenerationParameterOverride(
                    GenerationOverrideState.Value,
                    buildJsonObject { put("type", "object") },
                ),
            )),
            activeModel = AIModel(id = "model-a", name = "model-a", generationProfile = profile),
        )
        val projection = relayProjection(
            options.activeModel!!,
            RelayTransport.OpenAIChatCompletions,
            setOf("generation_parameter/json_schema"),
            setOf("generation_parameter/json_schema"),
        )
        val resolved = GenerationParameterResolver.apply("{}", options, null, projection)
        assertEquals("json_schema", json.parseToJsonElement(resolved).jsonObject["response_format"]
            ?.jsonObject?.get("type")?.jsonPrimitive?.content)
        val conflicted = ai.oriveo.community.core.provider.GenerationParameterResolver.apply(
            """{"tools":[{"type":"function"}]}""",
            options,
            null,
            projection,
        )
        assertEquals("""{"tools":[{"type":"function"}]}""", conflicted)
    }

    /**
     * A published wire mapping is a **write path**: the client trusts its semantics, never its
     * shape.
     *
     * The profile is produced by the production `GenerationProfileRef` deserialiser from
     * catalog-shaped (here deliberately malformed) JSON, and the body by the production
     * `buildOpenAIChatBody`. The test does not assemble a body itself and then poke `__proto__`
     * into it, which would only prove that the test can write a case.
     */
    @Test
    fun `wire hardening cases are enforced on production chat bodies`() {
        val contract = loadWireHardening()
        assertEquals("^[A-Za-z_][A-Za-z0-9_]*\$", contract.wireHardening.segmentPattern)
        assertEquals(listOf("__proto__", "prototype", "constructor"), contract.wireHardening.blockedSegments)
        assertEquals(4, contract.wireHardening.maxSegments)
        assertEquals(65536, contract.wireHardening.jsonSchemaLimits.maxBytes)
        assertEquals(
            listOf(
                "model", "messages", "input", "contents", "prompt", "attachments", "instructions", "system",
                "stream", "stream_options", "tools", "tool_choice", "plugins",
            ),
            contract.wireHardening.builderOwnedRootFields,
        )
        if (contract.wireHardeningCases.size < 15) fail("fewer than 15 wireHardeningCases: the contract has been trimmed")

        val failures = mutableListOf<String>()
        contract.wireHardeningCases.forEach { item ->
            GenerationParameterResolver.clearWireDiagnostics()
            val body = json.parseToJsonElement(buildHostileWireBody(item)).jsonObject
            val actual = (valueAtPath(body, item.wire) as? JsonPrimitive)?.doubleOrNull
            val diagnostics = GenerationParameterResolver.readWireDiagnostics()
            if (item.expect.applied) {
                if (actual != item.value) failures += "${item.caseId}: $actual, want ${item.value}"
                if (diagnostics.isNotEmpty()) failures += "${item.caseId}: a legal path must not record a diagnostic $diagnostics"
            } else {
                if (actual == item.value) failures += "${item.caseId}: a malformed path was written into the body"
                val expected = listOf(
                    GenerationParameterResolver.WireDiagnostic(
                        "temperature",
                        item.wire,
                        GenerationParameterResolver.WireRejectionReason.entries
                            .first { it.wireName == item.expect.reason },
                    ),
                )
                if (diagnostics != expected) failures += "${item.caseId}: diagnostics $diagnostics, want $expected"
            }
            // The builder's own skeleton has to survive untouched: a rejected write must not
            // quietly rewrite model or messages on its way out.
            if ((body["model"] as? JsonPrimitive)?.content != "fixture-chat") {
                failures += "${item.caseId}: model was overwritten by a wire mapping"
            }
            if (body["messages"] == null) failures += "${item.caseId}: messages was overwritten by a wire mapping"
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    /** A Relay-synthesised profile may only take its wire mappings and parameter ids from the
     *  in-app constant table, and every path must be structurally legal. */
    @Test
    fun `relay synthesized profiles only ship client constant wire paths`() {
        val engines = listOf("llamacpp", "ollama", "lmstudio", "vllm", "openwebui", null, "unknown-engine")
        var checked = 0
        engines.forEach { engine ->
            (listOf<RelayTransport?>(null) + RelayTransport.entries).forEach { transport ->
                val profile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
                    .profile(engine, transport) ?: return@forEach
                val declared = profile.parameters.mapNotNull { it.id }.toSet()
                profile.wire.forEach { (id, path) ->
                    checked += 1
                    if (id !in declared) fail("a Relay-synthesised profile carries a wire mapping for an undeclared id: $id")
                    val rejection = GenerationParameterResolver.wireRejectionReason(path)
                    if (rejection != null) fail("Relay wire mapping $id=$path is structurally illegal: $rejection")
                }
            }
        }
        if (checked == 0) fail("no Relay wire mapping was checked at all, so this test proves nothing")
    }

    /**
     * The shared `availabilityCases`: every case is driven straight through the production
     * `GenerationParameterAvailability` predicates rather than through a reimplementation here.
     *
     * The profile is deserialised by the production `GenerationProfileRef` reader from
     * catalog-shaped JSON, so a malformed publication really does erase the profile and the
     * production predicates fail closed on it.
     */
    @Test
    fun `shared availability cases match Android production visibility predicates`() {
        val contract = loadAvailability()
        assertEquals("availabilityCases count", 58, contract.availabilityCases.size)
        assertEquals(
            listOf("supported", "accepted", "accepted_unverified", "unknown"),
            contract.availabilityRules.outboundSupport,
        )

        val failures = mutableListOf<String>()
        contract.availabilityCases.forEach { item ->
            val subject = availabilitySubject(item.intent)
            val provider = subject.provider
            val model = subject.model
            val projection = subject.projection
            // A malformed/incomplete publication is allowed to erase the whole profile. The
            // production predicates then fail closed; the fixture must not turn that safety
            // result into a synthetic test failure by demanding a profile object.
            val profile = GenerationParameterAvailability.profile(provider, model)
            val access = GenerationAccess(item.intent.access.canManageRuntime)
            val scope = when (item.intent.scope) {
                "session" -> GenerationParameterEntryScope.Session
                "connectionDefaults" -> GenerationParameterEntryScope.ConnectionDefaults
                else -> error("unknown scope ${item.intent.scope}")
            }
            val inScope = when (scope) {
                GenerationParameterEntryScope.Session ->
                    GenerationParameterAvailability.sessionActionable(provider, model, projection)
                GenerationParameterEntryScope.ConnectionDefaults ->
                    GenerationParameterAvailability.connectionConfigurable(provider, model, access, projection)
            }.any { it.id == item.intent.parameter.id }
            if (inScope != item.expect.inScope) {
                failures += "${item.caseId}: inScope=$inScope, want ${item.expect.inScope}"
            }
            val visible = GenerationParameterAvailability.entryVisible(provider, model, scope, access, projection)
            if (visible != item.expect.entryVisible) {
                failures += "${item.caseId}: entryVisible=$visible, want ${item.expect.entryVisible}"
            }
            // Editability is judged on the first declared parameter of the profile, using the
            // same projection the production panel uses.
            val editable = inScope && profile?.parameters?.firstOrNull()?.let { parameter ->
                GenerationParameterAvailability.isEditable(provider, profile, parameter, projection)
            } == true
            if (editable != item.expect.editable) {
                failures += "${item.caseId}: editable=$editable, want ${item.expect.editable}"
            }
            // Final output authorization is asserted by request-shape tests through the same
            // projection; this availability suite must not reconstruct a raw support whitelist.
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    /**
     * End to end: a connection-scoped reasoning default really has to appear in the body the
     * production builder sends, and the whole group has to give way when the session-level
     * reasoning chip picks a level explicitly.
     *
     * The overrides come from the production `GenerationParameterSettingsStore.resolve`, the
     * profile from the production `LocalEngineGenerationProfiles`, and the body from the
     * production `buildOpenAIChatBody`.
     */
    @Test
    fun `connection scoped reasoning default reaches the wire and yields to an explicit chip`() {
        var payload: String? = null
        val store = ai.oriveo.community.core.model.GenerationParameterSettingsStore(
            readPayload = { payload },
            writePayload = { payload = it },
        )
        store.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "reasoning_effort" to GenerationParameterOverride(
                    GenerationOverrideState.Value,
                    JsonPrimitive("high"),
                ),
            )),
            providerID = "provider-a",
            modelID = "model-a",
        )
        val relayProfile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
            .profile(null, RelayTransport.OpenAIChatCompletions)
        assertEquals("reasoning_effort", relayProfile?.wire?.get("reasoning_effort"))

        fun bodyFor(mode: ReasoningMode): JsonObject {
            val model = AIModel(
                id = "model-a",
                name = "model-a",
                reasoningModeAvailable = true,
                reasoningProfile = "openai_chat",
                generationProfile = relayProfile,
            )
            val projection = relayProjection(
                model,
                RelayTransport.OpenAIChatCompletions,
                keys = setOf("generation_parameter/reasoning_effort") +
                    setOf("reasoning_level/fast", "reasoning_level/balanced", "reasoning_level/deep", "reasoning_level/max"),
                explicitKeys = setOf("generation_parameter/reasoning_effort") +
                    if (mode == ReasoningMode.Automatic) emptySet() else setOf("reasoning_level/${mode.rawValue}"),
            )
            return json.parseToJsonElement(
                buildOpenAIChatBody(
                modelID = "model-a",
                messages = emptyList(),
                stream = true,
                reasoningMode = mode,
                requestOptions = ChatRequestOptions(
                    generationParameters = store.resolve(
                        transient = null,
                        providerID = "provider-a",
                        modelID = "model-a",
                        conversationID = "conversation-a",
                        reasoningMode = mode,
                    ),
                    activeModel = model,
                ),
                    capabilityProjection = projection,
                ),
            ).jsonObject
        }

        // Chip left on Automatic: the connection-level default is released, the builder writes
        // no effort of its own, and the body carries what the user configured.
        assertEquals("high", bodyFor(ReasoningMode.Automatic)["reasoning_effort"]?.jsonPrimitive?.content)
        // Chip explicitly set to Fast (which maps to low): the whole connection-level reasoning
        // group gives way and the chip's level is what goes out. This is the control for the
        // assertion above - otherwise "high went out" could simply mean nothing was substituted.
        assertEquals("low", bodyFor(ReasoningMode.Fast)["reasoning_effort"]?.jsonPrimitive?.content)
    }

    /** A JSON Schema is an output contract, not an override channel: anything over 64 KiB must
     *  be dropped whole rather than squeezed into the request. */
    @Test
    fun `oversized json schema never reaches the body`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(
                id = "json_schema", support = "supported", valueSchema = "json-schema",
            )),
            wire = mapOf("json_schema" to "response_format"),
        )
        val options = ChatRequestOptions(
            generationParameters = GenerationParameterOverrides(mapOf(
                "json_schema" to GenerationParameterOverride(
                    GenerationOverrideState.Value,
                    buildJsonObject {
                        put("type", "object")
                        put("title", "x".repeat(64 * 1024))
                    },
                ),
            )),
            activeModel = AIModel(id = "model-a", name = "model-a", generationProfile = profile),
        )
        val projection = relayProjection(
            options.activeModel!!,
            RelayTransport.OpenAIChatCompletions,
            setOf("generation_parameter/json_schema"),
            setOf("generation_parameter/json_schema"),
        )
        val resolved = GenerationParameterResolver.apply("{}", options, null, projection)
        assertEquals("{}", resolved)
    }

    /** Each case is produced by a current official publication or a concrete Relay dispatch. */
    private fun availabilitySubject(intent: AvailabilityIntent): AvailabilitySubject {
        val parameter = intent.parameter
        if (intent.providerKind == "relay") {
            val model = AIModel(
                id = "model-availability",
                name = "model-availability",
                generationProfile = GenerationProfileRef(
                    template = "openai_chat_completions",
                    parameters = listOf(GenerationParameterRef(parameter.id, parameter.support, group = parameter.group)),
                    wire = parameter.wire?.let { mapOf(parameter.id to it) }.orEmpty(),
                ),
            )
            val provider = Provider(
                id = "provider-availability",
                kind = ProviderKind.Relay,
                baseUrlText = "https://relay.example/v1",
                relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            )
            return AvailabilitySubject(
                provider,
                model,
                relayProjection(model, RelayTransport.OpenAIChatCompletions,
                    setOf("generation_parameter/${parameter.id}"), emptySet()),
            )
        }
        val template = buildJsonObject {
            put("transport", "openai_chat")
            // `resolveGenerationProfile` rejects an empty template wire map. Keep the profile
            // production-valid while deliberately omitting this parameter's wire path.
            put("wire", buildJsonObject {
                if (parameter.wire == null) {
                    put("fixture_keep_profile", "fixture_unused_wire")
                } else {
                    put(parameter.id, parameter.wire)
                }
            })
        }
        val profile = buildJsonObject {
            put("template", "openai_chat_completions")
            put("parameters", kotlinx.serialization.json.buildJsonArray {
                add(buildJsonObject {
                    put("id", parameter.id)
                    put("support", parameter.support)
                    put("source", "authoritative_metadata")
                    parameter.group?.let { put("group", it) }
                })
            })
        }
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1)
            put("profiles", buildJsonObject {
                put("generation", buildJsonObject {
                    put("parameters", buildJsonObject {
                        put(parameter.id, buildJsonObject {
                            put("valueSchema", "number")
                            parameter.group?.let { put("group", it) }
                        })
                    })
                    put("templates", buildJsonObject { put("openai_chat_completions", template) })
                })
            })
            put("providers", buildJsonObject {
                put("openAI", buildJsonObject {
                    put("resolveMap", buildJsonObject { put("model-availability", "model-availability") })
                    put("models", buildJsonObject {
                        put("model-availability", buildJsonObject {
                            put("canonicalModelId", "model-availability")
                            put("transport", "openai_chat")
                            put("profiles", buildJsonObject { put("generation", profile) })
                        })
                    })
                })
            })
        }.toString())
        val provider = Provider(id = "provider-availability", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "model-availability", name = "model-availability")
        return AvailabilitySubject(
            provider,
            model,
            // Availability must exercise the same production projection consumed by the
            // composer/defaults panels. The generic capability projection deliberately lacks
            // generation-profile presentation and wire semantics, so using it here would test
            // an adapter the product never uses for generation rows.
            CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
                provider = provider,
                model = model,
                localIdentity = null,
                parameters = listOf(GenerationParameterRef(
                    id = parameter.id,
                    support = parameter.support,
                    group = parameter.group,
                )),
                values = GenerationParameterOverrides(),
            ),
        )
    }

    private data class AvailabilitySubject(
        val provider: Provider,
        val model: AIModel,
        val projection: CapabilityEvidenceProductionAdapter.Projection,
    )

    private fun buildHostileWireBody(item: WireHardeningCase): String {
        val model = AIModel(
            id = "fixture-chat", name = "fixture-chat",
            // Production deserializer consumes the server-shaped hostile declaration.
            generationProfile = json.decodeFromString<GenerationProfileRef>(
                """
                {"template":"openai_chat_completions",
                 "parameters":[{"id":"temperature","support":"supported",
                                "source":"authoritative_metadata","valueSchema":"number"}],
                 "wire":{"temperature":${JsonPrimitive(item.wire)}}}
                """.trimIndent(),
            ),
        )
        val projection = relayProjection(
            model,
            RelayTransport.OpenAIChatCompletions,
            setOf("generation_parameter/temperature"),
            setOf("generation_parameter/temperature"),
        )
        return buildOpenAIChatBody(
            modelID = "fixture-chat",
            messages = emptyList(),
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(
            generationParameters = GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(
                    GenerationOverrideState.Value,
                    JsonPrimitive(item.value),
                ),
            )),
            activeModel = model,
        ),
            capabilityProjection = projection,
        )
    }

    private fun buildBody(item: ContractCase): String {
        val override = when (item.intent.override.state) {
            "value" -> GenerationParameterOverride(
                state = GenerationOverrideState.Value,
                value = JsonPrimitive(item.intent.override.value ?: error("value missing")),
            )
            "omit" -> GenerationParameterOverride(state = GenerationOverrideState.Omit)
            else -> GenerationParameterOverride(state = GenerationOverrideState.Inherit)
        }
        val wire = if (item.intent.transport == "gemini_generate_content") {
            "generationConfig.temperature"
        } else {
            "temperature"
        }
        val options = ChatRequestOptions(
            generationParameters = GenerationParameterOverrides(mapOf("temperature" to override)),
            activeModel = AIModel(
                id = item.intent.modelId,
                name = item.intent.modelId,
                generationProfile = GenerationProfileRef(
                    template = item.intent.transport,
                    parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
                    wire = mapOf("temperature" to wire),
                ),
            ),
        )
        val transport = RelayTransport.entries.first { it.value == item.intent.transport }
        val projection = relayProjection(
            model = options.activeModel!!,
            transport = transport,
            keys = setOf("generation_parameter/temperature"),
            explicitKeys = if (item.intent.override.state == "inherit") emptySet() else setOf("generation_parameter/temperature"),
        )
        return when (item.intent.transport) {
            "openai_chat_completions" -> buildOpenAIChatBody(
                item.intent.modelId,
                emptyList(),
                true,
                ReasoningMode.Automatic,
                options,
                capabilityProjection = projection,
            )
            "openai_responses" -> buildResponsesBody(
                item.intent.modelId,
                emptyList(),
                true,
                false,
                ReasoningMode.Automatic,
                false,
                options,
                capabilityProjection = projection,
            )
            "anthropic_messages" -> buildAnthropicBody(
                item.intent.modelId,
                emptyList(),
                true,
                ReasoningMode.Automatic,
                options,
                capabilityProjection = projection,
            )
            "gemini_generate_content" -> buildGeminiBody(
                emptyList(),
                item.intent.modelId,
                false,
                ReasoningMode.Automatic,
                false,
                options,
                capabilityProjection = projection,
            )
            else -> error("unsupported transport ${item.intent.transport}")
        }
    }

    /** Relay production shape: declaration + exact dispatch endpoint + explicit request intent. */
    private fun relayProjection(
        model: AIModel,
        transport: RelayTransport,
        keys: Set<String>,
        explicitKeys: Set<String>,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val provider = Provider(
            id = "relay-contract",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
            model,
            transport,
            relayFinalUrl(transport, model.id),
        )
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = explicitKeys,
        )
    }

    private fun relayFinalUrl(transport: RelayTransport, modelId: String): String = when (transport) {
        RelayTransport.OpenAIChatCompletions -> "https://relay.example/v1/chat/completions"
        RelayTransport.OpenAIResponses -> "https://relay.example/v1/responses"
        RelayTransport.AnthropicMessages -> "https://relay.example/v1/messages"
        RelayTransport.GeminiGenerateContent ->
            "https://relay.example/v1beta/models/$modelId:generateContent"
        RelayTransport.LlamaCppNative -> "https://relay.example/completion"
        RelayTransport.Auto -> error("auto has no final dispatch identity")
    }

    private fun valueAtPath(root: JsonObject, path: String): JsonElement? =
        path.split('.').fold(root as JsonElement?) { current, segment ->
            current?.jsonObject?.get(segment)
        }

    private fun loadContract(): ContractFile = json.decodeFromString(contractText())

    private fun loadWireHardening(): WireHardeningFile = json.decodeFromString(contractText())

    private fun loadAvailability(): AvailabilityFile = json.decodeFromString(contractText())

    private fun contractText(): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/generation_parameter_contract.v1.json") }
            .firstOrNull(Files::exists)
            ?: error("generation_parameter_contract.v1.json not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    @Serializable
    private data class WireHardeningFile(
        val wireHardening: WireHardeningRules,
        val wireHardeningCases: List<WireHardeningCase>,
    )

    @Serializable
    private data class WireHardeningRules(
        val segmentPattern: String,
        val blockedSegments: List<String>,
        val maxSegments: Int,
        val builderOwnedRootFields: List<String>,
        val jsonSchemaLimits: JsonSchemaLimits,
    )

    @Serializable
    private data class JsonSchemaLimits(val maxBytes: Int, val maxDepth: Int)

    @Serializable
    private data class WireHardeningCase(
        val caseId: String,
        val wire: String,
        val value: Double,
        val expect: WireHardeningExpectation,
    )

    @Serializable
    private data class WireHardeningExpectation(val applied: Boolean, val reason: String? = null)

    @Serializable
    private data class AvailabilityFile(
        val availabilityCases: List<AvailabilityCase>,
        val availabilityRules: AvailabilityRules,
    )

    @Serializable
    private data class AvailabilityRules(val outboundSupport: List<String>)

    @Serializable
    private data class AvailabilityCase(
        val caseId: String,
        val intent: AvailabilityIntent,
        val expect: AvailabilityExpectation,
    )

    @Serializable
    private data class AvailabilityIntent(
        val providerKind: String,
        val scope: String,
        val parameter: AvailabilityParameter,
        @SerialName("entitlement") val access: AvailabilityAccess,
    )

    @Serializable
    private data class AvailabilityParameter(
        val id: String,
        val support: String,
        val group: String? = null,
        val wire: String? = null,
    )

    @Serializable
    private data class AvailabilityAccess(val canManageRuntime: Boolean)

    @Serializable
    private data class AvailabilityExpectation(
        val inScope: Boolean,
        val entryVisible: Boolean,
        val editable: Boolean,
    )

    @Serializable
    private data class ContractFile(val version: Int, val cases: List<ContractCase>)

    @Serializable
    private data class ContractCase(val caseId: String, val intent: Intent, val expect: Expectation)

    @Serializable
    private data class Intent(val transport: String, val modelId: String, val override: Override)

    @Serializable
    private data class Override(val state: String, val value: Double? = null)

    @Serializable
    private data class Expectation(
        val bodyIncludes: Map<String, JsonElement> = emptyMap(),
        val bodyExcludes: List<String> = emptyList(),
    )
}
