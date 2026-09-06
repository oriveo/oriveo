package ai.oriveo.community.feature.chat.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.util.localizedDescription
import ai.oriveo.community.core.util.localizedName
import ai.oriveo.community.core.util.localizedStarterMessages
import ai.oriveo.community.ui.theme.OriveoRadius
import ai.oriveo.community.ui.theme.OriveoSurfaceStyle
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.oriveoSurface
import kotlinx.coroutines.launch

@Composable
internal fun SkillStarterView(
    skill: Skill,
    onStarterClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OriveoTheme.colors
    val isDark = OriveoTheme.isDark
    val accentColor = try {
        Color(android.graphics.Color.parseColor(skill.color))
    } catch (_: Exception) {
        colors.primary
    }
    val starters = skill.localizedStarterMessages()

    val appearAlpha = remember { Animatable(0f) }
    val appearScale = remember { Animatable(0.86f) }
    val starterAnimatables = remember(starters.size) {
        List(starters.size) { Animatable(0f) }
    }

    LaunchedEffect(Unit) {
        launch { appearAlpha.animateTo(1f, tween(380)) }
        launch {
            appearScale.animateTo(1f, spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow))
        }
        starterAnimatables.forEachIndexed { index, animatable ->
            launch {
                kotlinx.coroutines.delay(120L + index * 60L)
                animatable.animateTo(
                    1f,
                    spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMediumLow),
                )
            }
        }
    }

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(32.dp))

        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.graphicsLayer {
                scaleX = appearScale.value
                scaleY = appearScale.value
                alpha = appearAlpha.value
            },
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(64.dp)
                    .background(accentColor.copy(alpha = 0.12f), CircleShape),
            ) {
                Text(text = skill.icon, fontSize = 36.sp)
            }
        }

        Spacer(Modifier.height(OriveoTheme.spacing.lg))

        // Skill name
        Text(
            text = skill.localizedName(),
            style = OriveoTheme.typography.hero,
            color = colors.textPrimary,
            modifier = Modifier.alpha(appearAlpha.value),
        )

        // Skill description
        if (skill.description.isNotBlank()) {
            Spacer(Modifier.height(OriveoTheme.spacing.sm))
            Text(
                text = skill.localizedDescription(),
                style = OriveoTheme.typography.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.alpha(appearAlpha.value),
            )
        }

        Spacer(Modifier.height(OriveoTheme.layout.sectionGap))

        // Starter messages
        Column(
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 680.dp),
        ) {
            starters.forEachIndexed { index, message ->
                val progress = if (index < starterAnimatables.size) starterAnimatables[index].value else 1f
                Surface(
                    onClick = { onStarterClick(message) },
                    shape = RoundedCornerShape(OriveoRadius.lg),
                    color = Color.Transparent,
                    modifier = Modifier
                        .fillMaxWidth()
                        .graphicsLayer {
                            alpha = progress
                            translationY = (1f - progress) * 14f * density
                        }
                        .oriveoSurface(
                            colors = colors,
                            isDark = isDark,
                            fill = colors.surfaceElevated,
                            borderColor = colors.border,
                            radius = OriveoRadius.lg,
                            shadowStyle = OriveoSurfaceStyle.Soft,
                        ),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
                    ) {
                        Text(
                            text = message,
                            style = OriveoTheme.typography.body.copy(fontSize = 15.sp),
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(OriveoTheme.spacing.md))
                        Icon(
                            imageVector = Icons.Filled.ArrowUpward,
                            contentDescription = null,
                            tint = colors.textTertiary,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(OriveoTheme.spacing.xl))
    }
}
