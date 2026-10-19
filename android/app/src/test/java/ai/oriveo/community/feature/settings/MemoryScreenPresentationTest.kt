package ai.oriveo.community.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoryScreenPresentationTest {

    @Test
    fun `starter mode with recent conversations adds first and drafts second`() {
        val presentation = buildMemoryScreenPresentation(
            hasItems = false,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenMode.Starter, presentation.mode)
        assertEquals(MemoryHeroStyle.DraftStarter, presentation.heroStyle)
        assertEquals(MemoryScreenAction.AddItem, presentation.primaryAction)
        assertEquals(MemoryScreenAction.GenerateDraft, presentation.secondaryAction)
        assertFalse(presentation.showsSupportSections)
    }

    @Test
    fun `starter mode without recent conversations only offers add`() {
        val presentation = buildMemoryScreenPresentation(
            hasItems = false,
            hasRecentConversations = false,
        )

        assertEquals(MemoryScreenMode.Starter, presentation.mode)
        assertEquals(MemoryHeroStyle.ManualStarter, presentation.heroStyle)
        assertEquals(MemoryScreenAction.AddItem, presentation.primaryAction)
        assertNull(presentation.secondaryAction)
    }

    @Test
    fun `items mode keeps support sections and uses active memory hero`() {
        val presentation = buildMemoryScreenPresentation(
            hasItems = true,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenMode.Items, presentation.mode)
        assertEquals(MemoryHeroStyle.ActiveMemory, presentation.heroStyle)
        assertTrue(presentation.showsSupportSections)
    }

    @Test
    fun `items mode exposes generate draft action when recent conversations exist`() {
        val presentation = buildMemoryScreenPresentation(
            hasItems = true,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenAction.GenerateDraft, presentation.primaryAction)
        assertNull(presentation.secondaryAction)
    }

    @Test
    fun `items mode hides primary action when no recent conversations`() {
        val presentation = buildMemoryScreenPresentation(
            hasItems = true,
            hasRecentConversations = false,
        )

        assertEquals(MemoryScreenMode.Items, presentation.mode)
        assertNull(presentation.primaryAction)
        assertNull(presentation.secondaryAction)
    }
}
