package ai.oriveo.community.ui.component

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * A high-fidelity panel modifier -- used for containers that need a
 * "floating, dimensional" feel, like the providers cluster container and the
 * cost summary card.
 *
 * Matches the shared design language's gradient panel style (22pt corner
 * radius by default, this is the trimmed final version):
 * - three refined drop shadows (near 1dp + mid 6dp + far 18dp)
 * - a 4-stop padding-box linear gradient fill (pure surface color at the
 *   bottom in light mode, no purple tint)
 * - a pair of radial-gradient cool blue-violet corner glows at top-left and
 *   bottom-right (#6B7FFF / #8FA0FF)
 * - a 6dp cool blue-violet soft glow band at the bottom (a glass-panel
 *   reflection feel)
 * - no outer stroke -- shadow and gradient fill alone separate it from the
 *   page background
 *
 * Removed: the original primary-purple radial sheen (a pinkish reflection on
 * a white background), the 1.5dp white top highlight, and the 1dp bottom
 * reflection line (replaced by the soft glow band).
 *
 * Unlike `oriveoSurface(...)`, this is a premium panel meant for a handful of
 * core containers (the cluster and the cost card) -- don't overuse it.
 */
fun Modifier.oriveoGradientPanel(radius: Dp = 22.dp): Modifier = composed {
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors
    val shape = remember(radius) { RoundedCornerShape(radius) }

    // This modifier wraps the whole provider cluster list, and a monthlyCost /
    // metadata refresh triggers a recomposition of the entire list. The
    // original code allocated all four Brush values directly inside the
    // modifier body, reallocating them on every recomposition. Every
    // parameter here derives only from isDark + colors (both stable), so
    // it's cached once with remember.
    val params = remember(isDark, colors) {
        // -- three refined shadow layers (light mode: 1dp x 0.10 + 6dp x 0.08 + 18dp x 0.16) --
        val s1Alpha = if (isDark) 0.9f else 0.10f
        val s1Elev = if (isDark) 4.dp else 1.dp
        val s2Alpha = if (isDark) 1.0f else 0.08f
        val s2Elev = if (isDark) 12.dp else 6.dp
        val s3Alpha = if (isDark) 0.85f else 0.16f
        val s3Elev = if (isDark) 24.dp else 18.dp
        val s1Color = colors.shadow.copy(alpha = colors.shadow.alpha * s1Alpha)
        val s2Color = colors.shadow.copy(alpha = colors.shadow.alpha * s2Alpha)
        val s3Color = colors.shadowStrong.copy(alpha = colors.shadowStrong.alpha * s3Alpha)

        // -- 4-stop padding-box fill --
        val fillColors = if (isDark) {
            listOf(
                blend(Color.White, colors.surface, 0.07f),
                colors.surface,
                colors.surface,
                blend(Color.Black, colors.surface, 0.14f),
            )
        } else {
            listOf(
                blend(Color.White, colors.surface, 0.65f),
                colors.surface,
                colors.surface,
                colors.surface,
            )
        }

        // -- corner cool blue-violet glow parameters --
        val cornerGlowColor = if (isDark) Color(0xFF8FA0FF) else Color(0xFF6B7FFF)
        val cornerGlowTLAlpha = if (isDark) 0.12f else 0.065f
        val cornerGlowBRAlpha = if (isDark) 0.08f else 0.045f
        val bottomGlowAlpha = if (isDark) 0.07f else 0.035f

        GradientPanelParams(
            s1Elev = s1Elev, s2Elev = s2Elev, s3Elev = s3Elev,
            s1Color = s1Color, s2Color = s2Color, s3Color = s3Color,
            fillColors = fillColors,
            cornerGlowColor = cornerGlowColor,
            cornerGlowTLAlpha = cornerGlowTLAlpha,
            cornerGlowBRAlpha = cornerGlowBRAlpha,
            bottomGlowAlpha = bottomGlowAlpha,
        )
    }

    this
        .shadow(params.s1Elev, shape, clip = false, ambientColor = params.s1Color, spotColor = params.s1Color)
        .shadow(params.s2Elev, shape, clip = false, ambientColor = params.s2Color, spotColor = params.s2Color)
        .shadow(params.s3Elev, shape, clip = false, ambientColor = params.s3Color, spotColor = params.s3Color)
        .clip(shape)
        .drawBehind {
            // drawBehind still runs every frame (the draw phase), but every color value
            // now comes from the remembered params instead of allocating new Color/List
            // objects. A Brush that depends on size still has to be created inside draw.
            // 1) padding-box 4-stop fill
            drawRect(
                brush = Brush.verticalGradient(
                    colors = params.fillColors,
                    startY = 0f,
                    endY = this.size.height,
                ),
                size = this.size,
            )
            // 2) top-left RadialGradient cool blue-violet glow (centered 5% outside the panel's top-left corner, bleeding in from outside)
            val tlCenter = Offset(this.size.width * -0.05f, this.size.height * -0.05f)
            val tlRadius = 280.dp.toPx()
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(params.cornerGlowColor.copy(alpha = params.cornerGlowTLAlpha), Color.Transparent),
                    center = tlCenter,
                    radius = tlRadius,
                ),
                radius = tlRadius,
                center = tlCenter,
            )
            // 3) bottom-right RadialGradient cool blue-violet glow (centered 5% outside the panel's bottom-right corner)
            val brCenter = Offset(this.size.width * 1.05f, this.size.height * 1.05f)
            val brRadius = 240.dp.toPx()
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(params.cornerGlowColor.copy(alpha = params.cornerGlowBRAlpha), Color.Transparent),
                    center = brCenter,
                    radius = brRadius,
                ),
                radius = brRadius,
                center = brCenter,
            )
            // 4) bottom 6dp cool blue-violet soft glow band (a glass-panel reflection feel)
            val bottomGlowH = 6.dp.toPx()
            val inset = 1.dp.toPx()
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.Transparent,
                        params.cornerGlowColor.copy(alpha = params.bottomGlowAlpha),
                    ),
                    startY = this.size.height - bottomGlowH,
                    endY = this.size.height,
                ),
                topLeft = Offset(inset, this.size.height - bottomGlowH),
                size = Size(this.size.width - inset * 2, bottomGlowH),
            )
        }
}

private data class GradientPanelParams(
    val s1Elev: Dp, val s2Elev: Dp, val s3Elev: Dp,
    val s1Color: Color, val s2Color: Color, val s3Color: Color,
    val fillColors: List<Color>,
    val cornerGlowColor: Color,
    val cornerGlowTLAlpha: Float,
    val cornerGlowBRAlpha: Float,
    val bottomGlowAlpha: Float,
)
