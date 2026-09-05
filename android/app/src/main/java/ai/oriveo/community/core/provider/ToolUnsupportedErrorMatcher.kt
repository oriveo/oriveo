package ai.oriveo.community.core.provider

/** Exact classifier. It never receives credentials and never logs the response body. */
internal object ToolUnsupportedErrorMatcher {
    private val excludedStatuses = setOf(401, 402, 403, 407, 408, 429)
    internal val subjectPatterns = listOf(
        "\\btools?\\b",
        "\\btool_calls?\\b",
        "\\btool_choice\\b",
        "\\bfunctions?\\b",
        "\\bfunction[_ ]call(ing)?\\b",
    )
    internal val verdictPatterns = listOf(
        "\\bunsupported\\b",
        "\\bnot (currently )?support(ed)?\\b",
        "\\bdoes(n't| not) support\\b",
        "\\binvalid\\b",
        "\\bunknown\\b",
        "\\bunrecognized\\b",
        "\\bunexpected\\b",
        "\\bextra (inputs?|fields?|parameters?)\\b",
        "\\bnot (allowed|permitted|available)\\b",
        "\\bnot a valid\\b",
    )
    private val subjects = subjectPatterns.map { Regex(it, RegexOption.IGNORE_CASE) }
    private val verdicts = verdictPatterns.map { Regex(it, RegexOption.IGNORE_CASE) }

    fun matches(statusCode: Int, body: String): Boolean {
        if (statusCode !in 400..499 || statusCode in excludedStatuses) return false
        return subjects.any { it.containsMatchIn(body) } && verdicts.any { it.containsMatchIn(body) }
    }
}
