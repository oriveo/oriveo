package ai.oriveo.community.ui.component

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** The three line glyphs of the bottom tab bar, shared with the iOS tab bar assets. */
enum class OriveoTabGlyph { Home, Providers, Settings }

/**
 * Bottom tab icons: a 24 grid, 1.8 stroke, round caps and joins. The paths are taken verbatim from the
 * iOS SVG assets, with every shorthand expanded into space-separated full numbers so PathParser cannot
 * misread the compact notation.
 *
 * - [template]: the unselected monochrome glyph, tinted by the caller through `Icon(tint = …)`.
 * - [selected]: the selected glyph with the tab gradient baked into the stroke, one set per dark and
 *   light theme; callers pass `tint = Color.Unspecified` to keep the colors. The gradient is the SVG
 *   `userSpaceOnUse` (2,2)→(22,22); VectorPainter brush coordinates are viewport coordinates, so the
 *   points are written directly on the 24 grid.
 *
 * Dark and light are chosen in code rather than through drawable-night: the app theme comes from a
 * preference (`LocalIsDarkTheme`) and does not necessarily match the system uiMode.
 */
internal object OriveoTabBarIcons {

    fun template(glyph: OriveoTabGlyph): ImageVector = when (glyph) {
        OriveoTabGlyph.Home -> homeTemplate
        OriveoTabGlyph.Providers -> providersTemplate
        OriveoTabGlyph.Settings -> settingsTemplate
    }

    fun selected(glyph: OriveoTabGlyph, isDark: Boolean): ImageVector = when (glyph) {
        OriveoTabGlyph.Home -> if (isDark) homeSelectedDark else homeSelectedLight
        OriveoTabGlyph.Providers -> if (isDark) providersSelectedDark else providersSelectedLight
        OriveoTabGlyph.Settings -> if (isDark) settingsSelectedDark else settingsSelectedLight
    }

    /** Gradient endpoints per tab; the start color doubles as the selected label color. */
    fun gradient(glyph: OriveoTabGlyph, isDark: Boolean): Pair<Color, Color> = when (glyph) {
        OriveoTabGlyph.Home ->
            if (isDark) Color(0xFFA78BFA) to Color(0xFF7DD3FC) else Color(0xFF8B5CF6) to Color(0xFF60A5FA)
        OriveoTabGlyph.Providers ->
            if (isDark) Color(0xFF2DD4BF) to Color(0xFF38BDF8) else Color(0xFF0D9488) to Color(0xFF0EA5E9)
        OriveoTabGlyph.Settings ->
            if (isDark) Color(0xFFFB923C) to Color(0xFFF472B6) else Color(0xFFEA580C) to Color(0xFFEC4899)
    }

    private val templateBrush = SolidColor(Color.Black)

    private fun gradientBrush(glyph: OriveoTabGlyph, isDark: Boolean): Brush {
        val (start, end) = gradient(glyph, isDark)
        return Brush.linearGradient(
            colors = listOf(start, end),
            start = Offset(2f, 2f),
            end = Offset(22f, 22f),
        )
    }

    // ── Home: speech bubble with three dots ──
    private const val HOME_BUBBLE =
        "M12 20.5 c4.7 0 8.5 -3.4 8.5 -7.75 S16.7 5 12 5 S3.5 8.4 3.5 12.75 " +
            "c0 1.6 0.5 3.1 1.4 4.35 L4 20.5 l3.6 -1.3 c1.3 0.8 2.8 1.3 4.4 1.3 Z"
    private val HOME_DOTS = listOf(
        circle(cx = 8.6f, cy = 12.75f, r = 0.6f),
        circle(cx = 12f, cy = 12.75f, r = 0.6f),
        circle(cx = 15.4f, cy = 12.75f, r = 0.6f),
    )

    // ── Providers: two four-pointed stars, one large and one small ──
    private val PROVIDERS_STARS = listOf(
        "M10 4 c0.4 3.9 2.6 6.1 6.5 6.5 c-3.9 0.4 -6.1 2.6 -6.5 6.5 " +
            "c-0.4 -3.9 -2.6 -6.1 -6.5 -6.5 C7.4 10.1 9.6 7.9 10 4 Z",
        "M18.5 13.5 c0.2 1.9 1.3 3 3.2 3.2 c-1.9 0.2 -3 1.3 -3.2 3.2 " +
            "c-0.2 -1.9 -1.3 -3 -3.2 -3.2 c1.9 -0.2 3 -1.3 3.2 -3.2 Z",
    )

    // ── Settings: three sliders ──
    private val SETTINGS_SLIDERS = listOf(
        "M4 7 h9", "M17 7 h3", circle(cx = 15f, cy = 7f, r = 2.2f),
        "M4 12 h3", "M11 12 h9", circle(cx = 9f, cy = 12f, r = 2.2f),
        "M4 17 h9", "M17 17 h3", circle(cx = 15f, cy = 17f, r = 2.2f),
    )

    private val homeTemplate by lazy { home("TabIconHome", templateBrush) }
    private val homeSelectedLight by lazy { home("TabIconHomeSelectedLight", gradientBrush(OriveoTabGlyph.Home, false)) }
    private val homeSelectedDark by lazy { home("TabIconHomeSelectedDark", gradientBrush(OriveoTabGlyph.Home, true)) }

    private val providersTemplate by lazy { strokes("TabIconProviders", PROVIDERS_STARS, templateBrush) }
    private val providersSelectedLight by lazy {
        strokes("TabIconProvidersSelectedLight", PROVIDERS_STARS, gradientBrush(OriveoTabGlyph.Providers, false))
    }
    private val providersSelectedDark by lazy {
        strokes("TabIconProvidersSelectedDark", PROVIDERS_STARS, gradientBrush(OriveoTabGlyph.Providers, true))
    }

    private val settingsTemplate by lazy { strokes("TabIconSettings", SETTINGS_SLIDERS, templateBrush) }
    private val settingsSelectedLight by lazy {
        strokes("TabIconSettingsSelectedLight", SETTINGS_SLIDERS, gradientBrush(OriveoTabGlyph.Settings, false))
    }
    private val settingsSelectedDark by lazy {
        strokes("TabIconSettingsSelectedDark", SETTINGS_SLIDERS, gradientBrush(OriveoTabGlyph.Settings, true))
    }

    /** The three dots are both filled and stroked in the SVG (inheriting the root 1.8 stroke), so the visible diameter is 1.2 + 1.8 = 3. */
    private fun home(name: String, brush: Brush): ImageVector =
        builder(name).apply {
            addStroke(HOME_BUBBLE, brush)
            HOME_DOTS.forEach { dot ->
                addPath(
                    pathData = addPathNodes(dot),
                    fill = brush,
                    stroke = brush,
                    strokeLineWidth = STROKE_WIDTH,
                    strokeLineCap = StrokeCap.Round,
                    strokeLineJoin = StrokeJoin.Round,
                )
            }
        }.build()

    private fun strokes(name: String, paths: List<String>, brush: Brush): ImageVector =
        builder(name).apply { paths.forEach { addStroke(it, brush) } }.build()

    private fun ImageVector.Builder.addStroke(path: String, brush: Brush) {
        addPath(
            pathData = addPathNodes(path),
            fill = null,
            stroke = brush,
            strokeLineWidth = STROKE_WIDTH,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }

    private fun builder(name: String) = ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    )

    /** Closed two-arc path equivalent to an SVG `<circle>`. */
    private fun circle(cx: Float, cy: Float, r: Float): String =
        "M${cx - r} $cy a$r $r 0 1 0 ${r * 2} 0 a$r $r 0 1 0 ${-r * 2} 0 Z"

    private const val STROKE_WIDTH = 1.8f
}
