package ai.oriveo.community.feature.home

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.Skill
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeSkillsEntryCardTest {

    private fun skill(
        id: String,
        name: String = id,
        auto: Boolean = false,
        lastUsedAt: String? = null,
    ) = Skill(id = id, name = name, systemPrompt = "p", autoInvoke = auto, lastUsedAt = lastUsedAt)

    @Test
    fun `subtitle counts auto skills when any is enabled`() {
        val skills = listOf(skill("a", auto = true), skill("b"), skill("c", auto = true))
        assertEquals(HomeSkillsSubtitle.AutoCount(2), homeSkillsSubtitle(skills))
    }

    @Test
    fun `subtitle hints the slash command when skills exist without auto`() {
        assertEquals(HomeSkillsSubtitle.SlashHint, homeSkillsSubtitle(listOf(skill("a"), skill("b"))))
    }

    @Test
    fun `subtitle reads as no auto skills when the settings master switch is off`() {
        val skills = listOf(skill("a", auto = true), skill("b"))
        assertEquals(HomeSkillsSubtitle.SlashHint, homeSkillsSubtitle(skills, autoInvokeEnabled = false))
        assertEquals(HomeSkillsSubtitle.Empty, homeSkillsSubtitle(emptyList(), autoInvokeEnabled = false))
        assertEquals(HomeSkillsSubtitle.AutoCount(1), homeSkillsSubtitle(skills, autoInvokeEnabled = true))
    }

    @Test
    fun `subtitle invites saving the first skill when there is none`() {
        assertEquals(HomeSkillsSubtitle.Empty, homeSkillsSubtitle(emptyList()))
    }

    @Test
    fun `tags put auto first then most recently used and cap at two`() {
        val skills = listOf(
            skill("old", lastUsedAt = "2026-10-01T08:00:00Z"),
            skill("recent", lastUsedAt = "2026-10-29T08:00:00Z"),
            skill("never"),
            skill("auto", auto = true),
        )
        assertEquals(listOf("auto", "recent"), homeSkillsTags(skills).map { it.id })
    }

    @Test
    fun `tags order recency across offsets and fall back to name for unused skills`() {
        val used = listOf(
            skill("utc", lastUsedAt = "2026-10-29T08:00:00Z"),
            // 09:00+02:00 is 07:00Z, earlier than the UTC one despite the larger wall clock
            skill("offset", lastUsedAt = "2026-10-29T09:00:00+02:00"),
        )
        assertEquals(listOf("utc", "offset"), homeSkillsTags(used).map { it.id })

        val unused = listOf(skill("z", name = "Zeta"), skill("a", name = "alpha"), skill("m", name = "Mu"))
        assertEquals(listOf("a", "m"), homeSkillsTags(unused).map { it.id })

        val mixed = listOf(skill("never", name = "Aaa"), skill("used", name = "Zzz", lastUsedAt = "2020-01-01T00:00:00Z"))
        assertEquals(listOf("used", "never"), homeSkillsTags(mixed).map { it.id })
    }

    @Test
    fun `tags are empty without skills`() {
        assertEquals(emptyList<Skill>(), homeSkillsTags(emptyList()))
        // Without skills or a template cache both pills are skeletons
        val slots = homeSkillTagSlots(emptyList(), homeFeaturedTemplates(emptyList()))
        assertEquals(listOf<Skill?>(null, null), slots.tags)
        assertFalse(slots.showsTemplates)
        // Empty slots still draw skeleton pills on the full pill shell
        for (dark in listOf(true, false)) {
            assertEquals(homeSkillTagChrome(skill("a"), dark), homeSkillTagChrome(null, dark))
        }
    }

    private fun template(id: String, whenToUse: String = "", sortOrder: Int = 0) =
        Skill(id = id, name = id, systemPrompt = "p", whenToUse = whenToUse, sortOrder = sortOrder)

    @Test
    fun empty_card_shows_featured_template_names_when_cached() {
        val catalog = listOf(
            template("plain"),
            template("second", whenToUse = "when B", sortOrder = 9),
            template("first", whenToUse = "when A", sortOrder = 1),
            template("third", whenToUse = "when C"),
        )
        val featured = homeFeaturedTemplates(catalog)
        // Cache (DAO) order, featured only, first two
        assertEquals(listOf("second", "first"), featured.map { it.id })
        val slots = homeSkillTagSlots(emptyList(), featured)
        assertEquals(listOf("second", "first"), slots.tags.map { it?.name })
        assertTrue(slots.showsTemplates)
        assertEquals(0.6f, HomeSkillTemplatePreviewAlpha, 0f)

        // A single cached template fills the first pill; the second stays a skeleton
        val one = homeSkillTagSlots(emptyList(), homeFeaturedTemplates(listOf(template("only", whenToUse = "w"))))
        assertEquals(listOf("only", null), one.tags.map { it?.id })
        assertTrue(one.showsTemplates)

        // Any skill of my own replaces the templates
        val mine = homeSkillTagSlots(listOf(skill("mine")), featured)
        assertEquals(listOf("mine", null), mine.tags.map { it?.id })
        assertFalse(mine.showsTemplates)
    }

    @Test
    fun empty_card_falls_back_to_skeleton_without_cache() {
        for (catalog in listOf(emptyList(), listOf(template("plain"), template("other")))) {
            val slots = homeSkillTagSlots(emptyList(), homeFeaturedTemplates(catalog))
            assertEquals(listOf<Skill?>(null, null), slots.tags)
            assertFalse(slots.showsTemplates)
        }
    }

    @Test
    fun empty_pills_use_full_pill_chrome() {
        for (dark in listOf(true, false)) {
            val chrome = homeSkillTagChrome(null, dark)
            assertEquals(homeSkillTagChrome(skill("a", auto = true), dark), chrome)
            assertEquals(28.dp, chrome.height)
            assertEquals(14.dp, chrome.corner)
            assertEquals(7.dp, chrome.paddingStart)
            assertEquals(11.dp, chrome.paddingEnd)
        }
        assertEquals(Color.White, homeSkillTagChrome(null, isDark = false).fill)
        assertEquals(Color(0xFF1F1C24), homeSkillTagChrome(null, isDark = true).fill)
        assertEquals(Color(0x29FFFFFF), homeSkillSkeletonColor(isDark = true))
        assertEquals(Color(0x1A000000), homeSkillSkeletonColor(isDark = false))
        assertEquals(6.dp, HomeSkillSkeletonBarHeight)
        assertEquals(3.dp, HomeSkillSkeletonBarCorner)
        assertEquals(44.dp, homeSkillSkeletonBarWidth(0, 64.dp))
        assertEquals(32.dp, homeSkillSkeletonBarWidth(1, 64.dp))
        // Capped by the name width, and dropped with the name on narrow cards
        assertEquals(30.dp, homeSkillSkeletonBarWidth(0, 30.dp))
        assertEquals(0.dp, homeSkillSkeletonBarWidth(1, 12.dp))
    }

    @Test
    fun illustration_scales_to_fit_two_line_subtitle() {
        // Text block: 15 top padding + 21 title + 2 gap + 16 per subtitle line
        val oneLine = 15.dp + 21.dp + 2.dp + 16.dp
        val twoLines = oneLine + 16.dp
        assertEquals(1f, homeSkillsIllustrationScale(150.dp, oneLine), 0f)
        val scale = homeSkillsIllustrationScale(150.dp, twoLines)
        assertTrue("two-line scale $scale should shrink", scale < 1f && scale > 0.8f)
        assertTrue(
            "scaled group ${HomeSkillsIllustrationHeight * scale} over ${150.dp - twoLines}",
            HomeSkillsIllustrationHeight * scale <= 150.dp - twoLines + 0.01.dp,
        )
        assertEquals(1f, homeSkillsIllustrationScale(150.dp, 0.dp), 0f)
    }

    @Test
    fun dot_grid_alpha_matches_notes_weight() {
        assertEquals(Color(0x1FFBBF24), HomeSkillsDotGridStyle.Dark.color)
        assertEquals(Color(0x29C2781E), HomeSkillsDotGridStyle.Light.color)
        for (style in listOf(HomeSkillsDotGridStyle.Dark, HomeSkillsDotGridStyle.Light)) {
            // Close to the notes card lines (white 9%): no heavier than 16%
            assertTrue("alpha ${style.color.alpha}", style.color.alpha <= 0.17f)
            assertEquals(1.dp, style.diameter)
            assertEquals(12.dp, style.step)
        }
    }

    @Test
    fun `accessibility reads title count and subtitle`() {
        assertEquals("Skills, 6, Auto · 4", homeSkillsAccessibilityText("Skills", 6, "Auto · 4"))
        // Zero count is not shown on the card, so it is not read either (same rule as the notes card)
        assertEquals("Skills. Save how you like it done", homeSkillsAccessibilityText("Skills", 0, "Save how you like it done"))
    }

    @Test
    fun `both tags end inside the card on every phone width`() {
        for (screen in listOf(320, 360, 393, 412, 430)) {
            val card = cardWidth(screen.dp)
            for (x in listOf(62.dp, 72.dp)) {
                val cap = homeSkillTagTextMaxWidth(card, x)
                assertTrue("screen $screen x $x: cap $cap over 64", cap <= 64.dp)
                // The name is dropped below 24dp; the dot-only pill is 7 + 14 + 11 wide.
                val pill = if (cap >= HomeSkillTagTextMinWidth) HomeSkillTagChrome + cap else 32.dp
                val right = x + pill
                assertTrue("screen $screen x $x: right edge $right past ${card - 12.dp}", right <= card - 12.dp)
            }
        }
    }

    @Test
    fun `tag name cap follows the card width and keeps 64 on wide cards`() {
        assertEquals(64.dp, homeSkillTagTextMaxWidth(cardWidth(430.dp), 62.dp))
        assertEquals(64.dp, homeSkillTagTextMaxWidth(cardWidth(430.dp), 72.dp))
        assertEquals(64.dp, homeSkillTagTextMaxWidth(cardWidth(412.dp), 62.dp))
        assertEquals(42.dp, homeSkillTagTextMaxWidth(cardWidth(360.dp), 62.dp))
        // 320dp: the second tag has 12dp for its name, under the 24dp floor, so it shows only the dot.
        assertTrue(homeSkillTagTextMaxWidth(cardWidth(320.dp), 72.dp) < HomeSkillTagTextMinWidth)
    }

    @Test
    fun ellipsis_hugs_last_visible_char() {
        // The cut falls right after a space: the ellipsis must hug "Meeting", with no gap before it.
        assertEquals("Meeting\u2026", trimmedEllipsis("Meeting notes", 8))
        // No overflow: the text is returned unchanged.
        assertEquals("Meeting notes", trimmedEllipsis("Meeting notes", "Meeting notes".length))
        // A cut inside a word keeps the visible prefix as is.
        assertEquals("Meet\u2026", trimmedEllipsis("Meeting notes", 4))
        assertEquals("Supercalifrag\u2026", trimmedEllipsis("Supercalifragilistic", 13))
    }

    /** Two cards side by side: 20dp screen margins and a 12dp gap. */
    private fun cardWidth(screen: Dp): Dp = (screen - 40.dp - 12.dp) / 2
}
