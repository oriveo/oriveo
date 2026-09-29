package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.ui.component.GlobalToastHost
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.theme.OriveoTheme
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithText
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.After
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.compose.KoinApplication
import org.koin.dsl.module
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A global toast raised while the model picker is open must be rendered inside the picker's own window,
 * and only once.
 *
 * `GlobalToastHost` is mounted in the root window, but a `ModalBottomSheet` draws in a separate window
 * above it. The Home and chat pickers are nearly full height, so the "added" toast shown after tapping
 * "+" was completely covered: the model disappeared from the list with no confirmation.
 *
 * This mounts things the way production does: a root host plus [ModelPickerSheet] inside
 * [OriveoModalBottomSheet]. The message must be rendered once, by the host in the sheet window; the
 * root host must not draw a second copy in the covered main window.
 */
@OptIn(ExperimentalMaterial3Api::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ModelPickerToastTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val snackbar = GlobalSnackbarManager()

    private val provider = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = listOf(AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true)),
    )

    @After
    fun tearDown() {
        org.koin.core.context.stopKoin()
    }

    private fun launchPicker() {
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        val toolCallMemory = mockk<ToolCallMemoryStore> {
            every { revision } returns MutableStateFlow(0L)
        }
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            KoinApplication(
                application = {
                    modules(
                        module {
                            single<ProviderRepository> { providerRepository }
                            single<ToolCallMemoryStore> { toolCallMemory }
                            single<GlobalSnackbarManager> { snackbar }
                        },
                    )
                },
            ) {
                OriveoTheme(darkTheme = false) {
                    GlobalToastHost(isRoot = true)
                    OriveoModalBottomSheet(onDismissRequest = {}) {
                        ModelPickerSheet(
                            context = ModelPickerContext.Home,
                            providers = listOf(provider),
                            activeProviderId = provider.id,
                            activeModelId = "gpt-4o-mini",
                            onModelSelected = { _, _ -> },
                            onEnableModel = { _, _ -> },
                            onDismiss = {},
                        )
                    }
                }
            }
        }
        composeRule.waitForIdle()
    }

    @Test
    fun `a success toast raised while the picker is open is rendered inside the picker`() {
        launchPicker()

        composeRule.runOnIdle {
            snackbar.show(
                GlobalSnackbarMessage(
                    message = UiText.Dynamic("Model added marker"),
                    style = GlobalToastStyle.Success,
                ),
            )
        }
        composeRule.waitForIdle()

        composeRule.onAllNodesWithText("Model added marker").assertCountEquals(1)
        // The only copy lives in the sheet window: the same compose root as the picker content, not the covered main window
        val toastRoot = composeRule.onNodeWithText("Model added marker").fetchSemanticsNode().root
        val pickerRoot = composeRule.onAllNodesWithText("GPT-4o mini", substring = true, useUnmergedTree = true)
            .onFirst().fetchSemanticsNode().root
        assertSame(pickerRoot, toastRoot)
    }
}
