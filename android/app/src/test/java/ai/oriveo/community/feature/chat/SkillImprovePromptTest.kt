package ai.oriveo.community.feature.chat

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.api.UpdateSkillRequest
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.model.SkillSource
import ai.oriveo.community.core.skills.SkillImprove
import ai.oriveo.community.core.telemetry.NoopTelemetry
import ai.oriveo.community.core.telemetry.Telemetry
import ai.oriveo.community.core.telemetry.TelemetryEvent
import ai.oriveo.community.core.telemetry.TelemetryHub
import ai.oriveo.community.feature.chat.components.SKILL_IMPROVE_ACCEPT_TAG
import ai.oriveo.community.feature.chat.components.SKILL_IMPROVE_DISMISS_TAG
import ai.oriveo.community.feature.chat.components.SkillImproveAcceptor
import ai.oriveo.community.feature.chat.components.SkillImproveDiffActions
import ai.oriveo.community.feature.chat.components.SkillImproveHost
import ai.oriveo.community.feature.chat.components.SkillImprovePrompt
import ai.oriveo.community.feature.chat.components.SkillImproveDiffRows
import ai.oriveo.community.feature.chat.components.SkillImprovePrompt.RowKind
import ai.oriveo.community.feature.chat.components.SkillImproveSheetModel
import ai.oriveo.community.feature.chat.components.diffLabelsStack
import ai.oriveo.community.feature.chat.components.skillImproveActionWidths
import ai.oriveo.community.feature.chat.composer.SkillPickerCache
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.lightOriveoColorsOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import kotlin.math.abs
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Skills revamp P5 contract items 8-10: prompt placement, diff panel rows and the accept path. */
@RunWith(RobolectricTestRunner::class)
class SkillImprovePromptTest {

    private class RecordingTelemetry : Telemetry {
        val tracked = mutableListOf<Pair<TelemetryEvent, Map<String, Any?>?>>()
        override val isEnabled = true
        override fun identify(distinctId: String, properties: Map<String, Any?>?) = Unit
        override fun track(event: TelemetryEvent, properties: Map<String, Any?>?) {
            tracked += event to properties
        }
        override fun screen(screenName: String, properties: Map<String, Any?>?) = Unit
        override fun reset() = Unit
        override fun setSuperProperties(properties: Map<String, Any?>) = Unit
        override fun optIn() = Unit
        override fun optOut() = Unit
    }

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val telemetry = RecordingTelemetry().also { TelemetryHub.setBackingForTest(it) }

    @After
    fun resetTelemetry() {
        TelemetryHub.setBackingForTest(NoopTelemetry)
    }

    private val skillId = "0b0f8a3e-0000-4000-8000-000000000001"
    private val rule = "Keep the summary under 100 words."
    private val base = "- Progress\n- Risks"
    private val skill = Skill(id = skillId, name = "Weekly report", systemPrompt = base, source = SkillSource.USER)
    private val cache = SkillPickerCache(mine = listOf(skill), templates = emptyList())

    private val messages = listOf(
        message("u-1", ChatRole.User),
        message("a-1", ChatRole.Assistant),
        message("u-2", ChatRole.User),
        message("a-2", ChatRole.Assistant),
    )

    private val repository = mockk<SkillRepository>()
    private val toasts = mutableListOf<GlobalSnackbarMessage>()
    private var accepted = 0
    private var dismissed = 0
    private val coordinator =
        ChatSkillImproveCoordinator(CoroutineScope(Dispatchers.Unconfined), { listOf(skill) }) { _, _, _ -> "" }
    private val acceptor = SkillImproveAcceptor(repository, { toasts += it }) { pending, current, writer ->
        coordinator.accept(pending, current, writer).also { if (it) accepted++ }
    }

    private fun message(id: String, role: ChatRole) =
        ChatMessage(
            id = id,
            role = role,
            text = "text $id",
            providerKind = ProviderKind.OpenAI,
            providerName = "Provider",
            modelName = "Model",
            state = ChatMessageState.Delivered,
        )

    private fun diff(instructions: String = base, replaces: String = ""): SkillImprove.Diff =
        requireNotNull(SkillImprove.buildImproveDiff(SkillImprove.DiffInput(instructions, rule, replaces)))

    private fun pending(userMessageId: String = "u-2", diffBase: String = base, replaces: String = "") =
        ChatSkillImproveCoordinator.Pending(
            conversationId = "conversation-1",
            userMessageId = userMessageId,
            skillId = skillId,
            rule = rule,
            replaces = replaces,
            diff = diff(diffBase, replaces),
            diffBase = diffBase,
        )

    private fun host(
        pending: ChatSkillImproveCoordinator.Pending? = pending(),
        reporter: SkillImprovePrompt.SuggestedReporter = SkillImprovePrompt.SuggestedReporter(),
        skills: SkillPickerCache? = cache,
    ): SkillImproveHost? = SkillImprovePrompt.host(pending, skills, { messages }, reporter, acceptor) { dismissed++ }

    @Test
    fun prompt_hangs_under_its_answer_only() {
        val host = host()
        assertTrue(SkillImprovePrompt.visible(host, "a-2", isStreaming = false))
        assertFalse("earlier answer gets no prompt", SkillImprovePrompt.visible(host, "a-1", isStreaming = false))
        assertFalse("user message gets no prompt", SkillImprovePrompt.visible(host, "u-2", isStreaming = false))
    }

    @Test
    fun prompt_hidden_while_answer_is_generating() {
        val host = host()
        assertFalse(SkillImprovePrompt.visible(host, "a-2", isStreaming = true))
        assertTrue("shows again once settled", SkillImprovePrompt.visible(host, "a-2", isStreaming = false))
    }

    @Test
    fun no_host_without_pending_or_cached_skill() {
        assertNull(host(pending = null))
        assertNull(host(skills = SkillPickerCache(mine = emptyList(), templates = listOf(skill))))
        assertFalse(SkillImprovePrompt.visible(null, "a-2", isStreaming = false))
    }

    @Test
    fun answer_id_is_reply_before_next_user_message() {
        assertEquals("a-1", SkillImprovePrompt.answerIdFor(messages, "u-1"))
        assertEquals("a-2", SkillImprovePrompt.answerIdFor(messages, "u-2"))
        assertNull(SkillImprovePrompt.answerIdFor(messages.take(3), "u-2"))
        assertNull(SkillImprovePrompt.answerIdFor(messages, "missing"))
    }

    @Test
    fun answer_id_is_first_reply_after_user_message() {
        val withTwoReplies = messages + message("a-3", ChatRole.Assistant)
        assertEquals("a-2", SkillImprovePrompt.answerIdFor(withTwoReplies, "u-2"))
    }

    @Test
    fun panel_rows_follow_current_instructions_when_skill_changed() {
        val pending = pending()
        assertEquals(
            "unchanged (up to surrounding whitespace) keeps the computed diff",
            SkillImprovePrompt.diffRows(pending.diff),
            SkillImprovePrompt.diffRows(pending, "$base\n"),
        )
        val rows = SkillImprovePrompt.diffRows(pending, "$base\n- Owners")
        assertEquals(listOf(RowKind.Context, RowKind.Context, RowKind.Added), rows.map { it.kind })
        assertEquals(listOf("- Risks", "- Owners", "- $rule"), rows.map { it.text })
        assertTrue(
            "no rows when the current instructions already hold the rule",
            SkillImprovePrompt.diffRows(pending, "$base\n- $rule").isEmpty(),
        )
    }

    @Test
    fun saved_instructions_differing_only_in_outer_whitespace_count_as_success() = runTest {
        coEvery { repository.update(any(), any()) } returns skill.copy(systemPrompt = "$base\n- $rule\n")
        val host = requireNotNull(host())

        assertTrue(host.accept())
        assertEquals(1, accepted)
        assertEquals(1, toasts.size)
    }

    @Test
    fun dismiss_clears_through_coordinator() {
        val host = requireNotNull(host())
        host.onDismiss()
        assertEquals(1, dismissed)
        assertEquals(0, accepted)
    }

    @Test
    fun panel_swipe_only_closes_panel() {
        val sheet = SkillImproveSheetModel()
        sheet.review()
        assertTrue(sheet.open)
        sheet.close()
        assertFalse(sheet.open)
        assertEquals("closing the panel does not dismiss the prompt", 0, dismissed)
    }

    @Test
    fun replace_rows_carry_two_context_lines_each_side() {
        val instructions = "- One\n- Two\n- Three\n- Risks\n- Five\n- Six\n- Seven"
        val rows = SkillImprovePrompt.diffRows(diff(instructions, replaces = "Risks"))
        assertEquals(
            listOf(RowKind.Context, RowKind.Context, RowKind.Removed, RowKind.Added, RowKind.Context, RowKind.Context),
            rows.map { it.kind },
        )
        assertEquals(listOf("- Two", "- Three", "- Risks", "- $rule", "- Five", "- Six"), rows.map { it.text })
    }

    @Test
    @Config(sdk = [34])
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun diff_rows_share_label_column() {
        val instructions = "- One\n- Two\n- Three\n- Risks\n- Five\n- Six\n- Seven"
        val rows = SkillImprovePrompt.diffRows(diff(instructions, replaces = "Risks"))
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Column(modifier = Modifier.width(360.dp)) { SkillImproveDiffRows(rows) }
            }
        }
        composeRule.waitForIdle()

        fun textLeft(text: String) = composeRule.onNodeWithText(text).getBoundsInRoot().left.value
        val contextLeft = textLeft("- Three")
        val removedLeft = textLeft("- Risks")
        val addedLeft = textLeft("- $rule")
        assertEquals("removed text starts where context text starts", contextLeft, removedLeft, 0.5f)
        assertEquals("added text starts where context text starts", contextLeft, addedLeft, 0.5f)
        val removedLabel = composeRule.onNodeWithText(activity.getString(R.string.skills_improve_removedLine))
        assertTrue("label column sits before the text", removedLabel.getBoundsInRoot().right.value < removedLeft)
    }

    @Test
    fun diff_labels_stack_above_body_when_narrow_pure() {
        assertTrue("body narrower than 180dp stacks", diffLabelsStack(availableWidth = 250.dp, labelWidth = 80.dp))
        assertFalse("body of exactly 180dp keeps the column", diffLabelsStack(availableWidth = 260.dp, labelWidth = 80.dp))
        assertFalse("wide panel keeps the column", diffLabelsStack(availableWidth = 336.dp, labelWidth = 56.dp))
    }

    @Test
    @Config(sdk = [34], qualifiers = "de")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun diff_labels_stack_above_body_when_narrow() {
        val instructions = "- One\n- Two\n- Three\n- Risks\n- Five\n- Six\n- Seven"
        val rows = SkillImprovePrompt.diffRows(diff(instructions, replaces = "Risks"))
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Column(modifier = Modifier.width(240.dp)) { SkillImproveDiffRows(rows) }
            }
        }
        composeRule.waitForIdle()

        val removedLabel = activity.getString(R.string.skills_improve_removedLine)
        assertEquals("de resources are in use", "Entfernt", removedLabel)
        val label = composeRule.onNodeWithText(removedLabel).getBoundsInRoot()
        val body = composeRule.onNodeWithText("- Risks").getBoundsInRoot()
        assertTrue("label sits above the body: ${label.bottom} <= ${body.top}", label.bottom.value <= body.top.value + 0.5f)
        val contextLeft = composeRule.onNodeWithText("- Three").getBoundsInRoot().left.value
        assertEquals("stacked body starts where context text starts", contextLeft, body.left.value, 0.5f)
        assertEquals("label starts at the body edge", body.left.value, label.left.value, 0.5f)
    }

    @Test
    @Config(sdk = [34], qualifiers = "en")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun diff_sheet_actions_are_equal_width() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        assertEquals("en resources are in use", "Add to skill", activity.getString(R.string.skills_improve_accept))
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Column(modifier = Modifier.width(360.dp)) {
                    SkillImproveDiffActions(saving = false, onDismiss = {}, onAccept = {})
                }
            }
        }
        composeRule.waitForIdle()

        // Unclipped pixel sizes: bounds in root are clipped to the Robolectric window, which can be narrower than the row.
        val dismiss = composeRule.onNodeWithTag(SKILL_IMPROVE_DISMISS_TAG).fetchSemanticsNode()
        val accept = composeRule.onNodeWithTag(SKILL_IMPROVE_ACCEPT_TAG).fetchSemanticsNode()
        val density = activity.resources.displayMetrics.density
        val gapPx = accept.positionInRoot.x - (dismiss.positionInRoot.x + dismiss.size.width)
        // Short en labels both fit in half the row, so the split is even (odd pixel goes to the accept pill).
        assertTrue(
            "both pills share the row width: ${dismiss.size.width}px vs ${accept.size.width}px",
            abs(dismiss.size.width - accept.size.width) <= 1,
        )
        assertEquals("pills are 10dp apart (density $density)", 10f * density, gapPx, 1.01f)
    }

    @Test
    fun diff_action_widths_match_ios() {
        // available = 1010 - 10 = 1000 in every case.
        assertEquals("both fit in half: equal halves", 500 to 500, skillImproveActionWidths(300, 400, 1010, 10))
        assertEquals("long accept keeps its ideal width", 400 to 600, skillImproveActionWidths(300, 600, 1010, 10))
        assertEquals("long dismiss keeps its ideal width", 600 to 400, skillImproveActionWidths(600, 300, 1010, 10))
        assertEquals("both too long: split by ideal ratio", 400 to 600, skillImproveActionWidths(600, 900, 1010, 10))
        assertEquals("odd remainder goes to accept", 333 to 334, skillImproveActionWidths(100, 200, 677, 10))
    }

    @Test
    @Config(sdk = [34], qualifiers = "de")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun diff_actions_de_narrow_stay_one_row() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val acceptLabel = activity.getString(R.string.skills_improve_accept)
        assertEquals("de resources are in use", "Zur Fähigkeit hinzufügen", acceptLabel)
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Column(modifier = Modifier.width(360.dp)) {
                    SkillImproveDiffActions(saving = false, onDismiss = {}, onAccept = {})
                }
            }
        }
        composeRule.waitForIdle()

        val dismiss = composeRule.onNodeWithTag(SKILL_IMPROVE_DISMISS_TAG).fetchSemanticsNode()
        val accept = composeRule.onNodeWithTag(SKILL_IMPROVE_ACCEPT_TAG).fetchSemanticsNode()
        assertEquals("both pills share one row", dismiss.positionInRoot.y, accept.positionInRoot.y, 0.5f)
        assertTrue("dismiss sits at the start edge", dismiss.positionInRoot.x < accept.positionInRoot.x)
        assertTrue(
            "the long accept label gets the wider pill: ${dismiss.size.width}px vs ${accept.size.width}px",
            accept.size.width > dismiss.size.width,
        )
        val layouts = mutableListOf<TextLayoutResult>()
        composeRule.onNodeWithText(acceptLabel).fetchSemanticsNode()
            .config[SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
        val label = layouts.single()
        assertEquals("accept label stays on one line", 1, label.lineCount)
        assertFalse("accept label is not cut off", label.hasVisualOverflow)
    }

    @Test
    fun accept_button_fill_contrast_meets_aa() {
        val choices = listOf(
            DarkPaletteChoice.Default,
            DarkPaletteChoice.Custom(0xFBBF24),
            DarkPaletteChoice.Custom(0x2DD4BF),
        )
        for (choice in choices) {
            val palettes = listOf(
                "dark" to choice.colors,
                "light" to lightOriveoColorsOf(choice.lightBrand),
            )
            for ((mode, colors) in palettes) {
                val ratio = OriveoCustomPalette.contrast(
                    colors.onPrimary.toArgb() and 0xFFFFFF,
                    colors.primaryFillText.toArgb() and 0xFFFFFF,
                )
                assertTrue("$choice $mode onPrimary on primaryFillText = $ratio", ratio >= 4.5)
            }
        }
    }

    @Test
    fun replace_at_first_line_has_no_lines_above() {
        val rows = SkillImprovePrompt.diffRows(diff("- Risks\n- Two", replaces = "Risks"))
        assertEquals(listOf(RowKind.Removed, RowKind.Added, RowKind.Context), rows.map { it.kind })
    }

    @Test
    fun append_rows_only_have_lines_above() {
        val rows = SkillImprovePrompt.diffRows(diff("- One\n- Two\n- Three"))
        assertEquals(listOf(RowKind.Context, RowKind.Context, RowKind.Added), rows.map { it.kind })
        assertEquals(listOf("- Two", "- Three", "- $rule"), rows.map { it.text })
    }

    @Test
    fun accept_puts_instructions_only_then_reports_and_clears() = runTest {
        val request = slot<UpdateSkillRequest>()
        coEvery { repository.update(skillId, capture(request)) } answers {
            skill.copy(systemPrompt = request.captured.systemPrompt.orEmpty())
        }
        val host = requireNotNull(host())
        val sheet = SkillImproveSheetModel().apply { review() }

        sheet.accept(host.accept)

        assertEquals(UpdateSkillRequest(systemPrompt = "$base\n- $rule"), request.captured)
        assertFalse("panel closes on success", sheet.open)
        assertEquals(1, accepted)
        val event = telemetry.tracked.single { it.first == TelemetryEvent.SkillImproveAccepted }
        assertEquals(mapOf("skill_id" to skillId, "op" to "add"), event.second)
        val toast = toasts.single().message as UiText.Resource
        assertEquals(R.string.skills_improve_saved, toast.resId)
        assertEquals(listOf<Any>("Weekly report"), toast.args)
    }

    @Test
    fun failed_put_shows_save_failed_and_keeps_panel() = runTest {
        coEvery { repository.update(any(), any()) } throws IllegalStateException("offline")
        val host = requireNotNull(host())
        val sheet = SkillImproveSheetModel().apply { review() }

        sheet.accept(host.accept)

        assertTrue(sheet.open)
        assertEquals(R.string.skills_saveFailed, sheet.errorRes)
        assertEquals(0, accepted)
        assertTrue(telemetry.tracked.none { it.first == TelemetryEvent.SkillImproveAccepted })
        assertTrue(toasts.isEmpty())
    }

    @Test
    fun conflict_copy_with_other_instructions_counts_as_failure() = runTest {
        coEvery { repository.update(any(), any()) } returns skill.copy(systemPrompt = "- Server copy")
        val host = requireNotNull(host())

        assertFalse(host.accept())
        assertEquals(0, accepted)
    }

    @Test
    fun refused_change_never_writes() = runTest {
        // The cached skill already holds the rule, so the recomputed diff is empty.
        val withRule = skill.copy(systemPrompt = "$base\n- $rule")
        val host = requireNotNull(
            SkillImprovePrompt.host(
                pending(),
                SkillPickerCache(mine = listOf(withRule), templates = emptyList()),
                { messages },
                SkillImprovePrompt.SuggestedReporter(),
                acceptor,
            ) { dismissed++ },
        )

        assertFalse(host.accept())
        coVerify(exactly = 0) { repository.update(any(), any()) }
    }

    @Test
    fun suggested_reported_once_per_prompt() {
        val reporter = SkillImprovePrompt.SuggestedReporter()
        val first = requireNotNull(host(reporter = reporter))
        first.onShown()
        first.onShown()
        val suggested = telemetry.tracked.filter { it.first == TelemetryEvent.SkillImproveSuggested }
        assertEquals(1, suggested.size)
        assertEquals(mapOf("skill_id" to skillId, "op" to "add"), suggested.single().second)

        requireNotNull(host(pending = pending(userMessageId = "u-1"), reporter = reporter)).onShown()
        assertEquals(2, telemetry.tracked.count { it.first == TelemetryEvent.SkillImproveSuggested })
    }
}
