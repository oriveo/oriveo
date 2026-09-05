package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class SkillHomeSelectionTest {

    private fun makeSkill(
        id: String,
        key: String? = null,
        name: String = id,
        source: SkillSource = SkillSource.BUILTIN,
        isPinned: Boolean = false,
        pinOrder: Int = 0,
        lastUsedAt: String? = null,
    ) = Skill(
        id = id,
        key = key,
        name = name,
        systemPrompt = "Prompt",
        source = source,
        isPinned = isPinned,
        pinOrder = pinOrder,
        lastUsedAt = lastUsedAt,
    )

    @Test
    fun `new user gets curated default builtin skills first`() {
        val result = selectHomeSkills(
            listOf(
                makeSkill(id = "code", key = "code_assistant"),
                makeSkill(id = "translation", key = "translation_expert"),
                makeSkill(id = "writing", key = "writing_coach"),
                makeSkill(id = "email", key = "email_assistant"),
                makeSkill(id = "brainstorm", key = "brainstorm"),
                makeSkill(id = "summary", key = "document_summarizer"),
            ),
        )

        assertEquals(
            listOf(
                "translation_expert",
                "writing_coach",
                "email_assistant",
                "brainstorm",
                "document_summarizer",
            ),
            result.take(5).map { it.key },
        )
    }

    @Test
    fun `pinned and recent skills win over recommendations and unused custom skills are skipped`() {
        val result = selectHomeSkills(
            listOf(
                makeSkill(id = "translation", key = "translation_expert"),
                makeSkill(id = "writing", key = "writing_coach"),
                makeSkill(id = "email", key = "email_assistant"),
                makeSkill(id = "brainstorm", key = "brainstorm"),
                makeSkill(id = "summary", key = "document_summarizer"),
                makeSkill(id = "pinned", name = "Pinned", source = SkillSource.USER, isPinned = true, pinOrder = 1),
                makeSkill(id = "recent", name = "Recent", source = SkillSource.USER, lastUsedAt = "2026-04-03T09:00:00Z"),
                makeSkill(id = "unused", name = "Unused", source = SkillSource.USER),
            ),
        )

        assertEquals(listOf("pinned", "recent"), result.take(2).map { it.id })
        assertFalse(result.any { it.id == "unused" })
    }

    @Test
    fun `selection is capped at 7 skills`() {
        val result = selectHomeSkills(
            (1..10).map { index ->
                makeSkill(id = "skill-$index", key = "key_$index", lastUsedAt = "2026-04-03T0$index:00:00Z")
            },
        )

        assertEquals(7, result.size)
    }
}
