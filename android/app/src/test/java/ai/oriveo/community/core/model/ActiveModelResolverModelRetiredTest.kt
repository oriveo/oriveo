package ai.oriveo.community.core.model

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelRetirement
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Falling back when the preferred model of a new chat is no longer valid. */
class ActiveModelResolverModelRetiredTest {

    @After
    fun tearDown() {
        setBundledSnapshotActive(false)
        MetadataTestFixtures.clear()
    }

    @Test
    fun `retired last used falls back to catalog default and carries the hint`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAI("gpt-legacy", "gpt-other", "gpt-next")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-legacy"))

        assertEquals("gpt-next", resolved?.model?.id)
        assertEquals(ModelRetirement.NewChatHint.LastUsedRetired, resolved?.hint)
        assertEquals("last_used_retired", resolved?.hint?.wire)
        assertEquals("gpt-legacy", resolved?.replacedModelId)
    }

    @Test
    fun `hint key is the last used connection and raw model id when falling back to another connection`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val exhausted = openAI("gpt-legacy")
        val issue = openAI("gpt-next").copy(id = "provider-issue", status = ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.ApiKey))
        val next = openAI("gpt-other").copy(id = "provider-next")

        val resolved = resolveActiveModel(listOf(issue, exhausted, next), LastUsedModelRef("provider-openai", "gpt-legacy"))

        // The unavailable connection is skipped and the last-used connection has nothing usable left, so list order moves on to the next one.
        assertEquals("provider-next", resolved?.provider?.id)
        assertEquals("gpt-other", resolved?.model?.id)
        assertEquals(ModelRetirement.NewChatHint.LastUsedRetired, resolved?.hint)
        assertEquals("provider-openai", resolved?.replacedProviderId)
        assertEquals("gpt-legacy", resolved?.replacedModelId)
    }

    @Test
    fun `default not enabled falls back to first usable enabled model`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAI("gpt-legacy", "gpt-old", "gpt-other")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-legacy"))

        assertEquals("gpt-other", resolved?.model?.id)
        assertEquals(ModelRetirement.NewChatHint.LastUsedRetired, resolved?.hint)
    }

    @Test
    fun `usable last used is kept without hint`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAI("gpt-legacy", "gpt-other", "gpt-next")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-other"))

        assertEquals("gpt-other", resolved?.model?.id)
        assertNull(resolved?.hint)
        assertNull(resolved?.replacedModelId)
    }

    @Test
    fun `unloaded catalog does not fall back`() {
        val provider = openAI("gpt-legacy", "gpt-other", "gpt-next")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-legacy"))

        assertEquals("gpt-legacy", resolved?.model?.id)
        assertNull(resolved?.hint)
    }

    @Test
    fun `relay is not judged`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val relay = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-legacy", name = "gpt-legacy"), AIModel(id = "gpt-next", name = "gpt-next")),
            apiKey = "sk-test",
        )

        val resolved = resolveActiveModel(listOf(relay), LastUsedModelRef("relay-1", "gpt-legacy"))

        assertEquals("gpt-legacy", resolved?.model?.id)
        assertNull(resolved?.hint)
    }

    @Test
    fun `no preference with a loaded catalog uses the catalog default`() {
        // Input of the shared fixture no_preferred_uses_default
        MetadataTestFixtures.applyRaw(NO_PREFERRED_CATALOG)
        val provider = openAI("deepseek-v4-pro", "deepseek-flash")

        val resolved = resolveActiveModel(listOf(provider), lastUsedModelRef = null)

        assertEquals("deepseek-flash", resolved?.model?.id)
        assertNull(resolved?.hint)
    }

    @Test
    fun `bundled snapshot keeps a last used model missing from it without hint`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        setBundledSnapshotActive(true)
        val provider = openAI("gpt-custom", "gpt-next")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-custom"))

        assertEquals("gpt-custom", resolved?.model?.id)
        assertNull(resolved?.hint)
    }

    @Test
    fun `retired preference with nothing usable does not select the retired model`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAI("gpt-legacy", "gpt-old")

        val resolved = resolveActiveModel(listOf(provider), LastUsedModelRef("provider-openai", "gpt-legacy"))

        assertNull(resolved?.model?.id)
    }

    @Test
    fun `newChatChoiceOf with 810 enabled models stays under budget`() {
        // Time of one new-chat judgement over an 810-model catalog (catalog view + lifecycle parsing + per-candidate judgement). The last-used model is retired, the default is not enabled and the first 100 are shut down, so this takes the longest path; the limit is one frame, 16 ms (the same on every client).
        MetadataTestFixtures.applyRaw(largeCatalog(LARGE_MODEL_COUNT))
        val ids = (0 until LARGE_MODEL_COUNT).map { "m-$it" }
        val provider = openAI(*(listOf("gpt-legacy") + ids).toTypedArray())
        val ref = LastUsedModelRef("provider-openai", "gpt-legacy")

        repeat(5) { resolveActiveModel(listOf(provider), ref) }
        val samples = (0 until 21).map {
            val start = System.nanoTime()
            val resolved = resolveActiveModel(listOf(provider), ref)
            val elapsed = (System.nanoTime() - start) / 1_000_000.0
            assertEquals(ModelRetirement.NewChatHint.LastUsedRetired, resolved?.hint)
            elapsed
        }.sorted()
        val median = samples[samples.size / 2]
        println("newChatChoiceOf 810 models median=${"%.2f".format(median)}ms max=${"%.2f".format(samples.last())}ms")

        // Actual production-path output: the first 100 are shut down and the first usable one is m-100 (even-numbered ones are deprecated but not yet due, odd-numbered ones are active).
        assertEquals("m-100", resolveActiveModel(listOf(provider), ref)?.model?.id)
        assertTrue("median ${median}ms exceeds 16ms (one frame) budget", median < 16.0)
    }

    @Test
    fun `RETIRED_alias_undated_default_matches_dated_enabled via resolveActiveModel`() =
        assertFixtureNewChat("alias_undated_default_matches_dated_enabled")

    @Test
    fun `RETIRED_alias_exact_undated_beats_other_snapshot via resolveActiveModel`() =
        assertFixtureNewChat("alias_exact_undated_beats_other_snapshot")

    /** One newChatCases entry of the shared fixture model-retired.v1: the catalog is loaded into MetadataClient and the model is chosen through the production new-chat path. */
    private fun assertFixtureNewChat(id: String) {
        val raw = fixtureNewChatCase(id)
        val catalog = raw["catalog"]!!.jsonObject
        val metadata = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                put("openAI", buildJsonObject {
                    put("defaultModelId", catalog["defaultModelId"]!!.jsonPrimitive.content)
                    put("retiredModels", catalog["retiredModels"]!!)
                    put("resolveMap", catalog["resolveMap"]!!)
                    put("models", buildJsonObject {
                        catalog["models"]!!.jsonArray.forEach { element ->
                            val model = element.jsonObject
                            val modelId = model["id"]!!.jsonPrimitive.content
                            put(modelId, buildJsonObject {
                                put("canonicalModelId", modelId)
                                put("displayName", model["displayName"]!!.jsonPrimitive.content)
                            })
                        }
                    })
                })
            })
        }
        MetadataTestFixtures.applyRaw(metadata.toString())
        val canonicalIds = (raw["userModelCanonicalIds"]?.takeUnless { it is JsonNull }?.jsonObject)
            ?.mapValues { it.value.jsonPrimitive.content }
            .orEmpty()
        val provider = openAI(*raw["userModels"]!!.jsonArray.map { it.jsonPrimitive.content }.toTypedArray()).let { p ->
            p.copy(models = p.models.map { it.copy(canonicalModelId = canonicalIds[it.id]) })
        }

        val resolved = resolveActiveModel(listOf(provider), lastUsedModelRef = null)

        val expect = raw["expect"]!!.jsonObject
        assertEquals("$id modelId", expect["modelId"]!!.jsonPrimitive.content, resolved?.model?.id)
        assertNull("$id hint", resolved?.hint)
    }

    private fun fixtureNewChatCase(id: String): JsonObject {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/provider-catalog/model-retired.v1.json")
            if (candidate.exists()) {
                return Json.parseToJsonElement(candidate.readText()).jsonObject["newChatCases"]!!.jsonArray
                    .map { it.jsonObject }
                    .first { it["id"]!!.jsonPrimitive.content == id }
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("model-retired.v1.json not found")
    }

    private fun setBundledSnapshotActive(active: Boolean) {
        MetadataClient::class.java.getDeclaredField("bundledSnapshotActive")
            .apply { isAccessible = true }
            .setBoolean(MetadataClient.instance, active)
    }

    private fun openAI(vararg ids: String): Provider {
        val models = ids.map { AIModel(id = it, name = it) }
        return Provider(
            id = "provider-openai",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = models,
            catalogModels = models,
            apiKey = "sk-test",
            apiKeyPreview = "sk-...test",
        )
    }

    private companion object {
        const val LARGE_MODEL_COUNT = 810
        // The first 100 are past their shutdown date: the new-chat judgement must go down one by one and only hits at m-100 (the same fixture on every client).
        const val LARGE_SHUTDOWN_PREFIX = 100

        fun largeCatalog(count: Int): String {
            val models = (0 until count).joinToString(",\n") { i ->
                val lifecycle = if (i < LARGE_SHUTDOWN_PREFIX) {
                    """, "lifecycle": { "state": "deprecated", "shutdownAt": "2020-01-01" }"""
                } else if (i % 2 == 0) {
                    """, "lifecycle": { "state": "deprecated", "shutdownAt": "2099-01-01" }"""
                } else {
                    ""
                }
                """"m-$i": { "canonicalModelId": "m-$i", "displayName": "Model $i"$lifecycle }"""
            }
            val resolveMap = (0 until count).joinToString(", ") { i -> """"m-$i": "m-$i"""" }
            return """
                {
                  "version": 1,
                  "contractVersion": 1,
                  "providers": {
                    "openAI": {
                      "defaultModelId": "not-enabled-default",
                      "retiredModels": [
                        { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "m-0" }
                      ],
                      "resolveMap": { $resolveMap },
                      "models": {
                        "not-enabled-default": { "canonicalModelId": "not-enabled-default", "displayName": "Default" },
                        $models
                      }
                    }
                  }
                }
            """.trimIndent()
        }

        val NO_PREFERRED_CATALOG = """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "deepseek-flash",
                  "retiredModels": [],
                  "resolveMap": {},
                  "models": {
                    "deepseek-flash": { "canonicalModelId": "deepseek-flash", "displayName": "DeepSeek Flash" },
                    "deepseek-v4-pro": { "canonicalModelId": "deepseek-v4-pro", "displayName": "DeepSeek V4 Pro" }
                  }
                }
              }
            }
        """.trimIndent()

        val OPENAI_CATALOG = """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-next",
                  "retiredModels": [
                    { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "gpt-next" }
                  ],
                  "resolveMap": { "gpt-next": "gpt-next", "gpt-other": "gpt-other", "gpt-old": "gpt-old" },
                  "models": {
                    "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" },
                    "gpt-other": { "canonicalModelId": "gpt-other", "displayName": "GPT Other" },
                    "gpt-old": { "canonicalModelId": "gpt-old", "displayName": "GPT Old", "lifecycle": { "state": "deprecated", "shutdownAt": "2026-01-01" } }
                  }
                }
              }
            }
        """.trimIndent()
    }
}
