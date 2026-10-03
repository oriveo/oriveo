package ai.oriveo.community.feature.mcp

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
import ai.oriveo.community.core.mcp.McpInvalidUrlReason
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Each add-failure page is rendered once and read through the real semantics tree, including limit reached, could not save and a rejected token. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McpAddFailureUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity

    private fun render(state: McpAddUiState, actions: McpAddActions = McpAddActions(onBack = {}), dark: Boolean = false) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = dark) { Column { McpAddServerContent(state, actions) } } }
        composeRule.waitForIdle()
    }

    private fun text(id: Int, vararg args: Any): String = activity.getString(id, *args)

    private fun plural(id: Int, count: Int, vararg args: Any): String =
        activity.resources.getQuantityString(id, count, *(if (args.isEmpty()) arrayOf<Any>(count) else args))

    private fun failure(kind: McpAddFailure, name: String = "", url: String = "https://nas.example.net/mcp", token: String = "", max: Int = 0, tokenRejected: Boolean = false) =
        McpAddUiState(url = url, name = name, token = token, screen = McpAddScreen.Failure(kind, max = max, tokenRejected = tokenRejected))

    // ── Bad address ────────────────────────────────────────────

    @Test
    fun `a bad address shows the error under the field and disables connect`() {
        render(McpAddUiState(url = "linear.app/mcp", urlError = McpInvalidUrlReason.Malformed))
        composeRule.onNodeWithText(text(R.string.mcp_add_error_url)).assertIsDisplayed()
        // While the error shows, the field hint gives way to the error text.
        composeRule.onAllNodesWithText(text(R.string.mcp_add_address_hint)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsNotEnabled()
    }

    @Test
    fun `an address with a username or password explains to use an access token instead`() {
        render(McpAddUiState(url = "https://alice:secret@mcp.example.com/mcp", urlError = McpInvalidUrlReason.HasUserinfo))
        composeRule.onNodeWithText(text(R.string.mcp_add_error_url_userinfo)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsNotEnabled()
    }

    // ── Cannot connect ─────────────────────────────────────────

    @Test
    fun `cannot connect offers try again and edit address`() {
        var retries = 0
        var edits = 0
        render(failure(McpAddFailure.Unreachable), McpAddActions(onBack = {}, onRetry = { retries += 1 }, onEditAddress = { edits += 1 }))
        composeRule.onNodeWithText("nas.example.net").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_panel_cant_connect)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_unreachable_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_unreachable_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_try_again)).performClick()
        composeRule.onNodeWithText(text(R.string.mcp_add_edit_address)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, retries)
        assertEquals(1, edits)
    }

    @Test
    fun `dark cannot connect renders`() {
        render(failure(McpAddFailure.Unreachable), dark = true)
        composeRule.onNodeWithText(text(R.string.mcp_add_unreachable_title)).assertIsDisplayed()
    }

    // ── Not an MCP server ──────────────────────────────────────

    @Test
    fun `not an mcp server only offers edit address`() {
        var edits = 0
        render(failure(McpAddFailure.NotMcp), McpAddActions(onBack = {}, onEditAddress = { edits += 1 }))
        composeRule.onNodeWithText(text(R.string.mcp_add_not_mcp_status)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_not_mcp_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_not_mcp_body)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_try_again)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.mcp_add_edit_address)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, edits)
    }

    // ── Access token needed ────────────────────────────────────

    @Test
    fun `token needed has the token field in place and connect waits for a token`() {
        render(failure(McpAddFailure.NeedsToken, name = "GitHub"))
        composeRule.onNodeWithText("GitHub").assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_needs_token_status)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_needs_token_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_needs_token_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_token_note)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsNotEnabled()
    }

    @Test
    fun `with a token typed connect is enabled`() {
        var connects = 0
        render(failure(McpAddFailure.NeedsToken, name = "GitHub", token = "pat"), McpAddActions(onBack = {}, onConnectWithToken = { connects += 1 }))
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsEnabled().performClick()
        composeRule.waitForIdle()
        assertEquals(1, connects)
    }

    @Test
    fun `a rejected token shows the field error and connect waits for a new one`() {
        render(failure(McpAddFailure.NeedsToken, name = "GitHub", token = "pat", tokenRejected = true))
        composeRule.onNodeWithText(text(R.string.mcp_add_token_rejected)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_connect)).assertIsNotEnabled()
    }

    // ── Sign-in not finished ───────────────────────────────────

    @Test
    fun `sign-in not finished offers sign in again and cancel`() {
        var retries = 0
        var leaves = 0
        render(failure(McpAddFailure.AuthCancelled, name = "Linear"), McpAddActions(onBack = {}, onRetry = { retries += 1 }, onLeave = { leaves += 1 }))
        composeRule.onNodeWithText(text(R.string.mcp_add_auth_cancelled_status)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_auth_cancelled_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_auth_cancelled_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_sign_in_again)).performClick()
        composeRule.onNodeWithText(text(R.string.cancel)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, retries)
        assertEquals(1, leaves)
    }

    // ── Limit reached / could not save ─────────────────────────

    @Test
    fun `limit reached names the limit and only offers to close`() {
        var leaves = 0
        render(failure(McpAddFailure.LimitReached, max = 20), McpAddActions(onBack = {}, onLeave = { leaves += 1 }))
        composeRule.onNodeWithText(text(R.string.mcp_add_limit_title)).assertIsDisplayed()
        composeRule.onNodeWithText(plural(R.plurals.mcp_add_limit_body, 20)).assertIsDisplayed()
        composeRule.onAllNodesWithText(text(R.string.mcp_try_again)).assertCountEquals(0)
        composeRule.onNodeWithText(text(R.string.close)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, leaves)
    }

    @Test
    fun `could not save offers try again`() {
        var retries = 0
        render(failure(McpAddFailure.SaveFailed), McpAddActions(onBack = {}, onRetry = { retries += 1 }))
        composeRule.onNodeWithText(text(R.string.mcp_add_save_failed_title)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_add_save_failed_body)).assertIsDisplayed()
        composeRule.onNodeWithText(text(R.string.mcp_try_again)).performClick()
        composeRule.waitForIdle()
        assertEquals(1, retries)
    }
}
