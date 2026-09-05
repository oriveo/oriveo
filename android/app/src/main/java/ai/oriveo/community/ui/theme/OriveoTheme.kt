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

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFFC4B5FD),
    
    onPrimary = Color(0xFF0F1218),
    primaryContainer = Color(0x2EA78BFA),
    onPrimaryContainer = Color(0xFFF8FAFF),
    secondary = Color(0xFF4ADE80),
    onSecondary = Color.Black,
    tertiary = Color(0xFFFBBF24),
    onTertiary = Color.Black,
    error = Color(0xFFFB7185),
    onError = Color.Black,
    errorContainer = Color(0x2BFB7185),
    background = Color(0xFF0B1020),
    onBackground = Color(0xFFF8FAFF),
    surface = Color(0xFF141B2D),
    onSurface = Color(0xFFF8FAFF),
    surfaceVariant = Color(0xFF1B2440),
    onSurfaceVariant = Color(0xFFB4C1D9),
    outline = Color(0x1AFFFFFF),
    outlineVariant = Color(0x2EC7D2FE),
)


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
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme
    val oriveoColors = if (darkTheme) DarkOriveoColors else LightOriveoColors

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            
            
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
            WindowCompat.getInsetsController(window, view).isAppearanceLightNavigationBars = !darkTheme
            
            val windowBg = if (darkTheme) android.graphics.Color.parseColor("#FF090E1B")
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

object OriveoGradients {
    
    val primary = Brush.linearGradient(
        colors = listOf(Color(0xFF8347F5), Color(0xFF6B3BC7)),
        start = Offset.Zero,
        end = Offset.Infinite,
    )

    
    val primaryPressed = Brush.linearGradient(
        colors = listOf(Color(0xFF7238E5), Color(0xFF5A2BB0)),
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
    
    glowTint: Color = Color(0xFF8C5FF8),
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark

    
    val baseBrush = if (isDark) {
        Brush.linearGradient(
            colors = listOf(
                colors.backgroundBase,
                colors.background,
                Color(0xFF090E1B),
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
                            glowTint.copy(alpha = glowAlpha),
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
    val brush = if (isDark) {
        Brush.verticalGradient(listOf(Color(0xFF171520), Color(0xFF131019)))
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

    Box(modifier = modifier.fillMaxSize()) {
        if (isDark) {
            
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0xFF101016)),
            )
            Box(
                modifier = Modifier
                    .size(800.dp)
                    .align(Alignment.TopCenter)
                    .background(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Color(0xFF8C5FF8).copy(alpha = 0.06f),
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
