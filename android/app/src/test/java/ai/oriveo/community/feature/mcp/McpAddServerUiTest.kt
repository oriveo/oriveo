package ai.oriveo.community.feature.mcp

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpToolSnapshot
import ai.oriveo.community.feature.chat.mcp.McpSheetBody
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Each designed state of the add flow is rendered once and read through the real semantics tree. The failure pages live in
 * `McpAddFailureUiTest`.
 *
 * Bottom sheets render the sheet content itself (`McpSheetBody { … }`): under Robolectric the `ModalBottomSheet` window is not part of
 * the test semantics tree, and there is no logic between the content and its shell.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McpAddServerUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity

    private fun render(dark: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = dark) { Column(content = content) } }
        composeRule.waitForIdle()
    }

    private fun text(id: Int, vararg args: Any): String = activity.getString(id, *args)

    private fun plural(id: Int, count: Int, vararg args: Any): String =
        activity.resources.getQuantityString(id, count, *(if (args.isEmpty()) arrayOf<Any>(count) else args))

    private fun tool(name: String, title: String, readOnly: Boolean) = McpToolSnapshot(
        serverId = "s1", toolName = name, title = title, description = null,
        inputSchema = JsonObject(emptyMap()), annotations = JsonObject(emptyMap()),
        contentHash = "h", readOnly = readOnly, pendingReview = true, updatedAt = 1L,
    )

    private val linearTools = listOf(
        tool("search", "Search issues", true),
        tool("get", "Get issue", true),
        tool("list", "List projects", true),
        tool("teams", "List teams", true),
        tool("users", "List users", true),
        tool("create", "Create issue", false),
        tool("update", "Update issue", false),
    )

    // ── Settings entry ─────────────────────────────────────────

    @Test
    fun `settings shows the mcp servers row with its counts and opens the server list`() {
        var opened = 0
        render {
            SettingsToolsSectionContent(
                iconColor = Color.Magenta,
                mcpSummary = McpSettingsEntrySummary(serverCount = 4, attentionCount = 1),
                onNavigateToMcpServers = { opened += 1 },
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_settings_section)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_settings_entry_count_attention, plural(R.plurals.mcp_settings_entry_count, 4), plural(R.plurals.mcp_settings_entry_attention, 1))).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_title)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, opened)
    }

    @Test
    fun `the subtitle says there are no servers yet when none was added`() {
        render { SettingsToolsSectionContent(Color.Magenta, McpSettingsEntrySummary(0, 0), {}) }
        composeRule.onNodeWithText(text(R.string.mcp_servers_empty_title)).assertIsDisplayed()
    }

    /** Counts use plural forms: English never reads "1 servers" or "1 need attention". Asserted on literal values, rendered by the production composable. */
    @Test
    fun `counts read naturally for one - 1 server and 1 needs attention`() {
        render { SettingsToolsSectionContent(Color.Magenta, McpSettingsEntrySummary(1, 1), {}) }
        composeRule.onNodeWithText("1 server · 1 needs attention").assertIsDisplayed()
    }

    @Test
    fun `a single server without attention reads 1 server`() {
        render { SettingsToolsSectionContent(Color.Magenta, McpSettingsEntrySummary(1, 0), {}) }
        composeRule.onNodeWithText("1 server").assertIsDisplayed()
        composeRule.onAllNodesWithText("1 servers").assertCountEquals(0)
    }

    @Test
    fun `the subtitle only mentions attention when something needs it`() {
        render { SettingsToolsSectionContent(Color.Magenta, McpSettingsEntrySummary(2, 0), {}) }
        composeRule.onNodeWithText(plural(R.plurals.mcp_settings_entry_count, 2)).assertIsDisplayed()
    }

    // ── No servers yet ─────────────────────────────────────────

    @Test
    fun `empty state explains the feature gives three promises and offers add server`() {
        var adds = 0
        render {
            McpServersContent(
                state = McpServersUiState(loaded = true, servers = emptyList()),
                onBack = {}, onAddServer = { adds += 1 }, onOpenServer = {},
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_servers_empty_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_empty_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_promise_credentials)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_promise_confirm)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_promise_per_chat)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_server)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, adds)
    }

    @Test
    fun `nothing is drawn before the first read so existing users never see the empty state flash`() {
        render {
            McpServersContent(state = McpServersUiState(loaded = false), onBack = {}, onAddServer = {}, onOpenServer = {})
        }
        composeRule.onAllNodesWithText(text(R.string.mcp_servers_empty_title)).assertCountEquals(0)
        composeRule.onAllNodesWithText(text(R.string.mcp_add_server)).assertCountEquals(0)
    }

    // ── Entering the address ───────────────────────────────────

    /** The form has only an address and a name: no sign-in method picker and no access-token field. */
    @Test
    fun `the form has only address and name and connect is disabled until an address is typed`() {
        var typed = ""
        var connects = 0
        render {
            McpAddServerContent(
                state = McpAddUiState(),
                actions = McpAddActions(onBack = {}, onUrlChange = { typed = it }, onConnect = { connects += 1 }),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_add_subtitle)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_address_hint)).assertIsDisplayed()
        composeRule.onNodeWithContentDescription(text(R.string.mcp_add_name)).assertExists()
        composeRule.onNodeWithText(text(R.string.mcp_add_sign_in_note)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_access_token)).assertCountEquals(0)
        composeRule.onAllNodesWithContentDescription(text(R.string.mcp_access_token)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsNotEnabled()

        composeRule.onNodeWithContentDescription(text(R.string.mcp_add_address)).performTextInput("https://mcp.linear.app/mcp")
        composeRule.waitForIdle()
        assertEquals("https://mcp.linear.app/mcp", typed)
        assertEquals(0, connects)
    }

    @Test
    fun `connect works once an address is filled`() {
        var connects = 0
        render {
            McpAddServerContent(
                state = McpAddUiState(url = "https://mcp.linear.app/mcp"),
                actions = McpAddActions(onBack = {}, onConnect = { connects += 1 }),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(1, connects)
    }

    // ── Progress pages ─────────────────────────────────────────

    private fun progress(stage: McpAddStage, name: String = "", signedIn: Boolean = false) = McpAddUiState(
        url = "https://mcp.linear.app/mcp",
        name = name,
        screen = McpAddScreen.Progress(stage, authorizationHost = "linear.app", signedIn = signedIn),
    )

    @Test
    fun `connecting shows the host name while the name is unknown and the three step checklist`() {
        var cancels = 0
        render { McpAddServerContent(progress(McpAddStage.Connecting), McpAddActions(onBack = {}, onCancel = { cancels += 1 })) }
        composeRule.onNodeWithText("mcp.linear.app").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_connecting)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_found)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_checking)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_reading_tools)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.cancel)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, cancels)
    }

    @Test
    fun `while the system browser is open the checklist says sign-in is needed`() {
        render { McpAddServerContent(progress(McpAddStage.Browser, name = "Linear"), McpAddActions(onBack = {})) }
        composeRule.onNodeWithText(text(R.string.mcp_add_browser)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_sign_in_needed, "Linear")).assertIsDisplayed()
    }

    @Test
    fun `after the callback the second step reads signed in and the tool list is being read`() {
        render { McpAddServerContent(progress(McpAddStage.Finishing, name = "Linear", signedIn = true), McpAddActions(onBack = {})) }
        composeRule.onNodeWithText(text(R.string.mcp_add_finishing)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_signed_in, "Linear")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_step_reading_tools)).assertIsDisplayed()
    }

    // ── Pre-sign-in prompt ─────────────────────────────────────

    @Test
    fun `the sign-in prompt names the sign-in page host and the server host and waits for continue`() {
        var continued = 0
        var cancelled = 0
        render {
            McpSheetBody {
                McpAuthPromptContent(
                    name = "Linear", nameKnown = true, authorizationHost = "linear.app", serverHost = "mcp.linear.app",
                    onContinue = { continued += 1 }, onCancel = { cancelled += 1 },
                )
            }
        }
        composeRule.onNodeWithText(text(R.string.mcp_auth_prompt_title, "Linear")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_auth_prompt_body, "Linear")).assertIsDisplayed()
        composeRule.onNodeWithText("linear.app", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText("mcp.linear.app", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_auth_prompt_hint)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_continue)).performClick()
        composeRule.onNodeWithText(text(R.string.cancel)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, continued)
        assertEquals(1, cancelled)
    }

    @Test
    fun `dark the sign-in prompt renders`() {
        render(dark = true) {
            McpSheetBody {
                McpAuthPromptContent("Linear", true, "linear.app", "mcp.linear.app", onContinue = {}, onCancel = {})
            }
        }
        composeRule.onNodeWithText(text(R.string.mcp_auth_prompt_title, "Linear")).assertIsDisplayed()
    }

    // ── Confirming the default permissions ─────────────────────

    private fun review(tools: List<McpToolSnapshot> = linearTools) = McpAddUiState(
        url = "https://mcp.linear.app/mcp",
        serverName = "Linear",
        screen = McpAddScreen.Review(serverId = "s1", tools = tools),
    )

    @Test
    fun `review shows connected the tool count both groups with default permissions and done`() {
        var finished = 0
        render { McpAddServerContent(review(), McpAddActions(onBack = {}, onFinish = { finished += 1 })) }
        composeRule.onNodeWithText("Linear").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_status_connected)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_panel_tool_count, 7)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_default_permissions)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_group_read_only)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_group_changes_data)).assertIsDisplayed()
        // The summary uses the titles exactly as the server gives them: the first 3 plus the total.
        composeRule.onNodeWithText(text(R.string.mcp_add_group_summary, "Search issues · Get issue · List projects", 5)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_group_summary, "Create issue · Update issue", 2)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_auto)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_ask)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_review_note)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.done)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, finished)
    }

    @Test
    fun `a server without tools replaces the permission card with one sentence and keeps done`() {
        render { McpAddServerContent(review(tools = emptyList()), McpAddActions(onBack = {})) }
        composeRule.onNodeWithText(text(R.string.mcp_no_tools)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_add_default_permissions)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.done)).assertIsEnabled()
    }

    @Test
    fun `dark review renders`() {
        render(dark = true) { McpAddServerContent(review(), McpAddActions(onBack = {})) }
        composeRule.onNodeWithText(text(R.string.mcp_add_default_permissions)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.done)).assertIsDisplayed()
    }
}
