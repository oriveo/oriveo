package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Capability-aware filtering surfaced up front in the model picker.
 *
 * This uses a real production snapshot, not a hand-written fixture -- the
 * gap where the model catalog says a model supports web search but the chat
 * page can't actually turn it on is exactly the kind of divergence that
 * showed up across dozens of real production models, and a hand-written
 * fixture can't pin that down.
 */
class ModelPickerCapabilityFilterTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val snapshot: JsonObject by lazy {
        json.parseToJsonElement(
            workspaceFile("shared/model-contracts/production-capability-snapshot.json").readText(),
        ).jsonObject
    }

    private val models: Map<String, JsonObject> by lazy {
        snapshot["models"]!!.jsonObject.mapValues { it.value.jsonObject }
    }

    private fun client(): MetadataClient {
        val registry = workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText().trim()
        val runtime = registry.removeSuffix("}") +
            ",\"revision\":\"picker-snapshot\",\"generatedAt\":\"2026-08-13T00:00:00Z\"}"
        val providers = buildJsonObject {
            models.values.groupBy { it["providerKind"]!!.jsonPrimitive.content }.forEach { (kind, entries) ->
                put(
                    kind,
                    buildJsonObject {
                        put(
                            "resolveMap",
                            buildJsonObject {
                                entries.forEach { put(it["modelId"]!!.jsonPrimitive.content, it["modelId"]!!.jsonPrimitive.content) }
                            },
                        )
                        put(
                            "models",
                            buildJsonObject {
                                entries.forEach { entry ->
                                    put(
                                        entry["modelId"]!!.jsonPrimitive.content,
                                        buildJsonObject {
                                            put("canonicalModelId", entry["modelId"]!!.jsonPrimitive.content)
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
        val payload = buildJsonObject {
            put("version", JsonPrimitive(1))
            put(
                "profiles",
                buildJsonObject { put("reasoning", snapshot["profiles"]!!.jsonObject["reasoning"]!!.jsonObject) },
            )
            put("providers", providers)
        }.toString().removeSuffix("}") + ",\"capabilityRuntime\":$runtime}"
        return MetadataClient().also { it.loadNetworkPayloadForTesting(payload, "etag-picker") }
    }

    private fun sections(metadata: MetadataClient): List<ModelPickerSection> =
        models.values.groupBy { it["providerKind"]!!.jsonPrimitive.content }.map { (kind, entries) ->
            ModelPickerSection(
                provider = Provider(
                    id = kind,
                    kind = ProviderKind.entries.first { it.rawValue == kind },
                ),
                models = entries.map { entry ->
                    val id = entry["modelId"]!!.jsonPrimitive.content
                    AIModel(id = id, name = id)
                },
            )
        }

    /**
     * The badge verdict must be word-for-word the same one the chat page's
     * controls use. No second expectation is written here -- this
     * reconciles directly against [CapabilityControlResolution.resolve]'s
     * own conclusion.
     */
    @Test
    fun `badges are exactly what the chat capability decision function says`() {
        val metadata = client()
        sections(metadata).forEach { section ->
            section.models.forEach { model ->
                val badges = modelPickerCapabilityBadges(section.provider, model, metadata)
                ModelPickerCapabilityFilterKind.entries.forEach { kind ->
                    val expected = CapabilityControlResolution
                        .resolve(section.provider, model, kind.owner, metadata)
                        .state == "auto_available"
                    assertEquals(
                        "${section.provider.kind.rawValue}/${model.id} ${kind.owner}",
                        expected,
                        kind in badges,
                    )
                }
            }
        }
    }

    /** The count must equal the number of rows the filter actually keeps -- otherwise the badge says one number while tapping in shows another. */
    @Test
    fun `filter counts equal the number of rows the filter actually keeps`() {
        val metadata = client()
        val all = sections(metadata)
        val counts = modelPickerCapabilityFilterCounts(all, metadata)
        assertEquals(
            "filter kinds are exactly web search / reasoning",
            setOf(ModelPickerCapabilityFilterKind.Web, ModelPickerCapabilityFilterKind.Reasoning),
            counts.keys,
        )
        ModelPickerCapabilityFilterKind.entries.forEach { kind ->
            val kept = applyModelPickerCapabilityFilter(
                all,
                setOf(kind),
                metadata,
            ).sumOf { it.models.size }
            assertEquals("${kind.owner} count must match what the filter actually keeps", counts.getValue(kind), kept)
        }
        // Both sides must be non-empty in the production snapshot, otherwise this assertion pins nothing down.
        ModelPickerCapabilityFilterKind.entries.forEach { kind ->
            assertTrue("${kind.owner}'s matching side must not be empty", counts.getValue(kind) > 0)
        }
        val total = all.sumOf { it.models.size }
        ModelPickerCapabilityFilterKind.entries.forEach { kind ->
            assertTrue("${kind.owner}'s non-matching side must not be empty", counts.getValue(kind) < total)
        }
    }

    /** Multiple chips intersect; an empty selection filters nothing; a provider section left empty by the filter is removed entirely, deferring to an honest empty state. */
    @Test
    fun `multiple chips intersect and an empty selection filters nothing`() {
        val metadata = client()
        val all = sections(metadata)
        assertEquals(all, applyModelPickerCapabilityFilter(all, emptySet(), metadata))

        val webAndReasoning = setOf(ModelPickerCapabilityFilterKind.Web, ModelPickerCapabilityFilterKind.Reasoning)
        assertEquals("filter kinds are exactly web search / reasoning", webAndReasoning, ModelPickerCapabilityFilterKind.entries.toSet())
        val both = applyModelPickerCapabilityFilter(all, webAndReasoning, metadata)
        assertTrue("the web + reasoning intersection in the production snapshot must be non-empty, otherwise the intersection assertion pins nothing down", both.isNotEmpty())
        both.forEach { section ->
            section.models.forEach { model ->
                assertEquals(webAndReasoning, modelPickerCapabilityBadges(section.provider, model, metadata))
            }
        }
        assertTrue("the filter must not leave behind an empty section", both.none { it.models.isEmpty() })
        val webOnly = applyModelPickerCapabilityFilter(
            all,
            setOf(ModelPickerCapabilityFilterKind.Web),
            metadata,
        ).sumOf { it.models.size }
        assertTrue("the intersection must be narrower than or equal to a single selection", both.sumOf { it.models.size } <= webOnly)
    }

    /**
     * Qwen's raw capabilities list web, but capabilityControls.web is unknown:
     * the web badge follows the same [CapabilityControlResolution.resolve] result as the control and stays off, with no Qwen special case.
     */
    @Test
    fun `qwen raw web capability does not light the web badge while the web control is unknown`() {
        val metadata = client()
        val entry = models.getValue("qwen/qwen3-max")
        val controlState = entry["capabilityControls"]!!.jsonObject["web"]!!.jsonObject["state"]!!.jsonPrimitive.content
        assertEquals("Snapshot precondition: the qwen3-max web control is unknown", "unknown", controlState)
        val provider = Provider(id = "qwen", kind = ProviderKind.Qwen)
        val model = AIModel(id = "qwen3-max", name = "qwen3-max", capabilities = listOf(ModelCapability.Text, ModelCapability.Web))

        val resolution = CapabilityControlResolution.resolve(provider, model, "web", metadata)
        assertFalse(resolution.isAvailable)
        assertFalse(ModelPickerCapabilityFilterKind.Web in modelPickerCapabilityBadges(provider, model, metadata))
        assertFalse(
            ModelCapability.Web in CapabilityEvidenceProductionAdapter.governedMetadataCapabilities(
                provider,
                model,
                metadataClient = metadata,
            ),
        )
    }

    // ---- Realtime voice filter ----

    private fun withRealtime(all: List<ModelPickerSection>): List<ModelPickerSection> = all.map { section ->
        if (section.provider.kind == ProviderKind.OpenAI) {
            section.copy(
                realtimeModels = listOf(
                    VoiceRealtimeEntry(
                        model = "gpt-realtime-2",
                        transport = VoiceTransport.OpenAIRealtime,
                        path = "/v1/realtime",
                        contextWindow = 128_000,
                        voices = listOf(VoiceOption("marin", isDefault = true)),
                        isDefault = true,
                    ),
                ),
            )
        } else {
            section
        }
    }

    @Test
    fun `realtime filter keeps only realtime rows`() {
        val metadata = client()
        val all = withRealtime(sections(metadata))
        assertTrue("snapshot precondition: an OpenAI group exists", all.any { it.realtimeModels.isNotEmpty() })

        val kept = applyModelPickerCapabilityFilter(all, emptySet(), metadata, realtimeSelected = true)
        assertTrue(kept.isNotEmpty())
        assertTrue("text rows do not match the realtime filter", kept.all { it.models.isEmpty() })
        assertEquals(listOf("gpt-realtime-2"), kept.flatMap { it.realtimeModels }.map { it.model })

        // With no realtime filter selected, realtime rows are still listed as usual
        assertEquals(all, applyModelPickerCapabilityFilter(all, emptySet(), metadata))
    }

    @Test
    fun `realtime filter together with web search is empty and web alone drops realtime rows`() {
        val metadata = client()
        val all = withRealtime(sections(metadata))
        val both = applyModelPickerCapabilityFilter(
            all,
            setOf(ModelPickerCapabilityFilterKind.Web),
            metadata,
            realtimeSelected = true,
        )
        assertTrue(both.isEmpty())

        val webOnly = applyModelPickerCapabilityFilter(all, setOf(ModelPickerCapabilityFilterKind.Web), metadata)
        assertTrue(webOnly.isNotEmpty())
        assertTrue(webOnly.all { it.realtimeModels.isEmpty() })
    }

    @Test
    fun realtime_chip_count_is_realtime_row_total() {
        val metadata = client()
        val all = withRealtime(sections(metadata))
        val total = all.sumOf { it.realtimeModels.size }
        assertTrue("snapshot precondition: realtime rows exist", total > 0)
        assertEquals(total, modelPickerRealtimeFilterCount(all))
        val kept = applyModelPickerCapabilityFilter(all, emptySet(), metadata, realtimeSelected = true)
        assertEquals("the count matches the rows the realtime filter keeps", kept.sumOf { it.realtimeModels.size }, modelPickerRealtimeFilterCount(all))
        assertEquals(0, modelPickerRealtimeFilterCount(sections(metadata)))
    }

    @Test
    fun `without realtime rows the realtime filter does not appear and selecting it changes nothing`() {
        val metadata = client()
        val all = sections(metadata)
        assertEquals(all, applyModelPickerCapabilityFilter(all, emptySet(), metadata, realtimeSelected = true))
        val result = buildModelPickerSectionsResult(
            context = ModelPickerContext.Chat,
            providers = all.map { it.provider },
            activeProviderId = null,
            currentModel = null,
            searchText = "",
            selectedCapabilityFilters = emptySet(),
            realtimeFilterSelected = true,
        )
        assertFalse(result.showsRealtimeFilter)
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("could not find $relative")
    }
}
