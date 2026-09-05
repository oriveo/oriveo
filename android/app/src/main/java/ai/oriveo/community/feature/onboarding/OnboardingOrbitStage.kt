package ai.oriveo.community.feature.onboarding

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind

import ai.oriveo.community.ui.component.providerLogoRes
import ai.oriveo.community.ui.component.rememberBrandPainter


object OnboardingPalette {
    val ink = Color(0xFFF3F1FF)
    val muted = Color(0xFFA9A3C2)
    val faint = Color(0xFF6E6890)
    val purple = Color(0xFF9D7BFF)
    val purpleBright = Color(0xFFB794FF)
    val line = Color(0xFF9D7BFF).copy(alpha = 0.14f)
    val hairline = Color.White.copy(alpha = 0.08f)

    
    val highlightGradient = Brush.linearGradient(
        colors = listOf(Color(0xFFEDE6FF), Color(0xFF9D7BFF), Color(0xFFEDE6FF)),
    )

    /** Gold gradient used by the BYOK key highlight. */
    val keyGradient = Brush.linearGradient(
        colors = listOf(Color(0xFFFCD34D), Color(0xFFF59E0B)),
    )

    val shieldFill = Brush.linearGradient(
        colors = listOf(Color(0xFF221D40), Color(0xFF0F0C1F)),
    )

    
    fun ctaGradient(alpha: Float): Brush = Brush.linearGradient(
        colors = listOf(
            Color(0xFF8347F5).copy(alpha = alpha),
            Color(0xFF6B3BC7).copy(alpha = alpha),
        ),
    )
}


private val NUCLEUS_SIZE = 68.dp
private val NUCLEUS_CORNER_RADIUS = 16.dp


private fun orbiterLogoRes(id: String): Int = when (id) {
    "openai" -> providerLogoRes(ProviderKind.OpenAI, darkAppearance = true)
    "gemini" -> providerLogoRes(ProviderKind.Gemini, darkAppearance = true)
    "deepseek" -> providerLogoRes(ProviderKind.DeepSeek, darkAppearance = true)
    "mistral" -> providerLogoRes(ProviderKind.Mistral, darkAppearance = true)
    "anthropic" -> providerLogoRes(ProviderKind.Anthropic, darkAppearance = true)
    "qwen" -> providerLogoRes(ProviderKind.Qwen, darkAppearance = true)
    "grok" -> providerLogoRes(ProviderKind.Grok, darkAppearance = true)
    else -> providerLogoRes(ProviderKind.Moonshot, darkAppearance = true)
}


@Composable
fun OnboardingOrbitStage(
    values: OnboardingStageValues,
    stageScale: Float,
    ringsRevealed: Boolean,
    nucleusRevealed: Boolean,
    isAnimating: Boolean,
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val clockPaused = OnboardingMotionPolicy.isOrbitClockPaused(reduceMotion, isAnimating)

    
    
    val time by produceState(0f, clockPaused) {
        if (clockPaused) {
            value = 0f
            return@produceState
        }
        val start = withFrameNanos { it }
        while (true) {
            withFrameNanos { now -> value = (now - start) / 1_000_000_000f }
        }
    }

    Box(
        modifier = modifier.graphicsLayer {
            scaleX = stageScale
            scaleY = stageScale
        },
        contentAlignment = Alignment.Center,
    ) {
        
        OrbitRings(
            time = time,
            alpha = values.ringsOpacity * (if (ringsRevealed) 1f else 0f),
            modifier = Modifier.zIndex(-2f),
        )

        
        OnboardingOrbitCatalog.orbiters.forEach { orbiter ->
            val point = OnboardingOrbitCatalog.position(orbiter, time)
            OrbiterLogo(
                orbiter = orbiter,
                point = point,
                groupAlpha = values.orbitersOpacity,
                groupOffsetX = values.orbitersOffsetX,
                modifier = Modifier.zIndex(point.depth),
            )
        }

        
        Nucleus(values = values, revealed = nucleusRevealed, modifier = Modifier.zIndex(0f))

        
        ByokPiece(values = values, reduceMotion = reduceMotion, modifier = Modifier.zIndex(2f))
    }
}


@Composable
private fun OrbitRings(time: Float, alpha: Float, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(420.dp)) {
        val center = Offset(size.width / 2f, size.height / 2f)
        val density = size.width / 420f

        OnboardingOrbitCatalog.rings.forEachIndexed { index, ring ->
            
            val tilt = if (index == 2) OnboardingOrbitCatalog.decorativeSpinDegrees(time) else ring.tiltDegrees
            rotate(degrees = tilt, pivot = center) {
                drawOval(
                    color = OnboardingPalette.purpleBright.copy(alpha = ring.strokeOpacity * alpha),
                    topLeft = Offset(
                        center.x - ring.radiusX * density,
                        center.y - ring.radiusY * density,
                    ),
                    size = Size(ring.radiusX * 2f * density, ring.radiusY * 2f * density),
                    style = Stroke(width = 1f * density),
                )
            }
        }
    }
}


@Composable
private fun OrbiterLogo(
    orbiter: OnboardingOrbiter,
    point: OnboardingOrbitPoint,
    groupAlpha: Float,
    groupOffsetX: Float,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    
    val depthScale = 1f + 0.08f * point.depth
    val depthAlpha = 0.82f + 0.18f * (point.depth + 1f) / 2f
    val sizeDp = orbiter.sizeDp.dp

    Image(
        painter = rememberBrandPainter(orbiterLogoRes(orbiter.id), sizeDp),
        contentDescription = null,
        modifier = modifier
            .size(sizeDp)
            .graphicsLayer {
                translationX = with(density) { (point.x + groupOffsetX).dp.toPx() }
                translationY = with(density) { point.y.dp.toPx() }
                scaleX = depthScale
                scaleY = depthScale
                alpha = groupAlpha * depthAlpha
                shadowElevation = with(density) { 6.dp.toPx() }
                shape = CircleShape
                clip = false
            },
    )
}


@Composable
private fun Nucleus(values: OnboardingStageValues, revealed: Boolean, modifier: Modifier = Modifier) {
    val density = LocalDensity.current
    val shape = RoundedCornerShape(NUCLEUS_CORNER_RADIUS)
    val scale = values.nucleusScale * (if (revealed) 1f else 0.82f)

    Image(
        painter = rememberBrandPainter(R.drawable.ic_oriveo_logo, NUCLEUS_SIZE),
        contentDescription = null,
        modifier = modifier
            .graphicsLayer {
                translationX = with(density) { values.nucleusOffsetX.dp.toPx() }
                scaleX = scale
                scaleY = scale
                alpha = values.nucleusOpacity * (if (revealed) 1f else 0f)
            }
            .size(NUCLEUS_SIZE)
            .shadow(
                elevation = 30.dp,
                shape = shape,
                ambientColor = OnboardingPalette.purple,
                spotColor = Color.Black,
            )
            .clip(shape)
            .border(1.dp, OnboardingPalette.purpleBright.copy(alpha = 0.28f), shape),
    )
}


@Composable
private fun ByokPiece(values: OnboardingStageValues, reduceMotion: Boolean, modifier: Modifier = Modifier) {
    val density = LocalDensity.current

    
    
    
    
    val transition = rememberInfiniteTransition(label = "costCard")
    val animatedTarget = if (reduceMotion) 0f else 1f
    val lift by transition.animateFloat(
        initialValue = 0f,
        targetValue = animatedTarget,
        animationSpec = infiniteRepeatable(tween(6000, easing = LinearEasing), RepeatMode.Reverse),
        label = "lift",
    )
    val drift by transition.animateFloat(
        initialValue = 0f,
        targetValue = animatedTarget,
        animationSpec = infiniteRepeatable(tween(7400, easing = LinearEasing), RepeatMode.Reverse),
        label = "drift",
    )

    Box(
        modifier = modifier.graphicsLayer {
            translationX = with(density) { values.byokOffsetX.dp.toPx() }
            scaleX = values.byokScale
            scaleY = values.byokScale
            alpha = values.byokOpacity
        },
        contentAlignment = Alignment.Center,
    ) {
        ShieldWithKey(
            modifier = Modifier
                .size(width = 128.dp, height = 142.dp)
                .graphicsLayer { translationX = with(density) { (-30).dp.toPx() } },
        )

        OnboardingCostCard(
            lift = lift,
            modifier = Modifier.graphicsLayer {
                translationX = with(density) { (46f + (drift * 12f - 5f)).dp.toPx() }
                translationY = with(density) { (115f + (5f - lift * 22f)).dp.toPx() }
                
                val cardScale = 0.99f + 0.04f * lift
                scaleX = cardScale
                scaleY = cardScale
                
                rotationX = 1.6f - 4.2f * lift
                cameraDistance = 12f * density.density
            },
        )
    }
}


@Composable
private fun ShieldWithKey(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val sx = size.width / 128f
        val sy = size.height / 142f
        fun px(x: Float, y: Float) = Offset(x * sx, y * sy)

        val shield = Path().apply {
            moveTo(px(64f, 6f).x, px(64f, 6f).y)
            lineTo(px(116f, 26f).x, px(116f, 26f).y)
            lineTo(px(116f, 64f).x, px(116f, 64f).y)
            cubicTo(
                px(116f, 98f).x, px(116f, 98f).y,
                px(94f, 124f).x, px(94f, 124f).y,
                px(64f, 136f).x, px(64f, 136f).y,
            )
            cubicTo(
                px(34f, 124f).x, px(34f, 124f).y,
                px(12f, 98f).x, px(12f, 98f).y,
                px(12f, 64f).x, px(12f, 64f).y,
            )
            lineTo(px(12f, 26f).x, px(12f, 26f).y)
            close()
        }
        drawPath(shield, brush = OnboardingPalette.shieldFill)
        drawPath(
            shield,
            color = OnboardingPalette.purpleBright.copy(alpha = 0.4f),
            style = Stroke(width = 1.6f * sx),
        )

        
        val edge = Path().apply {
            moveTo(px(64f, 6f).x, px(64f, 6f).y)
            lineTo(px(116f, 26f).x, px(116f, 26f).y)
            lineTo(px(116f, 64f).x, px(116f, 64f).y)
            cubicTo(
                px(116f, 98f).x, px(116f, 98f).y,
                px(94f, 124f).x, px(94f, 124f).y,
                px(64f, 136f).x, px(64f, 136f).y,
            )
        }
        drawPath(edge, color = Color(0xFFFCD34D).copy(alpha = 0.35f), style = Stroke(width = 1.6f * sx))

        
        val keyStroke = Stroke(width = 5.5f * sx, cap = StrokeCap.Round)
        drawCircle(
            brush = OnboardingPalette.keyGradient,
            radius = 13f * sx,
            center = px(57f, 62f),
            style = keyStroke,
        )
        val shaft = Path().apply {
            moveTo(px(67f, 71f).x, px(67f, 71f).y)
            lineTo(px(84f, 88f).x, px(84f, 88f).y)
            moveTo(px(84f, 88f).x, px(84f, 88f).y)
            lineTo(px(84f, 80f).x, px(84f, 80f).y)
            moveTo(px(84f, 88f).x, px(84f, 88f).y)
            lineTo(px(76f, 88f).x, px(76f, 88f).y)
        }
        drawPath(shaft, brush = OnboardingPalette.keyGradient, style = keyStroke)
    }
}


@Composable
private fun OnboardingCostCard(lift: Float, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(14.dp)

    Column(
        modifier = modifier
            .width(172.dp)
            
            
            .shadow(
                elevation = (20f + 20f * lift).dp,
                shape = shape,
                ambientColor = OnboardingPalette.purple,
                spotColor = Color.Black,
            )
            .clip(shape)
            .background(Color(0xFF141124).copy(alpha = 0.88f))
            .border(1.dp, OnboardingPalette.line, shape)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        CostRow("GPT-5.2", "$0.0042", isSummary = false)
        CostRow("Claude", "$0.0117", isSummary = false)

        Spacer(Modifier.height(3.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(OnboardingPalette.hairline))
        Spacer(Modifier.height(4.dp))

        CostRow(
            title = androidx.compose.ui.res.stringResource(R.string.onboarding_cost_card_week),
            value = "$1.83",
            isSummary = true,
        )
    }
}

@Composable
private fun CostRow(title: String, value: String, isSummary: Boolean) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.5.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            fontSize = 11.5.sp,
            color = if (isSummary) Color(0xFFFCD34D) else OnboardingPalette.muted,
            maxLines = 1,
        )
        Text(
            text = value,
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = if (isSummary) Color(0xFFFCD34D) else OnboardingPalette.ink,
        )
    }
}

