package ai.oriveo.community.feature.onboarding

import androidx.compose.ui.graphics.Color

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.sin


enum class OnboardingAct(val index: Int, val stepName: String) {
    
    Brand(0, "welcome"),
    Models(1, "models"),
    Byok(2, "byok"),
    Start(3, "start"),
    ;

    companion object {
        val ordered: List<OnboardingAct> = listOf(Brand, Models, Byok, Start)

        fun fromIndex(index: Int): OnboardingAct? = ordered.firstOrNull { it.index == index }
    }
}


object OnboardingMath {
    fun clamp(value: Float, lower: Float, upper: Float): Float =
        minOf(maxOf(value, lower), upper)

    fun lerp(from: Float, to: Float, t: Float): Float = from + (to - from) * t

    
    fun tri(p: Float, center: Float, half: Float): Float {
        if (half <= 0f) return if (p == center) 1f else 0f
        return clamp(1f - abs(p - center) / half, 0f, 1f)
    }

    fun smoothstep(t: Float): Float {
        val x = clamp(t, 0f, 1f)
        return x * x * (3f - 2f * x)
    }
}


data class OnboardingRgb(val red: Float, val green: Float, val blue: Float) {
    fun toColor(): Color = Color(red = red, green = green, blue = blue)

    companion object {
        fun fromHex(hex: Long): OnboardingRgb = OnboardingRgb(
            red = ((hex shr 16) and 0xFF).toFloat() / 255f,
            green = ((hex shr 8) and 0xFF).toFloat() / 255f,
            blue = (hex and 0xFF).toFloat() / 255f,
        )

        fun lerp(from: OnboardingRgb, to: OnboardingRgb, t: Float): OnboardingRgb = OnboardingRgb(
            red = OnboardingMath.lerp(from.red, to.red, t),
            green = OnboardingMath.lerp(from.green, to.green, t),
            blue = OnboardingMath.lerp(from.blue, to.blue, t),
        )
    }
}


class OnboardingStageValues(progress: Float, width: Float) {

    val progress: Float

    val auroraTop: OnboardingRgb
    val auroraBottom: OnboardingRgb

    val ringsOpacity: Float
    val orbitersOpacity: Float
    val orbitersOffsetX: Float

    val nucleusOpacity: Float
    val nucleusOffsetX: Float
    val nucleusScale: Float

    val byokOpacity: Float
    val byokOffsetX: Float
    val byokScale: Float

    val freeBadgeOpacity: Float
    val freeBadgeOffsetX: Float
    val freeBadgeScale: Float

    
    val ctaMorph: Float
    val pillWidth: Float
    val dotsOpacity: Float
    val ctaLabelOpacity: Float
    val loginOpacity: Float
    val loginOffsetY: Float
    val legalOpacity: Float
    val skipOpacity: Float

    init {
        val pageCount = OnboardingAct.ordered.size.toFloat()
        val pc = OnboardingMath.clamp(progress, -0.35f, pageCount - 1f + 0.35f)
        this.progress = pc

        
        val index = OnboardingMath.clamp(floor(pc), 0f, pageCount - 2f).toInt()
        val fraction = OnboardingMath.clamp(pc - index.toFloat(), 0f, 1f)
        auroraTop = OnboardingRgb.lerp(AURORA_PALETTE[index].first, AURORA_PALETTE[index + 1].first, fraction)
        auroraBottom = OnboardingRgb.lerp(AURORA_PALETTE[index].second, AURORA_PALETTE[index + 1].second, fraction)

        
        val parallax = width * 0.25f

        ringsOpacity = OnboardingMath.clamp(
            0.35f +
                0.65f * maxOf(OnboardingMath.tri(pc, 0f, 1.2f), OnboardingMath.tri(pc, 1f, 1.2f)) -
                0.25f * OnboardingMath.tri(pc, 2f, 1f),
            0f,
            1f,
        )

        orbitersOpacity = OnboardingMath.tri(pc, 1f, 1.0f)
        
        orbitersOffsetX = (1f - pc) * width * 0.18f

        val nucleus = maxOf(OnboardingMath.tri(pc, 0f, 1f), OnboardingMath.tri(pc, 1f, 1f) * 0.92f)
        nucleusOpacity = nucleus
        nucleusOffsetX = -OnboardingMath.clamp(pc - 1f, 0f, 2f) * parallax +
            OnboardingMath.clamp(-pc, 0f, 1f) * parallax
        nucleusScale = 0.86f + 0.14f * nucleus

        val byok = OnboardingMath.tri(pc, 2f, 0.85f)
        byokOpacity = byok
        byokOffsetX = (2f - pc) * parallax
        byokScale = 0.9f + 0.1f * byok

        val free = OnboardingMath.tri(pc, 3f, 0.85f)
        freeBadgeOpacity = free
        freeBadgeOffsetX = (3f - pc) * parallax
        freeBadgeScale = 0.9f + 0.1f * free

        
        val raw = OnboardingMath.clamp((pc - 2.2f) / 0.8f, 0f, 1f)
        val morph = OnboardingMath.smoothstep(raw)
        ctaMorph = morph
        pillWidth = OnboardingMath.lerp(DOTS_BAR_WIDTH, maxOf(width - 72f, DOTS_BAR_WIDTH), morph)
        dotsOpacity = 1f - OnboardingMath.clamp(morph * 1.6f, 0f, 1f)
        ctaLabelOpacity = OnboardingMath.clamp((morph - 0.45f) / 0.55f, 0f, 1f)
        loginOpacity = OnboardingMath.clamp((morph - 0.55f) / 0.45f, 0f, 1f)
        loginOffsetY = (1f - morph) * 8f
        legalOpacity = OnboardingMath.clamp((morph - 0.6f) / 0.4f, 0f, 1f) * 0.9f
        skipOpacity = 1f - OnboardingMath.clamp((pc - 2.1f) / 0.6f, 0f, 1f)
    }

    
    fun copyOpacity(act: OnboardingAct): Float =
        OnboardingMath.tri(progress, act.index.toFloat(), 0.62f)

    
    val isSkipInteractive: Boolean get() = progress <= 2.6f

    
    val isCtaInteractive: Boolean get() = progress > 2.7f

    
    val areDotsInteractive: Boolean get() = ctaMorph <= 0.4f

    companion object {
        
        val AURORA_PALETTE: List<Pair<OnboardingRgb, OnboardingRgb>> = listOf(
            OnboardingRgb.fromHex(0x7C3AED) to OnboardingRgb.fromHex(0x2A1E5C),
            OnboardingRgb.fromHex(0x4F46E5) to OnboardingRgb.fromHex(0x0D9488),
            OnboardingRgb.fromHex(0x6D28D9) to OnboardingRgb.fromHex(0xB45309),
            OnboardingRgb.fromHex(0x9D7BFF) to OnboardingRgb.fromHex(0x7C3AED),
        )

        
        const val DOTS_BAR_WIDTH = 84f

        
        const val REFERENCE_WIDTH = 390f
    }
}


data class OnboardingOrbitRing(
    val radiusX: Float,
    val radiusY: Float,
    val tiltDegrees: Float,
    val strokeOpacity: Float,
    
    val periodSeconds: Float,
    val isReversed: Boolean,
)


data class OnboardingOrbiter(
    val id: String,
    val sizeDp: Float,
    val ringIndex: Int,
    
    val phase: Float,
)


data class OnboardingOrbitPoint(val x: Float, val y: Float, val depth: Float)

object OnboardingOrbitCatalog {
    
    val rings: List<OnboardingOrbitRing> = listOf(
        OnboardingOrbitRing(176f, 62f, -24f, 0.30f, 64f, isReversed = false),
        OnboardingOrbitRing(150f, 54f, 30f, 0.20f, 78f, isReversed = true),
        OnboardingOrbitRing(122f, 46f, 84f, 0.12f, 105f, isReversed = false),
    )

    
    val orbiters: List<OnboardingOrbiter> = listOf(
        OnboardingOrbiter("openai", 40f, 0, 0.00f),
        OnboardingOrbiter("gemini", 38f, 0, 0.26f),
        OnboardingOrbiter("deepseek", 44f, 0, 0.52f),
        OnboardingOrbiter("mistral", 34f, 0, 0.76f),
        OnboardingOrbiter("anthropic", 36f, 1, 0.05f),
        OnboardingOrbiter("qwen", 36f, 1, 0.30f),
        OnboardingOrbiter("grok", 32f, 1, 0.55f),
        OnboardingOrbiter("kimi", 28f, 1, 0.80f),
    )

    
    fun position(orbiter: OnboardingOrbiter, time: Float): OnboardingOrbitPoint {
        val ring = rings[orbiter.ringIndex.coerceIn(0, rings.lastIndex)]
        val direction = if (ring.isReversed) -1f else 1f
        val theta = (orbiter.phase + direction * time / ring.periodSeconds) * 2f * Math.PI.toFloat()
        val localX = ring.radiusX * cos(theta)
        val localY = ring.radiusY * sin(theta)
        val tilt = ring.tiltDegrees * Math.PI.toFloat() / 180f
        return OnboardingOrbitPoint(
            x = localX * cos(tilt) - localY * sin(tilt),
            y = localX * sin(tilt) + localY * cos(tilt),
            depth = sin(theta),
        )
    }

    
    fun decorativeSpinDegrees(time: Float): Float {
        val ring = rings[2]
        return ring.tiltDegrees + time / ring.periodSeconds * 360f
    }
}


object OnboardingMotionPolicy {
    
    fun isOrbitClockPaused(reduceMotion: Boolean, isStageActive: Boolean): Boolean =
        reduceMotion || !isStageActive

    
    fun revealsInstantly(reduceMotion: Boolean): Boolean = reduceMotion
}


object OnboardingCopyMarkup {
    data class Segment(val text: String, val isHighlighted: Boolean)

    fun parse(raw: String): List<Segment> {
        val segments = mutableListOf<Segment>()
        val buffer = StringBuilder()
        var insideHighlight = false

        for (character in raw) {
            when {
                character == '{' && !insideHighlight -> {
                    if (buffer.isNotEmpty()) {
                        segments.add(Segment(buffer.toString(), false))
                        buffer.clear()
                    }
                    insideHighlight = true
                }
                character == '}' && insideHighlight -> {
                    if (buffer.isNotEmpty()) {
                        segments.add(Segment(buffer.toString(), true))
                        buffer.clear()
                    }
                    insideHighlight = false
                }
                else -> buffer.append(character)
            }
        }

        if (buffer.isNotEmpty()) {
            
            segments.add(Segment(if (insideHighlight) "{$buffer" else buffer.toString(), false))
        }
        return segments
    }

    
    fun plainText(raw: String): String = parse(raw).joinToString("") { it.text }
}


object OnboardingLinkMarkup {
    data class Segment(val text: String, val url: String?)

    private val LINK = Regex("""\[([^\]]+)]\(([^)]+)\)""")

    fun parse(raw: String): List<Segment> {
        val segments = mutableListOf<Segment>()
        var cursor = 0
        for (match in LINK.findAll(raw)) {
            if (match.range.first > cursor) {
                segments.add(Segment(raw.substring(cursor, match.range.first), null))
            }
            segments.add(Segment(match.groupValues[1], match.groupValues[2]))
            cursor = match.range.last + 1
        }
        if (cursor < raw.length) {
            segments.add(Segment(raw.substring(cursor), null))
        }
        return segments
    }
}
