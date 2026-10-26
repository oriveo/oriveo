package ai.oriveo.community.core.model

import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.usage.CostPart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationTest {

    // ── costParts ────────────────────────────────────────

    @Test
    fun `costParts empty for zero cost`() {
        val conv = Conversation(id = "1", title = "Test", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1")
        assertEquals(emptyList<CostPart>(), conv.costParts)
    }

    @Test
    fun `costParts lists USD first then other currencies`() {
        val conv = Conversation(
            id = "1", title = "Test", providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI,
            estimatedCost = 1.50,
            nonUsdCostTotals = mapOf("EUR" to 2.0, "CNY" to 3.5),
        )
        assertEquals(listOf(CostPart("USD", 1.5), CostPart("CNY", 3.5), CostPart("EUR", 2.0)), conv.costParts)
    }

    // ── createdAt ────────────────────────────────────────────────

    @Test
    fun `createdAt defaults to current time`() {
        val before = System.currentTimeMillis()
        val conv = Conversation(id = "1", title = "Test", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1")
        val after = System.currentTimeMillis()
        assertTrue("createdAt should be >= before", conv.createdAt >= before)
        assertTrue("createdAt should be <= after", conv.createdAt <= after)
    }

    @Test
    fun `createdAt can be set explicitly`() {
        val ts = 1700000000000L
        val conv = Conversation(
            id = "1", title = "Test", providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI,
            createdAt = ts,
        )
        assertEquals(ts, conv.createdAt)
    }

    // ── updatedAt ────────────────────────────────────────────────

    @Test
    fun `updatedAt defaults to current time`() {
        val before = System.currentTimeMillis()
        val conv = Conversation(id = "1", title = "Test", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1")
        val after = System.currentTimeMillis()
        assertTrue("updatedAt should be >= before", conv.updatedAt >= before)
        assertTrue("updatedAt should be <= after", conv.updatedAt <= after)
    }

    // ── default values ───────────────────────────────────────────

    @Test
    fun `default values are correct`() {
        val conv = Conversation(id = "1", title = "Test", providerID = "p1", providerKind = ProviderKind.OpenAI, modelID = "m1")
        assertEquals(false, conv.hasCustomTitle)
        assertEquals("", conv.previewText)
        assertEquals(0.0, conv.estimatedCost, 0.001)
        assertEquals(false, conv.isDraft)
        assertEquals(emptyList<ChatMessage>(), conv.messages)
        assertEquals("", conv.draftText)
    }

    // ── copy preserves createdAt ─────────────────────────────────

    @Test
    fun `copy preserves createdAt when not specified`() {
        val ts = 1700000000000L
        val conv = Conversation(
            id = "1", title = "Test", providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI,
            createdAt = ts,
        )
        val copied = conv.copy(title = "Updated")
        assertEquals(ts, copied.createdAt)
    }
}
