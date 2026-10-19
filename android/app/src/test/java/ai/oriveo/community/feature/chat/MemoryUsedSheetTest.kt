package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryStatus
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.navigation.AppRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The "Memory" marker on the answer meta row and the item list shown when it is opened. */
class MemoryUsedSheetTest {

    @Test
    fun chip_shown_with_ids() {
        assertTrue(MemoryUsed.chipVisible(assistant(ids = listOf("memory-1"))))
        assertTrue(MemoryUsed.chipVisible(assistant(ids = listOf("memory-1", "memory-2"), state = ChatMessageState.Interrupted)))
    }

    @Test
    fun chip_hidden_without_ids_or_streaming() {
        assertFalse(MemoryUsed.chipVisible(assistant(ids = null)))
        assertFalse(MemoryUsed.chipVisible(assistant(ids = emptyList())))
        // No marker while streaming; it appears once settled
        assertFalse(MemoryUsed.chipVisible(assistant(ids = listOf("memory-1"), state = ChatMessageState.Generating)))
        // Only assistant messages carry the marker
        assertFalse(MemoryUsed.chipVisible(assistant(ids = listOf("memory-1")).copy(role = ChatRole.User)))
    }

    @Test
    fun lists_items_and_deleted() {
        val long = "\u957f".repeat(70)
        val items = listOf(
            item("memory-1", "I use Kotlin\nand some Swift"),
            item("memory-2", long),
            item("memory-3", "Gone").copy(status = MemoryStatus.DELETED, deletedAt = "2026-10-01T00:00:00Z"),
        )

        val rows = MemoryUsed.rows(listOf("memory-1", "MEMORY-2", "memory-3", "memory-missing"), items)

        assertEquals(listOf("memory-1", "memory-2", "memory-3", "memory-missing"), rows.map { it.itemId })
        // First line of the item
        assertEquals("I use Kotlin", rows[0].firstLine)
        // At most 60 glyphs; longer text gets an ellipsis
        assertEquals("\u957f".repeat(60) + "…", rows[1].firstLine)
        // A tombstone and a locally missing item are both "deleted memory": no first line, no button
        assertNull(rows[2].firstLine)
        assertNull(rows[3].firstLine)
        assertFalse(rows[2].canFix)
        assertFalse(rows[3].canFix)
    }

    @Test
    fun fix_opens_editor() {
        val rows = MemoryUsed.rows(listOf("memory-1"), listOf(item("memory-1", "I use Kotlin")))

        assertTrue(rows.single().canFix)
        // [This is wrong] goes to the memory settings page with the item id
        assertEquals(AppRoute.Memory(editItemId = "memory-1"), MemoryUsed.editRoute(rows.single()))
        assertNull(AppRoute.Memory().editItemId)
        assertNull(MemoryUsed.editRoute(MemoryUsed.rows(listOf("memory-x"), emptyList()).single()))
    }

    private fun assistant(ids: List<String>?, state: ChatMessageState = ChatMessageState.Delivered) = ChatMessage(
        id = "assistant-1",
        role = ChatRole.Assistant,
        text = "Answer",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = state,
        memoryItemIds = ids,
    )

    private fun item(id: String, content: String) = MemoryItem(
        id = id,
        kind = MemoryKind.FACT,
        content = content,
        mutationId = "mutation-$id",
        deviceId = "device-1",
    )
}
