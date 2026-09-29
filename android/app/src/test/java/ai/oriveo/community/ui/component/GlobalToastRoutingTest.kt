package ai.oriveo.community.ui.component

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Multi-window toast routing: one host per window, only the topmost renders, and when an upper window
 * closes the remaining time hands back to the one below. Every assertion goes through the production
 * [GlobalSnackbarManager] / [GlobalToastHost] / [SheetToastLayer] / [DialogToastLayer], with no hand-made events.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class GlobalToastRoutingTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `root host stays at the bottom even when attached after a sheet`() {
        val manager = GlobalSnackbarManager()
        val root = Any()
        val sheet = Any()
        manager.attachHost(sheet, isRoot = false)
        manager.attachHost(root, isRoot = true)
        assertSame(sheet, manager.topHost.value)

        val nested = Any()
        manager.attachHost(nested, isRoot = false)
        assertSame(nested, manager.topHost.value)

        manager.detachHost(nested)
        manager.detachHost(sheet)
        assertSame(root, manager.topHost.value)
        manager.detachHost(root)
        assertNull(manager.topHost.value)
    }

    @Test
    fun `handover keeps only the remaining duration and dismiss ignores superseded toasts`() {
        var now = 0L
        val manager = GlobalSnackbarManager(nanoClock = { now })
        manager.show(GlobalSnackbarMessage(UiText.Dynamic("first")))
        val first = manager.active.value!!
        now = 1_000_000_000L
        assertEquals(2_000L, manager.remainingMillis(first, 3_000L))

        manager.show(GlobalSnackbarMessage(UiText.Dynamic("second")))
        manager.dismiss(first)
        assertEquals("second", (manager.active.value!!.message.message as UiText.Dynamic).value)
    }

    @Test
    fun `a toast renders once in the topmost host and falls back to root when the sheet closes`() {
        val manager = GlobalSnackbarManager()
        val sheetOpen = mutableStateOf(true)
        launch(manager, sheetOpen)

        composeRule.runOnIdle { manager.show(GlobalSnackbarMessage(UiText.Dynamic("Routed marker"))) }
        composeRule.waitForIdle()
        // Both the root host and the sheet host are attached; only one copy may appear
        composeRule.onAllNodesWithText("Routed marker").assertCountEquals(1)

        composeRule.runOnIdle { sheetOpen.value = false }
        composeRule.waitForIdle()
        // Still within its display time after the sheet closes: the root host keeps showing it instead of it vanishing with the sheet
        composeRule.onAllNodesWithText("Routed marker").assertCountEquals(1)
    }

    @Test
    fun `full-screen dialog layer takes the toast and hands it back to root when closed`() {
        val manager = GlobalSnackbarManager()
        val dialogOpen = mutableStateOf(true)
        launch(manager, dialogOpen, fullScreenDialog = true)

        composeRule.runOnIdle { manager.show(GlobalSnackbarMessage(UiText.Dynamic("Dialog marker"))) }
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText("Dialog marker").assertCountEquals(1)

        composeRule.runOnIdle { dialogOpen.value = false }
        composeRule.waitForIdle()
        composeRule.onAllNodesWithText("Dialog marker").assertCountEquals(1)
    }

    private fun launch(
        manager: GlobalSnackbarManager,
        sheetOpen: MutableState<Boolean>,
        fullScreenDialog: Boolean = false,
    ) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Box {
                    GlobalToastHost(manager = manager, isRoot = true)
                    if (sheetOpen.value) {
                        if (fullScreenDialog) {
                            DialogToastLayer(manager = manager) { Text("Dialog body") }
                        } else {
                            SheetToastLayer(manager = manager) { Text("Sheet body") }
                        }
                    }
                }
            }
        }
        composeRule.waitForIdle()
    }
}
