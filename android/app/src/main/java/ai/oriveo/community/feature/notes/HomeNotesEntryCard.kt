package ai.oriveo.community.feature.notes

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.sin
import ai.oriveo.community.R
import ai.oriveo.community.feature.home.AuroraTheme
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Pushpin on the top sheet: round radial-gradient head, exposed metal needle, soft drop shadow and a pierce hole.
 * No text, hidden from screen readers. Fixed colours, never follow the theme. All lengths are in dp, in the top
 * sheet's own 122x96 coordinates.
 */
/** Fixed (non-theme) palette of the home entry card. */
@Immutable
internal data class HomeEntryPalette(
    val ring: Color,
    val title: Color,
    val count: Color,
    val subtitle: Color,
) {
    companion object {
        val Light = HomeEntryPalette(
            ring = Color(0x1418181B),
            title = Color(0xFF18181B),
            count = Color(0xFF9A96A6),
            subtitle = Color(0xFF8A8594),
        )
        val Dark = HomeEntryPalette(
            ring = Color(0x1FFFFFFF),
            title = Color(0xFFF4F3F7),
            count = Color(0xFF858091),
            subtitle = Color(0xFF8E899A),
        )
    }
}

internal val HomeEntryCardShape = RoundedCornerShape(22.dp)

/** Card shell: 150dp tall, 22dp corners, vertical wash ending in [washEnd]; no outer stroke, the base sets it apart. */
internal fun Modifier.homeEntryCardSurface(isDark: Boolean, washEnd: Color): Modifier {
    val base = if (isDark) Color(0xFF1F1D24) else Color.White
    return this
        .height(150.dp)
        .clip(HomeEntryCardShape)
        .background(Brush.verticalGradient(0.38f to base, 1f to washEnd))
}

/** Title + mono count, centered on the line box (CJK titles sit higher than digits on a baseline). */
@Composable
internal fun HomeEntryTitleCount(
    title: String,
    count: Int,
    palette: HomeEntryPalette,
    modifier: Modifier = Modifier,
    showsZero: Boolean = false,
) {
    Row(
        modifier = modifier.heightIn(min = 21.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = title,
            style = TextStyle(fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp),
            color = palette.title,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (count > 0 || (showsZero && count == 0)) {
            Text(
                text = count.toString(),
                style = AuroraTheme.Typography.countMono.copy(fontSize = 13.sp, lineHeight = 18.sp),
                color = palette.count,
                maxLines = 1,
            )
        }
    }
}

internal object HomeNotesPushpin {
    const val HeadDiameter = 11f

    /** Distance from the head centre to the pierce point. */
    const val NeedleLength = 9f

    /** Lean towards the upper left, measured from vertical. */
    const val TiltDegrees = 24f

    /** Where the needle enters the sheet: horizontally centred, 10dp below the top edge. */
    const val PierceX = 61f
    const val PierceY = 10f

    const val NeedleWidth = 1.2f
    val NeedleColor = Color(0xFFA1A1AA) // capability-ui-lint: allow pushpin needle metal grey, not a capability colour

    /** Head gradient: light pink, pink, deep pink at [HeadStops]; centre at (0.35, 0.30) of the head box. */
    val HeadColors: List<Color> = listOf(
        Color(0xFFFBCFE8), // capability-ui-lint: allow pushpin head decoration pink, not a capability colour
        Color(0xFFEC4899), // capability-ui-lint: allow pushpin head decoration pink, not a capability colour
        Color(0xFF9D174D), // capability-ui-lint: allow pushpin head decoration pink, not a capability colour
    )
    val HeadStops: List<Float> = listOf(0f, 0.45f, 1f)
    const val HeadGradientCenterX = 0.35f
    const val HeadGradientCenterY = 0.30f
    const val HeadGradientRadiusScale = 0.75f

    /** White highlight circle, offset from the head centre. */
    const val HighlightDiameter = 3f
    const val HighlightOffsetX = -2f
    const val HighlightOffsetY = -2.2f

    /** Shadow: a black circle the size of the head, offset from its centre and blurred. */
    const val ShadowOffsetX = 2.2f
    const val ShadowOffsetY = 2.6f
    const val ShadowBlur = 1.6f

    const val HoleDiameter = 1.6f

    /** Head centre for a pierce point: the needle runs [NeedleLength] up and [TiltDegrees] to the left. */
    fun headCenter(pierce: Offset): Offset {
        val tilt = Math.toRadians(TiltDegrees.toDouble())
        return Offset(
            x = (pierce.x - NeedleLength * sin(tilt)).toFloat(),
            y = (pierce.y - NeedleLength * cos(tilt)).toFloat(),
        )
    }

    fun shadowAlpha(isDark: Boolean): Float = if (isDark) 0.45f else 0.22f

    fun highlightAlpha(isDark: Boolean): Float = if (isDark) 0.70f else 0.85f

    fun holeAlpha(isDark: Boolean): Float = if (isDark) 0.40f else 0.28f
}

/**
 * Covers the top sheet (122x96dp) and draws, bottom to top: shadow, pierce hole, needle, head, highlight.
 * Not clipped, so the head may rise above the sheet's top edge.
 */
@Composable
private fun Pushpin(isDark: Boolean, modifier: Modifier) {
    Canvas(modifier = modifier.size(width = 122.dp, height = 96.dp)) {
        val scale = density
        val pierceDp = Offset(HomeNotesPushpin.PierceX, HomeNotesPushpin.PierceY)
        val pierce = pierceDp * scale
        val head = HomeNotesPushpin.headCenter(pierceDp) * scale
        val headRadius = HomeNotesPushpin.HeadDiameter / 2f * scale
        // Blur simulated by a radial fade: solid up to (radius - blur), transparent at (radius + blur)
        val blur = HomeNotesPushpin.ShadowBlur * scale
        val shadowRadius = headRadius + blur
        val shadowCenter = head + Offset(HomeNotesPushpin.ShadowOffsetX, HomeNotesPushpin.ShadowOffsetY) * scale
        val shadow = Color.Black.copy(alpha = HomeNotesPushpin.shadowAlpha(isDark))
        drawCircle(
            brush = Brush.radialGradient(
                0f to shadow,
                (headRadius - blur) / shadowRadius to shadow,
                1f to Color.Transparent,
                center = shadowCenter,
                radius = shadowRadius,
            ),
            radius = shadowRadius,
            center = shadowCenter,
        )
        drawCircle(
            color = Color.Black.copy(alpha = HomeNotesPushpin.holeAlpha(isDark)),
            radius = HomeNotesPushpin.HoleDiameter / 2f * scale,
            center = pierce,
        )
        drawLine(
            color = HomeNotesPushpin.NeedleColor,
            start = pierce,
            end = head,
            strokeWidth = HomeNotesPushpin.NeedleWidth * scale,
            cap = StrokeCap.Round,
        )
        val diameter = HomeNotesPushpin.HeadDiameter * scale
        val headTopLeft = head - Offset(headRadius, headRadius)
        drawCircle(
            brush = Brush.radialGradient(
                *HomeNotesPushpin.HeadStops.zip(HomeNotesPushpin.HeadColors).toTypedArray(),
                center = headTopLeft + Offset(
                    diameter * HomeNotesPushpin.HeadGradientCenterX,
                    diameter * HomeNotesPushpin.HeadGradientCenterY,
                ),
                radius = diameter * HomeNotesPushpin.HeadGradientRadiusScale,
            ),
            radius = headRadius,
            center = head,
        )
        drawCircle(
            color = Color.White.copy(alpha = HomeNotesPushpin.highlightAlpha(isDark)),
            radius = HomeNotesPushpin.HighlightDiameter / 2f * scale,
            center = head + Offset(HomeNotesPushpin.HighlightOffsetX, HomeNotesPushpin.HighlightOffsetY) * scale,
        )
    }
}

/** Paper-stack colours; fixed, never follow the theme. */
private class NotesPaperColors(
    val back: Color,
    val backAlpha: Float,
    val middle: Color,
    val front: Color,
    val line: Color,
    val ink: Color,
)

private val NotesPaperLight = NotesPaperColors(
    back = Color(0xFFFBD3E5),
    backAlpha = 0.75f,
    middle = Color(0xFFFFE6F0),
    front = Color.White,
    line = Color(0xFFF2E7ED),
    ink = Color(0xFF3F3F46),
)

private val NotesPaperDark = NotesPaperColors(
    back = Color(0xFF562B44),
    backAlpha = 0.8f,
    middle = Color(0xFF3A2633),
    front = Color(0xFF2A252E),
    line = Color(0x17FFFFFF),
    ink = Color(0xFFEDEBF2),
)

/**
 * Home Notes entry card, half of the entry row next to the Skills card: title + count and a stacked-paper
 * illustration hidden from screen readers. With a titled latest note the subtitle reads "Recently edited" and
 * the title is written on the top sheet (the pushpin stays blank); otherwise there is no subtitle and the top sheet
 * carries the invitation copy. Screen readers keep the previewLine wording. The whole card opens the notes list.
 */
@Composable
fun HomeNotesEntryCard(
    noteCount: Int,
    latestTitle: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val isDark = OriveoTheme.isDark
    val palette = if (isDark) HomeEntryPalette.Dark else HomeEntryPalette.Light
    val paper = if (isDark) NotesPaperDark else NotesPaperLight
    val hasNotes = noteCount > 0
    val invitation = stringResource(R.string.notes_subtitle)
    val previewLine = homeNotesPreviewLine(
        count = noteCount,
        latestTitle = latestTitle,
        untitled = stringResource(R.string.notes_untitled),
        invitation = invitation,
    )
    val tapeTitle = homeNotesTapeTitle(count = noteCount, latestTitle = latestTitle)
    val title = stringResource(R.string.home_notes_title)
    val countText = if (hasNotes) pluralStringResource(R.plurals.notes_count, noteCount, noteCount) else null
    val accessibilityText = homeNotesAccessibilityText(title = title, countText = countText, previewLine = previewLine)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .homeEntryCardSurface(isDark, washEnd = if (isDark) Color(0xFF2B1B28) else Color(0xFFFFF1F6))
            .clickable(onClick = onClick)
            // The visible latest title is read too (TalkBack carries the same information as the card)
            .clearAndSetSemantics {
                contentDescription = accessibilityText
                role = Role.Button
            },
    ) {
        PaperSheet(paper.back, 116.dp, Modifier.paperAt(x = 44.dp, overhang = 32.dp, degrees = -11f).alpha(paper.backAlpha))
        PaperSheet(paper.middle, 118.dp, Modifier.paperAt(x = 38.dp, overhang = 27.dp, degrees = 6f))
        Box(modifier = Modifier.paperAt(x = 30.dp, overhang = 22.dp, degrees = -3f)) {
            PaperSheet(paper.front, 122.dp, Modifier)
            // Same as iOS: latest title (one line) or the invitation (up to two lines) on the sheet, ruled lines below
            Column(modifier = Modifier.width(122.dp).padding(start = 12.dp, top = 15.dp, end = 12.dp)) {
                Text(
                    text = tapeTitle ?: invitation,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = paper.ink,
                    maxLines = if (tapeTitle != null) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(bottom = 7.dp),
                )
                listOf(0.92f, 0.74f, 0.5f).forEachIndexed { index, fraction ->
                    Box(
                        modifier = Modifier
                            .padding(top = if (index == 0) 0.dp else 7.dp)
                            .fillMaxWidth(fraction)
                            .height(2.dp)
                            .clip(RoundedCornerShape(1.dp))
                            .background(paper.line),
                    )
                }
            }
            // Drawn last so it overlaps the sheet edge; the card clears its semantics, so screen readers skip it
            Pushpin(isDark = isDark, modifier = Modifier)
        }
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 15.dp)) {
            HomeEntryTitleCount(title = title, count = noteCount, palette = palette)
            if (tapeTitle != null) {
                Text(
                    text = stringResource(R.string.skills_home_notesRecent),
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    color = palette.subtitle,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp).heightIn(min = 16.dp),
                )
            }
        }
    }
}

/** Places a 96dp-tall sheet [x] from the left of the 150dp card, hanging [overhang] below its bottom edge. */
private fun Modifier.paperAt(x: Dp, overhang: Dp, degrees: Float): Modifier =
    this.offset(x = x, y = 150.dp - 96.dp + overhang).rotate(degrees)

@Composable
private fun PaperSheet(fill: Color, width: Dp, modifier: Modifier) {
    Box(
        modifier = modifier
            .size(width = width, height = 96.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(fill),
    )
}

/** With notes → the latest title (blank after trim shows "Untitled note", as iOS NoteText.displayTitle); empty → invitation. */
internal fun homeNotesPreviewLine(count: Int, latestTitle: String?, untitled: String, invitation: String): String {
    if (count <= 0) return invitation
    return latestTitle?.trim().orEmpty().ifEmpty { untitled }
}

/** The latest note title for the top sheet: only with notes and a non-blank title; otherwise null (invitation on the sheet). */
internal fun homeNotesTapeTitle(count: Int, latestTitle: String?): String? {
    if (count <= 0) return null
    return latestTitle?.trim()?.takeIf { it.isNotEmpty() }
}

internal fun homeNotesAccessibilityText(title: String, countText: String?, previewLine: String): String =
    if (countText == null) "$title. $previewLine" else "$title, $countText, $previewLine"
