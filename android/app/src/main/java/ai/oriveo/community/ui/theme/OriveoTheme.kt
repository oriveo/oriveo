package ai.oriveo.community.ui.theme

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import ai.oriveo.community.ui.component.BrandImageBitmapCache
import ai.oriveo.community.ui.component.BrandImageRequest
import ai.oriveo.community.ui.component.BrandLogoResources
import ai.oriveo.community.ui.component.LocalBrandImageBitmapCache

private val LightColorScheme = lightColorScheme(
    primary = Color(0xFF8C5FF8),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFEDE9FE),
    onPrimaryContainer = Color(0xFF21005D),
    secondary = Color(0xFF10B981),
    onSecondary = Color.White,
    tertiary = Color(0xFFF59E0B),
    onTertiary = Color.White,
    error = Color(0xFFEF4444),
    onError = Color.White,
    errorContainer = Color(0xFFFEF2F2),
    background = Color(0xFFF8FAFC),
    onBackground = Color(0xFF111827),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF111827),
    surfaceVariant = Color(0xFFF8FAFC),
    onSurfaceVariant = Color(0xFF6B7280),
    outline = Color(0xFFE5E7EB),
    outlineVariant = Color(0xFFD1D5DB),
)

/**
 * The dark Material3 ColorScheme is derived from the current palette instance instead of keeping a separate hex copy (the old one drifted from OriveoColors:
 * primary, surface and others no longer matched). M3 components (Dialog / Menu / TextField) therefore follow palette switches.
 */
internal fun darkColorSchemeOf(c: OriveoColors): ColorScheme = darkColorScheme(
    primary = c.primary,
    onPrimary = c.onPrimary,
    primaryContainer = c.primary.copy(alpha = 0.18f),
    onPrimaryContainer = c.textPrimary,
    secondary = c.success,
    onSecondary = c.onSuccess,
    tertiary = c.warning,
    onTertiary = c.onWarning,
    error = c.danger,
    onError = c.onDanger,
    errorContainer = c.dangerSoft,
    background = c.backgroundBase,
    onBackground = c.textPrimary,
    surface = c.surface,
    onSurface = c.textPrimary,
    surfaceVariant = c.surfaceElevated,
    onSurfaceVariant = c.textSecondary,
    surfaceContainerLowest = c.backgroundBase,
    surfaceContainerLow = c.background,
    surfaceContainer = c.surface,
    surfaceContainerHigh = c.surfaceElevated,
    surfaceContainerHighest = c.surfaceElevated,
    outline = c.border,
    outlineVariant = c.borderStrong,
)

/**
 * Dark palette ids, in the same order and with the same names as `order` in `shared/theme-contracts/dark-palettes.v1.json`.
 * Light is unaffected. An unknown or missing id always falls back to the default [Dark].
 */
enum class DarkPaletteId(val id: String) {
    Dark("dark"),
    Purple("dark-purple"),
    Graphite("dark-graphite"),
    Black("dark-black"),
    Ocean("dark-ocean"),
    Forest("dark-forest"),
    Sunset("dark-sunset"),
    ;

    val colors: OriveoColors
        get() = when (this) {
            Dark -> DarkOriveoColors
            Purple -> DarkPurpleOriveoColors
            Graphite -> DarkGraphiteOriveoColors
            Black -> DarkBlackOriveoColors
            Ocean -> DarkOceanOriveoColors
            Forest -> DarkForestOriveoColors
            Sunset -> DarkSunsetOriveoColors
        }

    companion object {
        val Default: DarkPaletteId = Dark

        fun fromId(id: String?): DarkPaletteId = fromIdOrNull(id) ?: Default

        /** A known id returns its palette; an unknown or missing id returns null. */
        fun fromIdOrNull(id: String?): DarkPaletteId? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Single source of truth for the motion durations of the model-control modal.
 *
 * The Android equivalent of "reduce motion" is `ANIMATOR_DURATION_SCALE == 0`
 * (read by the existing `isReduceMotionEnabled(context)`; do not write a second copy). When it applies the
 * **duration drops to zero** instead of switching to a shorter curve: a "faster animation" is not "no animation".
 */
object OriveoMotion {

    const val modelControlSegmentMillis = 180

    const val modelControlPageMillis = 250

    fun modelControlSegmentMillis(reduceMotion: Boolean): Int =
        if (reduceMotion) 0 else modelControlSegmentMillis

    fun modelControlPageMillis(reduceMotion: Boolean): Int =
        if (reduceMotion) 0 else modelControlPageMillis
}

@Composable
fun modelControlTextButtonColors(): ButtonColors =
    ButtonDefaults.textButtonColors(contentColor = OriveoTheme.colors.primaryTextSafe)

// ── Theme Composable ──

@Composable
fun OriveoTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    palette: DarkPaletteId = DarkPaletteId.Default,
    content: @Composable () -> Unit,
) {
    // A palette switch only swaps the palette in the CompositionLocal: the Activity is not recreated, and remember state, input and scroll positions are all kept
    val oriveoColors = if (darkTheme) palette.colors else LightOriveoColors
    val colorScheme = if (darkTheme) remember(oriveoColors) { darkColorSchemeOf(oriveoColors) } else LightColorScheme

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window

            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
            WindowCompat.getInsetsController(window, view).isAppearanceLightNavigationBars = !darkTheme
            // Sync the window background color dynamically, using the gradient base so the navigation bar area blends with the background gradient
            val windowBg = if (darkTheme) oriveoColors.backgroundBase.toArgb()
                else android.graphics.Color.parseColor("#FFF6F5FA")
            window.decorView.setBackgroundColor(windowBg)
        }
    }

    val currentDensity = LocalDensity.current
    val factor = densityScaleFactor(LocalConfiguration.current.screenWidthDp)
    val adjustedDensity = if (factor < 1f) {
        Density(density = currentDensity.density * factor, fontScale = currentDensity.fontScale)
    } else {
        currentDensity
    }

    val applicationContext = LocalContext.current.applicationContext
    val brandImageCache = remember(applicationContext) {
        BrandImageBitmapCache(applicationContext.resources)
    }
    LaunchedEffect(brandImageCache, adjustedDensity) {
        val preloadRequests = BrandLogoResources.commonBrandLogos.map { spec ->
            BrandImageRequest(
                resId = spec.resId,
                targetEdgePx = with(adjustedDensity) { spec.targetSize.roundToPx().coerceAtLeast(1) },
            )
        }
        brandImageCache.preload(preloadRequests)
    }

    CompositionLocalProvider(
        LocalOriveoColors provides oriveoColors,
        LocalIsDarkTheme provides darkTheme,
        LocalDensity provides adjustedDensity,
        LocalBrandImageBitmapCache provides brandImageCache,

        LocalContentColor provides oriveoColors.textPrimary,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            content = content,
        )
    }
}

object OriveoTheme {
    val colors: OriveoColors
        @Composable get() = LocalOriveoColors.current

    val isDark: Boolean
        @Composable get() = LocalIsDarkTheme.current

    val typography: OriveoTypography get() = OriveoTypography
    val spacing: OriveoSpacing get() = OriveoSpacing
    val radius: OriveoRadius get() = OriveoRadius

    val layout: OriveoLayout get() = OriveoLayout
}

// ── OriveoGradients ──

/**
 * Primary button / user bubble gradient. Dark uses the current palette's gradient-brand (135 degrees, primary -> accent) and follows palette switches immediately;
 * light keeps the original brand gradient (aligned with iOS primaryGradient), pixel for pixel unchanged.
 */
object OriveoGradients {
    // dark-palette-guard: keep (d) light branch
    private val LightPrimaryStops = listOf(Color(0xFF8347F5), Color(0xFF6B3BC7))

    // dark-palette-guard: keep (d) light branch
    private val LightPrimaryPressedStops = listOf(Color(0xFF7238E5), Color(0xFF5A2BB0))

    private val lightPrimary = brandLinear(LightPrimaryStops)
    private val lightPrimaryPressed = brandLinear(LightPrimaryPressedStops)

    /** Primary gradient endpoints: dark = [primary, accent], light = the original brand gradient. */
    internal fun primaryStops(colors: OriveoColors, isDark: Boolean): List<Color> =
        if (isDark) colors.gradientBrandStops else LightPrimaryStops

    /** Pressed-state endpoints: dark = [primaryActive, accent], light = the original pressed gradient. */
    internal fun primaryPressedStops(colors: OriveoColors, isDark: Boolean): List<Color> =
        if (isDark) listOf(colors.primaryActive, colors.accent) else LightPrimaryPressedStops

    /** Primary button / user bubble gradient, aligned with iOS primaryGradient */
    val primary: Brush
        @Composable get() {
            val colors = LocalOriveoColors.current
            return if (LocalIsDarkTheme.current) {
                remember(colors) { brandLinear(primaryStops(colors, isDark = true)) }
            } else {
                lightPrimary
            }
        }

    /** Primary button pressed-state gradient, aligned with iOS primaryGradientPressed */
    val primaryPressed: Brush
        @Composable get() {
            val colors = LocalOriveoColors.current
            return if (LocalIsDarkTheme.current) {
                remember(colors) { brandLinear(primaryPressedStops(colors, isDark = true)) }
            } else {
                lightPrimaryPressed
            }
        }

    /** Icon / text color on the [primary] gradient: the palette onPrimary in dark, white in light. */
    internal fun onPrimaryContent(colors: OriveoColors, isDark: Boolean): Color =
        if (isDark) colors.onPrimary else Color.White

    /** Reads [onPrimaryContent] during composition. */
    val onPrimary: Color
        @Composable get() = onPrimaryContent(LocalOriveoColors.current, LocalIsDarkTheme.current)

    private fun brandLinear(stops: List<Color>): Brush = Brush.linearGradient(
        colors = stops,
        start = Offset.Zero,
        end = Offset.Infinite,
    )
}

enum class OriveoSurfaceStyle { None, Soft, Lifted }

fun Modifier.oriveoSurface(
    colors: OriveoColors,
    isDark: Boolean,
    fill: Color = colors.surface,
    borderColor: Color = colors.border,
    radius: Dp = OriveoRadius.md,
    shadowStyle: OriveoSurfaceStyle = OriveoSurfaceStyle.Soft,
): Modifier {
    val shape = RoundedCornerShape(radius)

    val shadowElevation = when (shadowStyle) {
        OriveoSurfaceStyle.None -> 0.dp
        OriveoSurfaceStyle.Soft -> if (isDark) 16.dp else 8.dp
        OriveoSurfaceStyle.Lifted -> if (isDark) 26.dp else 14.dp
    }
    val shadowColor = when (shadowStyle) {
        OriveoSurfaceStyle.None -> Color.Transparent
        OriveoSurfaceStyle.Soft -> colors.shadow
        OriveoSurfaceStyle.Lifted -> colors.shadowStrong
    }

    val edgeShadowElevation = when (shadowStyle) {
        OriveoSurfaceStyle.None -> 0.dp
        OriveoSurfaceStyle.Soft -> 2.dp
        OriveoSurfaceStyle.Lifted -> 3.dp
    }
    val edgeShadowColor = if (shadowStyle == OriveoSurfaceStyle.None) {
        Color.Transparent
    } else {
        shadowColor.copy(alpha = shadowColor.alpha * 0.6f)
    }

    return this

        .shadow(
            elevation = shadowElevation,
            shape = shape,
            ambientColor = shadowColor,
            spotColor = shadowColor,
        )

        .shadow(
            elevation = edgeShadowElevation,
            shape = shape,
            ambientColor = edgeShadowColor,
            spotColor = edgeShadowColor,
        )

        .background(fill, shape)

        .background(
            brush = Brush.linearGradient(
                colors = listOf(colors.cardHighlight, Color.Transparent),
                start = Offset.Zero,
                end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
            ),
            shape = shape,
        )

        .border(OriveoBorderWidth.standard, borderColor, shape)

        .then(
            if (isDark) {
                Modifier.border(
                    width = OriveoBorderWidth.fine,
                    brush = Brush.linearGradient(
                        colors = listOf(colors.hairline, Color.Transparent),
                        start = Offset.Zero,
                        end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
                    ),
                    shape = shape,
                )
            } else {
                Modifier
            },
        )
}

@Composable
fun OriveoScreenBackground(
    modifier: Modifier = Modifier,
    /** Glow hue: defaults to the current palette primary; a page with its own accent can pass its own hue. Aligned with iOS glowTint. */
    glowTint: Color = Color.Unspecified,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    // dark-palette-guard: keep (d) light branch
    val resolvedGlowTint = glowTint.takeOrElse { if (isDark) colors.primary else Color(0xFF8C5FF8) }

    val baseBrush = if (isDark) {
        Brush.linearGradient(
            colors = listOf(
                colors.backgroundBase,
                colors.background,
                colors.backgroundBase,
            ),
            start = Offset.Zero,
            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
        )
    } else {
        Brush.linearGradient(
            colors = listOf(
                Color(0xFFFAFBFF),
                Color(0xFFF6F5FA),
            ),
            start = Offset.Zero,
            end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY),
        )
    }

    val glowAlpha = if (isDark) 0.14f else 0.07f
    val glowSize = if (isDark) 500.dp else 460.dp
    val glowOffsetY = if (isDark) (-100).dp else (-80).dp

    Box(modifier = modifier.fillMaxSize()) {

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(baseBrush),
        )

        Box(
            modifier = Modifier
                .size(glowSize)
                .offset(y = glowOffsetY)
                .align(Alignment.TopCenter)
                .background(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            resolvedGlowTint.copy(alpha = glowAlpha),
                            Color.Transparent,
                        ),
                    ),
                    shape = CircleShape,
                ),
        )
    }
}

@Composable
fun OriveoNotesBackground(
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors
    val brush = if (isDark) {
        Brush.verticalGradient(listOf(colors.background, colors.backgroundBase))
    } else {
        Brush.verticalGradient(listOf(Color(0xFFF7F5FB), Color(0xFFF1ECF8)))
    }
    Box(modifier = modifier.fillMaxSize().background(brush))
}

@Composable
fun OriveoV2ScreenBackground(
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val colors = OriveoTheme.colors

    Box(modifier = modifier.fillMaxSize()) {
        if (isDark) {

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(colors.backgroundBase),
            )
            Box(
                modifier = Modifier
                    .size(800.dp)
                    .align(Alignment.TopCenter)
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                colors.primary.copy(alpha = 0.06f),
                                Color.Transparent,
                            ),
                        ),
                        shape = CircleShape,
                    ),
            )
        } else {

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        brush = Brush.verticalGradient(
                            colors = listOf(
                                Color(0xFFFAF8FF),
                                Color(0xFFF6F4FB),
                            ),
                        ),
                    ),
            )
        }
    }
}
