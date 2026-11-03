package ai.oriveo.community.feature.home.homescreen

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.unit.dp
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.feature.chat.composer.DictationHostActions
import ai.oriveo.community.feature.chat.composer.DictationHostCoordinator
import ai.oriveo.community.feature.chat.composer.DictationToastSpec
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.HomeSkillsEntryDepth
import ai.oriveo.community.feature.home.AuroraDarkColors
import ai.oriveo.community.feature.home.AuroraGreeting
import ai.oriveo.community.feature.home.AuroraHeroCardAppearance
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.feature.home.auroraCssShadowRadius
import ai.oriveo.community.feature.home.auroraHeroRimBrush
import ai.oriveo.community.feature.home.homeHeroPillModelName
import ai.oriveo.community.feature.notes.HomeNotesPushpin
import ai.oriveo.community.feature.notes.homeNotesAccessibilityText
import ai.oriveo.community.feature.notes.homeNotesPreviewLine
import ai.oriveo.community.ui.theme.DarkForestOriveoColors
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import java.util.Calendar
import java.util.TimeZone
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Contracts for the home hero, greeting and Notes entry.
 * Pure functions are asserted on their values; only structural rules ("must not regress to the old style")
 * read the source.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class HomeHeroVisualContractTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun hero_input_visible_empty_and_draft() {
        // Device regression: with a dictation handle the home screen wraps the normal input in a Crossfade (Box)
        // inside DictationInputSwitcher, so the input area stacked on the bottom row and got covered; in both
        // states the field must be visible, have a height and sit entirely above the bottom row.
        val draft = mutableStateOf("")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val model = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
        val active = HomeViewModel.ActiveModel(
            provider = Provider(id = "provider-1", kind = ProviderKind.OpenAI, status = ProviderConnectionState.Connected, models = listOf(model)),
            model = model,
        )
        val dictation = DictationHostCoordinator("draft:home", IdleDictationCommands(), NoopDictationActions())
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                NewChatBar(
                    activeModel = active,
                    hasProvider = true,
                    isDark = true,
                    heroText = draft.value,
                    onHeroTextChange = {},
                    isSendingFromHero = false,
                    isSearchActive = false,
                    onSend = {},
                    onModelSelect = {},
                    onAddProvider = {},
                    onStartVoiceConversation = {},
                    dictation = dictation,
                )
            }
        }
        for (text in listOf("", "Plan a weekend in Kyoto")) {
            composeRule.runOnIdle { draft.value = text }
            composeRule.waitForIdle()

            val input = composeRule.onNode(hasSetTextAction())
            input.assertExists().assertIsDisplayed()
            val inputBounds = input.getUnclippedBoundsInRoot()
            val inputHeight = inputBounds.bottom - inputBounds.top
            assertTrue("draft='$text' input height $inputHeight must be > 0", inputHeight.value > 0f)
            val send = composeRule.onNodeWithContentDescription(activity.getString(ai.oriveo.community.R.string.send))
                .getUnclippedBoundsInRoot()
            assertTrue(
                "draft='$text' input bottom ${inputBounds.bottom} must sit above the bottom row (send top ${send.top})",
                inputBounds.bottom <= send.top,
            )
        }
    }

    @Test
    fun `hero idle is flat and only focus lights the aurora ring`() {
        val darkIdle = AuroraHeroCardAppearance.resolve(isDark = true, focused = false)
        val darkFocused = AuroraHeroCardAppearance.resolve(isDark = true, focused = true)
        val lightIdle = AuroraHeroCardAppearance.resolve(isDark = false, focused = false)
        val lightFocused = AuroraHeroCardAppearance.resolve(isDark = false, focused = true)

        // Idle: 1dp stroke, no aurora ring; focused: aurora ring, stroke hidden
        listOf(darkIdle, lightIdle).forEach {
            assertFalse(it.showsGlowBorder)
            assertTrue(it.showsHairlineBorder)
        }
        listOf(darkFocused, lightFocused).forEach {
            assertTrue(it.showsGlowBorder)
            assertFalse(it.showsHairlineBorder)
        }

        // Dark: 0 12 28 -6 rgba(0,0,0,.36), unchanged on focus
        assertNull(darkIdle.contactShadow)
        assertEquals(
            AuroraHeroCardAppearance.CardShadow(Color.Black.copy(alpha = 0.36f), 28.dp, 12.dp, spread = (-6).dp),
            darkIdle.ambientShadow,
        )
        assertEquals(darkIdle.ambientShadow, darkFocused.ambientShadow)
        // Light idle: 0 1 2 rgba(15,23,42,.04) + 0 10 28 rgba(139,92,246,.08); light focused: 0 14 40 rgba(139,92,246,.16)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF0F172A).copy(alpha = 0.04f), 2.dp, 1.dp), lightIdle.contactShadow)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.08f), 28.dp, 10.dp), lightIdle.ambientShadow)
        assertNull(lightFocused.contactShadow)
        assertEquals(AuroraHeroCardAppearance.CardShadow(Color(0xFF8B5CF6).copy(alpha = 0.16f), 40.dp, 14.dp), lightFocused.ambientShadow)
    }

    @Test
    fun `dark hero keeps the card flat and puts the aurora on its top edge`() {
        // The dark card looked muddy when it carried a glow blob in one corner, too much saturation in the dark
        // areas and grey text of a different hue than the face. The fix keeps the face a uniform base, brighter at
        // the top, and moves the aurora to the top edge and outside the card.
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()

        // Face: two vertical stops with no directional glow blobs; only the afterglow a finger's width below the top edge remains. Both stops derive from the current dark palette
        assertTrue(themeSource.contains("colors = listOf(dark.heroSurfaceTop, dark.heroSurfaceBottom)"))
        assertFalse("the dark face no longer hard-codes one palette's base", themeSource.contains("heroSurfaceDarkTop"))
        assertFalse("the dark face no longer uses the 150-degree diagonal gradient", themeSource.contains("auroraCssGradientPoints(150f, size)"))

        // The pill is opaque: a translucent white over the face fades into a grey patch (the same for every dark palette)
        assertEquals(1f, AuroraDarkColors.from(DarkOriveoColors).pillFill.alpha)
        assertEquals(1f, AuroraDarkColors.from(DarkForestOriveoColors).pillFill.alpha)
        // Grey text inside the hero shares the face's hue and is not the global t3 (a warm grey-purple)
        assertNotEquals(AuroraTheme.Colors.textTertiaryDark, AuroraTheme.Colors.heroTextTertiaryDark)
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()
        assertFalse("Tertiary grey inside the hero card always goes through heroTextTertiary()", barSource.contains("AuroraTheme.textTertiary()"))

        // Light is unaffected: still a white card + two glows + a uniform cardBorder stroke
        assertEquals(Color(0xFFEC8FEA).copy(alpha = 0.08f), AuroraTheme.Colors.heroGlowBLight)
        assertEquals(SolidColor(AuroraTheme.Colors.cardBorderLight), auroraHeroRimBrush(isDark = false, height = 100f))
    }

    @Test
    fun `the aurora crown lights hero and notes alike and fades out on focus`() {
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()

        // The hero has the near-white hot core + the outer halo; Notes is the same light one step weaker, without core or halo
        assertTrue(themeSource.contains("drawAuroraCrown(dark, hairlinePath, hairlineWidth, scale = 1f, hotCore = true, alpha = 1f - p)"))
        // The notes entry card no longer uses the aurora surface, so the weaker notes crown is gone
        assertFalse(themeSource.contains("AURORA_CROWN_NOTES_SCALE"))
        assertFalse(themeSource.contains("auroraNotesSurface"))
        // When focused, the aurora crown fades out together with the halo outside the card, replaced by the aurora ring: two glows stacked together would blur
        assertTrue(themeSource.contains("if (p < 1f) halo.forEach { with(it) { draw(size, alpha = 1f - p) } }"))
    }

    @Test
    fun `home header clears the top fade band at rest`() {
        // The band [status bar, status bar + fade length] at the top of the list washes content out; a header placed right under the status bar looks as if its capsule were covered
        val screenSource = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        assertTrue(screenSource.contains("contentPadding = PaddingValues(top = statusBarInset + OriveoSystemBarFadeLength)"))
    }

    @Test
    fun `css blur converts to the compose shadow radius`() {
        // CSS blur B → sigma B/2; BlurMaskFilter sigma = 0.57735 r → r ≈ 0.866 B
        assertEquals(25.98f, auroraCssShadowRadius(30.dp).value, 0.01f)
        assertEquals(1.732f, auroraCssShadowRadius(2.dp).value, 0.001f)
    }

    @Test
    fun `model pill drops vendor prefix and free suffix`() {
        assertEquals("DeepSeek V4 Flash", homeHeroPillModelName("DeepSeek: DeepSeek V4 Flash"))
        assertEquals("LFM2.5-1.2B-Instruct", homeHeroPillModelName("LiquidAI: LFM2.5-1.2B-Instruct (free)"))
        assertEquals("GPT-5", homeHeroPillModelName("  GPT-5  "))
    }

    @Test
    fun `notes entry shows the latest title or the invitation copy`() {
        assertEquals("Invite", homeNotesPreviewLine(count = 0, latestTitle = "Old", untitled = "Untitled", invitation = "Invite"))
        assertEquals("Metal shaders", homeNotesPreviewLine(count = 3, latestTitle = "  Metal shaders ", untitled = "Untitled", invitation = "Invite"))
        // Notes exist but the latest has no title: "Untitled", not the empty-state invitation (matches iOS NoteText.displayTitle)
        assertEquals("Untitled", homeNotesPreviewLine(count = 3, latestTitle = "   ", untitled = "Untitled", invitation = "Invite"))
        assertEquals("Untitled", homeNotesPreviewLine(count = 3, latestTitle = null, untitled = "Untitled", invitation = "Invite"))

        assertEquals("Notes, 3 notes, Metal shaders", homeNotesAccessibilityText("Notes", "3 notes", "Metal shaders"))
        assertEquals("Notes. Invite", homeNotesAccessibilityText("Notes", null, "Invite"))
    }

    @Test
    fun `hero card keeps the flat design structure`() {
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()

        assertTrue(
            "Hero uses the shared aurora glass card with the 26dp radius and border-box padding 19/19/15.",
            barSource.contains(".auroraGlassCard(isDark = isDark, cornerRadius = HOME_HERO_CORNER_RADIUS, focused = isFocused)") &&
                barSource.contains(".padding(start = 19.dp, end = 19.dp, top = 19.dp, bottom = 15.dp)"),
        )
        assertFalse(
            "The idle hero has no hairline divider between the input and the controls any more.",
            barSource.contains("Brush.horizontalGradient") || barSource.contains("AuroraTheme.hairline()"),
        )
        assertFalse(
            "The send button is a flat solid purple circle: no gradient, no shadow, no sheen.",
            barSource.contains("OriveoGradients.primary") ||
                barSource.contains("Color.White.copy(alpha = 0.28f)") ||
                barSource.contains(".shadow("),
        )
        // The up arrow is always the primary key and reads "Send"; the voice key is a separate secondary button to its left.
        assertTrue(
            "The send button always announces Send; the separate voice key announces the voice conversation.",
            barSource.contains("contentDescription = stringResource(R.string.send)") &&
                barSource.contains("contentDescription = stringResource(R.string.voice_conversation_start_a11y)"),
        )
        assertTrue(
            "The model pill stays a picker with connection avatar, cleaned model name and provider subtitle.",
            barSource.contains("ConnectionAvatar(") &&
                barSource.contains("active.provider.displayName") &&
                barSource.contains("homeHeroPillModelName(") &&
                barSource.contains("stringResource(R.string.select_model)") &&
                barSource.contains("stringResource(R.string.add_provider)"),
        )
    }

    @Test
    fun `greeting and tagline daily index stay aligned with iOS`() {
        assertEquals(17, AuroraGreeting.GREETING_SALT)
        assertEquals(31, AuroraGreeting.TAGLINE_SALT)
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(2026, Calendar.SEPTEMBER, 13, 9, 0, 0)
        }
        assertEquals(3, AuroraGreeting.dailyIndex(cal, 17, 5))
        assertEquals(2, AuroraGreeting.dailyIndex(cal, 31, 8))
        val later = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(2026, Calendar.SEPTEMBER, 13, 11, 0, 0)
        }
        assertEquals(
            AuroraGreeting.dailyIndex(cal, 17, 5),
            AuroraGreeting.dailyIndex(later, 17, 5),
        )

        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()
        assertTrue(themeSource.contains("greeting_morning_5"))
        assertTrue(themeSource.contains("tagline_morning_8"))
    }

    @Test
    fun `keycap has no hard lip band`() {
        val keycap = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
            .substringAfter("private fun SkillsKeycap(").substringBefore("\n}\n")
        assertTrue("keycap function found", keycap.contains("RoundedCornerShape(10.dp)"))
        assertFalse("keycap draws no bottom lip band", keycap.contains("drawRect"))
        listOf(false, true).forEach { isDark ->
            val colors = HomeSkillsEntryDepth.keycapFaceColors(isDark)
            assertEquals("three face colours (dark=$isDark)", 3, colors.size)
            assertTrue(
                "face luminance strictly decreases top to bottom (dark=$isDark)",
                colors.zipWithNext().all { (upper, lower) -> upper.luminance() > lower.luminance() },
            )
        }
        assertEquals(listOf(0f, 0.6f, 1f), HomeSkillsEntryDepth.KeycapFaceStops)
    }

    @Test
    fun `keycap and chips share soft shadow`() {
        val ambientLight = HomeSkillsEntryDepth.ambientShadow(isDark = false)
        val ambientDark = HomeSkillsEntryDepth.ambientShadow(isDark = true)
        assertEquals(Color(0xFFEA580C), ambientLight.color)
        assertTrue("light ambient opacity in (0, 0.4]", ambientLight.opacity > 0f && ambientLight.opacity <= 0.4f)
        assertTrue("ambient radius at least 5", ambientLight.radius >= 5.dp)
        assertTrue("ambient falls downwards", ambientLight.y > 0.dp)
        assertEquals(Color(0xFF000000), ambientDark.color)
        assertTrue("dark ambient is denser than light", ambientDark.opacity > ambientLight.opacity)

        val contactLight = HomeSkillsEntryDepth.contactShadow(isDark = false)
        val contactDark = HomeSkillsEntryDepth.contactShadow(isDark = true)
        listOf(contactLight, contactDark).forEach { contact ->
            assertTrue("contact radius in (0, 1.5]", contact.radius > 0.dp && contact.radius <= 1.5.dp)
        }
        assertTrue("dark contact is denser than light", contactDark.opacity > contactLight.opacity)

        val source = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        listOf("SkillsKeycap", "SkillsTag").forEach { name ->
            val body = source.substringAfter("private fun $name(").substringBefore("\n}\n")
            assertTrue("$name draws the shared ambient shadow", body.contains("HomeSkillsEntryDepth.ambientShadow"))
        }
    }

    @Test
    fun `home entry row puts the notes and skills cards side by side at equal width`() {
        val screenSource = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        val entryItem = screenSource.substringAfter("item(key = \"notes_entry\")").substringBefore("item(key = \"list_top_gap\")")
        assertTrue(entryItem.contains("horizontalArrangement = Arrangement.spacedBy(12.dp)"))
        assertTrue(entryItem.contains("HomeNotesEntryCard("))
        assertTrue(entryItem.contains("HomeSkillsEntryCard("))
        assertEquals("both cards take an equal share of the row", 2, Regex("""\.weight\(1f\)""").findAll(entryItem).count())
        assertFalse("the pinned skill chip row is gone", screenSource.contains("SkillChip"))

        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        val skillsSource = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        val shell = skillsSource.substringAfter("internal fun Modifier.homeEntryCardSurface(").substringBefore("\n}\n")
        assertTrue(skillsSource.contains("HomeEntryCardShape = RoundedCornerShape(22.dp)"))
        assertTrue(shell.contains(".height(150.dp)"))
        listOf(notesSource, skillsSource).forEach { source ->
            assertTrue("both cards share the same shell", source.contains(".homeEntryCardSurface("))
            // Neither card follows the theme palette
            assertFalse(source.contains("OriveoTheme.colors"))
            assertFalse(source.contains("auroraNotesSurface"))
        }
        assertTrue("breathing dot holds still when animations are off", skillsSource.contains("isReduceMotionEnabled("))
        assertTrue(skillsSource.contains("durationMillis = 2400"))
        assertTrue("tag dots use the glyph hue", skillsSource.contains("SkillGlyphs.hue("))
    }

    @Test
    fun `pushpin has round head and visible needle`() {
        val diameter = HomeNotesPushpin.HeadDiameter
        assertTrue("head diameter $diameter reads as a round pin head", diameter in 9f..13f)
        assertTrue(
            "needle shows below the head",
            HomeNotesPushpin.NeedleLength - diameter / 2f >= 3f,
        )
        assertTrue("pin leans up-left", HomeNotesPushpin.TiltDegrees in 15f..35f)
        val pierce = Offset(HomeNotesPushpin.PierceX, HomeNotesPushpin.PierceY)
        assertEquals(Offset(61f, 10f), pierce)
        val tilt = Math.toRadians(24.0)
        val expectedX = (61.0 - 9.0 * kotlin.math.sin(tilt)).toFloat()
        val expectedY = (10.0 - 9.0 * kotlin.math.cos(tilt)).toFloat()
        val center = HomeNotesPushpin.headCenter(pierce)
        assertEquals("head centre x", expectedX, center.x, 0.01f)
        assertEquals("head centre y", expectedY, center.y, 0.01f)
        assertTrue("head crosses the sheet top edge", center.y - diameter / 2f < 0f)
        assertTrue("needle has width", HomeNotesPushpin.NeedleWidth > 0f)
        assertEquals("three head colours", 3, HomeNotesPushpin.HeadColors.size)
        assertEquals("one stop per head colour", 3, HomeNotesPushpin.HeadStops.size)
        assertTrue(
            "head gradient runs from light to dark",
            HomeNotesPushpin.HeadColors.first().luminance() > HomeNotesPushpin.HeadColors.last().luminance(),
        )
    }

    @Test
    fun `pushpin casts shadow in both appearances`() {
        listOf(false, true).forEach { isDark ->
            assertTrue("shadow visible (dark=$isDark)", HomeNotesPushpin.shadowAlpha(isDark) > 0f)
            assertTrue("highlight visible (dark=$isDark)", HomeNotesPushpin.highlightAlpha(isDark) >= 0.6f)
            assertTrue("pierce hole visible (dark=$isDark)", HomeNotesPushpin.holeAlpha(isDark) > 0f)
        }
        assertTrue(
            "dark shadow is stronger than light",
            HomeNotesPushpin.shadowAlpha(isDark = true) > HomeNotesPushpin.shadowAlpha(isDark = false),
        )
        assertTrue("shadow falls right", HomeNotesPushpin.ShadowOffsetX > 0f)
        assertTrue("shadow falls down", HomeNotesPushpin.ShadowOffsetY > 0f)
        assertTrue("shadow is blurred", HomeNotesPushpin.ShadowBlur > 0f)
    }

    @Test
    fun `notes card has no washi tape`() {
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        assertFalse("washi tape is gone from the notes card", notesSource.contains("WashiTape"))
    }

    @Test
    fun `home entry cards have no outer stroke`() {
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        val skillsSource = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        assertTrue(skillsSource.contains("internal fun Modifier.homeEntryCardSurface("))
        assertTrue(notesSource.contains("private fun PaperSheet("))
        val shell = skillsSource.substringAfter("internal fun Modifier.homeEntryCardSurface(").substringBefore("\n}\n")
        val sheet = notesSource.substringAfter("private fun PaperSheet(").substringBefore("\n}\n")
        assertFalse("the shared card shell draws no outer stroke", shell.contains(".border("))
        assertFalse("paper sheets draw no pink ring", sheet.contains(".border("))
        assertTrue("dark card base is lifted above the page", shell.contains("0xFF1F1D24"))
    }

    @Test
    fun `notes card and section header share the centered title count`() {
        // The Notes card once used baseline alignment: its count sat about 1.5pt below the optical center; the group title was also raised another 1dp
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        val headerSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/HomeEditingToolbar.kt").readText()
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()
        val skillsSource = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        // The entry cards keep the centered title count but not the themed accent count
        assertTrue(notesSource.contains("HomeEntryTitleCount("))
        assertTrue(skillsSource.contains("HomeEntryTitleCount("))
        assertTrue(skillsSource.contains("verticalAlignment = Alignment.CenterVertically"))
        assertTrue(headerSource.contains("AuroraTitleCount("))
        assertFalse(notesSource.contains("alignByBaseline"))
        assertFalse(skillsSource.contains("alignByBaseline"))
        assertFalse(headerSource.contains("offset(y ="))
        val titleCount = themeSource.substringAfter("internal fun AuroraTitleCount(").substringBefore("// ── Section Rule")
        assertTrue(titleCount.contains("verticalAlignment = Alignment.CenterVertically"))
        assertFalse(titleCount.contains("offset("))
    }

    @Test
    fun `production pools rotate through every line so both platforms pick the same index`() {
        // Walk the production functions day by day: a pool one line short picks a different index than iOS
        for (hour in listOf(9, 15, 20, 2)) {
            val greetings = mutableSetOf<Int>()
            val taglines = mutableSetOf<Int>()
            for (offset in 0 until 40) {
                val day = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                    clear()
                    set(2026, Calendar.MARCH, 1, hour, 0, 0)
                    add(Calendar.DAY_OF_YEAR, offset)
                }
                greetings += AuroraGreeting.greetingResId(day)
                taglines += AuroraGreeting.taglineResId(day)
            }
            assertEquals("hour=$hour greeting pool should have 5 lines", 5, greetings.size)
            assertEquals("hour=$hour tagline pool should have 8 lines", 8, taglines.size)
        }

        // Same anchor as iOS HomeViewTests: 2026-09-16 afternoon -> greeting 5, tagline 8
        val anchor = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(2026, Calendar.SEPTEMBER, 16, 15, 0, 0)
        }
        assertEquals(ai.oriveo.community.R.string.greeting_afternoon_5, AuroraGreeting.greetingResId(anchor))
        assertEquals(ai.oriveo.community.R.string.tagline_afternoon_8, AuroraGreeting.taglineResId(anchor))
    }

    @Test
    fun `pushpin has round head and visible needle`() {
        val diameter = HomeNotesPushpin.HeadDiameter
        assertTrue("head diameter $diameter reads as a round pin head", diameter in 9f..13f)
        assertTrue(
            "needle shows below the head",
            HomeNotesPushpin.NeedleLength - diameter / 2f >= 3f,
        )
        assertTrue("pin leans up-left", HomeNotesPushpin.TiltDegrees in 15f..35f)
        val pierce = Offset(HomeNotesPushpin.PierceX, HomeNotesPushpin.PierceY)
        assertEquals(Offset(61f, 10f), pierce)
        val tilt = Math.toRadians(24.0)
        val expectedX = (61.0 - 9.0 * kotlin.math.sin(tilt)).toFloat()
        val expectedY = (10.0 - 9.0 * kotlin.math.cos(tilt)).toFloat()
        val center = HomeNotesPushpin.headCenter(pierce)
        assertEquals("head centre x", expectedX, center.x, 0.01f)
        assertEquals("head centre y", expectedY, center.y, 0.01f)
        assertTrue("head crosses the sheet top edge", center.y - diameter / 2f < 0f)
        assertTrue("needle has width", HomeNotesPushpin.NeedleWidth > 0f)
        assertEquals("three head colours", 3, HomeNotesPushpin.HeadColors.size)
        assertEquals("one stop per head colour", 3, HomeNotesPushpin.HeadStops.size)
        assertTrue(
            "head gradient runs from light to dark",
            HomeNotesPushpin.HeadColors.first().luminance() > HomeNotesPushpin.HeadColors.last().luminance(),
        )
    }

    @Test
    fun `pushpin casts shadow in both appearances`() {
        listOf(false, true).forEach { isDark ->
            assertTrue("shadow visible (dark=$isDark)", HomeNotesPushpin.shadowAlpha(isDark) > 0f)
            assertTrue("highlight visible (dark=$isDark)", HomeNotesPushpin.highlightAlpha(isDark) >= 0.6f)
            assertTrue("pierce hole visible (dark=$isDark)", HomeNotesPushpin.holeAlpha(isDark) > 0f)
        }
        assertTrue(
            "dark shadow is stronger than light",
            HomeNotesPushpin.shadowAlpha(isDark = true) > HomeNotesPushpin.shadowAlpha(isDark = false),
        )
        assertTrue("shadow falls right", HomeNotesPushpin.ShadowOffsetX > 0f)
        assertTrue("shadow falls down", HomeNotesPushpin.ShadowOffsetY > 0f)
        assertTrue("shadow is blurred", HomeNotesPushpin.ShadowBlur > 0f)
    }

    @Test
    fun `notes card has no washi tape`() {
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        assertFalse("washi tape is gone from the notes card", notesSource.contains("WashiTape"))
    }

    @Test
    fun `home entry cards have no outer stroke`() {
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        val skillsSource = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        assertTrue(skillsSource.contains("internal fun Modifier.homeEntryCardSurface("))
        assertTrue(notesSource.contains("private fun PaperSheet("))
        val shell = skillsSource.substringAfter("internal fun Modifier.homeEntryCardSurface(").substringBefore("\n}\n")
        val sheet = notesSource.substringAfter("private fun PaperSheet(").substringBefore("\n}\n")
        assertFalse("the shared card shell draws no outer stroke", shell.contains(".border("))
        assertFalse("paper sheets draw no pink ring", sheet.contains(".border("))
        assertTrue("dark card base is lifted above the page", shell.contains("0xFF1F1D24"))
    }

    @Test
    fun `keycap has no hard lip band`() {
        val keycap = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
            .substringAfter("private fun SkillsKeycap(").substringBefore("\n}\n")
        assertTrue("keycap function found", keycap.contains("RoundedCornerShape(10.dp)"))
        assertFalse("keycap draws no bottom lip band", keycap.contains("drawRect"))
        listOf(false, true).forEach { isDark ->
            val colors = HomeSkillsEntryDepth.keycapFaceColors(isDark)
            assertEquals("three face colours (dark=$isDark)", 3, colors.size)
            assertTrue(
                "face luminance strictly decreases top to bottom (dark=$isDark)",
                colors.zipWithNext().all { (upper, lower) -> upper.luminance() > lower.luminance() },
            )
        }
        assertEquals(listOf(0f, 0.6f, 1f), HomeSkillsEntryDepth.KeycapFaceStops)
    }

    @Test
    fun `keycap and chips share soft shadow`() {
        val ambientLight = HomeSkillsEntryDepth.ambientShadow(isDark = false)
        val ambientDark = HomeSkillsEntryDepth.ambientShadow(isDark = true)
        assertEquals(Color(0xFFEA580C), ambientLight.color)
        assertTrue("light ambient opacity in (0, 0.4]", ambientLight.opacity > 0f && ambientLight.opacity <= 0.4f)
        assertTrue("ambient radius at least 5", ambientLight.radius >= 5.dp)
        assertTrue("ambient falls downwards", ambientLight.y > 0.dp)
        assertEquals(Color(0xFF000000), ambientDark.color)
        assertTrue("dark ambient is denser than light", ambientDark.opacity > ambientLight.opacity)

        val contactLight = HomeSkillsEntryDepth.contactShadow(isDark = false)
        val contactDark = HomeSkillsEntryDepth.contactShadow(isDark = true)
        listOf(contactLight, contactDark).forEach { contact ->
            assertTrue("contact radius in (0, 1.5]", contact.radius > 0.dp && contact.radius <= 1.5.dp)
        }
        assertTrue("dark contact is denser than light", contactDark.opacity > contactLight.opacity)

        val source = File("src/main/java/ai/oriveo/community/feature/home/HomeSkillsEntryCard.kt").readText()
        listOf("SkillsKeycap", "SkillsTag").forEach { name ->
            val body = source.substringAfter("private fun $name(").substringBefore("\n}\n")
            assertTrue("$name draws the shared ambient shadow", body.contains("HomeSkillsEntryDepth.ambientShadow"))
        }
    }

    @Test
    fun `notes card and section header share the centered title count`() {
        // The Notes card once used baseline alignment, which dropped the count below the middle of CJK
        // titles; the group header lifted it by an extra 1dp
        val notesSource = File("src/main/java/ai/oriveo/community/feature/notes/HomeNotesEntryCard.kt").readText()
        val headerSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/HomeEditingToolbar.kt").readText()
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()
        assertTrue(notesSource.contains("AuroraTitleCount("))
        assertTrue(headerSource.contains("AuroraTitleCount("))
        assertFalse(notesSource.contains("alignByBaseline"))
        assertFalse(headerSource.contains("offset(y ="))
        val titleCount = themeSource.substringAfter("internal fun AuroraTitleCount(").substringBefore("// -- Section Rule")
        assertTrue(titleCount.contains("verticalAlignment = Alignment.CenterVertically"))
        assertFalse(titleCount.contains("offset("))
    }

    private class IdleDictationCommands : DictationCommands {
        override val state = MutableStateFlow<DictationState>(DictationState.Idle)
        override val engineInfo = MutableStateFlow<DictationEngineInfo?>(null)
        override val pendingDurationSec = MutableStateFlow<Double?>(null)
        override val levelMeter = MutableStateFlow<List<Float>>(emptyList())
        override val boundOwner = MutableStateFlow<Any?>(null)
        override fun start(slotKey: String) = Unit
        override fun finish(submit: DictationSubmit) = Unit
        override fun discard() = Unit
        override fun transcribeSaved(submit: DictationSubmit) = Unit
        override fun discardAndRestart() = Unit
        override fun dismissDenied() = Unit
        override fun undoDiscard(slotKey: String): Boolean = false
        override fun bind(slotKey: String, owner: Any) = Unit
        override fun detach(slotKey: String, owner: Any) = Unit
    }

    private class NoopDictationActions : DictationHostActions {
        override fun insert(text: String) = Unit
        override fun canSend(): Boolean = true
        override fun send() = Unit
        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) = Unit
        override fun openAppSettings() = Unit
        override fun openProviderDetail(providerId: String) = Unit
        override fun openProviderSetup() = Unit
        override fun openVoiceSettings() = Unit
    }
}
