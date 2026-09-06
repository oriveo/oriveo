package ai.oriveo.community.core.notes

object NoteTitle {

    private val HEADING = Regex("^#{1,6}\\s+")
    private val QUOTE = Regex("^>\\s?")
    private val UNORDERED = Regex("^[-*+]\\s+")
    private val ORDERED = Regex("^\\d+\\.\\s+")
    private val EMPHASIS = Regex("[*_`~]")
    private val WHITESPACE = Regex("\\s+")
    private val TABLE_SEP_OR_HR = Regex("^[|\\s:+-]+$")
    private val CODE_FENCE = Regex("^(```|~~~)")

    fun placeholderTitle(body: String): String {
        for (line in displayBodyForTitle(body).split("\n")) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (TABLE_SEP_OR_HR.matches(trimmed)) continue
            if (CODE_FENCE.containsMatchIn(trimmed)) continue
            val clean = trimmed
                .replace(HEADING, "")
                .replace(QUOTE, "")
                .replace(UNORDERED, "")
                .replace(ORDERED, "")
                .replace("|", " ")
                .replace(EMPHASIS, "")
                .replace(WHITESPACE, " ")
                .trim()
            if (clean.isNotEmpty()) return clean.take(200)
        }
        return ""
    }

    fun placeholderTitleFromSource(sourcePrompt: String?, body: String): String {
        val fromPrompt = placeholderTitle(sourcePrompt ?: "")
        return fromPrompt.ifEmpty { placeholderTitle(body) }
    }

    private fun displayBodyForTitle(body: String): String {
        val lines = body.split("\n")
        val index = lines.indexOfFirst { it.trim().startsWith("## Cross-check") }
        if (index < 0) return body
        return lines.drop(index + 1).joinToString("\n").trim().ifEmpty { body }
    }
}
