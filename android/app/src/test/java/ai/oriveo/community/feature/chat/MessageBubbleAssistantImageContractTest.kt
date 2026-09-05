package ai.oriveo.community.feature.chat

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageBubbleAssistantImageContractTest {
    private val sourceDir: Path = Paths.get("src/main")

    @Test
    fun `assistant image uses iOS aligned max width aspect ratio container`() {
        val messageBubble = readText(
            sourceDir.resolve("java/ai/oriveo/community/feature/chat/components/MessageBubble.kt"),
        )

        assertTrue(
            "Assistant images should expand to the available message width before applying the iOS-aligned max width.",
            messageBubble.contains(".fillMaxWidth()") &&
                messageBubble.contains(".widthIn(max = 320.dp)"),
        )
        assertTrue(
            "Assistant images should preserve the decoded image aspect ratio instead of rendering at thumbnail intrinsic size.",
            messageBubble.contains("bitmap.width.toFloat() / max(bitmap.height.toFloat(), 1f)") &&
                messageBubble.contains(".aspectRatio(aspectRatio)"),
        )
        assertTrue(
            "Assistant images should fit inside the aspect-ratio container like iOS scaledToFit.",
            messageBubble.contains("contentScale = androidx.compose.ui.layout.ContentScale.Fit"),
        )
    }

    private fun readText(path: Path): String =
        String(Files.readAllBytes(path), StandardCharsets.UTF_8)
}
