package ai.oriveo.community.feature.chat

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationBootstrapStateStyleContractTest {
    private val bootstrapFile = Paths.get(
        "src/main/java/ai/oriveo/community/feature/chat/components/ConversationBootstrap.kt",
    )

    @Test
    fun `conversation bootstrap skeleton stays in the iOS top bootstrap region`() {
        val source = String(Files.readAllBytes(bootstrapFile), StandardCharsets.UTF_8)
        val stateBody = source.substringAfter("fun ConversationBootstrapState")
            .substringBefore("fun promptIcon")

        assertFalse(
            "Bootstrap skeleton must not use weighted spacer in the full-height Android container; iOS only bottoms it inside a 420pt region",
            stateBody.contains("Spacer(modifier = Modifier.weight(1f, fill = true))"),
        )
        assertTrue(
            "Bootstrap skeleton should constrain its rows to the same 420dp initial region as iOS",
            stateBody.contains(".heightIn(min = 420.dp)"),
        )
    }

    @Test
    fun `conversation bootstrap skeleton uses iOS matched bubble styling`() {
        val source = String(Files.readAllBytes(bootstrapFile), StandardCharsets.UTF_8)
        val stateBody = source.substringAfter("fun ConversationBootstrapState")
            .substringBefore("fun promptIcon")

        assertFalse(
            "Bootstrap skeleton should draw dedicated chat bubbles, not reuse the generic card surface",
            stateBody.contains("OriveoCard("),
        )
        assertTrue(stateBody.contains("RoundedCornerShape(22.dp)"))
        assertTrue(stateBody.contains("560.dp * spec.widthFraction"))
        assertTrue(stateBody.contains(".padding(horizontal = OriveoTheme.spacing.lg)"))
        assertTrue(stateBody.contains(".padding(vertical = OriveoTheme.spacing.md)"))
        assertTrue(stateBody.contains("colors.primary.copy(alpha = 0.08f)"))
        assertTrue(stateBody.contains("colors.textTertiary.copy(alpha = 0.12f)"))
    }
}
