package ai.oriveo.community.feature.home.homescreen

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the dictation wiring of the home input card: the input area is wrapped in DictationInputSwitcher, the bottom
 * row has no microphone, and the selection reaches rememberComposerLengthLimitedField through selectionProbe;
 * HomeScreen hosts the draft:home slot with the status card above the input card, and passes the handle and probe
 * into NewChatBar.
 */
class HomeDictationWiringTest {
    private val source: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()
    }

    private val homeScreenSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
    }

    @Test
    fun `input area is wrapped by the dictation switcher`() {
        val switcherAt = source.indexOf("DictationInputSwitcher(")
        assertTrue("The home input area is not wrapped in DictationInputSwitcher, so the recording bar would never replace it", switcherAt >= 0)
        // Same as the chat page and iOS DictationInputRow: the glass card wraps only the input area (inside the input slot), and the recording bar sits in its own row below the card, 8dp apart.
        val cardAt = source.indexOf(".auroraGlassCard(", switcherAt)
        assertTrue("The glass card must sit inside the input slot of DictationInputSwitcher", cardAt > switcherAt)
        val call = source.substring(switcherAt, cardAt)
        assertTrue("The spacing between the recording bar and the input card must be 8dp", call.contains("spacing = 8.dp"))
        assertTrue("The glass card must be inside the input slot", call.contains("input = {"))
    }

    @Test
    fun `hero input has no dictation mic`() {
        // The home bottom row has no microphone: only the secondary voice key and the up arrow remain
        assertTrue("The home input card must not contain DictationMicButton", !source.contains("DictationMicButton("))
    }

    @Test
    fun `selection probe reaches the length limited field`() {
        assertTrue("NewChatBar is missing the selectionProbe wiring", source.contains("selectionProbe = "))
        assertTrue(
            "selectionProbe must be passed to rememberComposerLengthLimitedField",
            source.contains("rememberComposerLengthLimitedField(text = text, onTextChange = onTextChange, selectionProbe = selectionProbe)"),
        )
    }

    @Test
    fun `home screen hosts dictation on the home draft slot`() {
        val hostAt = homeScreenSource.indexOf("rememberDictationHost(")
        assertTrue("HomeScreen is missing rememberDictationHost", hostAt >= 0)
        assertTrue(
            "The home host must use the HOME_DRAFT_KEY slot",
            homeScreenSource.indexOf("HOME_DRAFT_KEY", hostAt) in hostAt until hostAt + 200,
        )
    }

    @Test
    fun `prompt card sits above the hero and the handle reaches NewChatBar`() {
        val slotAt = homeScreenSource.indexOf("DictationPromptSlot(")
        val barAt = homeScreenSource.indexOf("NewChatBar(", slotAt.coerceAtLeast(0))
        assertTrue("HomeScreen is missing DictationPromptSlot", slotAt >= 0)
        assertTrue("The status card must sit above the input card (before NewChatBar)", barAt > slotAt)
        val call = homeScreenSource.substring(barAt)
        assertTrue("The handle must be passed into NewChatBar", call.contains("dictation = "))
        assertTrue("The probe must be passed into NewChatBar", call.contains("selectionProbe = "))
    }
}
