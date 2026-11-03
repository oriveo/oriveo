package ai.oriveo.community.feature.chat.composer

/**
 * An open `/` or `@` skill trigger in the composer text.
 *
 * [start] is the UTF-16 offset of the trigger symbol; [query] runs from just after it up to the caret.
 */
data class SkillTrigger(
    val symbol: Char,
    val start: Int,
    val query: String,
) {
    /** Offset just past the query (the caret when the trigger was detected). */
    val end: Int get() = start + 1 + query.length

    /** `via` of skill_manual_attached for a skill picked from this trigger. */
    val via: String get() = if (symbol == SkillComposerTrigger.AT) SkillComposerTrigger.VIA_AT else SkillComposerTrigger.VIA_SLASH
}

/**
 * Composer trigger rules (P4 contract 18): `/` or `@` opens the skill picker only at the start of the
 * text or right after a whitespace character; the query is the text between the symbol and the caret and any
 * whitespace in it closes the picker. Other positions (URLs, paths, e-mail addresses) never trigger.
 */
object SkillComposerTrigger {
    const val SLASH: Char = '/'
    const val AT: Char = '@'
    const val VIA_SLASH: String = "slash"
    const val VIA_AT: String = "at"
    const val VIA_BUTTON: String = "button"

    /**
     * Trigger ending at [caret] in [text]; null when there is none. A non-collapsed selection
     * ([selectionStart] != [caret]) never triggers.
     */
    fun detect(text: String, caret: Int, selectionStart: Int = caret): SkillTrigger? {
        if (selectionStart != caret || caret < 0 || caret > text.length) return null
        var index = caret - 1
        while (index >= 0) {
            val char = text[index]
            if (char.isWhitespace()) return null
            if (char == SLASH || char == AT) {
                val atBoundary = index == 0 || text[index - 1].isWhitespace()
                return if (atBoundary) SkillTrigger(char, index, text.substring(index + 1, caret)) else null
            }
            index--
        }
        return null
    }

    /** [text] with the trigger symbol and its query removed; unchanged when [trigger] no longer matches it. */
    fun remove(text: String, trigger: SkillTrigger): String {
        if (trigger.end > text.length || text.getOrNull(trigger.start) != trigger.symbol) return text
        if (text.substring(trigger.start + 1, trigger.end) != trigger.query) return text
        return text.removeRange(trigger.start, trigger.end)
    }
}
