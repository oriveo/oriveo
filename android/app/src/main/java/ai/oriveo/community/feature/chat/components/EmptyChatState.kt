package ai.oriveo.community.feature.chat.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.rememberBrandPainter
import ai.oriveo.community.ui.theme.OriveoGradients
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.launch

/**
 * Empty state shown for a new conversation.
 *
 * Vertically centered: a brand logo (soft glow circle + gradient outline ring), a
 * random warm greeting (hero style), and a subtitle (caption style). The ambient
 * aurora backdrop is supplied by [ChatAuroraBackground] underneath this layer.
 *
 * For a skill conversation ([skillIcon] non-null), the center logo is swapped for the
 * skill's icon (reusing the same glow circle and outline ring container), and the
 * subtitle becomes that skill's one-line description ([skillDescription], clamped to
 * two lines); the random greeting headline stays unchanged.
 */
@Composable
internal fun EmptyChatState(
    modifier: Modifier = Modifier,
    skillIcon: String? = null,
    skillDescription: String? = null,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    // Pick one greeting at random on entering the empty state; fixed for the session so it doesn't jitter on recompose.
    val greetingRes = remember { GREETING_RES.random() }

    // Entrance: cluster scales 0.86 -> 1 with a 0 -> 1 fade-in.
    val appearAlpha = remember { Animatable(0f) }
    val appearScale = remember { Animatable(0.86f) }
    LaunchedEffect(Unit) {
        launch { appearAlpha.animateTo(1f, tween(380)) }
        launch { appearScale.animateTo(1f, spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow)) }
    }

    // The glow circle settles from 0.92 to 1.06 once on entrance, then stays put.
    // It used to breathe permanently between 0.92 and 1.14, which redrew the empty chat
    // screen every frame indefinitely -- see the profiling notes in [ChatAuroraBackground].
    val glowScale = remember { Animatable(if (reduceMotion) 1.06f else 0.92f) }
    LaunchedEffect(reduceMotion) {
        if (!reduceMotion) glowScale.animateTo(1.06f, tween(durationMillis = 900, easing = EaseInOut))
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center, // centers content shorter than the viewport; scrolls once it grows
    ) {
        // Brand logo cluster: glow circle + 72dp logo + gradient outline ring
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.graphicsLayer {
                scaleX = appearScale.value
                scaleY = appearScale.value
                alpha = appearAlpha.value
            },
        ) {
            if (skillIcon != null) {
                // Skill conversation: flat presentation -- just the skill icon itself,
                // with no glow circle, white background, or outline ring; the icon is
                // shown as-is and the ambient backdrop comes from the aurora layer below.
                Text(text = skillIcon, fontSize = 60.sp)
            } else {
                // Glow circle: simulated with a radialGradient plus a blur-like falloff, since Android doesn't rely on Modifier.blur here
                Box(
                    modifier = Modifier
                        .size(130.dp)
                        .graphicsLayer {
                            val g = glowScale.value
                            scaleX = g
                            scaleY = g
                            alpha = 0.85f
                        }
                        .background(
                            brush = Brush.radialGradient(
                                colors = listOf(colors.primaryGlow, colors.primaryGlow.copy(alpha = 0f)),
                            ),
                            shape = CircleShape,
                        ),
                )
                // Circular 72dp logo
                Image(
                    painter = rememberBrandPainter(R.drawable.ic_oriveo_logo, 72.dp),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(72.dp)
                        .clip(CircleShape),
                )
                // Gradient outline ring, 1.5dp (74dp = logo size + 2dp of ring)
                Box(
                    modifier = Modifier
                        .size(74.dp)
                        .border(width = 1.5.dp, brush = OriveoGradients.primary, shape = CircleShape),
                )
            }
        }

        Spacer(modifier = Modifier.height(OriveoTheme.spacing.xl))

        // Random greeting (hero style / textPrimary)
        Text(
            text = stringResource(greetingRes),
            style = OriveoTheme.typography.hero,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.graphicsLayer { alpha = appearAlpha.value },
        )

        Spacer(modifier = Modifier.height(OriveoTheme.spacing.sm))

        // Subtitle (caption style / textSecondary) -- skill conversations show the skill's description, otherwise generic guidance
        Text(
            text = skillDescription?.takeIf { it.isNotBlank() }
                ?: stringResource(R.string.empty_chat_ask_anything),
            style = OriveoTheme.typography.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .padding(horizontal = OriveoTheme.spacing.xl)
                .graphicsLayer { alpha = appearAlpha.value },
        )
    }
}

/** Candidate warm greetings shown on the empty state. */
private val GREETING_RES = listOf(
    R.string.empty_greeting_explore,
    R.string.empty_greeting_begin,
    R.string.empty_greeting_mind,
    R.string.empty_greeting_together,
)
