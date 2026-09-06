package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelCapabilityTest {

    @Test
    fun `titleResId returns correct values for all capabilities`() {
        assertEquals(ai.oriveo.community.R.string.capability_reasoning, ModelCapability.Reasoning.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_text, ModelCapability.Text.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_image, ModelCapability.Image.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_video, ModelCapability.Video.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_file, ModelCapability.File.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_web, ModelCapability.Web.titleResId)
        assertEquals(ai.oriveo.community.R.string.capability_image_gen, ModelCapability.ImageGen.titleResId)
    }

    @Test
    fun `titleResId covers all enum values`() {
        ModelCapability.entries.forEach { cap ->
            assertTrue("titleResId should be positive for $cap", cap.titleResId > 0)
        }
    }

    @Test
    fun `iconName returns valid icon name for all capabilities`() {
        assertEquals("psychology", ModelCapability.Reasoning.iconName)
        assertEquals("notes", ModelCapability.Text.iconName)
        assertEquals("image", ModelCapability.Image.iconName)
        assertEquals("videocam", ModelCapability.Video.iconName)
        assertEquals("description", ModelCapability.File.iconName)
        assertEquals("language", ModelCapability.Web.iconName)
        assertEquals("brush", ModelCapability.ImageGen.iconName)
    }

    @Test
    fun `iconName covers all enum values`() {
        ModelCapability.entries.forEach { cap ->
            assertTrue("iconName should not be empty for $cap", cap.iconName.isNotEmpty())
        }
    }

    @Test
    fun `capabilities include NativePdf and Unknown`() {

        assertTrue(ModelCapability.entries.size >= 9)
        assertTrue(ModelCapability.entries.any { it == ModelCapability.NativePdf })
        assertTrue(ModelCapability.entries.any { it == ModelCapability.Unknown })
    }
}
