package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FadeRenderingTest {

    private val base = Color.Black

    @Test
    fun `ledger never lets alpha regress`() {
        val ledger = FadeAlphaLedger()
        assertEquals(200, ledger.clamp(0, 200))

        assertEquals(200, ledger.clamp(0, 120))
        assertEquals(255, ledger.clamp(0, 255))
        assertEquals(255, ledger.clamp(0, 0))
    }

    @Test
    fun `ledger tracks characters independently`() {
        val ledger = FadeAlphaLedger()
        ledger.clamp(0, 255)
        assertEquals(80, ledger.clamp(5, 80))
        assertEquals(255, ledger.clamp(0, 10))
    }

    @Test
    fun `ledger resets when rendered text shrinks`() {
        val ledger = FadeAlphaLedger()
        ledger.clamp(9, 255)
        ledger.resetIfShrunk(4)
        assertEquals(60, ledger.clamp(2, 60))
    }

    @Test
    fun `ledger keeps state while text grows`() {
        val ledger = FadeAlphaLedger()
        ledger.clamp(2, 240)
        ledger.resetIfShrunk(10)
        assertEquals(240, ledger.clamp(2, 100))
    }

    @Test
    fun `styled run fades with its own color and background`() {

        val codeFg = Color.Red
        val codeBg = Color.Yellow
        val src = buildAnnotatedString {
            append("abcd")
            addStyle(SpanStyle(color = codeFg, background = codeBg), 2, 4)
        }
        val alphas = intArrayOf(255, 128, 128, 128)
        val out = composeFadedSpans(src, base, alphas, firstUnsettled = 1)

        val fadeSpans = out.spanStyles.drop(src.spanStyles.size)

        val plain = fadeSpans.first { it.start == 1 && it.end == 2 }
        assertEquals(base.copy(alpha = 128 / 255f), plain.item.color)

        val code = fadeSpans.first { it.start == 2 && it.end == 4 }
        assertEquals(codeFg.copy(alpha = codeFg.alpha * (128 / 255f)), code.item.color)
        assertEquals(codeBg.copy(alpha = codeBg.alpha * (128 / 255f)), code.item.background)
    }

    @Test
    fun `settled characters get no fade span`() {
        val src = buildAnnotatedString { append("hello") }
        val alphas = intArrayOf(255, 255, 255, 200, 200)
        val out = composeFadedSpans(src, base, alphas, firstUnsettled = 3)
        assertEquals(1, out.spanStyles.size)
        assertEquals(3, out.spanStyles[0].start)
        assertEquals(5, out.spanStyles[0].end)
    }

    @Test
    fun `equal alpha runs merge but split at style boundaries`() {
        val src = buildAnnotatedString {
            append("abcdef")
            addStyle(SpanStyle(color = Color.Blue), 2, 4)
        }
        val alphas = intArrayOf(100, 100, 100, 100, 100, 100)
        val out = composeFadedSpans(src, base, alphas, firstUnsettled = 0)
        val fadeSpans = out.spanStyles.drop(src.spanStyles.size)

        assertEquals(3, fadeSpans.size)
        assertTrue(fadeSpans.any { it.start == 0 && it.end == 2 })
        assertTrue(fadeSpans.any { it.start == 2 && it.end == 4 })
        assertTrue(fadeSpans.any { it.start == 4 && it.end == 6 })
    }
}
