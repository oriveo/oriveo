package ai.oriveo.community.feature.chat

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSyncFields
import ai.oriveo.community.core.model.UsedSkill
import ai.oriveo.community.core.skills.SkillGlyphs
import ai.oriveo.community.core.telemetry.TelemetryEvent
import ai.oriveo.community.feature.chat.components.SkillUsedCard
import ai.oriveo.community.feature.chat.components.SkillUsedChipLabel
import ai.oriveo.community.feature.chat.composer.SkillPickerCache
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Locale
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** P4 contracts 22 / 23 / 27: skill lines on chat messages and the used-skill card. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SkillUsageLabelsTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val weeklyId = "11111111-1111-1111-1111-111111111111"
    private val polishId = "22222222-2222-2222-2222-222222222222"
    private val templateId = "33333333-3333-3333-3333-333333333333"
    private val deletedId = "44444444-4444-4444-4444-444444444444"

    private val weekly = Skill(id = weeklyId, name = "Weekly report", systemPrompt = "Sort the week.", iconKey = "glyph:code")
    private val polish = Skill(id = polishId, name = "Polish", systemPrompt = "Polish it.")
    private val template = Skill(id = templateId, name = "Translator", systemPrompt = "Translate.")

    private val cache = SkillPickerCache(mine = listOf(weekly, polish), templates = listOf(template))

    @Test
    fun `attached names come from the cache and unknown ids are skipped`() {
        val ids = listOf(weeklyId, deletedId, templateId.lowercase())
        assertEquals(listOf("Weekly report", "Translator"), SkillUsageLabels.attachedNames(ids, cache))
        assertEquals("Weekly report and Translator", SkillUsageLabels.attachedList(ids, cache, Locale.US))
    }

    @Test
    fun `attached line is hidden when no name resolves or the cache is not loaded`() {
        assertNull(SkillUsageLabels.attachedList(listOf(deletedId), cache, Locale.US))
        assertNull(SkillUsageLabels.attachedList(listOf(weeklyId), null, Locale.US))
        assertNull(SkillUsageLabels.attachedList(emptyList(), cache, Locale.US))
    }

    @Test
    fun `attached list follows the app language list format`() {
        val ids = listOf(weeklyId, polishId, templateId)
        assertEquals("Weekly report, Polish, and Translator", SkillUsageLabels.attachedList(ids, cache, Locale.US))
        val chinese = SkillUsageLabels.attachedList(ids, cache, Locale.SIMPLIFIED_CHINESE)
        assertEquals("Weekly report\u3001Polish\u548cTranslator", chinese)
    }

    @Test
    fun `used chip joins names with plus and takes the first icon`() {
        val used = listOf(
            UsedSkill(id = weeklyId, name = "Old name", via = "manual"),
            UsedSkill(id = deletedId, name = "Gone", via = "auto", reason = "fits"),
        )
        val chip = SkillUsageLabels.chip(used, streaming = false, userAttachedIds = emptyList(), cache = cache)
        assertEquals(SkillUsageLabels.Chip.Used(names = "Weekly report + Gone", iconKey = SkillGlyphs.resolve(weekly)), chip)
    }

    @Test
    fun `streaming reply with no used skills shows the attached skills as loading`() {
        val attached = listOf(weeklyId, polishId)
        assertEquals(
            SkillUsageLabels.Chip.Loading("Weekly report + Polish"),
            SkillUsageLabels.chip(emptyList(), streaming = true, userAttachedIds = attached, cache = cache),
        )
        assertNull(SkillUsageLabels.chip(emptyList(), streaming = false, userAttachedIds = attached, cache = cache))
        assertNull(SkillUsageLabels.chip(emptyList(), streaming = true, userAttachedIds = emptyList(), cache = cache))
        assertNull(SkillUsageLabels.chip(emptyList(), streaming = true, userAttachedIds = listOf(deletedId), cache = cache))
    }

    @Test
    fun `auto items offer disable and view while manual items only offer view`() {
        val used = listOf(
            UsedSkill(id = polishId, name = "Polish", via = "manual"),
            UsedSkill(id = weeklyId, name = "Weekly report", via = "auto", reason = " You pasted a week of notes. "),
        )
        val items = SkillUsageLabels.items(used, cache, disabledAutoSkillIds = emptyList())
        assertEquals(
            listOf(
                SkillUsageLabels.Item(polishId, "Polish", auto = false, reason = null, canDisable = false, canView = true),
                SkillUsageLabels.Item(
                    weeklyId,
                    "Weekly report",
                    auto = true,
                    reason = "You pasted a week of notes.",
                    canDisable = true,
                    canView = true,
                ),
            ),
            items,
        )
    }

    @Test
    fun `a single item carries no name and a deleted skill has no view`() {
        val single = SkillUsageLabels.items(listOf(UsedSkill(deletedId, "Gone", "auto", "fits")), cache, emptyList()).single()
        assertNull(single.name)
        assertTrue(single.canDisable)
        assertFalse(single.canView)
        val unloaded = SkillUsageLabels.items(listOf(UsedSkill(weeklyId, "Weekly report", "manual")), null, emptyList()).single()
        assertFalse(unloaded.canView)
    }

    @Test
    fun `disabling here calls disableAutoSkill and the disable button goes away`() = runTest {
        val used = listOf(UsedSkill(id = weeklyId, name = "Weekly report", via = "auto", reason = "fits"))
        var stored = emptyList<String>()
        val calls = mutableListOf<String>()
        val tracked = mutableListOf<Pair<TelemetryEvent, Map<String, Any?>>>()

        val next = SkillUsageLabels.disableHere(
            skillId = weeklyId,
            disable = { id ->
                calls += id
                SkillSyncFields.appendDisabledAutoSkill(stored, id).also { stored = it }
            },
            track = { event, props -> tracked += event to props },
        )

        assertEquals(listOf(weeklyId), calls)
        assertEquals(listOf(TelemetryEvent.SkillAutoDisabledInConversation to mapOf<String, Any?>("skill_id" to weeklyId)), tracked)
        val item = SkillUsageLabels.items(used, cache, next.orEmpty()).single()
        assertFalse(item.canDisable)
        assertTrue(item.canView)
    }

    @Test
    fun `disabling a conversation that no longer exists sends nothing`() = runTest {
        val tracked = mutableListOf<TelemetryEvent>()
        val next = SkillUsageLabels.disableHere(weeklyId, disable = { null }, track = { event, _ -> tracked += event })
        assertNull(next)
        assertTrue(tracked.isEmpty())
    }

    @Test
    @Config(qualifiers = "de")
    fun header_truncates_names_before_verb() {
        val names = "My writing tone + Weekly report"
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Box(Modifier.width(140.dp)) {
                    SkillUsedChipLabel(labelRes = R.string.skills_used_chip, names = names)
                }
            }
        }
        composeRule.waitForIdle()

        val namesLayout = layoutOf(names)
        assertTrue("names should be ellipsized in a narrow chip", namesLayout.isLineEllipsized(0))
        val verbLayout = layoutOf(" verwendet")
        assertEquals(" verwendet", verbLayout.layoutInput.text.text)
        assertFalse("verb must stay whole", verbLayout.isLineEllipsized(0))
        assertEquals("verb must stay on one line", 1, verbLayout.lineCount)
        assertEquals("verb must show its last character", " verwendet".length, verbLayout.getLineEnd(0))
        val right = verbLayout.getLineRight(0)
        val width = verbLayout.size.width
        assertTrue("verb right edge $right must fit its width $width", right <= width + 0.5f)
    }

    @Test
    fun used_card_actions_stack_when_narrow() {
        val item = SkillUsageLabels.Item(weeklyId, null, auto = true, reason = "fits", canDisable = true, canView = true)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Box(Modifier.width(140.dp)) {
                    SkillUsedCard(items = listOf(item), onDisable = {}, onView = {})
                }
            }
        }
        composeRule.waitForIdle()

        val disableText = activity.getString(R.string.skills_used_disableHere)
        val viewText = activity.getString(R.string.skills_used_view)
        val disable = composeRule.onNodeWithText(disableText).fetchSemanticsNode().boundsInRoot
        val view = composeRule.onNodeWithText(viewText).fetchSemanticsNode().boundsInRoot
        val limit = with(composeRule.density) { 140.dp.toPx() } + 0.5f
        assertTrue("view button ($view) must sit below the disable button ($disable)", view.top >= disable.bottom)
        assertTrue("disable button right ${disable.right} must fit $limit", disable.right <= limit)
        assertTrue("view button right ${view.right} must fit $limit", view.right <= limit)
        listOf(disableText, viewText).forEach { text ->
            val layout = layoutOf(text)
            val last = layout.lineCount - 1
            assertFalse("$text must not be ellipsized", layout.isLineEllipsized(last))
            assertEquals("$text must show its last character", text.length, layout.getLineEnd(last))
        }
    }

    @Test
    @Config(qualifiers = "ar")
    fun used_card_reason_follows_content_direction() {
        val reason = "You pasted a week of notes."
        val item = SkillUsageLabels.Item(weeklyId, null, auto = true, reason = reason, canDisable = true, canView = true)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Box(Modifier.width(320.dp)) {
                    SkillUsedCard(items = listOf(item), onDisable = {}, onView = {})
                }
            }
        }
        composeRule.waitForIdle()

        val layout = layoutOf(reason)
        assertEquals(ResolvedTextDirection.Ltr, layout.getParagraphDirection(0))
        assertTrue("LTR reason must start at the left edge", layout.getLineLeft(0) <= 0.5f)
        assertTrue(
            "reason must span the card width so its alignment is visible",
            layout.size.width > layout.getLineRight(0) + 1f,
        )
    }

    private fun layoutOf(text: String): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        composeRule.onNodeWithText(text).fetchSemanticsNode()
            .config[SemanticsActions.GetTextLayoutResult].action?.invoke(results)
        return results.single()
    }
}
