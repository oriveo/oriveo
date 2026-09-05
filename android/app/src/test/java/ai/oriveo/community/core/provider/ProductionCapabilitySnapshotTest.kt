package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real decision function [CapabilityControlResolution.resolve] with a slice of
 * **actually published** metadata rather than yet another set of hand-written fixtures.
 *
 * Why not hand-written fixtures: an earlier round was verified entirely by "unit tests pass,
 * the curl output has the right fields, the deploy returned 200". None of those three say
 * anything about what a user sees on screen, and every one of those tests had built its own
 * data specifically so that its assertion would hold. The state and profile combinations here
 * are lifted verbatim out of the published catalog, and the expected values live in the same
 * slice (`expectedVerdicts`) so that they cannot be quietly rewritten to match the code.
 */
class ProductionCapabilitySnapshotTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val snapshot: JsonObject by lazy {
        json.parseToJsonElement(
            workspaceFile("shared/model-contracts/production-capability-snapshot.json").readText(),
        ).jsonObject
    }

    private val models: Map<String, JsonObject> by lazy {
        snapshot["models"]!!.jsonObject.mapValues { it.value.jsonObject }
    }

    private val expectedVerdicts: Map<String, JsonObject> by lazy {
        snapshot["expectedVerdicts"]!!.jsonObject
            .filterKeys { !it.startsWith("$") }
            .mapValues { it.value.jsonObject }
    }

    /**
     * The registry itself is used as the capabilityRuntime, not a mock of it.
     *
     * A false green of exactly this shape was fixed once before: the mock supplied
     * `recipes: {}`, so every auto_available control carrying a recipeRef fell through
     * `dangling_recipe_ref` into the legacy path, and the assertion claiming "the legacy
     * profile is not consulted" was in fact passing because of the legacy profile. So this
     * reads the registry file directly instead of inventing a recipe set.
     */
    private fun metadataClient(): MetadataClient {
        val registry = workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText().trim()
        val runtime = registry.removeSuffix("}") +
            ",\"revision\":\"production-snapshot\",\"generatedAt\":\"2026-08-13T00:00:00Z\"}"

        val providers = buildJsonObject {
            models.values.groupBy { it["providerKind"]!!.jsonPrimitive.content }
                .forEach { (kind, entries) ->
                    put(
                        kind,
                        buildJsonObject {
                            put(
                                "resolveMap",
                                buildJsonObject {
                                    entries.forEach { entry ->
                                        val id = entry["modelId"]!!.jsonPrimitive.content
                                        put(id, id)
                                    }
                                },
                            )
                            put(
                                "models",
                                buildJsonObject {
                                    entries.forEach { entry ->
                                        val id = entry["modelId"]!!.jsonPrimitive.content
                                        put(
                                            id,
                                            buildJsonObject {
                                                put("canonicalModelId", id)
                                                put("transport", entry["transport"]!!.jsonPrimitive.content)
                                                put("capabilities", entry["capabilities"]!!.jsonArray)
                                                put("profiles", entry["profiles"]!!.jsonObject)
                                                put("capabilityControls", entry["capabilityControls"]!!.jsonObject)
                                            },
                                        )
                                    }
                                },
                            )
                        },
                    )
                }
        }
        val reasoningProfiles = snapshot["profiles"]!!.jsonObject["reasoning"]!!.jsonObject
        val payload = buildJsonObject {
            put("version", JsonPrimitive(1))
            put("profiles", buildJsonObject { put("reasoning", reasoningProfiles) })
            put("providers", providers)
        }.toString()
        // capabilityRuntime is injected as raw registry text, so buildJsonObject never gets to
        // reorder it.
        val withRuntime = payload.removeSuffix("}") + ",\"capabilityRuntime\":$runtime}"

        val client = MetadataClient()
        client.loadNetworkPayloadForTesting(withRuntime, "etag-production-snapshot")
        return client
    }

    private fun verdict(
        client: MetadataClient,
        key: String,
        capability: String,
    ): CapabilityControlResolution.Verdict {
        val entry = models.getValue(key)
        val kind = ProviderKind.entries.first { it.rawValue == entry["providerKind"]!!.jsonPrimitive.content }
        val modelId = entry["modelId"]!!.jsonPrimitive.content
        return CapabilityControlResolution.resolve(
            provider = Provider(id = "p", kind = kind),
            model = AIModel(id = modelId, name = modelId),
            capability = capability,
            metadata = client,
        )
    }

    /** Every model in the slice must have an expected verdict; cherry-picking a handful of
     * capable models is precisely what let the previous round through. */
    @Test
    fun `covers every model in the shared slice - no cherry-picking`() {
        assertEquals(models.keys.sorted(), expectedVerdicts.keys.sorted())
    }

    /**
     * The full per-model matrix. Of the hundreds of models in the published catalog, roughly
     * half cannot emit a web-search tool at all, so most users land on the empty side. Models
     * with no capability are first-class cases here, not an afterthought.
     */
    @Test
    fun `resolves web and reasoning for every production model exactly as the shared table says`() {
        val client = metadataClient()
        listOf("web", "reasoning").forEach { capability ->
            var available = 0
            var unavailable = 0
            models.keys.forEach { key ->
                val expected = expectedVerdicts.getValue(key)[capability]!!.jsonObject
                val actual = verdict(client, key, capability)
                assertEquals(
                    "$key/$capability state",
                    expected["state"]!!.jsonPrimitive.content,
                    actual.state,
                )
                assertEquals(
                    "$key/$capability viaLegacyProfile",
                    expected["viaLegacyProfile"]!!.jsonPrimitive.content.toBoolean(),
                    actual.viaLegacyProfile,
                )
                expected["intents"]?.let { intents ->
                    assertEquals(
                        "$key/$capability intents",
                        intents.jsonArray.map { it.jsonPrimitive.content },
                        actual.intents,
                    )
                }
                // The shared criterion behind the badge and the control has to be decided by
                // state alone; nowhere else may add a condition of its own.
                if (actual.isAvailable) available += 1 else unavailable += 1
            }
            // Empty states are first-class: if the slice is ever trimmed down to only the
            // capable models, these two go red.
            assertTrue("$capability: the available side must not be empty", available > 0)
            assertTrue("$capability: the unavailable side must not be empty", unavailable > 0)
        }
    }

    /**
     * "Automatic configuration exists but there is no ladder to choose from" is a first-class
     * state, not a broken auto_available.
     *
     * Observed in the published catalog: `openAI/gpt-5-pro` accepts only high and
     * `gpt-5.2-chat-latest` only medium, and the catalog deliberately publishes no
     * `availableIntents` for either. The client must neither downgrade them to unavailable nor
     * invent tiers of its own; inventing tiers is what produces the dead end where the panel
     * says the control is available and then offers nothing to pick.
     */
    @Test
    fun `an automatic reasoning control with an empty ladder stays available and stays empty`() {
        val client = metadataClient()
        listOf("openAI/gpt-5-pro", "openAI/gpt-5.2-chat-latest").forEach { key ->
            val entry = models.getValue(key)
            val reasoning = entry["capabilityControls"]!!.jsonObject["reasoning"]!!.jsonObject
            // Self-evidencing premise: the slice really is shaped like this, the assertions
            // below are not assuming it.
            assertEquals("$key slice state", "auto_available", reasoning["state"]!!.jsonPrimitive.content)
            assertNull("$key slice carries no availableIntents", reasoning["availableIntents"])
            assertTrue(
                "$key slice carries no legacy reasoning profile",
                entry["profiles"]!!.jsonObject["reasoning"] is JsonNull,
            )

            val actual = verdict(client, key, "reasoning")
            assertEquals("auto_available", actual.state)
            assertEquals(emptyList<String>(), actual.intents)
            assertTrue(actual.isAvailable)
        }
    }

    /**
     * Only an exact official recipe is trusted. Even when a historical snapshot still carries a
     * legacy web profile, unknown has to stay unknown; it may not be guessed into available
     * from the provider, the model id or the profile.
     */
    @Test
    fun `an unknown v2 control stays unknown and never falls back to a legacy profile`() {
        val client = metadataClient()
        val actual = verdict(client, "qwen/qwen3-max", "web")
        assertEquals("unknown", actual.state)
        assertTrue(!actual.viaLegacyProfile)
        assertEquals("official_source_insufficient", actual.reasonCode)
    }

    /** The reverse assertion: when v2 says outright that a capability is unsupported, the
     * legacy fallback may not lift it back to available. */
    @Test
    fun `an explicitly unavailable control is never lifted by a legacy profile`() {
        val client = metadataClient()
        val actual = verdict(client, "qwen/qwen3.6-plus", "web")
        assertEquals("unavailable", actual.state)
        assertTrue(!actual.viaLegacyProfile)
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot locate $relative")
    }
}
