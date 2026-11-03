package ai.oriveo.community.feature.chat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source-level style checks for the message recovery card.
 * - Failure icon uses the Phosphor warning-circle drawable instead of Material Filled.Error.
 * - Secondary button text (e.g. Edit Message) uses the text-safe brand color, not the raw fill color.
 */
class MessageRecoveryCardStyleTest {
    private val card = File(
        "src/main/java/ai/oriveo/community/feature/chat/recovery/MessageRecoveryCard.kt",
    ).readText()

    private val buttons = File(
        "src/main/java/ai/oriveo/community/ui/component/OriveoButtons.kt",
    ).readText()

    @Test
    fun `failure icon uses phosphor warning circle`() {
        assertTrue(
            "MessageRecoveryCard danger icon must be painterResource(R.drawable.ph_warning_circle)",
            card.contains("painterResource(R.drawable.ph_warning_circle)"),
        )
        assertFalse(
            "MessageRecoveryCard must no longer use Icons.Filled.Error",
            card.contains("Icons.Filled.Error"),
        )
        assertFalse(
            "MessageRecoveryCard must no longer import material filled Error",
            card.contains("import androidx.compose.material.icons.filled.Error"),
        )
    }

    @Test
    fun `secondary button text uses primaryTextSafe`() {
        val start = buttons.indexOf("fun OriveoSecondaryButton(")
        assertTrue("OriveoSecondaryButton not found", start >= 0)
        val next = buttons.indexOf("\nfun ", start + 1).let { if (it < 0) buttons.length else it }
        val body = buttons.substring(start, next)
        val textColors = Regex("""Text\([^)]*?color = ([\w.]+)""", RegexOption.DOT_MATCHES_ALL)
            .findAll(body)
            .map { it.groupValues[1] }
            .toList()
        assertEquals(
            "OriveoSecondaryButton should render its label in both branches",
            2,
            textColors.size,
        )
        textColors.forEach {
            assertEquals("OriveoSecondaryButton label color", "colors.primaryTextSafe", it)
        }
    }
}
