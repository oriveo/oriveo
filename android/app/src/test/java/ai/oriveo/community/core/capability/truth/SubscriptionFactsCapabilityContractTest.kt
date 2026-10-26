package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityConnection
import ai.oriveo.community.core.provider.MetadataTestFixtures
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Input verdicts and reasoning tiers for the subscription form: expectations are always read from the shared fixture
 * subscription-facts.v1.json, one `SUBSCRIPTION_FACTS_<id>` test per case. Input verdicts go through
 * [SubscriptionTruthAdapter.inputVerdict] and are then projected by the table in [CapabilityEvidenceFacade.projectInputCapability];
 * tiers go through [CapabilityControlResolution.subscriptionDeclaredReasoningLevels].
 */
class SubscriptionFactsCapabilityContractTest {
    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/test-fixtures/capability/subscription-facts.v1.json").readText()).jsonObject

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test fun SUBSCRIPTION_FACTS_first_hand_image_auto() = assertInputCase("first_hand_image_auto")
    @Test fun SUBSCRIPTION_FACTS_first_hand_without_video_unavailable() = assertInputCase("first_hand_without_video_unavailable")
    @Test fun SUBSCRIPTION_FACTS_model_facts_image_auto() = assertInputCase("model_facts_image_auto")
    @Test fun SUBSCRIPTION_FACTS_model_facts_without_file_unknown() = assertInputCase("model_facts_without_file_unknown")
    @Test fun SUBSCRIPTION_FACTS_model_facts_pdf_is_file() = assertInputCase("model_facts_pdf_is_file")
    @Test fun SUBSCRIPTION_FACTS_no_source_unknown() = assertInputCase("no_source_unknown")
    @Test fun SUBSCRIPTION_FACTS_end_not_implemented_disabled() = assertInputCase("end_not_implemented_disabled")

    @Test fun SUBSCRIPTION_FACTS_first_hand_wins() = assertReasoningCase("first_hand_wins")
    @Test fun SUBSCRIPTION_FACTS_model_facts_when_first_hand_absent() = assertReasoningCase("model_facts_when_first_hand_absent")
    @Test fun SUBSCRIPTION_FACTS_none_empty() = assertReasoningCase("none_empty")

    /**
     * The subscription slug differs from the canonical id and modelFacts are registered only under the canonical id: input / reasoning /
     * tool_call / reasoning tiers are all looked up by model.id, then the canonical id (the same rule as the Web subscription-truth-adapter),
     * and a slug that cannot be found does not degrade to unknown.
     */
    @Test
    fun `subscription slug without modelFacts falls back to the canonical id for input reasoning and tool_call`() {
        val canonical = "gpt-5.5"
        val metadata = MetadataClient().apply {
            loadNetworkPayloadForTesting(
                """
                {"version":1,"contractVersion":1,"providers":{},"modelFactsRevision":"sha256:subscription-canonical",
                 "modelFacts":{"${ProviderKind.OpenAI.rawValue}/${MetadataClient.normalizeModelFactsID(canonical)}":
                   {"toolCall":true,"reasoning":true,"reasoningEfforts":["low","high"],"modalities":{"input":["text","image"]}}}}
                """.trimIndent(),
                "\"subscription-canonical\"",
            )
        }
        val model = AIModel(id = "codex-sol-sub-slug", name = "codex-sol-sub-slug", canonicalModelId = canonical)
        val provider = Provider(
            id = "11111111-1111-4111-8111-111111111111",
            kind = ProviderKind.OpenAI,
            authMode = ProviderAuthMode.Subscription,
            models = listOf(model),
        )
        // Precondition: the slug itself really is not found, otherwise the fallback is meaningless.
        assertEquals(null, metadata.modelFacts(ProviderKind.OpenAI, model.id))

        val vision = SubscriptionTruthAdapter.inputVerdict(
            provider = provider,
            model = model,
            key = CapabilityEvidenceFacade.VISION_INPUT,
            wireFamily = null,
            metadataClient = metadata,
        )
        assertEquals(CapabilityControlResolution.STATE_AUTO_AVAILABLE, vision.state)

        assertTrue(SubscriptionTruthAdapter.thinking(CapabilityTruthAdapter.FactInput(provider, model, metadata)))

        assertEquals(
            true,
            CapabilityEvidenceProductionAdapter.toolCallVerdict(provider = provider, model = model, metadataClient = metadata),
        )

        // The tier logic reads the global MetadataClient: the same payload is injected through the production publish boundary, so tiers are also found by the canonical id.
        MetadataTestFixtures.applyRaw(
            """
            {"providers":{},"modelFactsRevision":"sha256:subscription-canonical",
             "modelFacts":{"${ProviderKind.OpenAI.rawValue}/${MetadataClient.normalizeModelFactsID(canonical)}":
               {"reasoning":true,"reasoningEfforts":["low","high"]}}}
            """.trimIndent(),
        )
        assertEquals(
            listOf("low", "high"),
            CapabilityControlResolution.subscriptionDeclaredReasoningLevels(ProviderKind.OpenAI, model),
        )
    }

    @Test
    fun SUBSCRIPTION_FACTS_case_ids_match_the_fixture() {
        assertEquals(
            setOf(
                "first_hand_image_auto",
                "first_hand_without_video_unavailable",
                "model_facts_image_auto",
                "model_facts_without_file_unknown",
                "model_facts_pdf_is_file",
                "no_source_unknown",
                "end_not_implemented_disabled",
            ),
            cases("inputCases").map { it.string("id") }.toSet(),
        )
        assertEquals(
            setOf("first_hand_wins", "model_facts_when_first_hand_absent", "none_empty"),
            cases("reasoningLevelCases").map { it.string("id") }.toSet(),
        )
    }

    private fun assertInputCase(id: String) {
        val case = case("inputCases", id)
        val key = case.string("key")!!
        val verdict = SubscriptionTruthAdapter.inputVerdict(
            key = key,
            firstHand = case["firstHand"].stringsOrNull(),
            modelFacts = case["modelFacts"].stringsOrNull(),
            wireFamily = null,
        )
        val expect = case.getValue("expect").jsonObject
        assertEquals("$id state", expect.string("state"), verdict.state)
        expect.string("reasonCode")?.let { assertEquals("$id reasonCode", it, verdict.reasonCode) }

        val projection = CapabilityEvidenceFacade.projectInputCapability(
            key = key,
            verdict = verdict,
            endImplements = case.getValue("endImplements").jsonPrimitive.content.toBooleanStrict(),
            override = null,
            negativeCacheHit = false,
            connection = InputCapabilityConnection.OFFICIAL,
        )
        assertEquals("$id visible", expect.bool("visible"), projection.visible)
        assertEquals("$id editable", expect.bool("editable"), projection.editable)
        assertEquals("$id outbound", expect.string("outbound"), Json.encodeToJsonElement(
            CapabilityEvidenceFacade.InputCapabilityOutbound.serializer(), projection.outbound,
        ).jsonPrimitive.content)
        expect.string("disabledReason")?.let { reason ->
            assertEquals("$id disabledReason", reason, projection.disabledReason?.let {
                Json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityDisabledReason.serializer(), it).jsonPrimitive.content
            })
        }
    }

    /** Injects modelFacts into the global MetadataClient through the production publish boundary (the tier logic reads it); the first-hand declaration lives in the model's upstreamReasoningLevels. */
    private fun assertReasoningCase(id: String) {
        val case = case("reasoningLevelCases", id)
        val modelId = "gpt-5.5"
        val facts = case["modelFactsEfforts"].stringsOrNull()
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("providers", JsonObject(emptyMap()))
                if (facts != null) {
                    put("modelFactsRevision", "sha256:subscription-facts")
                    put("modelFacts", buildJsonObject {
                        put("openAI/$modelId", buildJsonObject {
                            put("reasoning", true)
                            put("reasoningEfforts", JsonArray(facts.map { kotlinx.serialization.json.JsonPrimitive(it) }))
                        })
                    })
                }
            }.toString(),
        )
        val model = AIModel(
            id = modelId,
            name = modelId,
            upstreamReasoningLevels = case["firstHandEfforts"].stringsOrNull().orEmpty(),
        )
        val expect = case.getValue("expect").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(id, expect, CapabilityControlResolution.subscriptionDeclaredReasoningLevels(ProviderKind.OpenAI, model))
    }

    private fun cases(group: String): List<JsonObject> = fixture.getValue(group).jsonArray.map { it.jsonObject }

    private fun case(group: String, id: String): JsonObject = cases(group).single { it.string("id") == id }

    private fun JsonElement?.stringsOrNull(): List<String>? =
        if (this == null || this is JsonNull) null else jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.string(name: String): String? = this[name].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    private fun JsonObject.bool(name: String): Boolean = getValue(name).jsonPrimitive.content.toBooleanStrict()

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
