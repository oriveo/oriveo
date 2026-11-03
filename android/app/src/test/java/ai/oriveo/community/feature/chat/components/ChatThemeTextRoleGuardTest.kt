package ai.oriveo.community.feature.chat.components

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Theme-colored text on light surfaces must use `colors.primaryTextSafe`; raw `colors.primary`
 * is the ink role reserved for icons, strokes and fills. Scans every `Text(` call argument list
 * in the chat components and the skill editor and fails on any raw primary reference.
 */
class ChatThemeTextRoleGuardTest {

    private val files = listOf(
        "feature/chat/components/MessageBubble.kt",
        "feature/chat/components/ConversationBootstrap.kt",
        "feature/chat/components/UserMessageFullTextSheet.kt",
        "feature/chat/components/ChatToolbar.kt",
        "feature/skills/SkillEditScreen.kt",
    )

    private val textCall = Regex("""(?<![A-Za-z0-9_.])Text\(""")
    private val rawPrimary = Regex("""colors\.primary\b(?!TextSafe|FillText|Soft|Pressed|Active)""")

    @Test
    fun text_never_uses_raw_primary() {
        val violations = mutableListOf<String>()
        var scannedCalls = 0
        for (file in files) {
            val text = source(file)
            for (match in textCall.findAll(text)) {
                val args = argumentSegment(text, match.range.last)
                scannedCalls++
                if (rawPrimary.containsMatchIn(args)) {
                    val line = text.substring(0, match.range.first).count { it == '\n' } + 1
                    violations += "$file:$line"
                }
            }
        }
        assertTrue("expected Text( calls to scan", scannedCalls > 0)
        assertTrue(
            "Text color must use colors.primaryTextSafe, not raw colors.primary: $violations",
            violations.isEmpty(),
        )
    }

    /** Returns the text from the opening parenthesis to its balanced closing parenthesis. */
    private fun argumentSegment(text: String, openIndex: Int): String {
        var depth = 0
        for (i in openIndex until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return text.substring(openIndex, i + 1)
                }
            }
        }
        return text.substring(openIndex)
    }

    private fun source(file: String): String =
        File("src/main/java/ai/oriveo/community/$file").readText()
}
