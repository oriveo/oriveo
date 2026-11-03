package ai.oriveo.community.feature.chat.voice

import androidx.annotation.DrawableRes
import ai.oriveo.community.R

/**
 * Material Symbols Rounded vector icons for the voice stage and dictation, one per design weight.
 * Filled white; callers tint them. None mirror under RTL.
 */
object VoiceGlyphs {
    /** Stage close button. */
    @DrawableRes val closeStage: Int = R.drawable.ic_voice_close_w700

    /** Dictation close (✕). */
    @DrawableRes val closeDictation: Int = R.drawable.ic_voice_close_w600

    @DrawableRes val mic: Int = R.drawable.ic_voice_mic_w500

    @DrawableRes val micOff: Int = R.drawable.ic_voice_mic_off_w500

    @DrawableRes val graphicEq: Int = R.drawable.ic_voice_graphic_eq_w600

    @DrawableRes val arrowUpward: Int = R.drawable.ic_voice_arrow_upward_w700

    /** Globe (language). */
    @DrawableRes val language: Int = R.drawable.ic_voice_language_w600

    @DrawableRes val keyboard: Int = R.drawable.ic_voice_keyboard_w500

    @DrawableRes val check: Int = R.drawable.ic_voice_check_w600

    /** All icons; tests check them one to one against the ic_voice_* resources. */
    val all: List<Int> = listOf(
        closeStage, closeDictation, mic, micOff, graphicEq, arrowUpward, language, keyboard, check,
    )
}
