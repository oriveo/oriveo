package ai.oriveo.community.feature.mcp

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpAuthKind
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.core.mcp.McpPendingToolChange
import ai.oriveo.community.core.mcp.McpReauthPhase
import ai.oriveo.community.core.mcp.McpReauthSession
import ai.oriveo.community.core.mcp.McpServerHealth
import ai.oriveo.community.core.mcp.McpServerRecord
import ai.oriveo.community.core.mcp.McpServerSummary
import ai.oriveo.community.core.mcp.McpToolChange
import ai.oriveo.community.core.mcp.McpToolChangeKind
import ai.oriveo.community.core.mcp.McpToolPermission
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
 * Each designed state of the management pages is rendered once and read through the real semantics tree, including the
 * address-needed-again state and the re-sign-in sheet.
 *
 * Bottom sheets and dialogs render the content itself: under Robolectric their windows are not part of the test semantics tree, and there is no logic between the content and its shell.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h1090dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McpManagementUiTest {

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

    private fun record(id: String, name: String) = McpServerRecord(
        id = id, name = name, slug = id, url = "https://mcp.linear.app/mcp", authKind = McpAuthKind.Auto, localOnly = false,
        iconURL = null, createdAt = 1L, updatedAt = 1L,
    )

    private fun summary(id: String, name: String, health: McpServerHealth, tools: Int = 0) =
        McpServerSummary(record(id, name), health, tools, lastSuccessAt = null)

    private fun tool(name: String, title: String, readOnly: Boolean, description: String? = "desc", pending: Boolean = false, oversized: Boolean = false) =
        McpToolSnapshot(
            serverId = "linear", toolName = name, title = title, description = description,
            inputSchema = JsonObject(emptyMap()), annotations = JsonObject(emptyMap()),
            contentHash = "h", readOnly = readOnly, pendingReview = pending, oversized = oversized, updatedAt = 1L,
        )

    private val tools = listOf(
        tool("search", "Search issues", true),
        tool("get", "Get issue", true),
        tool("projects", "List projects", true),
        tool("teams", "List teams", true),
        tool("users", "List users", true),
        tool("create", "Create issue", false, description = "Create a new issue in a team. Requires a title."),
        tool("update", "Update issue", false),
    )

    private fun detail(
        health: McpServerHealth = McpServerHealth.Connected,
        snapshots: List<McpToolSnapshot> = tools,
    ) = McpServerDetailUiState(
        loaded = true,
        summary = summary("linear", "Linear", health, snapshots.size),
        signIn = McpSignInLabel.Browser,
        snapshots = snapshots,
        permissions = mapOf("update" to McpToolPermission.Off),
    )

    // ── Server list ────────────────────────────────────────────

    @Test
    fun `the list shows a card per server with the four status pills and the trust note`() {
        val opened = mutableListOf<String>()
        var adds = 0
        render {
            McpServersContent(
                state = McpServersUiState(
                    loaded = true,
                    servers = listOf(
                        summary("linear", "Linear", McpServerHealth.Connected, tools = 7),
                        summary("notion", "Notion", McpServerHealth.NeedsReview, tools = 14),
                        summary("github", "GitHub", McpServerHealth.NeedsAuth),
                        summary("nas", "Home NAS", McpServerHealth.Unreachable),
                    ),
                ),
                onBack = {}, onAddServer = { adds += 1 }, onOpenServer = { opened += it },
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_servers_added)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_count, 4)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_status_connected)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_panel_tool_count, 7)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_status_tools_changed)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_needs_review)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_sign_in_expired)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_needs_reauth)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_cant_connect)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_trust_note)).assertIsDisplayed()
        // With servers present the large bottom button is gone; the add entry sits on the right of the top bar.
        composeRule.onAllNodesWithText(text(R.string.mcp_add_server)).assertCountEquals(0)
        composeRule.onNodeWithContentDescription(text(R.string.mcp_add_server)).performClick()
        composeRule.onNodeWithText("GitHub").performClick()
        composeRule.waitForIdle()
        assertEquals(1, adds)
        assertEquals(listOf("github"), opened)
    }

    @Test
    fun `a server that needs its address again says so`() {
        render {
            McpServersContent(
                state = McpServersUiState(loaded = true, servers = listOf(summary("nas", "Home NAS", McpServerHealth.NeedsAddress))),
                onBack = {}, onAddServer = {}, onOpenServer = {},
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_status_needs_address)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_servers_needs_address)).assertIsDisplayed()
    }

    // ── Server detail ──────────────────────────────────────────

    @Test
    fun `detail shows the hero rows two tool groups collapsed to three and the actions`() {
        var reloads = 0
        var removes = 0
        val permissionTools = mutableListOf<String>()
        render {
            McpServerDetailContent(
                state = detail(),
                actions = McpDetailActions(
                    onBack = {}, onReloadTools = { reloads += 1 }, onAskRemove = { removes += 1 }, onOpenPermission = { permissionTools += it },
                ),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_status_connected)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_panel_tool_count, 7)).assertIsDisplayed()
        composeRule.onNodeWithText("mcp.linear.app/mcp", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_sign_in_browser), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_never), useUnmergedTree = true).assertIsDisplayed()

        composeRule.onNodeWithText(text(R.string.mcp_group_read_only)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_count, 5)).assertIsDisplayed()
        composeRule.onNodeWithText("Search issues", useUnmergedTree = true).assertIsDisplayed()
        // Each group shows 3 by default; the rest are collapsed.
        composeRule.onAllNodesWithText("List teams", useUnmergedTree = true).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_detail_show_more, 2)).performScrollTo().performClick()
        composeRule.onNodeWithText("List teams", useUnmergedTree = true).assertExists()
        composeRule.onNodeWithText("List users", useUnmergedTree = true).assertExists()

        composeRule.onNodeWithText(text(R.string.mcp_group_changes_data)).assertExists()
        composeRule.onNodeWithText(text(R.string.mcp_permission_off), useUnmergedTree = true).assertExists()
        composeRule.onNodeWithText("Create issue", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithText(text(R.string.mcp_detail_reload_tools)).performScrollTo().performClick()
        composeRule.onNodeWithText(text(R.string.mcp_detail_remove_server)).performScrollTo().performClick()
        composeRule.waitForIdle()
        assertEquals(listOf("create"), permissionTools)
        assertEquals(1, reloads)
        assertEquals(1, removes)
    }

    @Test
    fun `tools that changed offer review changes and say they wait for confirmation`() {
        var opens = 0
        render {
            McpServerDetailContent(
                state = detail(
                    health = McpServerHealth.NeedsReview,
                    snapshots = listOf(tool("search", "Search issues", true, pending = true), tool("big", "Huge tool", false, oversized = true)),
                ),
                actions = McpDetailActions(onBack = {}, onOpenChanges = { opens += 1 }),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_status_tools_changed)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_oversized), useUnmergedTree = true).assertExists()
        composeRule.onNodeWithText(text(R.string.mcp_detail_review_changes)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, opens)
    }

    @Test
    fun `dark detail renders the same structure`() {
        render(dark = true) { McpServerDetailContent(detail(), McpDetailActions(onBack = {})) }
        composeRule.onNodeWithText(text(R.string.mcp_status_connected)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_reload_tools)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_group_read_only)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_remove_server)).assertExists()
    }

    // ── Sign-in expired ────────────────────────────────────────

    @Test
    fun `an expired sign-in swaps the hero button for sign in again and locks the tool list`() {
        var reauths = 0
        val permissionTools = mutableListOf<String>()
        render {
            McpServerDetailContent(
                state = detail(health = McpServerHealth.NeedsAuth),
                actions = McpDetailActions(onBack = {}, onReauthorize = { reauths += 1 }, onOpenPermission = { permissionTools += it }),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_panel_sign_in_expired)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_tools_unavailable)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_detail_reload_tools)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_sign_in_again)).performClick()
        // The tool list is dimmed and not tappable.
        composeRule.onNode(hasText("Search issues")).assertIsNotEnabled()
        composeRule.onNodeWithText(text(R.string.mcp_detail_remove_server)).assertExists()
        composeRule.waitForIdle()
        assertEquals(1, reauths)
        assertEquals(emptyList<String>(), permissionTools)
    }

    // ── Address needed again ───────────────────────────────────

    @Test
    fun `a server whose address is not on this device asks for it and reports a bad one under the field`() {
        var saves = 0
        render {
            McpServerDetailContent(
                state = detail(health = McpServerHealth.NeedsAddress).copy(addressDraft = "https://nas.example.net/mcp?key=1"),
                actions = McpDetailActions(onBack = {}, onSaveAddress = { saves += 1 }),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_status_needs_address)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_needs_address_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_needs_address_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_save_address)).assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(1, saves)
    }

    @Test
    fun `a bad re-entered address shows the field error and disables save`() {
        render {
            McpServerDetailContent(
                state = detail(health = McpServerHealth.NeedsAddress)
                    .copy(addressDraft = "nas.example.net", addressError = McpInvalidUrlReason.Malformed),
                actions = McpDetailActions(onBack = {}),
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_add_error_url)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_detail_save_address)).assertIsNotEnabled()
    }

    // ── Permission of a single tool ────────────────────────────

    @Test
    fun `a tool that changes data recommends ask every time and warns on run automatically`() {
        val chosen = mutableListOf<McpToolPermission>()
        renderSheet {
            McpToolPermissionContent(
                serverName = "Linear",
                tool = tools.first { it.toolName == "create" },
                selected = McpToolPermission.Ask,
                onSelect = { chosen += it },
            )
        }
        composeRule.onNodeWithText("Create issue").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_subtitle, "Linear", text(R.string.mcp_group_changes_data))).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_description_title)).assertIsDisplayed()
        // Shown exactly as the server gives it, untranslated.
        composeRule.onNodeWithText("Create a new issue in a team. Requires a title.").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_recommended), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNode(hasText(text(R.string.mcp_permission_ask))).assertIsSelected()
        composeRule.onNodeWithText(text(R.string.mcp_permission_ask_hint), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_auto_hint_write, "Linear"), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_permission_off_hint), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNode(hasText(text(R.string.mcp_permission_auto))).assertIsNotSelected().performClick()
        composeRule.onNode(hasText(text(R.string.mcp_permission_off))).performClick()
        composeRule.waitForIdle()
        assertEquals(listOf(McpToolPermission.Auto, McpToolPermission.Off), chosen)
    }

    @Test
    fun `a read-only tool recommends run automatically without the data warning`() {
        renderSheet {
            McpToolPermissionContent(
                serverName = "Linear",
                tool = tool("search", "Search issues", true, description = null),
                selected = McpToolPermission.Auto,
                onSelect = {},
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_permission_no_description)).assertIsDisplayed()
        composeRule.onNode(hasText(text(R.string.mcp_permission_auto))).assertIsSelected()
        composeRule.onNodeWithText(text(R.string.mcp_permission_auto_hint_read), useUnmergedTree = true).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_permission_auto_hint_write, "Linear"), useUnmergedTree = true).assertCountEquals(0)
    }

    // ── Tool updates awaiting confirmation ─────────────────────

    private val pendingChanges = listOf(
        McpPendingToolChange(McpToolChangeKind.Added, tool("bulk", "Bulk update issues", false, description = "Update many issues", pending = true), McpToolPermission.Ask),
        McpPendingToolChange(McpToolChangeKind.Changed, tool("search", "Search issues", true, description = "Search, now with more", pending = true), McpToolPermission.Auto),
    )

    @Test
    fun `the changes sheet lists new changed and removed tools and see what changed compares before and now`() {
        var confirms = 0
        var pauses = 0
        renderSheet {
            McpToolsChangedContent(
                serverName = "Linear",
                pending = pendingChanges,
                sheet = McpChangesSheetState(
                    previous = listOf(tool("search", "Search issues", true, description = "Search issues by text")),
                    removed = listOf(McpToolChange(McpToolChangeKind.Removed, "projects", "List projects")),
                ),
                confirming = false,
                onConfirm = { confirms += 1 },
                onPause = { pauses += 1 },
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_changes_title, "Linear")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_changes_subtitle)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_changes_new)).assertIsDisplayed()
        composeRule.onNodeWithText("Bulk update issues").assertIsDisplayed()
        composeRule.onNodeWithText(
            text(R.string.mcp_changes_row_hint, text(R.string.mcp_group_changes_data), text(R.string.mcp_permission_ask)),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_changes_changed)).assertIsDisplayed()
        composeRule.onNodeWithText(
            text(R.string.mcp_changes_row_hint, text(R.string.mcp_group_read_only), text(R.string.mcp_permission_auto)),
        ).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_changes_removed)).assertIsDisplayed()
        composeRule.onNodeWithText("List projects").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_changes_removed_hint)).assertIsDisplayed()

        // "See what changed": a row whose description changed expands into an old/new comparison.
        composeRule.onAllNodesWithText(text(R.string.mcp_changes_see))[1].performClick()
        composeRule.onNodeWithText(text(R.string.mcp_changes_before)).assertExists()
        composeRule.onNodeWithText("Search issues by text").assertExists()
        composeRule.onNodeWithText(text(R.string.mcp_changes_now)).assertExists()
        composeRule.onNodeWithText("Search, now with more").assertExists()

        composeRule.onNodeWithText(text(R.string.mcp_changes_confirm)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_changes_pause)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, confirms)
        assertEquals(1, pauses)
    }

    @Test
    fun `after a confirmation that left tools quarantined the sheet asks to look again`() {
        renderSheet {
            McpToolsChangedContent(
                serverName = "Linear",
                pending = pendingChanges.take(1),
                sheet = McpChangesSheetState(notice = McpChangesNotice.StillPending),
                confirming = false, onConfirm = {}, onPause = {},
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_changes_still_pending)).assertIsDisplayed()
    }

    @Test
    fun `dark the changes sheet renders`() {
        renderSheet(dark = true) {
            McpToolsChangedContent("Linear", pendingChanges, McpChangesSheetState(), confirming = true, onConfirm = {}, onPause = {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_changes_title, "Linear")).assertIsDisplayed()
    }

    // ── Remove confirmation ────────────────────────────────────

    @Test
    fun `the remove dialog names the server explains what is deleted and offers remove and cancel`() {
        var removes = 0
        var cancels = 0
        render {
            McpRemoveConfirmContent(serverName = "Linear", removing = false, failed = false, onRemove = { removes += 1 }, onCancel = { cancels += 1 })
        }
        composeRule.onNodeWithText(text(R.string.mcp_remove_title, "Linear")).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_remove_body)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_remove_failed)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.remove)).performClick()
        composeRule.onNodeWithText(text(R.string.cancel)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, removes)
        assertEquals(1, cancels)
    }

    /** While removing, the button shows only a spinner and no text: a screen reader still announces it as Remove, and as disabled. */
    @Test
    fun `while removing the remove button still has a screen reader label and is disabled`() {
        render { McpRemoveConfirmContent("Linear", removing = true, failed = false, onRemove = {}, onCancel = {}) }
        composeRule.onAllNodesWithText(text(R.string.remove)).assertCountEquals(0)
        composeRule.onNodeWithContentDescription(text(R.string.remove)).assertIsDisplayed().assertIsNotEnabled()
    }

    @Test
    fun `a failed removal says so in the dialog`() {
        render { McpRemoveConfirmContent("Linear", removing = false, failed = true, onRemove = {}, onCancel = {}) }
        composeRule.onNodeWithText(text(R.string.mcp_remove_failed)).assertIsDisplayed()
    }

    // ── Re-sign-in sheet ───────────────────────────────────────

    private fun session(phase: McpReauthPhase) = McpReauthSession("github", "GitHub", phase)

    @Test
    fun `re-sign-in first shows the same prompt as adding with the sign-in page host`() {
        var continued = 0
        renderSheet {
            McpReauthorizationContent(
                session = session(McpReauthPhase.Prompt("github.com", "api.githubcopilot.com")),
                onContinue = { continued += 1 }, onSubmitToken = {}, onRetry = {}, onCancel = {},
            )
        }
        composeRule.onNodeWithText(text(R.string.mcp_auth_prompt_title, "GitHub")).assertIsDisplayed()
        composeRule.onNodeWithText("github.com", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText("api.githubcopilot.com", useUnmergedTree = true).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_continue)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, continued)
    }

    @Test
    fun `re-sign-in for a token server asks for a new token and shows a rejected one as a field error`() {
        renderSheet {
            McpReauthorizationContent(session(McpReauthPhase.Token(rejected = true)), onContinue = {}, onSubmitToken = {}, onRetry = {}, onCancel = {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_reauth_token_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_token_rejected)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.save)).assertIsNotEnabled()
    }

    @Test
    fun `a re-sign-in that did not finish offers to sign in again and one that could not connect offers try again`() {
        var retries = 0
        renderSheet {
            McpReauthorizationContent(session(McpReauthPhase.Failed(unreachable = false)), onContinue = {}, onSubmitToken = {}, onRetry = { retries += 1 }, onCancel = {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_reauth_failed_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_reauth_failed_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_sign_in_again)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, retries)
    }

    @Test
    fun `a re-sign-in that could not reach the server offers try again`() {
        renderSheet {
            McpReauthorizationContent(session(McpReauthPhase.Failed(unreachable = true)), onContinue = {}, onSubmitToken = {}, onRetry = {}, onCancel = {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_add_unreachable_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_reauth_unreachable_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_try_again)).assertIsDisplayed()
    }

    @Test
    fun `while checking or waiting on the browser the sheet only shows progress`() {
        renderSheet {
            McpReauthorizationContent(session(McpReauthPhase.Checking), onContinue = {}, onSubmitToken = {}, onRetry = {}, onCancel = {})
        }
        composeRule.onNodeWithText(text(R.string.mcp_reauth_checking)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.cancel)).assertCountEquals(0)
    }
}
