package ai.oriveo.community.core.model

import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationContentEqualsTest {

    @Test
    fun `contentEquals true when user-facing fields match but updatedAt differs`() {
        val a = sample(title = "Note", updatedAt = 100L, previewText = "preview-a")
        val b = sample(title = "Note", updatedAt = 500L, previewText = "preview-b")
        assertTrue(a.contentEquals(b))
    }

    @Test
    fun `contentEquals false when title differs`() {
        val a = sample(title = "Alpha")
        val b = sample(title = "Beta")
        assertFalse(a.contentEquals(b))
    }

    @Test
    fun `contentEquals false when folderID differs`() {
        val a = sample(folderID = null)
        val b = sample(folderID = "folder-1")
        assertFalse(a.contentEquals(b))
    }

    @Test
    fun `contentEquals false when providerID or modelID differs`() {
        val a = sample(providerID = "p1", modelID = "m1")
        val b = sample(providerID = "p2", modelID = "m1")
        val c = sample(providerID = "p1", modelID = "m2")
        assertFalse(a.contentEquals(b))
        assertFalse(a.contentEquals(c))
    }

    private fun sample(
        id: String = "conv-id",
        title: String = "default title",
        providerID: String = "p1",
        modelID: String = "m1",
        folderID: String? = null,
        updatedAt: Long = 0L,
        previewText: String = "",
    ): Conversation = Conversation(
        id = id,
        title = title,
        providerID = providerID,
        providerKind = ProviderKind.OpenAI,
        modelID = modelID,
        previewText = previewText,
        folderID = folderID,
        updatedAt = updatedAt,
        createdAt = updatedAt,
    )
}
