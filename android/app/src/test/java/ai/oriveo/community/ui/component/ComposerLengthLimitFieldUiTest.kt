package ai.oriveo.community.ui.component

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.text.TextRange
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.util.COMPOSER_MAX_INPUT_LENGTH
import ai.oriveo.community.feature.home.homescreen.NewChatBar
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.core.context.startKoin
import org.koin.core.context.stopKoin
import org.koin.dsl.module
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The length limit wired to a real `BasicTextField`: after writing back a value that differs from
 * the one the field computed itself (truncated text plus an adjusted selection), are the text and
 * the selection right, and does later input still behave? The rules themselves are covered by
 * `ComposerLengthLimitTest`.
 *
 * Text enters through semantics actions (`performTextInput` commits a string at the caret), which
 * takes the same `EditProcessor -> onValueChange` path as a paste or an input method commit. A
 * composing state cannot be produced here; see the composition case in the JVM test.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ComposerLengthLimitFieldUiTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var activity: ComponentActivity
    private val snackbar = GlobalSnackbarManager()
    private var upstream by mutableStateOf("")

    @Before
    fun setUp() {
        stopKoin()
        startKoin { modules(module { single { snackbar } }) }
    }

    @After
    fun tearDown() {
        stopKoin()
    }

    private fun render(content: @Composable () -> Unit) {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent { OriveoTheme(darkTheme = false) { content() } }
        composeRule.waitForIdle()
    }

    private fun renderPlainField() = render {
        val field = rememberComposerLengthLimitedField(text = upstream, onTextChange = { upstream = it })
        BasicTextField(
            value = field.value,
            onValueChange = field.onValueChange,
            modifier = Modifier.testTag(FIELD_TAG),
        )
    }

    private fun plainField() = composeRule.onNodeWithTag(FIELD_TAG)

    private fun SemanticsNodeInteraction.selection(): TextRange =
        fetchSemanticsNode().config[SemanticsProperties.TextSelectionRange]

    private fun SemanticsNodeInteraction.editableText(): String =
        fetchSemanticsNode().config[SemanticsProperties.EditableText].text

    private fun toastText(): String? = snackbar.active.value?.message?.message?.resolve(activity)

    @Test
    fun limit_pasteOverflow_keepsPrefixAndToastsOnce() {
        renderPlainField()

        plainField().performTextInput("a".repeat(60_000))
        composeRule.waitForIdle()

        assertEquals(COMPOSER_MAX_INPUT_LENGTH, upstream.length)
        assertEquals(upstream, plainField().editableText())
        assertEquals(TextRange(COMPOSER_MAX_INPUT_LENGTH), plainField().selection())
        val toast = snackbar.active.value
        assertNotNull(toast)
        assertEquals(
            UiText.Resource(R.string.chat_input_length_limit_reached, listOf(COMPOSER_MAX_INPUT_LENGTH)),
            toast!!.message.message,
        )
        // The number is shown with locale-style digit grouping.
        assertEquals(true, toastText()!!.contains("50,000"))

        // Typing on at the limit: the same notice, not shown again (the host tells two notices
        // apart by instance identity).
        plainField().performTextInput("b")
        composeRule.waitForIdle()
        assertEquals(COMPOSER_MAX_INPUT_LENGTH, upstream.length)
        assertSame(toast, snackbar.active.value)
    }

    @Test
    fun limit_pasteInMiddle_keepsSurroundingTextAndCaret() {
        val head = "H".repeat(20_000)
        val tail = "T".repeat(20_000)
        upstream = head + tail
        renderPlainField()

        plainField().performTextInputSelection(TextRange(20_000))
        plainField().performTextInput("p".repeat(30_000))
        composeRule.waitForIdle()

        assertEquals(head + "p".repeat(10_000) + tail, upstream)
        assertEquals(upstream, plainField().editableText())
        assertEquals(TextRange(30_000), plainField().selection())

        // After the write-back the field's internal buffer must already match the truncated value:
        // delete at the caret and type again, and the caret still lands after the kept part.
        plainField().performTextReplacement(head + "p".repeat(9_999) + tail)
        plainField().performTextInputSelection(TextRange(29_999))
        plainField().performTextInput("q")
        composeRule.waitForIdle()
        assertEquals(head + "p".repeat(9_999) + "q" + tail, upstream)
        assertEquals(TextRange(30_000), plainField().selection())
    }

    @Test
    fun limit_typingAtLimit_blockedToastOnceUntilRearmed() {
        val base = "a".repeat(COMPOSER_MAX_INPUT_LENGTH - 1)
        upstream = base
        renderPlainField()
        plainField().performTextInputSelection(TextRange(base.length))

        plainField().performTextInput("b")
        composeRule.waitForIdle()
        assertEquals(base + "b", upstream)
        assertNull(snackbar.active.value)

        // A refused input changes no state (text and selection are the same as before). If the
        // field's internal buffer were not reset, typing after the second refused character would
        // edit a longer phantom text.
        plainField().performTextInput("c")
        plainField().performTextInput("d")
        composeRule.waitForIdle()
        assertEquals(base + "b", upstream)
        assertEquals(base + "b", plainField().editableText())
        assertEquals(TextRange(COMPOSER_MAX_INPUT_LENGTH), plainField().selection())
        val toast = snackbar.active.value
        assertNotNull(toast)

        // Deleting below the limit allows typing again; going over once more shows a new notice.
        plainField().performTextReplacement(base)
        plainField().performTextInputSelection(TextRange(base.length))
        plainField().performTextInput("e")
        composeRule.waitForIdle()
        assertEquals(base + "e", upstream)
        assertSame(toast, snackbar.active.value)
        plainField().performTextInput("f")
        composeRule.waitForIdle()
        assertEquals(base + "e", upstream)
        assertNotNull(snackbar.active.value)
        assertEquals(false, toast === snackbar.active.value)
    }

    @Test
    fun limit_legacyOverlongDraft_restoredIntact_onlyShrinkAllowed() {
        renderPlainField()
        val legacy = "a".repeat(70_000)

        // Programmatic write (draft restore): the owner swaps the text directly.
        upstream = legacy
        composeRule.waitForIdle()
        assertEquals(legacy, plainField().editableText())
        assertNull(snackbar.active.value)

        plainField().performTextInputSelection(TextRange(legacy.length))
        plainField().performTextInput("b")
        composeRule.waitForIdle()
        assertEquals(legacy, upstream)
        assertNotNull(snackbar.active.value)

        plainField().performTextReplacement(legacy.dropLast(5))
        composeRule.waitForIdle()
        assertEquals(69_995, upstream.length)
    }

    @Test
    fun limit_legacyOverlongDraft_replaceSelectionWithLonger_keepsPastePrefixUpToOldLength() {
        val head = "H".repeat(40_000)
        val tail = "T".repeat(29_900)
        upstream = head + "x".repeat(100) + tail
        renderPlainField()

        plainField().performTextInputSelection(TextRange(40_000, 40_100))
        plainField().performTextInput("p".repeat(500))
        composeRule.waitForIdle()

        assertEquals(head + "p".repeat(100) + tail, upstream)
        assertEquals(upstream, plainField().editableText())
        assertEquals(TextRange(40_100), plainField().selection())
        assertNotNull(snackbar.active.value)
    }

    @Test
    fun limit_homeComposer_sameRule() {
        render {
            NewChatBar(
                activeModel = null,
                hasProvider = true,
                isDark = false,
                heroText = upstream,
                onHeroTextChange = { upstream = it },
                isSendingFromHero = false,
                isSearchActive = false,
                onSend = {},
                onModelSelect = {},
                onAddProvider = {},
            )
        }
        val heroField = composeRule.onNode(hasSetTextAction())

        heroField.performTextInput("a".repeat(49_999) + "👨‍👩‍👧")
        composeRule.waitForIdle()

        assertEquals("a".repeat(49_999), upstream)
        assertEquals(TextRange(49_999), heroField.selection())
        assertNotNull(snackbar.active.value)
    }

    private companion object {
        const val FIELD_TAG = "length_limited_field"
    }
}
