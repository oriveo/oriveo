package ai.oriveo.community.feature.chat

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageBubbleTypingIndicatorContractTest {
    private val sourceDir: Path = Paths.get("src/main")

    @Test
    fun `assistant empty generating message uses shared iOS aligned typing indicator`() {
        val messageBubble = readText(
            sourceDir.resolve("java/ai/oriveo/community/feature/chat/components/MessageBubble.kt"),
        )

        assertTrue(
            "MessageBubble should import the shared iOS-aligned TypingIndicator",
            messageBubble.contains("import ai.oriveo.community.ui.component.TypingIndicator"),
        )
        assertFalse(
            "MessageBubble must not shadow the shared TypingIndicator with a local dots-only version",
            Regex("""private\s+fun\s+TypingIndicator\s*\(""").containsMatchIn(messageBubble),
        )
    }

    @Test
    fun `all assistant elements share the same left alignment`() {
        val messageBubble = readText(
            sourceDir.resolve("java/ai/oriveo/community/feature/chat/components/MessageBubble.kt"),
        )

        assertTrue(
            "MessageBubble should define a single body inset = 0.dp shared by providerBadge / reasoning bar / typing indicator / metadata",
            messageBubble.contains("private val AssistantBodyLeadingInset = 0.dp"),
        )
        assertFalse(
            "AssistantTypingLeadingInset has been removed — typing indicator no longer indents",
            messageBubble.contains("AssistantTypingLeadingInset"),
        )
        assertFalse(
            "AssistantHeaderAlignedInset must be gone — we picked left-edge alignment, not model-name alignment",
            messageBubble.contains("AssistantHeaderAlignedInset"),
        )
        assertFalse(
            "Typing indicator should not be wrapped in any inset padding",
            Regex("""Box\(modifier\s*=\s*Modifier\.padding\(start\s*=\s*[A-Za-z]+\)\)\s*\{\s*\n\s*TypingIndicator\(\)""")
                .containsMatchIn(messageBubble),
        )
        assertFalse(
            "Metadata row should not apply any state-dependent leading inset",
            messageBubble.contains("metadataLeadingInset"),
        )
    }

    @Test
    fun `shared typing indicator matches iOS visual contract`() {
        val typingIndicator = readText(
            sourceDir.resolve("java/ai/oriveo/community/ui/component/TypingIndicator.kt"),
        )

        assertTrue(typingIndicator.contains("Arrangement.spacedBy(8.dp)"))
        assertTrue(typingIndicator.contains(".size(6.dp)"))
        assertTrue(typingIndicator.contains("OriveoTheme.typography.footnote"))
        assertTrue(typingIndicator.contains("colors.textSecondary"))
        assertTrue(typingIndicator.contains("stringResource(R.string.generating)"))
    }

    @Test
    fun `generating labels omit trailing ellipsis like iOS`() {
        val failures = mutableListOf<String>()
        Files.list(sourceDir.resolve("res")).use { dirs ->
            dirs
                .filter { Files.isDirectory(it) }
                .filter { it.fileName.toString().startsWith("values") }
                .filter { Files.exists(it.resolve("strings.xml")) }
                .forEach { dir ->
                    val value = stringValue(readText(dir.resolve("strings.xml")), "generating")
                    if (value.endsWith("...") || value.endsWith("…")) {
                        failures += "${dir.fileName}: $value"
                    }
                }
        }

        assertTrue(
            "Android generating labels should match iOS L10n.tr(\"Generating\") without ellipsis:\n" +
                failures.joinToString("\n"),
            failures.isEmpty(),
        )
    }

    private fun stringValue(content: String, key: String): String {
        val match = Regex("""<string name="$key">(.*?)</string>""").find(content)
        return match?.groupValues?.get(1) ?: ""
    }

    private fun readText(path: Path): String =
        String(Files.readAllBytes(path), StandardCharsets.UTF_8)
}
