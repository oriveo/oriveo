package ai.oriveo.community.ui.theme

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Spacing tokens, aligned with iOS OriveoTheme.spacing (V1 + V2). */
object OriveoSpacing {
    val xs: Dp = 4.dp
    val s6: Dp = 6.dp    // V2 addition
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val s20: Dp = 20.dp  // V2 addition, iOS screen-level padding
    val xl: Dp = 24.dp
    val xxl: Dp = 32.dp
}

/**
 * Density scale factor (dp/pt correction).
 *
 * Narrow Android screens (<393dp) and iOS at the same physical size (393pt) differ in logical width,
 * so the same dp value takes up a larger share of the screen. Lowering density at the Compose root
 * pulls the logical width toward the iOS 393pt reference, and all dp/sp values scale proportionally in one step.
 *
 * Adjusts by at most 8% (factor >= 0.92) to keep touch targets safe (48dp >= 7mm).
 * Wide screens and tablets are not adjusted.
 *
 * | Device        | Raw width | factor | Corrected logical width |
 * |---------------|-----------|--------|-------------------------|
 * | Galaxy S23    | 360dp     | 0.92   | ~391dp                  |
 * | Pixel 6a      | 384dp     | 0.977  | ~393dp                  |
 * | Pixel 7       | 412dp     | 1.0    | 412dp (not adjusted)    |
 */
internal fun densityScaleFactor(screenWidthDp: Int): Float {
    if (screenWidthDp >= 393) return 1f
    return (screenWidthDp / 393f).coerceAtLeast(0.92f)
}

/**
 * Responsive layout tokens: spacing adapts to the logical width after density correction.
 *
 * Breakpoints are based on the corrected width (approximately iOS pt width), so dp/pt differences no longer interfere.
 *
 * | Corrected width (dp) | compact | screenH | sectionGap | cardPadding |
 * |----------------------|---------|---------|------------|-------------|
 * | < 380                | true    | 16dp    | 20dp       | 14dp        |
 * | 380-411              | false   | 20dp    | 24dp       | 16dp        |
 * | >= 412               | false   | 24dp    | 24dp       | 16dp        |
 */
object OriveoLayout {

    /** Logical screen width after density correction, used for responsive breakpoints. */
    private val adjustedWidthDp: Int
        @Composable get() {
            val raw = LocalConfiguration.current.screenWidthDp
            val factor = densityScaleFactor(raw)
            return if (factor < 1f) (raw / factor).toInt() else raw
        }

    /** Whether the layout is compact (corrected width < 380dp). */
    val isCompact: Boolean
        @Composable get() = adjustedWidthDp < 380

    val screenH: Dp
        @Composable get() = when {
            adjustedWidthDp < 380 -> 16.dp
            adjustedWidthDp < 412 -> 20.dp
            else -> 24.dp
        }

    /** Screen-level top padding. */
    val screenTop: Dp
        @Composable get() = screenH

    /** Gap between sections (iOS xl = 24pt). */
    val sectionGap: Dp
        @Composable get() = if (isCompact) 20.dp else 24.dp

    /** Card inner padding (iOS lg = 16pt). */
    val cardPadding: Dp
        @Composable get() = if (isCompact) 14.dp else 16.dp

    /** Vertical gap between rows inside a card. */
    val cardRowGap: Dp
        @Composable get() = if (isCompact) 14.dp else 16.dp

    /** Primary button height. */
    val buttonHeight: Dp
        @Composable get() = if (isCompact) 44.dp else 48.dp
}

/**
 * Corner radius tokens, aligned with iOS OriveoTheme.radius (legacy sm/md/lg plus the v3 semantic tiers hero/card/inset/chip).
 */
object OriveoRadius {
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val full: Dp = 999.dp

    val hero: Dp = 24.dp   // Hero / primary focus card (note list card)
    val card: Dp = 20.dp   // Standard card (detail reading card / source card)
    val inset: Dp = 16.dp  // Embedded block inside a card / input field
    val chip: Dp = 10.dp   // Chip / pill / folder chip

    val smShape: Shape = RoundedCornerShape(sm)
    val mdShape: Shape = RoundedCornerShape(md)
    val lgShape: Shape = RoundedCornerShape(lg)
    val fullShape: Shape = CircleShape
}

/**
 * Border width tokens. Compensates for the rendering difference between Compose and SwiftUI.
 *
 * SwiftUI `.stroke(lineWidth: 1)` strokes centered (0.5pt inside + 0.5pt outside),
 * while Compose `Modifier.border(1.dp)` is fully inside.
 * 0.5dp matches the visible inner width on iOS, so the visual weight lines up.
 */
object OriveoBorderWidth {

    /** Structural stroke for cards, input fields, panels and similar. */
    val standard: Dp = 0.5.dp

    /** Fine stroke for hairline highlights. */
    val fine: Dp = 0.33.dp
    /** Emphasized 1dp border for light cards that sit on a tinted fill. */
    val emphasis: Dp = 1.dp
}
