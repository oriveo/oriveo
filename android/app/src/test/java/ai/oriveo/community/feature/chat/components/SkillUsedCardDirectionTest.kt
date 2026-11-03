package ai.oriveo.community.feature.chat.components

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class SkillUsedCardDirectionTest {

    private val source = File("src/main/java/ai/oriveo/community/feature/chat/components/SkillUsedChip.kt").readText()

    private fun cardBody(): String {
        val start = source.indexOf("internal fun SkillUsedCard(")
        assertTrue("SkillUsedCard not found", start >= 0)
        return source.substring(start)
    }

    @Test
    fun `skill name in used card follows content direction`() {
        val body = cardBody()
        val nameBlock = body.substring(body.indexOf("item.name?.let"), body.indexOf("R.string.skills_used_why"))
        assertTrue("name Text must merge userContentTextStyle", nameBlock.contains("merge(userContentTextStyle)"))
        assertTrue("name Text must fill width so start alignment follows content", nameBlock.contains("fillMaxWidth()"))
    }

    @Test
    fun `reason in used card keeps content direction`() {
        val body = cardBody()
        val reasonBlock = body.substring(body.indexOf("item.reason?.let"))
        assertTrue(reasonBlock.substringBefore("}").contains("merge(userContentTextStyle)"))
    }
}
