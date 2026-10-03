package ai.oriveo.community.feature.chat.mcp

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpConfirmationChoice
import ai.oriveo.community.core.mcp.McpConfirmationCoordinator
import ai.oriveo.community.core.mcp.McpConfirmationRequest
import ai.oriveo.community.core.mcp.McpErrorCode
import ai.oriveo.community.core.mcp.McpJson
import ai.oriveo.community.core.mcp.McpStepPayload
import ai.oriveo.community.core.mcp.McpToolAvailability
import ai.oriveo.community.core.mcp.McpToolPanelServerRow
import ai.oriveo.community.core.mcp.McpToolPanelState
import ai.oriveo.community.core.mcp.McpToolStep
import ai.oriveo.community.core.mcp.McpToolStepUpdate
import ai.oriveo.community.feature.chat.components.StreamActivityLabel
import ai.oriveo.community.feature.chat.components.streamActivityLabelText
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Rendering behaviour of the remote MCP UI in chat: each designed state is rendered once and read through the real semantics tree.
 *
 * Bottom sheets render the sheet content itself (`McpSheetBody { … }`): under Robolectric the `ModalBottomSheet` window is not part of
 * the test semantics tree, and there is no logic between the content and its shell.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McpChatUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity

    private fun render(dark: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = dark) { Column(content = content) } }
        composeRule.waitForIdle()
    }

    private fun renderSheet(dark: Boolean = false, content: @Composable ColumnScope.() -> Unit) =
        render(dark) { McpSheetBody(content = content) }

    private fun text(id: Int, vararg args: Any): String = activity.getString(id, *args)

    private fun plural(id: Int, count: Int, vararg args: Any): String =
        activity.resources.getQuantityString(id, count, *(if (args.isEmpty()) arrayOf<Any>(count) else args))

    // ── Tool panel ─────────────────────────────────────────────

    private fun row(
        id: String,
        name: String,
        tools: Int,
        status: McpToolPanelServerRow.Status = McpToolPanelServerRow.Status.Ready,
        enabled: Boolean = false,
    ) = McpToolPanelServerRow(id = id, name = name, iconURL = null, toolCount = tools, status = status, isEnabled = enabled)

    private fun panel(
        availability: McpToolAvailability = McpToolAvailability.Available,
        rows: List<McpToolPanelServerRow> = listOf(
            row("linear", "Linear", 7, enabled = true),
            row("notion", "Notion", 14),
            row("github", "GitHub", 3, McpToolPanelServerRow.Status.NeedsAuth),
            row("nas", "Home NAS", 2, McpToolPanelServerRow.Status.Unreachable(lastSuccessAt = null)),
        ),
        truncated: Boolean = false,
    ) = McpToolPanelState(
        availability = availability, rows = rows, outboundToolCount = 7, estimatedTokens = 1800,
        truncated = truncated, maxToolsPerRequest = 40,
    )

    @Test
    fun `tool picker lists servers with switches re-sign-in and the cost note`() {
        val toggles = mutableListOf<Pair<String, Boolean>>()
        var reauthorized: String? = null
        var managed = 0
        renderSheet {
            McpToolPanelContent(
                state = panel(),
                onToggle = { id, on -> toggles += id to on },
                onReauthorize = { reauthorized = it },
                onManageServers = { managed += 1 },
                onAddServer = {},
                onSwitchModel = {},
            )
        }

        composeRule.onNodeWithText(text(R.string.mcp_panel_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_subtitle)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_panel_tool_count, 7)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_sign_in_expired)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_cant_connect)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_panel_footer, 7, 7, "1,800")).assertIsDisplayed()

        composeRule.onNodeWithContentDescription("Linear").assertIsOn()
        composeRule.onNodeWithContentDescription("Notion").assertIsOff().assertIsEnabled().performClick()
        composeRule.onNodeWithContentDescription("Home NAS").assertIsOff().assertIsNotEnabled()
        // A row whose sign-in expired offers "Sign in again" and has no switch.
        composeRule.onAllNodes(androidx.compose.ui.test.hasContentDescription("GitHub")).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_sign_in_again)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_panel_manage)).performClick()
        composeRule.waitForIdle()

        assertEquals(listOf("notion" to true), toggles)
        assertEquals("github", reauthorized)
        assertEquals(1, managed)
    }

    /** Counts use plural forms: one tool reads "1 tool" and "1 tool on. Its description…", never "1 tools". */
    @Test
    fun `one tool reads as 1 tool in the row and in the cost note`() {
        renderSheet {
            McpToolPanelContent(
                state = McpToolPanelState(
                    availability = McpToolAvailability.Available, rows = listOf(row("linear", "Linear", 1, enabled = true)),
                    outboundToolCount = 1, estimatedTokens = 200, truncated = false, maxToolsPerRequest = 40,
                ),
                onToggle = { _, _ -> }, onReauthorize = {}, onManageServers = {}, onAddServer = {}, onSwitchModel = {},
            )
        }
        composeRule.onNodeWithText("1 tool", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(
            "1 tool on. Its description is sent with every request, about 200 tokens, billed at your model’s price.",
        ).assertIsDisplayed()
    }

    @Test
    fun `too many tools replaces the cost note with a warning`() {
        renderSheet {
            McpToolPanelContent(panel(truncated = true), { _, _ -> }, {}, {}, {}, {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_panel_footer_truncated, 40, 40)).assertIsDisplayed()
        composeRule.onAllNodesWithText(plural(R.plurals.mcp_panel_footer, 7, 7, "1,800")).assertCountEquals(0)
    }

    @Test
    fun `with no servers the panel leads to adding one`() {
        var added = 0
        renderSheet {
            McpToolPanelContent(panel(rows = emptyList()), { _, _ -> }, {}, {}, { added += 1 }, {})
        }

        composeRule.onNodeWithText(text(R.string.mcp_panel_empty_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_empty_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_add_server)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, added)
    }

    @Test
    fun `a model without tool calling explains why tools are unavailable and locks the list`() {
        var switched = 0
        val toggles = mutableListOf<String>()
        renderSheet {
            McpToolPanelContent(
                panel(availability = McpToolAvailability.ModelUnsupported),
                { id, _ -> toggles += id }, {}, {}, {}, { switched += 1 },
            )
        }

        composeRule.onNodeWithText(text(R.string.mcp_panel_unavailable_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_unavailable_model)).assertIsDisplayed()
        // Servers that were on also show as off and cannot be flipped.
        composeRule.onNodeWithContentDescription("Linear").assertIsOff().assertIsNotEnabled()
        composeRule.onAllNodesWithText(text(R.string.mcp_sign_in_again)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_panel_switch_model)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, switched)
        assertTrue(toggles.isEmpty())
    }

    // ── Step block ─────────────────────────────────────────────

    private fun step(
        number: Int,
        status: McpToolStepUpdate.Status,
        server: String = "Linear",
        title: String = "Search issues",
        summary: String = "",
        errorCode: McpErrorCode? = null,
    ) = McpToolStep(
        id = "$number:c$number", serverId = "s-$server", serverName = server, toolName = "tool_$number", title = title,
        argsSummary = summary, status = status.wireValue, errorCode = errorCode?.wireValue, step = number, durationMs = 1200,
    )

    private val doneSteps = listOf(
        step(1, McpToolStepUpdate.Status.Done, summary = "open · bug"),
        step(2, McpToolStepUpdate.Status.Done, title = "Read issue", summary = "12"),
        step(3, McpToolStepUpdate.Status.Done, "Notion", "Find page", "Sprint notes"),
        step(4, McpToolStepUpdate.Status.Done, "Notion", "Create page", "Week 40"),
    )

    @Test
    fun `while tools run the block is open and names the step in progress`() {
        val selected = mutableListOf<String>()
        render {
            McpToolStepsBlock(
                steps = doneSteps.take(2) + step(3, McpToolStepUpdate.Status.Running, "Notion", "Find page", "Sprint notes"),
                isGenerating = true,
                onSelectStep = { selected += it.id },
            )
        }

        composeRule.onNodeWithText(text(R.string.mcp_steps_running)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_steps_step, 3)).assertIsDisplayed()
        composeRule.onNodeWithText("Linear · Search issues").assertIsDisplayed()
        composeRule.onNodeWithText("open · bug").assertIsDisplayed()
        composeRule.onNodeWithText("Notion · Find page").assertIsDisplayed()
        composeRule.onNodeWithContentDescription(text(R.string.mcp_status_done), useUnmergedTree = true)
        // The step still running cannot open its detail; finished ones can.
        composeRule.onNodeWithText("Notion · Find page").performClick()
        composeRule.onNodeWithText("Linear · Search issues").performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("1:c1"), selected)
    }

    @Test
    fun `a finished block is one line until opened and each step opens its detail`() {
        val selected = mutableListOf<String>()
        render { McpToolStepsBlock(steps = doneSteps, isGenerating = false, onSelectStep = { selected += it.id }) }

        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 4)).assertIsDisplayed()
        composeRule.onNodeWithText("Linear · Notion").assertIsDisplayed()
        composeRule.onAllNodesWithText("Notion · Create page").assertCountEquals(0)

        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 4)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Notion · Create page").assertIsDisplayed().performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("4:c4"), selected)
    }

    @Test
    fun `the block folds itself when the answer completes unless the user opened it`() {
        var generating by mutableStateOf(true)
        render { McpToolStepsBlock(steps = doneSteps, isGenerating = generating) }
        composeRule.onNodeWithText("Notion · Create page").assertIsDisplayed()

        generating = false
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText("Notion · Create page").assertCountEquals(0)
    }

    @Test
    fun `a block the user toggled by hand is not folded behind their back`() {
        var generating by mutableStateOf(true)
        render { McpToolStepsBlock(steps = doneSteps, isGenerating = generating) }
        // Collapsing then expanding by hand = the user has stated a preference.
        composeRule.onNodeWithText(text(R.string.mcp_steps_running)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_steps_running)).performClick()
        composeRule.waitForIdle()

        generating = false
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Notion · Create page").assertIsDisplayed()
    }

    @Test
    fun `a declined write says nothing was changed`() {
        render {
            McpToolStepsBlock(
                steps = doneSteps.take(3) + step(4, McpToolStepUpdate.Status.Denied, "Notion", "Create page", errorCode = McpErrorCode.UserDenied),
                isGenerating = false,
            )
        }
        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 3)).assertIsDisplayed().performClick()
        composeRule.onNodeWithText(text(R.string.mcp_steps_declined, 1)).assertIsDisplayed()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_step_declined)).assertIsDisplayed()
        composeRule.onNodeWithContentDescription(text(R.string.mcp_status_declined), useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun `a failed step explains the failure without protocol words`() {
        render {
            McpToolStepsBlock(
                steps = doneSteps.take(2) + step(3, McpToolStepUpdate.Status.Failed, "Notion", "Find page", errorCode = McpErrorCode.ToolError),
                isGenerating = false,
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_steps_failed, 1)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 2)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_failure_tool_error)).assertIsDisplayed()
        composeRule.onNodeWithContentDescription(text(R.string.mcp_status_failed), useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun `an expired sign-in pauses the block with re-sign-in and skip`() {
        val actions = mutableListOf<String>()
        val paused = step(3, McpToolStepUpdate.Status.NeedsAuth, "Notion", "Find page", errorCode = McpErrorCode.NeedsAuth)
        render {
            McpToolStepsBlock(
                steps = doneSteps.take(2) + paused,
                isGenerating = true,
                pausedStepId = paused.id,
                onReauthorize = { actions += "reauthorize:${it.id}" },
                onSkipStep = { actions += "skip:${it.id}" },
            )
        }

        composeRule.onNodeWithText(text(R.string.mcp_steps_waiting_sign_in)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_steps_step, 3)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_step_sign_in_expired, "Notion")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_step_resume_note)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_sign_in_again)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_step_skip)).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("reauthorize:3:c3", "skip:3:c3"), actions)
    }

    @Test
    fun `at the step limit earlier steps collapse and the tail says so`() {
        val steps = (1..8).map { step(it, McpToolStepUpdate.Status.Done, title = "Read issue $it") }
        render { McpToolStepsBlock(steps = steps, isGenerating = false, limitReached = true) }

        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 8)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_steps_limit_reached)).assertIsDisplayed()
        composeRule.onAllNodesWithText("Linear · Read issue 1").assertCountEquals(0)
        composeRule.onNodeWithText("Linear · Read issue 8").assertIsDisplayed()

        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_show_earlier, 6)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Linear · Read issue 1").assertIsDisplayed()
    }

    @Test
    fun `an interrupted step reads as interrupted`() {
        render {
            McpToolStepsBlock(steps = listOf(step(1, McpToolStepUpdate.Status.Interrupted, errorCode = McpErrorCode.Interrupted)), isGenerating = false)
        }
        composeRule.onNodeWithText(plural(R.plurals.mcp_steps_used, 0)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_step_interrupted)).assertIsDisplayed()
    }

    // ── Confirmation sheet and full-text page ──────────────────

    private val longBody = "Week 40 open bugs\n" + "line of the report. ".repeat(40)

    private fun confirmRequest() = McpConfirmationRequest(
        conversationId = "c1", serverId = "s1", serverName = "Notion", serverHost = "mcp.notion.com",
        toolName = "create_page", toolTitle = "Create page",
        arguments = McpJson.parse(
            "{\"parent\":\"Sprint notes\",\"title\":\"Week 40\",\"content\":${McpJson.encodeString(longBody)}}",
        ),
        inputSchema = JsonObject(emptyMap()),
    )

    @Test
    fun `confirmation shows what is about to be sent and offers three choices`() {
        val choices = mutableListOf<McpConfirmationChoice>()
        renderSheet { McpConfirmationContentView(confirmRequest(), confirmationId = "k1", onChoose = { choices += it }) }

        composeRule.onNodeWithText(text(R.string.mcp_confirm_title, "Notion", "Create page")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_subtitle, "Notion")).assertIsDisplayed()
        composeRule.onNodeWithText("Notion · mcp.notion.com").assertIsDisplayed()
        // Keys are the parameter names exactly as the server defines them.
        composeRule.onNodeWithText("parent").assertIsDisplayed()
        composeRule.onNodeWithText("Sprint notes").assertIsDisplayed()
        composeRule.onNodeWithText("content").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_about_characters, longBody.length)).assertIsDisplayed()

        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_once)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_conversation)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).performClick()
        composeRule.waitForIdle()
        assertEquals(
            listOf(McpConfirmationChoice.Once, McpConfirmationChoice.Conversation, McpConfirmationChoice.Deny),
            choices,
        )
    }

    @Test
    fun `view all opens the full text with only allow once and decline and back returns`() {
        val choices = mutableListOf<McpConfirmationChoice>()
        renderSheet { McpConfirmationContentView(confirmRequest(), confirmationId = "k1", onChoose = { choices += it }) }

        composeRule.onNodeWithText(text(R.string.mcp_confirm_view_all)).performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText(text(R.string.mcp_confirm_full_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_full_note, "Notion")).assertIsDisplayed()
        composeRule.onNode(androidx.compose.ui.test.hasText("Week 40 open bugs", substring = true)).assertExists()
        composeRule.onAllNodesWithText(text(R.string.mcp_confirm_allow_conversation)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_once)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).performClick()
        composeRule.onNodeWithContentDescription(text(R.string.back)).performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_conversation)).assertIsDisplayed()
        assertEquals(listOf(McpConfirmationChoice.Once, McpConfirmationChoice.Deny), choices)
    }

    /**
     * The confirmation host lives at the navigation root and follows the user: the confirmation appears even when the conversation that started the answer is not on screen,
     * and the user's choice travels back to the suspended loop through the real [McpConfirmationCoordinator].
     */
    @Test
    fun `the root host presents a confirmation from a conversation that is not on screen and returns the choice`() {
        val coordinator = McpConfirmationCoordinator()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val answer = scope.async { coordinator.requestConfirmation(confirmRequest().copy(conversationId = "a-chat-the-user-left")) }
            runBlocking { withTimeout(5_000) { coordinator.pending.first { it.isNotEmpty() } } }

            renderSheet { currentMcpConfirmation(coordinator)?.let { McpConfirmationHostContent(it, coordinator, store = null) } }

            composeRule.onNodeWithText(text(R.string.mcp_confirm_title, "Notion", "Create page")).assertIsDisplayed()
            composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).performClick()
            composeRule.waitForIdle()
            assertEquals(McpConfirmationChoice.Deny, runBlocking { withTimeout(5_000) { answer.await() } })
            assertTrue(coordinator.pending.value.isEmpty())
            composeRule.onAllNodesWithText(text(R.string.mcp_confirm_decline)).assertCountEquals(0)
        } finally {
            scope.cancel()
        }
    }

    /**
     * The sheet is triggered by the model, so it may appear at the very moment the user presses Enter. With a hardware keyboard the default focus lands on Decline,
     * never on an approve button; the same holds for the "View all" layer.
     */
    @Test
    fun `with a hardware keyboard the default focus is on decline not on an approve button`() {
        val keyboard = object : InputModeManager {
            override val inputMode: InputMode = InputMode.Keyboard
            override fun requestInputMode(inputMode: InputMode): Boolean = inputMode == InputMode.Keyboard
        }
        renderSheet {
            CompositionLocalProvider(LocalInputModeManager provides keyboard) {
                McpConfirmationContentView(confirmRequest(), confirmationId = "k1", onChoose = {})
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).assertIsFocused()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_once)).assertIsNotFocused()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_conversation)).assertIsNotFocused()

        composeRule.onNodeWithText(text(R.string.mcp_confirm_view_all)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).assertIsFocused()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_once)).assertIsNotFocused()
    }

    /** Bottom sheet padding is 30 / 20 / 34: the last button sits 34 above the bottom edge of the sheet. */
    @Test
    fun `the sheet leaves 34 below its last button`() {
        renderSheet { McpConfirmationContentView(confirmRequest(), confirmationId = "k1", onChoose = {}) }
        val sheetBottom = composeRule.onNodeWithTag(MCP_SHEET_BODY_TAG).getUnclippedBoundsInRoot().bottom
        val buttonBottom = composeRule.onNodeWithText(text(R.string.mcp_confirm_decline)).getUnclippedBoundsInRoot().bottom
        assertEquals(34f, (sheetBottom - buttonBottom).value, 0.5f)
    }

    // ── Step detail ────────────────────────────────────────────

    @Test
    fun `step detail shows the stored parameters and result`() {
        renderSheet {
            McpStepDetailContent(
                McpStepDetailState(
                    messageId = "m1",
                    step = step(1, McpToolStepUpdate.Status.Done, summary = "open · bug"),
                    payload = McpStepPayload(arguments = "{\"label\":\"bug\",\"state\":\"open\"}", resultPrefix = "ORV-2291 stream stops"),
                    loading = false,
                ),
            )
        }

        composeRule.onNodeWithText("Search issues").assertIsDisplayed()
        composeRule.onNodeWithText(
            text(R.string.mcp_detail_subtitle, "Linear", text(R.string.mcp_detail_seconds, "1.2"), text(R.string.mcp_status_done)),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_sent)).assertIsDisplayed()
        composeRule.onNodeWithText("label: \"bug\"\nstate: \"open\"").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_returned)).assertIsDisplayed()
        composeRule.onNodeWithText("ORV-2291 stream stops").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_third_party_note)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.copy)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text(R.string.copied)).assertIsDisplayed()
    }

    @Test
    fun `without a stored payload the detail says so instead of showing empty blocks`() {
        renderSheet {
            McpStepDetailContent(
                McpStepDetailState("m1", step(1, McpToolStepUpdate.Status.Done), payload = null, loading = false),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_detail_not_on_device)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_detail_sent)).assertCountEquals(0)
        composeRule.onAllNodesWithText(text(R.string.mcp_detail_returned)).assertCountEquals(0)
    }

    // ── Dark theme ─────────────────────────────────────────────

    @Test
    fun `dark theme renders the same structure`() {
        render(dark = true) {
            McpToolStepsBlock(
                steps = doneSteps.take(2) + step(3, McpToolStepUpdate.Status.Running, "Notion", "Find page"),
                isGenerating = true,
            )
            McpSheetBody { McpConfirmationContentView(confirmRequest(), confirmationId = "k1", onChoose = {}) }
        }
        composeRule.onNodeWithText(text(R.string.mcp_steps_running)).assertIsDisplayed()
        composeRule.onNodeWithText("Notion · Find page").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_title, "Notion", "Create page")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_confirm_allow_once)).assertIsDisplayed()
    }

    // ── Activity status line (mcp_tool) ────────────────────────

    @Test
    fun `mcp_tool activity names the server and tool of the running step and falls back without one`() {
        var withStep = ""
        var withoutStep = ""
        render {
            withStep = streamActivityLabelText(
                StreamActivityLabel.McpTool,
                doneSteps.take(1) + step(2, McpToolStepUpdate.Status.Running, "Notion", "Find page"),
            )
            withoutStep = streamActivityLabelText(StreamActivityLabel.McpTool, doneSteps)
        }
        assertEquals(text(R.string.stream_activity_mcp_tool, "Notion", "Find page"), withStep)
        assertEquals(text(R.string.mcp_steps_running), withoutStep)
    }
}
