package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.ui.theme.OriveoMotion
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Motion for the model options panel and its two secondary pages.
 *
 * The intent pills switch by toggling their fill rather than animating a moving indicator (a
 * row of wrapping pills has no single fixed track to slide along). The secondary page push /
 * pop transition is 250ms, and both must genuinely honor `isReduceMotionEnabled`: when reduce
 * motion is on, the transition has no animation at all, not just a faster curve.
 */
class ModelControlMotionTest {

    @Test
    fun `motion durations match the visual spec`() {
        assertEquals(180, OriveoMotion.modelControlSegmentMillis)
        assertEquals(250, OriveoMotion.modelControlPageMillis)
    }

    /** When `ANIMATOR_DURATION_SCALE == 0`, every duration must actually be zero. This drives the production pure function directly rather than inspecting source. */
    @Test
    fun `reduce motion zeroes every model control duration`() {
        assertEquals(0, OriveoMotion.modelControlSegmentMillis(reduceMotion = true))
        assertEquals(0, OriveoMotion.modelControlPageMillis(reduceMotion = true))
        assertEquals(180, OriveoMotion.modelControlSegmentMillis(reduceMotion = false))
        assertEquals(250, OriveoMotion.modelControlPageMillis(reduceMotion = false))
    }

    /**
     * The selected state on the intent pills is a fill toggle, not a moving indicator. Animating
     * a moving indicator would send pills flying sideways whenever a wrapping row reflows --
     * which is exactly the assumption (a single fixed track) that no longer holds for a row of
     * wrapping pills.
     */
    @Test
    fun `the intent pills switch fill instead of animating a moving indicator`() {
        val body = composableBody(componentsSource(), "internal fun ModelControlIntentPicker(")
        listOf("animateFloatAsState", "animateDpAsState", "graphicsLayer", "drawBehind", "offset(")
            .forEach { symbol ->
                assertFalse("the pill must not carry a translation/scale animation ($symbol)", body.contains(symbol))
            }
        assertTrue("wrapping is handled by FlowRow, so RTL doesn't need manually flipped coordinates", body.contains("FlowRow("))
    }

    @Test
    fun `both page containers animate at the page duration and honour reduce motion`() {
        listOf(
            "model options panel" to sheetSource(),
            "advanced settings page" to generationSheetSource(),
        ).forEach { (label, source) ->
            assertTrue("$label's secondary page must push in via AnimatedContent", source.contains("AnimatedContent("))
            assertTrue(
                "$label's transition duration must come from OriveoMotion as the single source of truth",
                source.contains("OriveoMotion.modelControlPageMillis("),
            )
            assertTrue(
                "$label must reuse the existing isReduceMotionEnabled, not write another copy that reads ANIMATOR_DURATION_SCALE",
                source.contains("isReduceMotionEnabled(") && !source.contains("ANIMATOR_DURATION_SCALE"),
            )
            assertTrue(
                "$label's container-height SizeTransform must use the same duration too, or that part would still bounce",
                source.contains("SizeTransform { _, _ -> tween("),
            )
        }
    }

    /** The scope upgrade row's visibility also honors reduce motion -- it's feedback for the instant something "just changed", and shouldn't still fade in when animations are turned off. */
    @Test
    fun `the scope upgrade row fades with the same reduce motion aware duration`() {
        val source = sheetSource()
        val block = source.substringAfter("visible = showsScopeUpgrade && route == null")
            .substringBefore("ModelControlScopeUpgradeRow(")
        assertTrue(block.contains("fadeIn(tween(pageMillis))"))
        assertTrue(block.contains("fadeOut(tween(pageMillis))"))
        assertTrue(source.contains("val pageMillis = OriveoMotion.modelControlPageMillis(reduceMotion)"))
    }

    private fun composableBody(source: String, signature: String): String {
        val start = source.indexOf(signature)
        assertTrue("could not find $signature", start >= 0)
        val end = source.indexOf("\n}", start)
        assertTrue("$signature's function body never closes", end > start)
        return source.substring(start, end)
    }

    private fun componentsSource(): String = repoFile("feature/chat/composer/ModelControlsComponents.kt").readText()

    private fun sheetSource(): String = repoFile("feature/chat/composer/ModelControlsSheet.kt").readText()

    private fun generationSheetSource(): String =
        repoFile("feature/providers/detail/GenerationParameterDefaultsSheet.kt").readText()

    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("could not find $relative (searched upward from ${System.getProperty("user.dir")})")
    }
}
