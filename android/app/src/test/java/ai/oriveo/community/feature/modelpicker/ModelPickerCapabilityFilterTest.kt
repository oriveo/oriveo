package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
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
                    val expected = if (kind == ModelPickerCapabilityFilterKind.Tool) {
                        CapabilityEvidenceProductionAdapter.toolCallVerdict(
                            section.provider,
                            model,
                            metadataClient = metadata,
                        ) == true
                    } else {
                        CapabilityControlResolution
                            .resolve(section.provider, model, kind.owner, metadata)
                            .isAvailable
                    }
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
        val learnedModel = AIModel(id = "learned-tool-model", name = "Learned", isManual = true)
        val all = sections(metadata) + ModelPickerSection(
            provider = Provider(
                id = "relay-tool-memory",
                kind = ProviderKind.Relay,
                relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            ),
            models = listOf(learnedModel),
        )
        val memoryVerdict: (Provider, AIModel) -> Boolean? = { _, model ->
            true.takeIf { model.id == learnedModel.id }
        }
        val counts = modelPickerCapabilityFilterCounts(all, metadata, memoryVerdict)
        ModelPickerCapabilityFilterKind.entries.forEach { kind ->
            val kept = applyModelPickerCapabilityFilter(
                all,
                setOf(kind),
                metadata,
                memoryVerdict,
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

        val both = applyModelPickerCapabilityFilter(
            all,
            ModelPickerCapabilityFilterKind.entries.toSet(),
            metadata,
        )
        both.forEach { section ->
            section.models.forEach { model ->
                assertEquals(
                    ModelPickerCapabilityFilterKind.entries.toSet(),
                    modelPickerCapabilityBadges(section.provider, model, metadata),
                )
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
