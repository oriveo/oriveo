package ai.oriveo.community.feature.providers.manual

import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ModelCapability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * "Add model manually" page (ManualModel board, cases BOARD-MANUALMODEL-01 to 03): relays and official providers share one page and one layout;
 * only the output of [ManualModelBoardModel.make] is asserted, and that the view source no longer has the old decorations.
 */
class ManualModelBoardTest {

    @Test
    fun `BOARD-MANUALMODEL-01 relay mode is a slot plus notes with the flagship placeholder`() {
        val board = ManualModelBoardModel.make(isRelay = true, modelID = "", isSaving = false, relayPlaceholder = "gpt-5.6-sol")
        assertEquals(listOf(ManualModelBlock.ModelSlot, ManualModelBlock.Notes), board.blocks)
        assertEquals(R.string.add_model, board.titleRes)
        assertEquals(R.string.model_id_label, board.slotTitleRes)
        assertEquals("gpt-5.6-sol", board.placeholder)
        assertNull(board.placeholderRes)
        assertEquals(
            listOf(R.string.relay_manual_model_entry_note_exact, R.string.relay_manual_model_entry_note_capabilities),
            board.notes,
        )
        assertEquals(R.string.save, board.primaryRes)
        assertNull(board.secondaryRes)
        // The model ID still runs left to right under RTL.
        assertTrue(board.slotIsLtr)

        val screen = File("src/main/java/ai/oriveo/community/feature/providers/manual/ManualModelEntryScreen.kt").readText()
        listOf(
            "SpotlightHero", "ExamplesList", "PreviewCard", "AutoAwesome", "NorthWest", "OriveoGradients", "relayKindMeta",
            "R.string.common_examples", "R.string.will_be_added", "R.string.default_capabilities_label", "R.string.tap_to_fill",
        ).forEach { assertFalse("the manual add-model page must no longer contain $it", screen.contains(it)) }
        // The input slot has a screen-reader name.
        assertTrue(screen.contains("contentDescription = slotTitle"))

        val strings = File("src/main/res/values/strings.xml").readText()
        listOf(
            "enter_a_model_id_relay_supports", "use_exact_model_id", "model_id_placeholder_relay", "common_examples",
            "tap_to_fill", "default_capabilities_label", "will_be_added", "add_a_model",
        ).forEach { assertFalse("legacy string $it should have been removed", strings.contains("name=\"$it\"")) }
    }

    @Test
    fun `BOARD-MANUALMODEL-02 official mode keeps its copy and retry sync in the same layout`() {
        val board = ManualModelBoardModel.make(isRelay = false, modelID = "", isSaving = false, relayPlaceholder = "gpt-5.6-sol")
        assertEquals(listOf(ManualModelBlock.ModelSlot, ManualModelBlock.Notes), board.blocks)
        assertEquals(R.string.manual_model_entry_title, board.titleRes)
        assertEquals(R.string.model_id_label, board.slotTitleRes)
        assertNull(board.placeholder)
        assertEquals(R.string.model_id_placeholder, board.placeholderRes)
        assertEquals(listOf(R.string.model_id_footnote), board.notes)
        assertEquals(R.string.save_and_continue, board.primaryRes)
        assertEquals(R.string.retry_sync, board.secondaryRes)
    }

    @Test
    fun `BOARD-MANUALMODEL-03 empty input disables save and clear follows any text`() {
        listOf(true, false).forEach { relay ->
            fun make(id: String) = ManualModelBoardModel.make(isRelay = relay, modelID = id, isSaving = false, relayPlaceholder = "p")
            assertFalse(make("").primaryEnabled)
            assertFalse(make("   ").primaryEnabled)
            assertTrue(make(" m ").primaryEnabled)
            assertFalse(make("").showsClear)
            assertTrue("the clear button is shown even when only spaces are typed", make(" ").showsClear)
            assertFalse(ManualModelBoardModel.make(isRelay = relay, modelID = "m", isSaving = true, relayPlaceholder = "p").primaryEnabled)
        }
        // A model saved for a relay carries only the text capability (persistence and this page share the same production constant).
        assertEquals(listOf(ModelCapability.Text), ProviderRepository.DEFAULT_MANUAL_MODEL_CAPABILITIES)
    }
}
