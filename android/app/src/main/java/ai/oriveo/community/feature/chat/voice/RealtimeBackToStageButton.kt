package ai.oriveo.community.feature.chat.voice

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R

internal const val RealtimeBackToStageOrbTag = "realtime_back_to_stage_orb"

internal val RealtimeBackToStageOrbSize: Dp = 36.dp

/**
 * The "back to voice stage" orb of both pages (E-528): the stage orb at rest, drawn at its own size and scaled down
 * to [RealtimeBackToStageOrbSize] so its glow and blur keep their proportions. Visual only: the slot that holds it
 * handles the tap. Read as "back to voice" while [announced].
 */
@Composable
internal fun RealtimeBackToStageButton(modifier: Modifier = Modifier, announced: Boolean = true) {
    val description = stringResource(R.string.voice_realtime_back_to_stage)
    Box(
        modifier = modifier
            .size(RealtimeBackToStageOrbSize)
            .testTag(RealtimeBackToStageOrbTag)
            .then(if (announced) Modifier.semantics { contentDescription = description } else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        val scale = RealtimeBackToStageOrbSize / VoiceAuroraOrbSize
        VoiceAuroraOrb(
            mode = VoiceOrbMode.Idle,
            level = null,
            nudges = 0,
            modifier = Modifier
                .requiredSize(VoiceAuroraOrbSize)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                },
        )
    }
}
