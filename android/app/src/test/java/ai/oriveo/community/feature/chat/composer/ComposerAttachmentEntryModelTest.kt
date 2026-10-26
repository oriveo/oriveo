package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import java.io.File
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Attachment menu model: each media item {shown, enabled, reason string key} is computed from the production projection
 * [resolveInputCapabilityProjections] through [ChatModelCapabilityResolver.attachmentEntryModel]; official verdicts
 * come from the real entries of the bundled snapshot bundled-metadata.v2.
 */
class ComposerAttachmentEntryModelTest {
    @Test
    fun `deepseek-v4-pro image item is visible but disabled with model absent reason`() {
        val entry = ChatModelCapabilityResolver(metadata = officialClient()).attachmentEntryModel(
            Provider(id = "official-deepseek", kind = ProviderKind.DeepSeek),
            AIModel(id = "deepseek-v4-pro", name = "deepseek-v4-pro"),
        )
        assertTrue(entry.image.shown)
        assertFalse(entry.image.enabled)
        assertEquals("capability_input_disabled_model_absent_image", entry.image.disabledReasonKey)
        assertEquals(R.string.capability_input_disabled_model_absent_image, entry.image.disabledReasonRes)
        assertFalse(entry.image.firstAttachHint)
        // The camera follows the image availability; it stays hidden on devices without a camera.
        assertTrue(entry.camera(deviceHasCamera = true).shown)
        assertFalse(entry.camera(deviceHasCamera = true).enabled)
        assertFalse(entry.camera(deviceHasCamera = false).shown)
        assertTrue(entry.showsEntry)
    }

    @Test
    fun `catalog silent model keeps item enabled with first attach hint and no reason`() {
        val entry = ChatModelCapabilityResolver(metadata = officialClient()).attachmentEntryModel(
            Provider(id = "official-groq", kind = ProviderKind.Groq),
            AIModel(id = "allam-2-7b", name = "allam-2-7b"),
        )
        assertTrue(entry.image.shown)
        assertTrue(entry.image.enabled)
        assertNull(entry.image.disabledReasonKey)
        assertTrue(entry.image.firstAttachHint)
    }

    @Test
    fun `form without projection keeps legacy hidden items`() {
        val entry = ComposerAttachmentEntryModel.from(projections = null, gate = AttachmentInputGate(image = true))
        assertTrue(entry.image.shown && entry.image.enabled)
        assertFalse(entry.video.shown)
        assertNull(entry.video.disabledReasonKey)
        assertFalse(ComposerAttachmentEntryModel.NONE.showsEntry)
    }

    private fun officialClient(): MetadataClient {
        val providers = bundledPayload().getValue("providers").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject {
                listOf("deepseek", "miniMax").forEach { key -> put(key, providers.getValue(key)) }
            })
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"attachment-entry\"") }
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
