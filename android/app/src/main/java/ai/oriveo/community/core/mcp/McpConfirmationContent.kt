package ai.oriveo.community.core.mcp

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// How arguments are presented in the confirmation dialog and in step details.
//
// Pure functions. Keys are the parameter names exactly as the server defines them and values are the raw content the
// model supplied; this file only decides which ones are shown and how they are truncated.

data class McpConfirmationParameter(
    val key: String,
    /** The full value (for the full-text page). Strings are verbatim, other types are JSON text. */
    val fullText: String,
    val display: Display,
) {
    sealed interface Display {
        /** Short value: shown directly (the UI clamps it to two lines). */
        data class Inline(val text: String) : Display

        /** Long text: only the character count is shown, with a "View full text" action next to it. */
        data class Long(val characterCount: Int) : Display
    }
}

object McpConfirmationContent {
    /** The maximum number of top-level parameters the dialog shows. */
    const val MAX_PARAMETERS = 4

    /** Values longer than this (or containing a line break) are treated as long text. */
    const val INLINE_CHARACTER_LIMIT = 80

    /** The first 4 top-level parameters, in the order the model supplied them. */
    fun parameters(arguments: JsonElement): List<McpConfirmationParameter> {
        val obj = arguments as? JsonObject ?: return emptyList()
        return obj.entries.take(MAX_PARAMETERS).map { (key, value) ->
            val text = text(value)
            val isLong = text.length > INLINE_CHARACTER_LIMIT || '\n' in text
            McpConfirmationParameter(
                key = key,
                fullText = text,
                display = if (isLong) {
                    McpConfirmationParameter.Display.Long(text.codePointCount(0, text.length))
                } else {
                    McpConfirmationParameter.Display.Inline(text)
                },
            )
        }
    }

    /** Whether there are more top-level parameters than the dialog shows (the rest are only visible on the full-text page). */
    fun hasMoreParameters(arguments: JsonElement): Boolean = ((arguments as? JsonObject)?.size ?: 0) > MAX_PARAMETERS

    /** All parameters, one `key: value` per line (full-text page, and "Arguments sent" in step details). */
    fun allParametersText(arguments: JsonElement): String {
        val obj = arguments as? JsonObject ?: return McpJson.ordered(arguments)
        return obj.entries.joinToString("\n") { (key, value) -> "$key: ${McpJson.ordered(value)}" }
    }

    /** The argument text of a locally stored payload in step details (stored as canonical JSON). Shown as is when it cannot be parsed. */
    fun allParametersText(storedJson: String): String =
        McpJson.parseOrNull(storedJson)?.let(::allParametersText) ?: storedJson

    private fun text(value: JsonElement): String =
        (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: McpJson.ordered(value)
}
