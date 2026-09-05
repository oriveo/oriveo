package ai.oriveo.community.feature.home.homescreen

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeHeroVisualContractTest {
    @Test
    fun `home hero composer uses aurora glow glass structure`() {
        val themeSource = File("src/main/java/ai/oriveo/community/feature/home/AuroraTheme.kt").readText()
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()
        val cardSource = themeSource.substring(
            themeSource.indexOf("internal fun Modifier.auroraGlassCard("),
            themeSource.indexOf("// -- Section Rule"),
        )

        assertTrue(
            "Aurora card must use the iOS-aligned elevated surface instead of the old translucent fill.",
            themeSource.contains("val surface = OriveoTheme.colors.surfaceElevated") &&
                themeSource.contains("Brush.radialGradient") &&
                themeSource.contains("Brush.sweepGradient"),
        )
        assertTrue(
            "Hero card focus should wake the aurora border and lift, matching iOS focused: heroFocused.",
            barSource.contains(".auroraGlassCard(isDark = isDark, cornerRadius = 28.dp, focused = isFocused)"),
        )
        assertFalse(
            "The old glass path had hard fill/border styling and must not be the active hero contract.",
            themeSource.contains(".border(BorderStroke(1.dp, cardBorder), shape)"),
        )
        assertFalse(
            "Compose has no iOS blur on the aurora border; carrying iOS 4dp/2dp strokes over makes focus look thick.",
            themeSource.contains("val outerStroke = if (focused) 4.dp.toPx() else 2.4.dp.toPx()") ||
                themeSource.contains("val innerStroke = if (focused) 2.dp.toPx() else 1.4.dp.toPx()"),
        )
        assertFalse(
            "Android glass should stay surface-led; high alpha pink/purple radial fills turn the whole hero interior pink.",
            themeSource.contains("0.24f else 0.12f") ||
                themeSource.contains("0.18f else 0.09f"),
        )
        assertTrue(
            "Android should approximate the iOS blurred border with a native blurred outer glow plus a crisp edge.",
            themeSource.contains("BlurMaskFilter") &&
                themeSource.contains("AndroidSweepGradient") &&
                themeSource.contains("auroraGlowColors") &&
                themeSource.contains("val glowStroke") &&
                themeSource.contains("val crispStroke"),
        )
        assertTrue(
            "The blurred glow must be drawn before the card is clipped; otherwise the glow turns into a thick internal border.",
            themeSource.indexOf("drawIntoCanvas") in 0 until themeSource.indexOf(".clip(shape)"),
        )
        assertTrue(
            "The unfocused hero needs a visible rainbow edge while the interior remains a neutral surface.",
            themeSource.contains("targetValue = if (focused) 1f else 0.82f") &&
                themeSource.contains("if (focused) 0.70f else 0.45f") &&
                themeSource.contains("if (focused) 0.96f else 0.78f") &&
                themeSource.contains("radius = 300.dp.toPx()") &&
                themeSource.contains("radius = 280.dp.toPx()"),
        )
        assertFalse(
            "The hero must not regress to a purple private surface or a duplicated single-purple ambient fill.",
            themeSource.contains("Color(0xFF201A37)") ||
                themeSource.contains("ambientGlowPaint"),
        )
        assertTrue(
            "The card should own exactly the iOS-aligned contact, ambient, and brand shadow roles.",
            cardSource.contains("val contactShadowPaint") &&
                cardSource.contains("val ambientShadowPaint") &&
                cardSource.contains("val brandShadowPaint"),
        )
        assertFalse(
            "Do not stack Compose elevation shadows over the native directional shadows.",
            cardSource.contains(".shadow("),
        )
    }

    @Test
    fun `home hero model pill uses provider logo subtitle and cleaned model name`() {
        val homeSource = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()

        assertTrue(
            "HomeScreen should pass the active provider/model snapshot, not only a raw model string.",
            homeSource.contains("activeModel = activeModelState.activeModel"),
        )
        assertTrue(
            "NewChatBar should hero the provider logo and render the provider subtitle.",
            barSource.contains("ProviderBadgeIcon(") &&
                barSource.contains("active.provider.displayName") &&
                barSource.contains("homeHeroPillModelName("),
        )
        assertTrue(
            "The model selector content should keep the same compact leading frame as iOS .frame(maxWidth: 250, alignment: .leading).",
            barSource.contains("Modifier.widthIn(max = 250.dp)") &&
                barSource.contains("rememberTextMeasurer()") &&
                barSource.contains("val textNaturalWidth") &&
                barSource.contains(".coerceAtMost(textMaxWidth)") &&
                barSource.contains("ProviderBadgeIcon(") &&
                barSource.contains("size = 24.dp"),
        )
        assertFalse(
            "The inner model selector row must not use weight for its text; that lets the chevron drift away from the label.",
            barSource.contains("Modifier.weight(1f, fill = false)"),
        )
        assertTrue(
            "The model selector affordance should be a compact double-chevron next to the text, matching iOS chevron.up.chevron.down.",
            barSource.contains("ModelSelectorChevron()") &&
                barSource.contains("Icons.Outlined.UnfoldMore") &&
                barSource.contains("Modifier.size(12.dp)"),
        )
        assertFalse(
            "SwapVert reads as a thick model-switch action and pushes the visual away from the iOS double-chevron selector.",
            barSource.contains("Icons.Outlined.SwapVert"),
        )
        assertFalse(
            "The iOS-aligned pill no longer uses a green online dot as the main model affordance.",
            barSource.contains(".size(6.dp)") && barSource.contains(".background(AuroraTheme.auroraGreen())"),
        )
        assertTrue(
            "When providers exist but active model is still resolving, the pill should remain a model picker, not an add-provider CTA.",
            barSource.contains("} else if (hasProvider)") &&
                barSource.contains("stringResource(R.string.select_model)") &&
                barSource.contains("enabled = hasProvider") &&
                barSource.contains("ModelSelectorPlaceholderIcon()"),
        )
        assertTrue(
            "Without providers, the add-provider label should remain a direct CTA, not only the send button.",
            barSource.contains("stringResource(R.string.add_provider)") &&
                barSource.contains(".clickable(onClick = onAddProvider)"),
        )
    }

    @Test
    fun `home hero send button uses brand gradient glass ball`() {
        val barSource = File("src/main/java/ai/oriveo/community/feature/home/homescreen/NewChatBar.kt").readText()

        assertTrue(
            "Send button should use the shared primary gradient and a top white sheen.",
            barSource.contains("OriveoGradients.primary") &&
                barSource.contains("Color.White.copy(alpha = 0.28f)") &&
                barSource.contains("OriveoTheme.colors.shadow") &&
                barSource.contains(".size(48.dp)") &&
                barSource.contains(".size(44.dp)"),
        )
        assertFalse(
            "Send button must not regress to the flat solid-color purple circle.",
            barSource.contains(".background(colors.primary, CircleShape)"),
        )
    }
}
