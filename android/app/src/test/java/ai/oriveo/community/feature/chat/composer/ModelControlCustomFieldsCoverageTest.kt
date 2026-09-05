package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The empty-state matrix for the "custom request fields" entry point.
 *
 * Why this test exists: the existing assertions all sit on the three cases that are non-empty
 * (`CapabilityRecipeRequestCompilerTest` asserts exactly what openAI / qwen each carry), and none
 * of them ever asked what the remaining 42 (provider x owner) combinations look like -- yet the
 * vast majority of real users land on the empty side. The whole server-side
 * `capability_custom_controls.v2.json` only defines three controls, mounted only at
 * openAI@openai_responses(reasoning/generation) and qwen@openai_chat(web), plus relay's
 * generation, so only 4 of the 45 combinations are non-empty.
 */
class ModelControlCustomFieldsCoverageTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** The official providers (excludes relay). */
    private val officialKinds = ProviderKind.entries.filter {
        it !in setOf(ProviderKind.Relay)
    }

    private val owners = listOf("web", "reasoning", "generation")

    /** The real mount points across the whole product surface. Adding or removing even one must turn this test red. */
    private val mountedOfficial = setOf(
        ProviderKind.OpenAI to "reasoning",
        ProviderKind.OpenAI to "generation",
        ProviderKind.Qwen to "web",
    )

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `15 official providers times 3 owners leaves only the three real mount points non-empty`() {
        assertEquals("if the official provider count changes, this matrix needs re-auditing", 15, officialKinds.size)
        MetadataTestFixtures.applyRaw(matrixPayload().toString())

        val available = mutableSetOf<Pair<ProviderKind, String>>()
        officialKinds.forEach { kind ->
            owners.forEach { owner ->
                val modelId = modelId(kind)
                if (
                    capabilityCustomFragmentAvailable(
                        providerKind = kind,
                        modelID = modelId,
                        finalTransport = transport(kind),
                        activeProfile = null,
                        owner = owner,
                    )
                ) available += kind to owner
            }
        }
        assertEquals(
            "only coordinates the server has actually mounted a control on may light up an entry",
            mountedOfficial,
            available,
        )
        assertEquals("only 3 of the 45 combinations are non-empty", 3, available.size)
        assertEquals("the remaining 42 must be the empty state", 42, officialKinds.size * owners.size - available.size)
    }

    @Test
    fun `official entry follows the v2 catalog transport, not the legacy v1 generation profile`() {
        MetadataTestFixtures.applyRaw(matrixPayload().toString())
        val provider = Provider(id = "openai-conn", kind = ProviderKind.OpenAI)
        val model = AIModel(id = modelId(ProviderKind.OpenAI), name = "OpenAI custom")
        val catalogTransport = ChatModelCapabilityResolver().finalTransport(provider, model)
        assertEquals("v2 catalog transport", "openai_responses", catalogTransport)

        // this fixture deliberately declares the v1 `profiles.generation` on a different protocol,
        // to prove the entry point reads v2 rather than falling back to it.
        val legacyTransport = MetadataClient.instance
            .currentCapabilityEvidenceModel(model.id, ProviderKind.OpenAI)
            ?.metadata?.profiles?.generation?.transport
        assertEquals("the fixture's v1 profile transport must differ from v2, or the comparison proves nothing", "openai_chat", legacyTransport)

        assertTrue(
            "the schema is only reachable via the v2 catalog transport",
            capabilityCustomFragmentAvailable(
                ProviderKind.OpenAI, model.id, catalogTransport, null, "generation",
            ),
        )
        assertFalse(
            "the v1 profile transport must fail closed",
            capabilityCustomFragmentAvailable(
                ProviderKind.OpenAI, model.id, legacyTransport, null, "generation",
            ),
        )
    }

    @Test
    fun `transport drift and blank transport both fail closed`() {
        MetadataTestFixtures.applyRaw(matrixPayload().toString())
        val modelId = modelId(ProviderKind.Qwen)
        assertTrue(capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelId, "openai_chat", null, "web"))
        assertFalse(
            "the same owner must fail once the transport drifts",
            capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelId, "openai_responses", null, "web"),
        )
        assertFalse(capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelId, null, null, "web"))
        assertFalse(capabilityCustomFragmentAvailable(ProviderKind.Qwen, modelId, "  ", null, "web"))
    }

    /**
     * Relay only has one owner, generation (a hard guard in `safeCustomFragmentAuthority`'s relay
     * branch), and it must both match transport *and* remain non-empty after wire filtering -- an
     * earlier UI check only looked at `owner == "generation"`, so the entry lit up while the outbound
     * request threw an InvalidConfiguration, exactly the dead end this test rules out.
     */
    @Test
    fun `relay grants generation only when the local profile really wires something`() {
        val provider = relayProvider()
        val wired = relayModel(
            transport = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
            wire = mapOf("temperature" to "temperature"),
        )
        val profile = GenerationParameterAvailability.profile(provider, wired)
        assertTrue(
            capabilityCustomFragmentAvailable(
                ProviderKind.Relay, wired.id, profile?.transport, profile, "generation",
            ),
        )
        listOf("web", "reasoning").forEach { owner ->
            assertFalse(
                "relay's $owner can never reach a schema",
                capabilityCustomFragmentAvailable(
                    ProviderKind.Relay, wired.id, profile?.transport, profile, owner,
                ),
            )
        }

        val unwired = relayModel(
            transport = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
            wire = emptyMap(),
        )
        val unwiredProfile = GenerationParameterAvailability.profile(provider, unwired)
        assertFalse(
            "the entry point cannot light up if an empty wire would be rejected outbound",
            capabilityCustomFragmentAvailable(
                ProviderKind.Relay, unwired.id, unwiredProfile?.transport, unwiredProfile, "generation",
            ),
        )

        // the wire only contains parameter ids the profile never declared; that fails the same outbound supportedIds filter.
        val strayWire = relayModel(
            transport = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
            wire = mapOf("top_p" to "top_p"),
        )
        val strayProfile = GenerationParameterAvailability.profile(provider, strayWire)
        assertFalse(
            capabilityCustomFragmentAvailable(
                ProviderKind.Relay, strayWire.id, strayProfile?.transport, strayProfile, "generation",
            ),
        )

        assertFalse(
            "must fail closed when the profile transport doesn't match the final transport",
            capabilityCustomFragmentAvailable(
                ProviderKind.Relay, wired.id, "anthropic_messages", profile, "generation",
            ),
        )
    }

    /** 45 (provider x owner) combinations plus relay's three owners; only 4 classes are non-empty. */
    @Test
    fun `the whole product surface has exactly four non-empty classes`() {
        MetadataTestFixtures.applyRaw(matrixPayload().toString())
        val relayProvider = relayProvider()
        val relayModel = relayModel(
            transport = "openai_chat_completions",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
            wire = mapOf("temperature" to "temperature"),
        )
        val relayProfile = GenerationParameterAvailability.profile(relayProvider, relayModel)
        val relayAvailable = owners.filter { owner ->
            capabilityCustomFragmentAvailable(
                ProviderKind.Relay, relayModel.id, relayProfile?.transport, relayProfile, owner,
            )
        }
        val officialAvailable = officialKinds.flatMap { kind ->
            owners.filter { owner ->
                capabilityCustomFragmentAvailable(kind, modelId(kind), transport(kind), null, owner)
            }.map { kind to it }
        }
        assertEquals(listOf("generation"), relayAvailable)
        assertEquals(4, officialAvailable.size + relayAvailable.size)
    }

    /** Server-side coverage lock: any change to the total control count or owner distribution must come back to re-judge this matrix. */
    @Test
    fun `server custom control definitions stay at three controls across three owners`() {
        val definitions = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_custom_controls.v2.json"),
        ).jsonObject
        assertEquals(3, definitions.size)
        assertEquals(
            mapOf(
                "qwen.web.enable_search" to "web",
                "openai.reasoning.effort" to "reasoning",
                "openai.generation.max_output_tokens" to "generation",
            ),
            definitions.mapValues { (_, raw) -> (raw.jsonObject["owner"] as JsonPrimitive).content },
        )
    }

    // ── fixtures ──────────────────────────────────────────────────────────────

    private fun modelId(kind: ProviderKind): String = "${providerKey(kind)}-matrix-model"

    private fun transport(kind: ProviderKind): String = when (kind) {
        ProviderKind.OpenAI -> "openai_responses"
        ProviderKind.Anthropic -> "anthropic_messages"
        ProviderKind.Gemini -> "gemini_generate_content"
        else -> "openai_chat"
    }

    private fun matrixPayload(): JsonObject {
        val execution = json.parseToJsonElement(
            load("shared/model-contracts/provider_recipe_execution.v1.json"),
        ).jsonObject
        val registryPath = (execution["registryPath"] as JsonPrimitive).content
        val registry = json.parseToJsonElement(load(registryPath)).jsonObject
        val definitions = json.parseToJsonElement(
            load("shared/capabilityrecipe/capability_custom_controls.v2.json"),
        ).jsonObject
        val runtime = JsonObject(
            registry + mapOf(
                "revision" to JsonPrimitive("sha256:custom-owner-matrix"),
                "generatedAt" to JsonPrimitive("2026-08-13T00:00:00Z"),
                "controlDefinitions" to definitions,
            ),
        )
        return buildJsonObject {
            put("version", 1)
            put("capabilityRuntime", runtime)
            // the v1 generation profile only exists once expanded through the top-level shared template; its transport comes from the template.
            put("profiles", buildJsonObject {
                put("generation", buildJsonObject {
                    put("parameters", buildJsonObject {
                        put("temperature", buildJsonObject { put("valueSchema", "number") })
                    })
                    put("templates", buildJsonObject {
                        put(LEGACY_TEMPLATE, buildJsonObject {
                            put("transport", "openai_chat")
                            put("wire", buildJsonObject { put("temperature", "temperature") })
                        })
                    })
                })
            })
            put("providers", buildJsonObject {
                officialKinds.forEach { kind ->
                    val id = modelId(kind)
                    put(providerKey(kind), buildJsonObject {
                        put("resolveMap", buildJsonObject { put(id, id) })
                        put("models", buildJsonObject { put(id, matrixModel(kind)) })
                    })
                }
            })
        }
    }

    private fun matrixModel(kind: ProviderKind): JsonObject = buildJsonObject {
        put("transport", transport(kind))
        // the v1 compatibility-window generation profile deliberately sits on a different protocol, to prove the entry point reads v2 rather than it.
        put("profiles", buildJsonObject {
            put("generation", buildJsonObject {
                put("template", LEGACY_TEMPLATE)
                put("parameters", JsonArray(listOf(buildJsonObject {
                    put("id", "temperature")
                    put("support", "supported")
                })))
            })
        })
        put("capabilityControls", buildJsonObject {
            owners.forEach { owner ->
                put(owner, buildJsonObject {
                    put("state", "auto_available")
                    customControlRefs(kind, owner)?.let { refs ->
                        put("customControlRefs", JsonArray(refs.map(::JsonPrimitive)))
                    }
                })
            }
        })
    }

    private fun customControlRefs(kind: ProviderKind, owner: String): List<String>? = when (kind to owner) {
        ProviderKind.Qwen to "web" -> listOf("qwen.web.enable_search")
        ProviderKind.OpenAI to "reasoning" -> listOf("openai.reasoning.effort")
        ProviderKind.OpenAI to "generation" -> listOf("openai.generation.max_output_tokens")
        else -> null
    }

    private fun relayProvider() = Provider(
        id = "relay-conn",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example.com/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
    )

    private fun relayModel(
        transport: String,
        parameters: List<GenerationParameterRef>,
        wire: Map<String, String>,
    ) = AIModel(
        id = "relay-model",
        name = "Relay model",
        generationProfile = GenerationProfileRef(parameters = parameters, wire = wire, transport = transport),
    )

    private fun providerKey(kind: ProviderKind): String = when (kind) {
        ProviderKind.Together -> "togetherAI"
        ProviderKind.Fireworks -> "fireworksAI"
        else -> kind.rawValue
    }

    private fun load(path: String): String {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val root = moduleDir.parentFile!!.parentFile!!
        return File(root, path).readText(Charsets.UTF_8)
    }

    private companion object {
        const val LEGACY_TEMPLATE = "matrix.legacy.chat.v1"
    }
}
