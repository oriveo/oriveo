package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlResolution
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Display-fact web badge: the expectations are always read from the badge cases of the shared fixture
 * display-facts.v1.json, one `DISPLAY_FACTS_<id>` test per case. Each case builds production objects so that the web
 * verdict [CapabilityControlResolution.resolve] equals the fixture's webControlState (asserted first), then asserts the
 * picker badge [modelPickerCapabilityBadges] and the capability filter [applyModelPickerCapabilityFilter]. Only
 * auto_available lights the badge and matches the filter.
 */
class DisplayFactsBadgeCapabilityContractTest {
    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/test-fixtures/capability/display-facts.v1.json").readText()).jsonObject

    @Test fun DISPLAY_FACTS_official_auto_badge() = assertBadgeCase("official_auto_badge")
    @Test fun DISPLAY_FACTS_official_custom_only_no_badge() = assertBadgeCase("official_custom_only_no_badge")

    @Test
    fun DISPLAY_FACTS_badge_case_ids_match_the_fixture() {
        assertEquals(
            setOf(
                "official_auto_badge",
                "official_custom_only_no_badge",
            ),
            cases().map { it.string("id") }.toSet(),
        )
    }

    private fun assertBadgeCase(id: String) {
        val case = cases().single { it.string("id") == id }
        val state = case.string("webControlState")
        val modelId = "display-facts-$id"
        val (provider, model, metadata) = when (val form = case.string("form")) {
            "official" -> official(modelId, state)
            else -> error("unknown form $form")
        }
        val resolved = CapabilityControlResolution.resolve(provider, model, "web", metadata).state
        assertEquals("$id precondition: the web verdict should equal the fixture webControlState", state, resolved)
        val expect = case.getValue("expect").jsonObject
        val badge = ModelPickerCapabilityFilterKind.Web in modelPickerCapabilityBadges(provider, model, metadata)
        assertEquals("$id badge", expect.string("badge")!!.toBooleanStrict(), badge)
        val kept = applyModelPickerCapabilityFilter(
            listOf(ModelPickerSection(provider = provider, models = listOf(model))),
            setOf(ModelPickerCapabilityFilterKind.Web),
            metadata,
        ).sumOf { it.models.size }
        assertEquals("$id pickerFilterMatches", expect.string("pickerFilterMatches")!!.toBooleanStrict(), kept == 1)
    }

    /** Official: the catalog capabilityControls.web is injected through the production publish boundary (with the real capabilityRuntime). */
    private fun official(modelId: String, state: String?): Triple<Provider, AIModel, MetadataClient> {
        val web = buildJsonObject {
            put("state", state)
            if (state == "auto_available") {
                put("recipeRef", "openai.responses.web.v1")
                put("availableIntents", JsonArray(listOf(JsonPrimitive("force"))))
            } else {
                put("reasonCode", "official_custom_parameters")
                put("sourceRefs", JsonArray(listOf(JsonPrimitive("openai.web_search"))))
            }
        }
        val registry = workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText().trim()
        val runtime = registry.removeSuffix("}") +
            ",\"revision\":\"display-facts\",\"generatedAt\":\"2026-10-20T00:00:00Z\"}"
        val payload = buildJsonObject {
            put("version", JsonPrimitive(1))
            put("providers", buildJsonObject {
                put("openAI", buildJsonObject {
                    put("resolveMap", buildJsonObject { put(modelId, modelId) })
                    put("models", buildJsonObject {
                        put(modelId, buildJsonObject {
                            put("canonicalModelId", modelId)
                            put("transport", "openai_responses")
                            put("capabilities", JsonArray(listOf(JsonPrimitive("text"), JsonPrimitive("web"))))
                            put("capabilityControls", buildJsonObject { put("web", web) })
                        })
                    })
                })
            })
        }.toString().removeSuffix("}") + ",\"capabilityRuntime\":$runtime}"
        val metadata = MetadataClient().also { it.loadNetworkPayloadForTesting(payload, "etag-display-facts") }
        return Triple(Provider(id = "official-openai", kind = ProviderKind.OpenAI), AIModel(id = modelId, name = modelId), metadata)
    }

    private fun cases(): List<JsonObject> = fixture.getValue("managedWebBadgeCases").jsonArray.map { it.jsonObject }

    private fun JsonObject.string(name: String): String? = this[name]?.jsonPrimitive?.content

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
