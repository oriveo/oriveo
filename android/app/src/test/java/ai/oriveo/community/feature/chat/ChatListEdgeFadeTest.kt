package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The chat page bottom no longer paints a background scrim; the message list fades out through an alpha mask. */
class ChatListEdgeFadeTest {

    @Test
    fun `composer tier alpha by distance above composer top`() {
        assertEquals(1f, ChatListEdgeFade.composerAlpha(60f), 0.001f)
        assertEquals(1f, ChatListEdgeFade.composerAlpha(40f), 0.001f)
        assertEquals(0.5f, ChatListEdgeFade.composerAlpha(22f), 0.02f)
        assertEquals(0f, ChatListEdgeFade.composerAlpha(4f), 0.001f)
        assertEquals(0f, ChatListEdgeFade.composerAlpha(-10f), 0.001f)
    }

    @Test
    fun `stage tier fades the top 30 percent with smoothstep`() {
        assertEquals(0f, ChatListEdgeFade.stageTopAlpha(0f), 0.001f)
        // smoothstep(0.25) = 3 * 0.0625 - 2 * 0.015625 = 0.15625, not the linear 0.25
        assertEquals(0.15625f, ChatListEdgeFade.stageTopAlpha(0.075f), 0.001f)
        assertEquals(0.5f, ChatListEdgeFade.stageTopAlpha(0.15f), 0.001f)
        assertEquals(1f, ChatListEdgeFade.stageTopAlpha(0.3f), 0.001f)
        assertEquals(1f, ChatListEdgeFade.stageTopAlpha(0.8f), 0.001f)
    }

    @Test
    fun `mask alpha combines composer tier with stage tier weighted by stage progress`() {
        val density = 2f
        val height = 1000f
        val overlay = 200f
        // Visible area is 800 px; the composer top is at y = 800.
        val farFromBoth = ChatListEdgeFade.maskAlphaAt(y = 500f, heightPx = height, overlayPx = overlay, density = density, stage = 1f)
        assertEquals(1f, farFromBoth, 0.001f)
        // 22 dp (44 px) above the composer top
        assertEquals(0.5f, ChatListEdgeFade.maskAlphaAt(756f, height, overlay, density, stage = 0f), 0.02f)
        // Fully transparent below the composer top
        assertEquals(0f, ChatListEdgeFade.maskAlphaAt(900f, height, overlay, density, stage = 0f), 0.001f)
        // Stage not yet entered: the top edge does not fade
        assertEquals(1f, ChatListEdgeFade.maskAlphaAt(0f, height, overlay, density, stage = 0f), 0.001f)
        // Stage fully entered: top edge is 0; at 15% of the visible area it is 0.5
        assertEquals(0f, ChatListEdgeFade.maskAlphaAt(0f, height, overlay, density, stage = 1f), 0.001f)
        assertEquals(0.5f, ChatListEdgeFade.maskAlphaAt(120f, height, overlay, density, stage = 1f), 0.001f)
        // Stage half entered: the top edge linearly blends between 1 and 0
        assertEquals(0.5f, ChatListEdgeFade.maskAlphaAt(0f, height, overlay, density, stage = 0.5f), 0.001f)
    }

    @Test
    fun `composer surface no longer paints a page color scrim`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
        val start = source.indexOf("val composerSurfaceModifier")
        val block = source.substring(start, source.indexOf("Box(modifier = composerSurfaceModifier)", start))
        assertFalse(block, block.contains("drawBehind"))
        assertFalse(block, block.contains("colors.background"))
        assertFalse(block, block.contains(".background("))
    }

    @Test
    fun `voice stage panel is transparent`() {
        val source = File("src/main/java/ai/oriveo/community/feature/chat/voice/VoiceConversationBar.kt").readText()
        val start = source.indexOf("internal fun VoiceStagePanel(")
        val block = source.substring(start, source.indexOf("VoiceAuroraFog(", start))
        assertFalse(block, block.contains("drawBehind"))
        assertFalse(block, block.contains("colors.background"))
        assertFalse(block, block.contains(".background("))
    }
}
