package ai.oriveo.community.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoryScreenPresentationTest {

    @Test
    fun `starter mode with recent conversations prefers draft action`() {
        val presentation = buildMemoryScreenPresentation(
            memoryText = "",
            isEditorFocused = false,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenMode.Starter, presentation.mode)
        assertEquals(MemoryHeroStyle.DraftStarter, presentation.heroStyle)
        assertEquals(MemoryScreenAction.GenerateDraft, presentation.primaryAction)
        assertEquals(MemoryScreenAction.FocusEditor, presentation.secondaryAction)
        assertFalse(presentation.showsExampleSuggestions)
        assertFalse(presentation.showsSupportSections)
    }

    @Test
    fun `starter mode without recent conversations goes straight to manual writing`() {
        val presentation = buildMemoryScreenPresentation(
            memoryText = "",
            isEditorFocused = false,
            hasRecentConversations = false,
        )

        assertEquals(MemoryScreenMode.Starter, presentation.mode)
        assertEquals(MemoryHeroStyle.ManualStarter, presentation.heroStyle)
        assertEquals(MemoryScreenAction.FocusEditor, presentation.primaryAction)
        assertNull(presentation.secondaryAction)
        assertFalse(presentation.showsExampleSuggestions)
    }

    @Test
    fun `editor mode keeps support sections and uses active memory hero`() {
        val withContent = buildMemoryScreenPresentation(
            memoryText = "Remember that I prefer concise answers.",
            isEditorFocused = false,
            hasRecentConversations = true,
        )
        val whileEditingEmpty = buildMemoryScreenPresentation(
            memoryText = "",
            isEditorFocused = true,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenMode.Editor, withContent.mode)
        assertEquals(MemoryHeroStyle.ActiveMemory, withContent.heroStyle)
        assertTrue(withContent.showsSupportSections)
        assertFalse(withContent.showsExampleSuggestions)

        assertEquals(MemoryScreenMode.Editor, whileEditingEmpty.mode)
        assertEquals(MemoryHeroStyle.ActiveMemory, whileEditingEmpty.heroStyle)
        assertTrue(whileEditingEmpty.showsSupportSections)
        assertFalse(whileEditingEmpty.showsExampleSuggestions)
    }

    @Test
    fun `editor mode exposes generate draft action when recent conversations exist`() {
        val withContent = buildMemoryScreenPresentation(
            memoryText = "Remember that I prefer concise answers.",
            isEditorFocused = false,
            hasRecentConversations = true,
        )
        val whileEditingEmpty = buildMemoryScreenPresentation(
            memoryText = "",
            isEditorFocused = true,
            hasRecentConversations = true,
        )

        assertEquals(MemoryScreenAction.GenerateDraft, withContent.primaryAction)
        assertNull(withContent.secondaryAction)
        assertEquals(MemoryScreenAction.GenerateDraft, whileEditingEmpty.primaryAction)
        assertNull(whileEditingEmpty.secondaryAction)
    }

    @Test
    fun `editor mode hides primary action when no recent conversations`() {
        val presentation = buildMemoryScreenPresentation(
            memoryText = "Remember that I prefer concise answers.",
            isEditorFocused = false,
            hasRecentConversations = false,
        )

        assertEquals(MemoryScreenMode.Editor, presentation.mode)
        assertNull(presentation.primaryAction)
        assertNull(presentation.secondaryAction)
    }
}
