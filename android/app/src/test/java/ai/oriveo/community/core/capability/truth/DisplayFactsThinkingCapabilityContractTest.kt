package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.DisclosureStatus
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Display fact reasoning.thinking: expectations are always read from the thinkingCases of the shared fixture display-facts.v1.json,
 * one `DISPLAY_FACTS_<id>` test per case. Each case maps the fixture source onto production objects by form (connection, model,
 * metadata injected through the publish boundary); the fact is read at the panel read point [ModelOptionsPanelInput.showsThinking]
 * (-> [CapabilityTruthRegistry.thinking]) and the thinking row comes from the production shape function [ModelOptionCapabilityShape.resolve].
 */
class DisplayFactsThinkingCapabilityContractTest {
    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/test-fixtures/capability/display-facts.v1.json").readText()).jsonObject

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test fun DISPLAY_FACTS_official_catalog_reasoning_switchable() = assertThinkingCase("official_catalog_reasoning_switchable")
    @Test fun DISPLAY_FACTS_official_catalog_no_reasoning() = assertThinkingCase("official_catalog_no_reasoning")
    @Test fun DISPLAY_FACTS_official_catalog_miss_model_facts() = assertThinkingCase("official_catalog_miss_model_facts")
    @Test fun DISPLAY_FACTS_subscription_first_hand_efforts() = assertThinkingCase("subscription_first_hand_efforts")
    @Test fun DISPLAY_FACTS_relay_declared_reasoning() = assertThinkingCase("relay_declared_reasoning")

    @Test
    fun DISPLAY_FACTS_thinking_case_ids_match_the_fixture() {
        assertEquals(
            setOf(
                "official_catalog_reasoning_switchable",
                "official_catalog_no_reasoning",
                "official_catalog_miss_model_facts",
                "subscription_first_hand_efforts",
                "relay_declared_reasoning",
            ),
            cases("thinkingCases").map { it.string("id") }.toSet(),
        )
    }

    private fun assertThinkingCase(id: String) {
        val case = cases("thinkingCases").single { it.string("id") == id }
        val modelId = case.string("modelId")!!
        val source = case.getValue("source").jsonObject
        val (provider, model) = when (val form = case.string("form")) {
            "official" -> official(modelId, source)
            "subscription" -> subscription(modelId, source)
            "relay" -> relay(modelId, source)
            else -> error("unknown form $form")
        }
        val expect = case.getValue("expect").jsonObject
        val showsThinking = ModelOptionsPanelInput.showsThinking(provider, model)
        assertEquals("$id showsThinking", expect.getValue("showsThinking").jsonPrimitive.content.toBooleanStrict(), showsThinking)
        val tiers = case["tiers"].strings().orEmpty()
        assertEquals("$id thinkingRow", expect.string("thinkingRow"), thinkingRow(showsThinking, tiers))
    }

    /** Official: the catalog entry and model facts are injected through the production publish boundary; a null catalogEntry means the model is not in the catalog. */
    private fun official(modelId: String, source: JsonObject): Pair<Provider, AIModel> {
        val catalogCapabilities = source["catalogCapabilities"].strings()
        val modelFacts = source["modelFacts"]?.takeUnless { it is JsonNull }?.jsonObject
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("providers", buildJsonObject {
                    if (catalogCapabilities != null) {
                        put("openAI", buildJsonObject {
                            // Production parsing requires resolveMap to be present (an empty map means lookup by model id only).
                            put("resolveMap", JsonObject(emptyMap()))
                            put("models", buildJsonObject {
                                put(modelId, buildJsonObject { put("capabilities", source.getValue("catalogCapabilities")) })
                            })
                        })
                    }
                })
                if (modelFacts != null) {
                    put("modelFactsRevision", "sha256:display-facts")
                    put("modelFacts", buildJsonObject { put("openAI/$modelId", modelFacts) })
                }
            }.toString(),
        )
        return Provider(id = "official-openai", kind = ProviderKind.OpenAI) to AIModel(id = modelId, name = modelId)
    }

    /** Subscription: first-hand tiers live in the snapshot model's upstreamReasoningLevels; modelFacts are not injected when null. */
    private fun subscription(modelId: String, source: JsonObject): Pair<Provider, AIModel> {
        val modelFacts = source["modelFacts"]?.takeUnless { it is JsonNull }?.jsonObject
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("providers", JsonObject(emptyMap()))
                if (modelFacts != null) {
                    put("modelFactsRevision", "sha256:display-facts")
                    put("modelFacts", buildJsonObject { put("openAI/$modelId", modelFacts) })
                }
            }.toString(),
        )
        val model = AIModel(id = modelId, name = modelId, upstreamReasoningLevels = source["firstHandEfforts"].strings().orEmpty())
        return Provider(
            id = "openai-subscription",
            kind = ProviderKind.OpenAI,
            authMode = ProviderAuthMode.Subscription,
            catalogModels = listOf(model),
        ) to model
    }

    /** Relay: the capabilities the user declared on the connection. */
    private fun relay(modelId: String, source: JsonObject): Pair<Provider, AIModel> {
        val declared = source["declaredCapabilities"].strings().orEmpty()
            .mapNotNull { raw -> ModelCapability.entries.firstOrNull { it.raw == raw } }
        val model = AIModel(id = modelId, name = modelId, capabilities = declared)
        return Provider(id = "relay", kind = ProviderKind.Relay, models = listOf(model)) to model
    }

    /**
     * Three kinds of thinking row: with tiers, the production shape function gives a selectable toggle / segments; without tiers, the production read-only row shows "thinking shown, fixed" or "no thinking mode" by the display fact.
     */
    private fun thinkingRow(showsThinking: Boolean, tiers: List<String>): String {
        val selectable = tiers.isNotEmpty()
        val shape = ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Reasoning,
                presentation = if (selectable) CapabilityControlPresentation.AutomaticAvailable else CapabilityControlPresentation.Unsupported,
                availableIntents = tiers,
                selectedIntent = null,
                connection = ModelOptionCapabilityShape.ConnectionCategory.Other,
                isWritable = selectable,
                showsThinking = showsThinking,
            ),
        )
        return when {
            shape is ModelOptionCapabilityShape.Toggle || shape is ModelOptionCapabilityShape.Tiers -> "switchable"
            shape == ModelOptionCapabilityShape.Disclosure(DisclosureStatus.ShowsThinkingFixed, tappable = false) -> "fixed"
            shape is ModelOptionCapabilityShape.Disclosure && shape.status == DisclosureStatus.ModelDoesNotThink -> "none"
            else -> error("unexpected thinking row $shape")
        }
    }

    private fun cases(group: String): List<JsonObject> = fixture.getValue(group).jsonArray.map { it.jsonObject }

    private fun JsonElement?.strings(): List<String>? =
        if (this == null || this is JsonNull) null else jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.string(name: String): String? = this[name].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    private fun JsonObject.bool(name: String): Boolean? = string(name)?.toBooleanStrict()

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
