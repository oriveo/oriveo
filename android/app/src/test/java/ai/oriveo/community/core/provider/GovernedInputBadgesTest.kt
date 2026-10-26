package ai.oriveo.community.core.provider

import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Image / file / video badges only follow the input capability projection's visible flag: they light up only when auto_available and implemented on this client,
 * unknown / unavailable do not light up, and raw capabilities are no longer passed through. The verdict comes from the real deepseek entry of the built-in snapshot bundled-metadata.v2,
 * injected into a standalone MetadataClient through the production decode / publish boundary.
 */
class GovernedInputBadgesTest {
    private val provider = Provider(id = "official-deepseek", kind = ProviderKind.DeepSeek)

    @Test
    fun `deepseek flash shows the image badge from the vision projection`() {
        val client = deepseekClient()
        val model = AIModel(id = "deepseek-flash", name = "deepseek-flash", capabilities = listOf(ModelCapability.Text))
        assertTrue(projections(model, client).vision.visible)
        assertTrue(ModelCapability.Image in badges(model, client))
    }

    @Test
    fun `capabilityControls without vision_input hides the image badge`() {
        val client = deepseekClient { models ->
            val flash = models.getValue("deepseek-flash").jsonObject
            val controls = flash.getValue("capabilityControls").jsonObject
            JsonObject(models + ("deepseek-flash" to JsonObject(flash + ("capabilityControls" to JsonObject(controls - "vision_input")))))
        }
        val model = AIModel(id = "deepseek-flash", name = "deepseek-flash", capabilities = listOf(ModelCapability.Text, ModelCapability.Image))
        assertFalse(ModelCapability.Image in badges(model, client))
    }

    @Test
    fun `deepseek v4 pro has no image badge even when raw capabilities say image`() {
        val client = deepseekClient()
        val model = AIModel(id = "deepseek-v4-pro", name = "deepseek-v4-pro", capabilities = listOf(ModelCapability.Text, ModelCapability.Image))
        assertFalse(projections(model, client).vision.visible)
        assertFalse(ModelCapability.Image in badges(model, client))
    }

    @Test
    fun `raw file and video capabilities do not pass through when the projection is unavailable`() {
        val client = deepseekClient()
        val model = AIModel(
            id = "deepseek-flash",
            name = "deepseek-flash",
            capabilities = listOf(ModelCapability.Text, ModelCapability.File, ModelCapability.Video),
        )
        val inputs = projections(model, client)
        // Precondition: in the real entry, deepseek-flash's native file / video are unavailable (with a reason), not unknown.
        assertTrue(inputs.file.toString(), inputs.file.disabledReason != null)
        assertTrue(inputs.video.toString(), inputs.video.disabledReason != null)
        val badges = badges(model, client)
        assertFalse(badges.toString(), ModelCapability.File in badges)
        assertFalse(badges.toString(), ModelCapability.Video in badges)
        assertTrue(badges.toString(), ModelCapability.Text in badges)
    }

    // ---- helpers ----

    private fun badges(model: AIModel, client: MetadataClient): Set<ModelCapability> =
        CapabilityEvidenceProductionAdapter.governedMetadataCapabilities(provider, model, metadataClient = client)

    private fun projections(model: AIModel, client: MetadataClient) =
        requireNotNull(resolveInputCapabilityProjections(provider, model, metadataClient = client))

    private fun deepseekClient(editModels: (JsonObject) -> JsonObject = { it }): MetadataClient {
        val entry = bundledPayload().getValue("providers").jsonObject.getValue("deepseek").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                put("deepseek", JsonObject(entry + ("models" to editModels(entry.getValue("models").jsonObject))))
            })
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"governed-input-badges\"") }
    }

    private fun bundledPayload(): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/model-contracts/bundled-metadata.v2.json.gz")
            if (candidate.exists()) {
                val text = GZIPInputStream(candidate.inputStream()).bufferedReader().use { it.readText() }
                return Json.parseToJsonElement(text).jsonObject
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("bundled-metadata.v2.json.gz not found")
    }
}
