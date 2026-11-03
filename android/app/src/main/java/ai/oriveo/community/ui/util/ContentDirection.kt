package ai.oriveo.community.ui.util

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.LayoutDirection

/**
 * User-authored content (bubbles, markdown, composer input, skill name / when-to-use) is laid out by
 * the direction of its own first strong character, so English text under an RTL locale keeps its
 * trailing punctuation at the end of the line. App copy keeps the locale direction.
 */
val userContentTextStyle: TextStyle = TextStyle(textDirection = TextDirection.Content)

private const val LEFT_TO_RIGHT_ISOLATE = '⁦'
private const val POP_DIRECTIONAL_ISOLATE = '⁩'

/** Wraps text in LRI...PDI so it stays LTR when embedded inside an RTL sentence. */
fun isolateLtr(text: String): String =
    "$LEFT_TO_RIGHT_ISOLATE$text$POP_DIRECTIONAL_ISOLATE"

/** Wraps a slash fragment in LRI...PDI so it stays LTR when embedded inside an RTL sentence. */
fun isolateSlashFragment(fragment: String): String = isolateLtr(fragment)

/**
 * Layout direction for a row that hosts user content (list bullet + text, step number + text):
 * follows the first strong directional character of [text]; with no strong character (digits,
 * punctuation, empty) the row keeps [fallback].
 */
fun contentLayoutDirection(text: String, fallback: LayoutDirection): LayoutDirection {
    var i = 0
    while (i < text.length) {
        val cp = text.codePointAt(i)
        when (Character.getDirectionality(cp)) {
            Character.DIRECTIONALITY_LEFT_TO_RIGHT,
            Character.DIRECTIONALITY_LEFT_TO_RIGHT_EMBEDDING,
            Character.DIRECTIONALITY_LEFT_TO_RIGHT_OVERRIDE,
            Character.DIRECTIONALITY_LEFT_TO_RIGHT_ISOLATE -> return LayoutDirection.Ltr
            Character.DIRECTIONALITY_RIGHT_TO_LEFT,
            Character.DIRECTIONALITY_RIGHT_TO_LEFT_ARABIC,
            Character.DIRECTIONALITY_RIGHT_TO_LEFT_EMBEDDING,
            Character.DIRECTIONALITY_RIGHT_TO_LEFT_OVERRIDE,
            Character.DIRECTIONALITY_RIGHT_TO_LEFT_ISOLATE -> return LayoutDirection.Rtl
        }
        i += Character.charCount(cp)
    }
    return fallback
}
