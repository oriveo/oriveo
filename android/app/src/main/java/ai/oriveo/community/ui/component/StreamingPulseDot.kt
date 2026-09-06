package ai.oriveo.community.ui.component

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.theme.OriveoTheme

@Composable
fun StreamingPulseDot(
    modifier: Modifier = Modifier,
    color: Color = OriveoTheme.colors.primary,
    size: Dp = 6.dp,
) {
    val context = LocalContext.current
    val reduceMotion = remember(context) { isReduceMotionEnabled(context) }

    val opacity = if (reduceMotion) {
        1f
    } else {
        val transition = rememberInfiniteTransition(label = "streaming-pulse")
        transition.animateFloat(
            initialValue = 0.45f,
            targetValue = 1.0f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1600, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "streaming-pulse-opacity",
        ).value
    }

    val a11y = stringResource(R.string.streaming_pulse_a11y)
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(color.copy(alpha = opacity))
            .semantics { contentDescription = a11y },
    )
}

internal fun isReduceMotionEnabled(context: Context): Boolean {
    cachedReduceMotion?.let { return it }
    return try {
        val appContext = context.applicationContext
        val enabled = Settings.Global.getFloat(
            appContext.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
        observeReduceMotionChanges(appContext)
        cachedReduceMotion = enabled
        enabled
    } catch (_: Exception) {
        false
    }
}

@Volatile private var cachedReduceMotion: Boolean? = null

private val reduceMotionObserverLock = Any()
private var reduceMotionObserverRegistered = false

private fun observeReduceMotionChanges(appContext: Context) {
    synchronized(reduceMotionObserverLock) {
        if (reduceMotionObserverRegistered) return
        val registered = runCatching {
            appContext.contentResolver.registerContentObserver(
                Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
                false,
                object : ContentObserver(Handler(Looper.getMainLooper())) {
                    override fun onChange(selfChange: Boolean) {
                        cachedReduceMotion = null
                    }
                },
            )
        }.isSuccess
        reduceMotionObserverRegistered = registered
    }
}
