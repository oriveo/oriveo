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

    private val webCard by lazy {
        sheet.substringAfter("private fun ModelControlWebCard(").substringBefore("private fun ModelControlReasoningCard(")
    }
    private val reasoningCard by lazy {
        sheet.substringAfter("private fun ModelControlReasoningCard(").substringBefore("private fun ModelControlStatusRowFor(")
    }

    /** The web card consumes every field [ModelControlWebLayout] produces; none may be dropped in the render layer. */
    @Test
    fun `the web card renders every field the layout produces`() {
        assertTrue(webCard.contains("ModelControlWebLayout.layout("))
        listOf(
            "layout.isOn",
            "layout.captionRes",
            "layout.timingOptions",
            "layout.timingSelection",
            "layout.statusTextRes",
            "layout.explanationRes",
            "layout.escape",
        ).forEach { assertTrue("web card did not wire up $it", webCard.contains(it)) }
        assertTrue("both forms need a real branch", webCard.contains("ModelControlWebLayout.Form.Toggle") &&
            webCard.contains("ModelControlWebLayout.Form.StatusRow"))
        assertFalse(
            "must not unconditionally flatten to all three tiers (force is only available on a subset of models)",
            webCard.contains("CapabilityWebPreference.Force,"),
        )
        assertFalse("the fallback expectation copy has been retired", layout.contains("model_control_web_auto_expectation"))
    }

    /** Same for the reasoning card; and the kill switch must be verifiable at the source level. */
    @Test
    fun `the reasoning card renders pills and its caption, with no switch left`() {
        assertTrue(reasoningCard.contains("ModelControlReasoningLayout.layout("))
        listOf(
            "layout.options",
            "layout.selection",
            "layout.selectedAnnotationRes",
            "layout.footnoteRes",
            "layout.statusTextRes",
            "layout.explanationRes",
            "layout.escape",
        ).forEach { assertTrue("reasoning card did not wire up $it", reasoningCard.contains(it)) }
        assertTrue(reasoningCard.contains("ModelControlIntentPicker("))
        assertFalse("the \"deep thinking\" switch has been removed", sheet.contains("model_control_reasoning_switch"))
        assertFalse("the old three-way segmented control has been retired", sheet.contains("ModelControlSegmented("))
        assertFalse("\"max\" is no longer a secondary entry point, it's an ordinary pill", sheet.contains("SecondaryTier"))
        assertTrue("the reasoning card carries no switch", reasoningCard.contains("toggle = null"))
    }

    /** The footer pure function is consumed by both cards, and they pass the same set of input fields. */
    @Test
    fun `both cards feed the shared footer with the same inputs`() {
        assertEquals(
            // The third consumer is the advanced-settings page header -- its status and fallback
            // copy can't just disappear, while the main panel row only shows title / status /
            // chevron. There is still only one implementation (the pure function `entries`); this
            // counts call sites.
            "the footer must have exactly one implementation: shared by both capability cards plus the advanced-settings page header",
            3,
            Regex("""ModelControlCapabilityFooter\.entries\(""").findAll(sheet).count(),
        )
        listOf(
            "readOnlyReasonRes = readOnlyReasonRes",
            "isConfigurable = status.isConfigurable",
            "statusTextRes = modelControlStatusTextRes(status)",
            "upstreamRejected = upstreamRejected",
            "riskTiers = riskTiers",
            "showsSupportedModelsAction = modelControlShowsSupportedModelsAction(status)",
            "showsAdvancedSettingsAction = overridden",
            "statusRowEscape =",
        ).forEach { assertTrue("footer input missing $it", webCard.contains(it) && reasoningCard.contains(it)) }
        // All three entry kinds must have a render branch, or a whole category the pure function produces silently vanishes.
        val footerView = sheet.substringAfter("private fun ModelControlCapabilityFooterView(")
            .substringBefore("private fun modelControlNoteIcon(")
        listOf(
            "ModelControlCapabilityFooter.Entry.Note ->",
            "ModelControlCapabilityFooter.Entry.SupportedModelsLink ->",
            "ModelControlCapabilityFooter.Entry.AdvancedSettingsLink ->",
        ).forEach { assertTrue("footer render missing $it", footerView.contains(it)) }
        assertTrue("an empty footer renders no zero-height container", footerView.contains("if (entries.isEmpty()) return"))
    }

    /**
     * Badges go through two separate projections: capability cards suppress "unavailable",
     * while the advanced-settings row suppresses "not ready".
     *
     * Nowhere in the panel may directly consume the un-suppressed `resolve(_)` -- doing so lets a
     * relay or a model with no `capabilityControls.generation` payload show a spurious "not ready"
     * badge on the pushed row, and that badge swallows the entire "N adjusted" line with it.
     * Per-tier judgment lives in `ModelControlCapabilityLayoutRulesTest`.
     */
    @Test
    fun `capability cards and the pushed row use different badge projections`() {
        assertEquals(
            2,
            Regex("""ModelControlBadgeClassification\.capabilityCard\(""").findAll(sheet).count(),
        )
        assertEquals(
            1,
            Regex("""ModelControlBadgeClassification\.advancedSettingsCard\(""").findAll(sheet).count(),
        )
        assertEquals(
            "the panel must not have any un-suppressed resolve consumption left",
            0,
            Regex("""ModelControlBadgeClassification\.resolve\(""").findAll(sheet).count(),
        )
    }

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

    /** The model list's capability badges and filter chips must reuse the single existing decision function, not add a second one. */
    @Test
    fun `the model picker badges and filters reuse the single capability decision function`() {
        assertTrue(picker.contains("modelPickerCapabilityBadges("))
        assertTrue(picker.contains("modelPickerCapabilityFilterCounts("))
        val badgeSource = repoFile("feature/modelpicker/ModelPickerCapabilityFilter.kt").readText()
        assertTrue(badgeSource.contains("CapabilityControlResolution.resolve("))
        assertTrue(picker.contains("R.string.model_picker_capability_filter_empty"))
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
