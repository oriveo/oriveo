package ai.oriveo.community.feature.chat.voice

import androidx.annotation.VisibleForTesting
import ai.oriveo.community.BuildConfig

/**
 * E-690 probe: the last non-blank model name a switch notice started for ([VoiceSwitchingTo.begin]). The status line
 * shows the notice only briefly, so E2E reads this latch instead of racing the display window. Written only in debug
 * builds; a release build never records anything.
 */
@VisibleForTesting
internal object VoiceSwitchNoticeLatch {
    @Volatile
    var last: String? = null
        private set

    /** A switch notice for [model] started; blank names are ignored and an unchanged name is not rewritten. */
    fun record(model: String?) {
        if (!BuildConfig.DEBUG || model.isNullOrBlank() || model == last) return
        last = model
    }

    /** Forgets the latched name (the E2E clears it before each pick). */
    fun clear() {
        last = null
    }
}
