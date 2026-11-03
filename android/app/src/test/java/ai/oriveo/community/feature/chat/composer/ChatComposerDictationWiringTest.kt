package ai.oriveo.community.feature.chat.composer

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the dictation wiring of the chat input box: the input row is wrapped in [DictationInputSwitcher], the text shell carries [DictationMicButton],
 * and the selection goes through selectionProbe into rememberComposerLengthLimitedField. Source scan: EnhancedComposer is too large to compose
 * as a whole in a unit test. ChatComposerHost attaches the slot-conversation host (HOME_DRAFT_KEY when there is no conversation), the status card sits above the input box,
 * and the handle and probe are passed into EnhancedComposer.
 */
class ChatComposerDictationWiringTest {
    private val source: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
    }

    private val hostSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/composer/ChatComposerHost.kt").readText()
    }

    @Test
    fun `input row is wrapped by the dictation switcher`() {
        val switcherAt = source.indexOf("DictationInputSwitcher(")
        assertTrue("The input row is not wrapped in DictationInputSwitcher, so the recording bar would never swap in", switcherAt >= 0)
        // Same as iOS DictationInputRow: the border wraps only the input row (inside the input slot), the recording bar sits one row below the border, 8dp spacing.
        val borderAt = source.indexOf(".border(OriveoBorderWidth.standard, composerShellBorder, composerShape)")
        assertTrue("The bordered input shell must be inside the input slot of DictationInputSwitcher", borderAt > switcherAt)
        val call = source.substring(switcherAt, borderAt)
        assertTrue("Recording bar to input box spacing must be 8dp", call.contains("spacing = 8.dp"))
        assertTrue("The border must be inside the input slot", call.contains("input = {"))
    }

    /**
     * Card aB1: EnhancedComposer has 86 parameters and the dex register count exceeds 256; the D8 9.4.24 bundled with AGP 9.4.1 compiled the null check of
     * `pendingQuoteContext?.sourceMessageId` onto a different register, so the getter is still called when the reference is null and throws an NPE (the chat page crashes on open).
     * The JVM bytecode itself is correct and Robolectric runs JVM bytecode, so this cannot be reproduced there; it only reproduces on a device (verified on emulator-5554).
     * The workaround is locked here: the quote focus effect lives in its own small function and does not return into the EnhancedComposer function body.
     */
    @Test
    fun `quote focus effect stays out of the oversized composer body`() {
        val bodyStart = source.indexOf("internal fun EnhancedComposer(")
        val bodyEnd = source.indexOf("\n@Composable\nprivate fun ", bodyStart)
        assertTrue("Cannot find the EnhancedComposer function body", bodyStart >= 0 && bodyEnd > bodyStart)
        val body = source.substring(bodyStart, bodyEnd)
        assertTrue("The quote focus effect must go through ComposerQuoteFocusEffect", body.contains("ComposerQuoteFocusEffect("))
        assertTrue(
            "EnhancedComposer's function body must not use pendingQuoteContext directly as a LaunchedEffect key (D8 null check on the wrong register)",
            !body.contains("LaunchedEffect(pendingQuoteContext"),
        )
        assertTrue("ComposerQuoteFocusEffect must be its own function", source.contains("private fun ComposerQuoteFocusEffect("))
    }

    @Test
    fun `text shell shows the mic button only with a dictation handle`() {
        val micAt = source.indexOf("DictationMicButton(")
        assertTrue("The text shell is missing DictationMicButton", micAt >= 0)
        val gateAt = source.lastIndexOf("if (dictation != null)", micAt)
        assertTrue("The mic button must only show when dictation is non-null", gateAt in 0 until micAt)
    }

    @Test
    fun `selection probe reaches the length limited field`() {
        assertTrue("EnhancedComposer is missing the selectionProbe wiring", source.contains("selectionProbe = "))
        assertTrue(
            "selectionProbe must be passed to rememberComposerLengthLimitedField",
            source.contains("rememberComposerLengthLimitedField(text = text, onTextChange = onValueChange, selectionProbe = selectionProbe)"),
        )
    }

    @Test
    fun `chat host binds the conversation slot or the home draft slot`() {
        assertTrue("ChatComposerHost is missing rememberDictationHost", hostSource.contains("rememberDictationHost("))
        assertTrue(
            "The slot key must be conversationId ?: HOME_DRAFT_KEY",
            hostSource.contains("conversationId ?: RecordingStore.HOME_DRAFT_KEY"),
        )
    }

    @Test
    fun `prompt card sits above the composer and the handle reaches EnhancedComposer`() {
        val slotAt = hostSource.indexOf("DictationPromptSlot(")
        assertTrue("ChatComposerHost is missing DictationPromptSlot", slotAt >= 0)
        val composerAt = hostSource.indexOf("EnhancedComposer(", slotAt)
        assertTrue("The status card must sit above the input (before EnhancedComposer)", composerAt > slotAt)
        val call = hostSource.substring(composerAt)
        assertTrue("The handle must be passed into EnhancedComposer", call.contains("dictation = "))
        assertTrue("The probe must be passed into EnhancedComposer", call.contains("selectionProbe = "))
    }
}
