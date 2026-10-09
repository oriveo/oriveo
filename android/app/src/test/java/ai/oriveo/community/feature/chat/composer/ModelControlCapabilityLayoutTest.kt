package ai.oriveo.community.feature.chat.composer

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Wiring red line for the layout pure functions (semantics assertions live in
 * [ModelControlCapabilityLayoutRulesTest]).
 *
 * This locks exactly one thing: the pure functions are actually consumed by the production UI,
 * and every field they produce is consumed. The earlier lesson was that the semantics were
 * written correctly but the screen was never wired to them -- the pure-function unit tests were
 * all green while the user still saw the old layout.
 */
class ModelControlCapabilityLayoutTest {
    private val sheet by lazy { repoFile("feature/chat/composer/ModelControlsSheet.kt").readText() }
    private val components by lazy { repoFile("feature/chat/composer/ModelControlsComponents.kt").readText() }
    private val layout by lazy { repoFile("feature/chat/composer/ModelControlCapabilityLayout.kt").readText() }
    private val picker by lazy { repoFile("feature/modelpicker/ModelPickerSheet.kt").readText() }

    /** The presentation state comes from a single projection; the panel no longer judges availability off a raw state string. */
    @Test
    fun `the panel consumes the single presentation projection`() {
        assertTrue(sheet.contains("CapabilityControlPresentationResolver.presentation(provider, model, capability, metadata, finalTransport)"))
        assertFalse(
            "the panel must not write a second availability check against a raw state string",
            sheet.contains("\"auto_available\" ||") || sheet.contains("modelControlCapabilityAvailable("),
        )
        assertFalse(
            "the old reasonCode-to-copy mapping has been retired; reasonCode now only participates in classification",
            sheet.contains("modelControlReasonMessage("),
        )
    }

    /** Disabled visuals only change color, never crush opacity; pill and badge intensity are pure functions a contrast test can pull. */
    @Test
    fun `the visual components expose their alphas instead of hiding literals`() {
        assertTrue(components.contains("internal fun modelControlUnselectedPillAlpha(isDark: Boolean)"))
        assertTrue(components.contains("internal fun modelControlBadgeCapsuleAlpha(isDark: Boolean)"))
        assertFalse(
            "disabled state must not crush the whole layer's opacity",
            Regex("""\.alpha\(0\.[0-9]+f?\)""").containsMatchIn(components),
        )
        assertFalse("cards have no outline and no backing plate", components.contains(".border("))
    }

    /**
     * The model list's filter chips must reuse the single existing decision function, not add a second one.
     * Row badges now use the same projection as provider detail (see ModelRowCapabilityContractTest)
     * instead of a separate set of pills.
     */
    @Test
    fun `the model picker badges and filters reuse the single capability decision function`() {
        assertFalse(picker.contains("modelPickerCapabilityBadges("))
        assertTrue(picker.contains("modelPickerCapabilityFilterCounts("))
        val badgeSource = repoFile("feature/modelpicker/ModelPickerCapabilityFilter.kt").readText()
        assertTrue(badgeSource.contains("fun modelPickerCapabilityBadges("))
        assertTrue(badgeSource.contains("CapabilityControlResolution.resolve("))
        assertTrue(picker.contains("R.string.model_picker_capability_filter_empty"))
    }

    /**
     * The capability cards are `ModelOptionCapabilityRow`s whose shape comes only from `ModelOptionCapabilityShape.resolve`;
     * the older web-search / thinking cards and their badge projections are gone.
     */
    @Test
    fun `capability rows render only what the shape function resolves`() {
        assertTrue(sheet.contains("val webShape = ModelOptionCapabilityShape.resolve("))
        assertTrue(sheet.contains("val reasoningShape = ModelOptionCapabilityShape.resolve("))
        assertTrue(sheet.contains("ModelOptionCapabilityRow(ModelOptionCapabilityShape.Capability.Web, webShape, webActions)"))
        assertTrue(sheet.contains("ModelOptionCapabilityRow(ModelOptionCapabilityShape.Capability.Reasoning, reasoningShape, reasoningActions)"))
        listOf("private fun ModelControlWebCard(", "private fun ModelControlReasoningCard(", "private fun modelControlBadge(")
            .forEach { assertTrue("the old component is unreferenced and should be deleted: $it", !sheet.contains(it)) }
        // Notes about takeover, rejection and risk tiers still go through the shared footer.
        assertTrue(sheet.contains("ModelControlCapabilityFooterView(capability = capability, entries = entries, onRoute = ::openRoute)"))
    }

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
        error("cannot find $relative")
    }
}
