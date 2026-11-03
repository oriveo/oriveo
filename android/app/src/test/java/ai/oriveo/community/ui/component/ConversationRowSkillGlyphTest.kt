package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.feature.chat.chatSkillGlyphKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationRowSkillGlyphTest {
    private val idA = "11111111-1111-1111-1111-111111111111"
    private val idB = "22222222-2222-2222-2222-222222222222"

    private fun conversation(skillIds: List<String> = emptyList(), skillId: String? = null) = Conversation(
        id = "c1",
        title = "t",
        providerID = "p1",
        providerKind = ProviderKind.entries.first(),
        modelID = "m1",
        skillId = skillId,
        skillIds = skillIds,
    )

    private fun skill(id: String, icon: String, iconKey: String = "") =
        Skill(id = id, name = "s", systemPrompt = "x", icon = icon, iconKey = iconKey)

    @Test
    fun firstSkillWithIconKeyUsesIconKey() {
        val skills = mapOf(
            idA to skill(idA, icon = "💻", iconKey = "glyph:music"),
            idB to skill(idB, icon = "💻"),
        )
        assertEquals("glyph:music", conversationSkillGlyphKey(conversation(listOf(idA, idB)), skills))
    }

    @Test
    fun legacyEmojiMapsThroughSkillGlyphs() {
        val skills = mapOf(idB to skill(idB, icon = "💻"))
        assertEquals("glyph:code", conversationSkillGlyphKey(conversation(listOf(idB, idA)), skills))
    }

    @Test
    fun legacySkillIdFallbackIsUsed() {
        val skills = mapOf(idA to skill(idA, icon = "📝"))
        assertEquals("glyph:writing", conversationSkillGlyphKey(conversation(skillId = idA), skills))
    }

    @Test
    fun skillMissingFromCacheShowsNothing() {
        val skills = mapOf(idB to skill(idB, icon = "💻"))
        assertNull(conversationSkillGlyphKey(conversation(listOf(idA)), skills))
        assertNull(conversationSkillGlyphKey(conversation(), skills))
    }

    @Test
    fun chatScreenGlyphResolvesCurrentSkillOrNothing() {
        assertEquals("glyph:code", chatSkillGlyphKey(skill(idA, icon = "\uD83D\uDCBB")))
        assertEquals("glyph:music", chatSkillGlyphKey(skill(idA, icon = "\uD83D\uDCBB", iconKey = "glyph:music")))
        assertNull(chatSkillGlyphKey(null))
    }
}
