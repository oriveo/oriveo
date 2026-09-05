package ai.oriveo.community.feature.providers

import androidx.compose.ui.graphics.Color
import ai.oriveo.community.feature.providers.relay.relayQuickSurfaceFillColor
import ai.oriveo.community.ui.theme.DarkOriveoColors
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoColors
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderSoftColorContractTest {

    private val colorChannelTolerance = 1f / 255f

    @Test
    fun `relay quick surfaces composite the same layered fill as iOS in light and dark`() {
        assertLayeredFill(LightOriveoColors, isDark = false, opacityFactor = 0.62f)
        assertLayeredFill(DarkOriveoColors, isDark = true, opacityFactor = 0.68f)
    }

    @Test
    fun `provider surfaces never replace alpha on translucent theme tokens`() {
        val projectRoot = generateSequence(File(".").canonicalFile) { it.parentFile }
            .first { File(it, "settings.gradle.kts").exists() }
        val providerRoot = File(
            projectRoot,
            "app/src/main/java/ai/oriveo/community/feature/providers",
        )
        val translucentTokens = listOf(
            "primarySoft",
            "primaryGlow",
            "successSoft",
            "warningSoft",
            "dangerSoft",
            "errorSoft",
            "infoSoft",
            "border",
            "borderStrong",
            "cardHighlight",
            "hairline",
            "glassHighlight",
            "surfaceChrome",
        )
        val alphaReplacement = Regex(
            "(?:${translucentTokens.joinToString("|")})\\s*\\.\\s*copy\\s*\\(\\s*alpha\\s*=",
        )
        val offenders = providerRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { alphaReplacement.containsMatchIn(it.readText()) }
            .map { it.relativeTo(projectRoot).path }
            .toList()

        assertTrue(
            "Semi-transparent theme tokens must use Color.opacity(factor), not copy(alpha=): $offenders",
            offenders.isEmpty(),
        )
    }

    private fun assertLayeredFill(
        colors: OriveoColors,
        isDark: Boolean,
        opacityFactor: Float,
    ) {
        val actual = relayQuickSurfaceFillColor(colors, isDark)
        val overlayAlpha = colors.primarySoft.alpha * opacityFactor

        assertEquals(1f, actual.alpha, 0.0001f)
        assertEquals(
            compositeChannel(colors.primarySoft.red, overlayAlpha, colors.surfaceInset.red),
            actual.red,
            colorChannelTolerance,
        )
        assertEquals(
            compositeChannel(colors.primarySoft.green, overlayAlpha, colors.surfaceInset.green),
            actual.green,
            colorChannelTolerance,
        )
        assertEquals(
            compositeChannel(colors.primarySoft.blue, overlayAlpha, colors.surfaceInset.blue),
            actual.blue,
            colorChannelTolerance,
        )
    }

    private fun compositeChannel(foreground: Float, alpha: Float, background: Float): Float =
        foreground * alpha + background * (1f - alpha)
}
