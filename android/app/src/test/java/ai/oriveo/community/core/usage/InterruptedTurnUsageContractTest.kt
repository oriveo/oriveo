package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.DeliveredCostResolver
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * interrupted-turn.v1 (BYOK paths): the stopped leg estimate plus finished legs, fed to the existing cost
 * derivation with a priced model.
 */
class InterruptedTurnUsageContractTest {

    private val cases: Map<String, JsonObject> by lazy {
        val root = Json.parseToJsonElement(workspaceFile("shared/test-fixtures/provider-usage/interrupted-turn.v1.json").readText()).jsonObject
        assertEquals("oriveo.fixture.interrupted-turn/v1", root["schema"]!!.jsonPrimitive.content)
        root["cases"]!!.jsonArray.map { it.jsonObject }.associateBy { it["id"]!!.jsonPrimitive.content }
            .also { assertEquals(13, it.size) }
    }

    private val model = AIModel(id = "gpt-test", name = "GPT Test", promptPrice = 0.000002, completionPrice = 0.000008)

    // A custom endpoint prices from the model's own prices without a catalog entry.
    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "sk-test",
        endpointSource = OfficialEndpointSource.CUSTOM,
        models = listOf(model),
    )

    @Test fun interrupted_turn_stopped_with_text() = check("stopped-with-text", "byok")

    @Test fun interrupted_turn_stopped_with_reasoning_and_text() = check("stopped-with-reasoning-and-text", "byok")

    @Test fun interrupted_turn_stopped_before_output() = check("stopped-before-output", "byok")

    @Test fun interrupted_turn_stopped_without_input_estimate() = check("stopped-without-input-estimate", "byok")

    @Test fun interrupted_turn_stopped_after_reported_leg() = check("stopped-after-reported-leg", "byok")

    @Test fun interrupted_turn_stopped_before_output_after_reported_leg() = check("stopped-before-output-after-reported-leg", "byok")

    @Test fun interrupted_turn_trial_stopped_with_text() = check("trial-stopped-with-text", "trial")

    @Test fun interrupted_turn_stopped_without_input_estimate_after_reported_leg() =
        check("stopped-without-input-estimate-after-reported-leg", "byok")

    @Test fun interrupted_turn_stopped_after_leg_separator() = check("stopped-after-leg-separator", "byok")

    private fun check(id: String, path: String) {
        val case = cases.getValue(id)
        assertEquals(path, case["path"]!!.jsonPrimitive.content)
        val input = case["input"]!!.jsonObject
        val expect = case["expect"]!!.jsonObject
        val finishedLegs = input["finishedLegs"]?.jsonArray.orEmpty().map { leg ->
            val o = leg.jsonObject
            ProviderChatResult(
                text = "",
                promptTokens = o["inputTokens"]!!.jsonPrimitive.intOrNull!!,
                completionTokens = o["outputTokens"]!!.jsonPrimitive.intOrNull!!,
                usageReported = o["usageReported"]!!.jsonPrimitive.booleanOrNull!!,
            )
        }

        val usage = InterruptedTurnUsage.result(
            estimatedInput = input["estimatedInput"].intOrNull(),
            rhoHi = input["rhoHi"]!!.jsonPrimitive.doubleOrNull!!,
            // The stopped leg's share of what is shown, through the production leg split.
            visibleText = InterruptedTurnUsage.stoppedLegText(
                input["visibleText"]!!.jsonPrimitive.content,
                shownBefore = input["shownBefore"]?.jsonPrimitive?.content.orEmpty(),
            ),
            reasoningText = InterruptedTurnUsage.stoppedLegText(input["reasoningText"]!!.jsonPrimitive.content, shownBefore = ""),
            finishedLegs = finishedLegs,
        )

        val recorded = expect["recorded"]!!.jsonPrimitive.booleanOrNull!!
        assertEquals("$id recorded", recorded, usage != null)
        assertEquals("$id inputTokens", expect["inputTokens"].intOrNull(), usage?.let(InterruptedTurnUsage::inputTokens))
        assertEquals("$id outputTokens", expect["outputTokens"].intOrNull(), usage?.completionTokens)
        assertEquals(
            "$id skillManifestTokens",
            expect["skillManifestTokens"].intOrNull(),
            InterruptedTurnUsage.manifestTokens(usage, input["skillManifestTokens"].intOrNull()),
        )

        // Cost through the production derivation; nothing recorded means cost unknown (never 0).
        val costSource = usage?.let {
            DeliveredCostResolver.record(
                DeliveredCostResolver.resolveParts(
                    result = InterruptedTurnUsage.pricingResult(it),
                    model = model,
                    provider = provider,
                    modelId = model.id,
                    at = Instant.parse("2026-11-02T00:00:00Z"),
                ),
            ).costSource
        } ?: CostSource.UNKNOWN.name
        val expectedSource = when (val wire = expect["costSource"]!!.jsonPrimitive.content) {
            "localEstimate" -> CostSource.LOCAL_ESTIMATE.name
            "unknown" -> CostSource.UNKNOWN.name
            else -> error("unexpected costSource $wire")
        }
        assertEquals("$id costSource", expectedSource, costSource)
        if (!recorded) assertNull("$id no usage", usage)
    }

    private fun JsonElement?.intOrNull(): Int? = if (this == null || this is JsonNull) null else jsonPrimitive.intOrNull

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("missing $relative")
    }
}
