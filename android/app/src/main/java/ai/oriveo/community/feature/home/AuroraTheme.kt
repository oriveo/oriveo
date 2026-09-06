package ai.oriveo.community.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.ui.theme.OriveoTheme
import java.util.Calendar
import android.graphics.BlurMaskFilter
import android.graphics.Paint as AndroidPaint
import android.graphics.SweepGradient as AndroidSweepGradient

/**
 * Aurora -- the home screen's dedicated visual system (matches iOS AuroraTheme).
 *
 * Design philosophy: liquid glass, an Apple-Intelligence-style purple glow, and an airy, elegant
 * feel. Scoped to Home only, so it doesn't leak into the global OriveoTheme.
 */
internal object AuroraTheme {

    // color palette -- fully aligned with iOS AuroraTheme.Colors
    object Colors {
        val accentLight = Color(0xFF8B5CF6)
        val accentDark = Color(0xFFA78BFA)

        val accentGlowLight = Color(0xFF8B5CF6)
        val accentGlowDark = Color(0xFFC4B5FD)

        val auroraBlueLight = Color(0xFF60A5FA)
        val auroraBlueDark = Color(0xFF93C5FD)

        val textPrimaryLight = Color(0xFF0A0612)
        val textPrimaryDark = Color(0xFFFAFAFB)

        val textSecondaryLight = Color(0xFF6B6378)
        val textSecondaryDark = Color(0xFFC4BFD3)

        val textTertiaryLight = Color(0xFF9C95AA)
        val textTertiaryDark = Color(0xFF8C8499)

        val cardFillLight = Color(0xFFFFFFFF).copy(alpha = 0.72f)
        val cardFillDark = Color(0xFF1A1530).copy(alpha = 0.55f)
        val cardBorderLight = Color(0xFF6B5BD0).copy(alpha = 0.10f)
        val cardBorderDark = Color(0xFFFFFFFF).copy(alpha = 0.08f)

        // hairline: black @ 0.06 / white @ 0.08
        val hairlineLight = Color(0xFF000000).copy(alpha = 0.06f)
        val hairlineDark = Color(0xFFFFFFFF).copy(alpha = 0.08f)

        // dark-mode screen background gradient endpoints -- kept in the same lightness tier as
        // OriveoColors.dark.backgroundBase (#0F1218), using a softer L*~11/13 range rather than a near-black tone.
        val bgDarkTop = Color(0xFF1B1A2A)
        val bgDarkBottom = Color(0xFF14101F)

        // light-mode screen background gradient endpoints
        val bgLightTop = Color(0xFFF7F4FB)
        val bgLightBottom = Color(0xFFF1ECF7)

        // hero text gradient (matches iOS heroTextGradient)
        val heroGradientLightStart = Color(0xFF0A0612)
        val heroGradientLightEnd = Color(0xFF4C1D95)
        val heroGradientDarkStart = Color(0xFFFFFFFF)
        val heroGradientDarkEnd = Color(0xFFC4B5FD)

        val auroraPink = Color(0xFFEC8FEA)
        val auroraLavender = Color(0xFFC4B5FD)
        val auroraSoftBlue = Color(0xFF8DB4FF)
        val auroraSoftCyan = Color(0xFF86D2E6)
    }

    /** The primary accent purple for the current mode. */
    @Composable
    fun accent(): Color = if (OriveoTheme.isDark) Colors.accentDark else Colors.accentLight

    @Composable
    fun accentGlow(): Color = if (OriveoTheme.isDark) Colors.accentGlowDark else Colors.accentGlowLight

    @Composable
    fun textPrimary(): Color = if (OriveoTheme.isDark) Colors.textPrimaryDark else Colors.textPrimaryLight

    @Composable
    fun textSecondary(): Color = if (OriveoTheme.isDark) Colors.textSecondaryDark else Colors.textSecondaryLight

    @Composable
    fun textTertiary(): Color = if (OriveoTheme.isDark) Colors.textTertiaryDark else Colors.textTertiaryLight

    @Composable
    fun cardFill(): Color = if (OriveoTheme.isDark) Colors.cardFillDark else Colors.cardFillLight

    @Composable
    fun cardBorder(): Color = if (OriveoTheme.isDark) Colors.cardBorderDark else Colors.cardBorderLight

    @Composable
    fun hairline(): Color = if (OriveoTheme.isDark) Colors.hairlineDark else Colors.hairlineLight

    // fonts (matches iOS AuroraTheme.Typography)
    object Typography {
        val hero = TextStyle(
            fontSize = 32.sp,
            lineHeight = 36.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = (-0.5).sp,
        )
        val composerPlaceholder = TextStyle(
            fontSize = 18.sp,
            lineHeight = 24.sp,
            fontWeight = FontWeight.Medium,
        )
        val section = TextStyle(
            fontSize = 20.sp,
            lineHeight = 24.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = (-0.3).sp,
        )
        val countMono = TextStyle(
            fontSize = 13.sp,
            lineHeight = 16.sp,
            fontWeight = FontWeight.Medium,
            // monospaced is provided by the system's monospace font
        )
    }
}

/** iOS `auroraGlowColors`' fixed color sequence: purple -> lavender -> pink -> blue -> cyan -> light purple -> purple. */
private val auroraGlowColors = listOf(
    AuroraTheme.Colors.accentLight,
    AuroraTheme.Colors.accentDark,
    AuroraTheme.Colors.auroraPink,
    AuroraTheme.Colors.auroraSoftBlue,
    AuroraTheme.Colors.auroraSoftCyan,
    AuroraTheme.Colors.auroraLavender,
    AuroraTheme.Colors.accentLight,
)

@Composable
internal fun AuroraScreenBackground(modifier: Modifier = Modifier) {
    val isDark = OriveoTheme.isDark
    val brush = remember(isDark) {
        Brush.verticalGradient(
            colors = if (isDark) {
                listOf(AuroraTheme.Colors.bgDarkTop, AuroraTheme.Colors.bgDarkBottom)
            } else {
                listOf(AuroraTheme.Colors.bgLightTop, AuroraTheme.Colors.bgLightBottom)
            },
        )
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(brush),
    )
}

// ── Glass Card ──

/**
 * Aurora glass card background -- matches iOS `AuroraGlassCardModifier`.
 *
 * Visuals: a neutral elevated card surface, a localized inner glow at the top, a sharp rainbow
 * edge plus a blurred rainbow halo, and three layers of directional soft shadow.
 *
 * The @Composable version caches the Brush; focus only drives the stroke brightness and shadow
 * strength, to keep the home screen's persistent animation cheap.
 */
@androidx.compose.runtime.Composable
internal fun Modifier.auroraGlassCard(
    isDark: Boolean,
    cornerRadius: Dp = 24.dp,
    focused: Boolean = false,
): Modifier {
    val shape = androidx.compose.runtime.remember(cornerRadius) { RoundedCornerShape(cornerRadius) }
    val surface = OriveoTheme.colors.surfaceElevated
    val accent = if (isDark) AuroraTheme.Colors.accentDark else AuroraTheme.Colors.accentLight
    val glowAlpha by animateFloatAsState(
        targetValue = if (focused) 1f else 0.82f,
        animationSpec = tween(durationMillis = 450, easing = EaseInOut),
        label = "home-hero-aurora-glow",
    )
    return this
        .drawWithCache {
            val cr = cornerRadius.toPx()
            val glowPath = Path().apply {
                addRoundRect(
                    androidx.compose.ui.geometry.RoundRect(
                        left = 0f,
                        top = 0f,
                        right = size.width,
                        bottom = size.height,
                        cornerRadius = CornerRadius(cr, cr),
                    ),
                )
            }
            val frameworkGlowPath = glowPath.asAndroidPath()
            val contactShadowPaint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.FILL
                color = Color.Black
                    .copy(alpha = if (isDark) 0.30f else 0.05f)
                    .toArgb()
                maskFilter = BlurMaskFilter(
                    if (isDark) 6.dp.toPx() else 5.dp.toPx(),
                    BlurMaskFilter.Blur.NORMAL,
                )
            }
            val ambientShadowPaint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.FILL
                color = Color.Black
                    .copy(alpha = if (isDark) 0.45f else 0.08f)
                    .toArgb()
                maskFilter = BlurMaskFilter(
                    if (isDark) 26.dp.toPx() else 24.dp.toPx(),
                    BlurMaskFilter.Blur.NORMAL,
                )
            }
            val brandShadowPaint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.FILL
                color = accent
                    .copy(
                        alpha = if (focused) {
                            if (isDark) 0.30f else 0.18f
                        } else {
                            if (isDark) 0.16f else 0.09f
                        },
                    )
                    .toArgb()
                maskFilter = BlurMaskFilter(
                    if (focused) 46.dp.toPx() else 32.dp.toPx(),
                    BlurMaskFilter.Blur.NORMAL,
                )
            }
            val glowStroke = if (focused) 4.dp.toPx() else 2.4.dp.toPx()
            val glowOpacity = (if (focused) 0.70f else 0.45f) * glowAlpha
            val glowPaint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
                style = AndroidPaint.Style.STROKE
                strokeWidth = glowStroke
                shader = AndroidSweepGradient(
                    size.width / 2f,
                    size.height / 2f,
                    auroraGlowColors.map { it.toArgb() }.toIntArray(),
                    null,
                )
                alpha = (glowOpacity * 255).toInt()
                maskFilter = BlurMaskFilter(
                    if (focused) 6.dp.toPx() else 3.dp.toPx(),
                    BlurMaskFilter.Blur.NORMAL,
                )
            }
            onDrawBehind {
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.save()
                    canvas.nativeCanvas.translate(0f, 14.dp.toPx())
                    canvas.nativeCanvas.drawPath(frameworkGlowPath, brandShadowPaint)
                    canvas.nativeCanvas.restore()

                    canvas.nativeCanvas.save()
                    canvas.nativeCanvas.translate(0f, if (isDark) 16.dp.toPx() else 12.dp.toPx())
                    canvas.nativeCanvas.drawPath(frameworkGlowPath, ambientShadowPaint)
                    canvas.nativeCanvas.restore()

                    canvas.nativeCanvas.save()
                    canvas.nativeCanvas.translate(0f, 2.dp.toPx())
                    canvas.nativeCanvas.drawPath(frameworkGlowPath, contactShadowPaint)
                    canvas.nativeCanvas.restore()

                    canvas.nativeCanvas.drawPath(frameworkGlowPath, glowPaint)
                }
            }
        }
        .clip(shape)
        .drawWithCache {
            val cr = cornerRadius.toPx()
            val innerPurpleGlow = Brush.radialGradient(
                colors = listOf(
                    accent.copy(alpha = if (isDark) 0.16f else 0.07f),
                    Color.Transparent,
                ),
                center = Offset(0f, 0f),
                radius = 300.dp.toPx(),
            )
            val innerPinkGlow = Brush.radialGradient(
                colors = listOf(
                    AuroraTheme.Colors.auroraPink.copy(alpha = if (isDark) 0.10f else 0.04f),
                    Color.Transparent,
                ),
                center = Offset(size.width, 0f),
                radius = 280.dp.toPx(),
            )
            val darkTopSheen = Brush.verticalGradient(
                colors = listOf(
                    Color.White.copy(alpha = if (isDark) 0.05f else 0f),
                    Color.Transparent,
                ),
            )
            val glowRing = Brush.sweepGradient(
                colors = auroraGlowColors,
                center = Offset(size.width / 2f, size.height / 2f),
            )
            val crispStroke = if (focused) 1.35.dp.toPx() else 0.95.dp.toPx()
            val crispInset = crispStroke / 2f
            onDrawBehind {
                drawRoundRect(color = surface, cornerRadius = CornerRadius(cr, cr))
                drawRoundRect(brush = innerPurpleGlow, cornerRadius = CornerRadius(cr, cr))
                drawRoundRect(brush = innerPinkGlow, cornerRadius = CornerRadius(cr, cr))
                if (isDark) {
                    drawRoundRect(brush = darkTopSheen, cornerRadius = CornerRadius(cr, cr))
                    drawRoundRect(
                        color = Color.White,
                        topLeft = Offset(0.375.dp.toPx(), 0.375.dp.toPx()),
                        size = Size(
                            width = size.width - 0.75.dp.toPx(),
                            height = size.height - 0.75.dp.toPx(),
                        ),
                        cornerRadius = CornerRadius(
                            (cr - 0.375.dp.toPx()).coerceAtLeast(0f),
                            (cr - 0.375.dp.toPx()).coerceAtLeast(0f),
                        ),
                        alpha = 0.06f,
                        style = Stroke(width = 0.75.dp.toPx()),
                    )
                }
                drawRoundRect(
                    brush = glowRing,
                    topLeft = Offset(crispInset, crispInset),
                    size = Size(
                        width = size.width - crispInset * 2,
                        height = size.height - crispInset * 2,
                    ),
                    cornerRadius = CornerRadius(
                        (cr - crispInset).coerceAtLeast(0f),
                        (cr - crispInset).coerceAtLeast(0f),
                    ),
                    alpha = (if (focused) 0.96f else 0.78f) * glowAlpha,
                    style = Stroke(width = crispStroke),
                )
            }
        }
}

// -- Section Rule (the glowing purple vertical bar) --

@Composable
internal fun AuroraSectionRule(modifier: Modifier = Modifier) {
    val accent = AuroraTheme.accent()
    val accentGlow = AuroraTheme.accentGlow()
    Box(
        modifier = modifier
            .width(3.dp)
            .height(22.dp)
            .shadow(
                elevation = 4.dp,
                shape = RoundedCornerShape(50),
                ambientColor = accent.copy(alpha = 0.55f),
                spotColor = accent.copy(alpha = 0.55f),
                clip = false,
            )
            .clip(RoundedCornerShape(50))
            .background(
                Brush.verticalGradient(colors = listOf(accentGlow, accent)),
            ),
    )
}

// ── Greeting ──

internal object AuroraGreeting {

    enum class Bucket { MORNING, AFTERNOON, EVENING, NIGHT }

    fun current(now: Calendar = Calendar.getInstance()): Bucket {
        return when (now.get(Calendar.HOUR_OF_DAY)) {
            in 5..11 -> Bucket.MORNING
            in 12..17 -> Bucket.AFTERNOON
            in 18..22 -> Bucket.EVENING
            else -> Bucket.NIGHT
        }
    }

    /** Matches iOS AuroraGreeting.currentKey() exactly: the nameless greeting. */
    fun greetingResId(now: Calendar = Calendar.getInstance()): Int {
        return when (current(now)) {
            Bucket.MORNING -> ai.oriveo.community.R.string.greeting_morning
            Bucket.AFTERNOON -> ai.oriveo.community.R.string.greeting_afternoon
            Bucket.EVENING -> ai.oriveo.community.R.string.greeting_evening
            Bucket.NIGHT -> ai.oriveo.community.R.string.greeting_still_up
        }
    }

    /** The greeting with a name (includes a %1$s placeholder). */
    fun nameGreetingResId(now: Calendar = Calendar.getInstance()): Int {
        return when (current(now)) {
            Bucket.MORNING -> ai.oriveo.community.R.string.greeting_morning_with_name
            Bucket.AFTERNOON -> ai.oriveo.community.R.string.greeting_afternoon_with_name
            Bucket.EVENING -> ai.oriveo.community.R.string.greeting_evening_with_name
            Bucket.NIGHT -> ai.oriveo.community.R.string.greeting_still_up_with_name
        }
    }

    /**
     * Sixteen taglines across the four time-of-day buckets -- stable within a day (no flicker),
     * refreshed daily. Design philosophy: self-compassion / autonomy / companionship /
     * containment / validation / presence -- consistently avoiding toxic positivity ("you've got this!").
     */
    private val morningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_morning_1,
        ai.oriveo.community.R.string.tagline_morning_2,
        ai.oriveo.community.R.string.tagline_morning_3,
        ai.oriveo.community.R.string.tagline_morning_4,
    )
    private val afternoonTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_afternoon_1,
        ai.oriveo.community.R.string.tagline_afternoon_2,
        ai.oriveo.community.R.string.tagline_afternoon_3,
        ai.oriveo.community.R.string.tagline_afternoon_4,
    )
    private val eveningTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_evening_1,
        ai.oriveo.community.R.string.tagline_evening_2,
        ai.oriveo.community.R.string.tagline_evening_3,
        ai.oriveo.community.R.string.tagline_evening_4,
    )
    private val nightTaglines = intArrayOf(
        ai.oriveo.community.R.string.tagline_night_1,
        ai.oriveo.community.R.string.tagline_night_2,
        ai.oriveo.community.R.string.tagline_night_3,
        ai.oriveo.community.R.string.tagline_night_4,
    )

    fun taglineResId(now: Calendar = Calendar.getInstance()): Int {
        val pool = when (current(now)) {
            Bucket.MORNING -> morningTaglines
            Bucket.AFTERNOON -> afternoonTaglines
            Bucket.EVENING -> eveningTaglines
            Bucket.NIGHT -> nightTaglines
        }
        val dayOfYear = now.get(Calendar.DAY_OF_YEAR)
        val year = now.get(Calendar.YEAR)
        val index = ((dayOfYear * 31 + year) and 0x7FFFFFFF) % pool.size
        return pool[index]
    }

    /** Matches iOS placeholderKey() -- "What can I help with?" is used across every time bucket. */
    val placeholderResId: Int = ai.oriveo.community.R.string.aurora_placeholder_what_can_i_help
}

/**
 * Cleans up the hero model pill's display name -- matches iOS `pillModelName`.
 *
 * Catalogs like OpenRouter often write a model's name as `Vendor: Model` or `Model (free)`; the
 * home screen pill has limited space, so keeping just the model name reduces truncation on small screens.
 */
internal fun homeHeroPillModelName(rawName: String): String {
    var name = rawName.trim()
    val vendorSeparator = name.indexOf(": ")
    if (vendorSeparator >= 0 && vendorSeparator + 2 < name.length) {
        name = name.substring(vendorSeparator + 2)
    }
    if (name.endsWith(" (free)", ignoreCase = true)) {
        name = name.dropLast(" (free)".length).trimEnd()
    }
    return name
}
