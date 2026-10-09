package ai.oriveo.community.core.error

import android.content.Context
import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.feature.providers.detail.CustomRequestFieldRejection
import ai.oriveo.community.feature.providers.detail.customRequestFieldRejection

/**
 * Safe code of a local rejection (additional request body / web-search and thinking custom fields) to error card copy.
 *
 * A failed message stores only the safe code (`LocalRequestRejected.technicalDetail`) and it is turned into a sentence in the current language here at display time,
 * so older messages follow a language change. The output is plain data (a resource id plus arguments) that unit tests assert on directly; only rendering needs a Context.
 */
internal object LocalRequestRejectionCopy {
    data class Code(
        val owner: String,
        val reason: String,
        val field: String? = null,
        val line: Int? = null,
        val allowed: List<String> = emptyList(),
    )

    /** An argument may be a nested [Text]; the inner one is rendered first. */
    data class Text(@StringRes val res: Int, val args: List<Any> = emptyList())

    private const val ADDITIONAL_PREFIX = "additional_body_rejected:"
    private const val CUSTOM_PREFIX = "custom_request_fields_rejected:"
    private const val ALLOWED_MARKER = "#allowed="

    // Only these two reasons carry a field name, and the name is a JSON key the user wrote that may contain ':' or '@', so everything after the colon is the field name.
    private val FIELD_REASONS = setOf("blocked_segment", "protected_field")
    private val REASON_AND_LINE = Regex("""^([a-z_]+)(?:@(\d+))?$""")

    fun isCode(raw: String?): Boolean = parse(raw) != null

    fun parse(raw: String?): Code? {
        if (raw == null) return null
        if (raw.startsWith(ADDITIONAL_PREFIX)) {
            val rest = raw.removePrefix(ADDITIONAL_PREFIX)
            val reason = rest.substringBefore(':')
            if (reason in FIELD_REASONS) {
                val field = rest.substringAfter(':', missingDelimiterValue = "").ifEmpty { return null }
                return Code(AdditionalRequestBody.OWNER, reason, field = field)
            }
            val match = REASON_AND_LINE.matchEntire(rest) ?: return null
            return Code(AdditionalRequestBody.OWNER, match.groupValues[1], line = match.groupValues[2].toIntOrNull())
        }
        if (raw.startsWith(CUSTOM_PREFIX)) {
            val rest = raw.removePrefix(CUSTOM_PREFIX).substringBefore(ALLOWED_MARKER)
            val owner = rest.substringBefore(':', missingDelimiterValue = "").ifEmpty { return null }
            val match = REASON_AND_LINE.matchEntire(rest.substringAfter(':')) ?: return null
            val allowed = raw.substringAfter(ALLOWED_MARKER, missingDelimiterValue = "").takeIf { it.isNotEmpty() }?.let { encoded ->
                runCatching { String(java.util.Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
                    ?.split('\u001f')?.filter { it.isNotEmpty() }
            }.orEmpty()
            return Code(owner, match.groupValues[1], line = match.groupValues[2].toIntOrNull(), allowed = allowed)
        }
        return null
    }

    @StringRes
    fun title(code: Code): Int =
        if (code.owner == AdditionalRequestBody.OWNER) R.string.additional_body_check
        else R.string.model_control_custom_request_fields

    fun body(code: Code): Text {
        val reason = reasonText(code)
        val located = if (code.owner == AdditionalRequestBody.OWNER) {
            code.line?.let { Text(R.string.local_request_line_format, listOf(it, reason)) } ?: reason
        } else {
            val section = sectionTitle(code.owner)
            when {
                section == null -> code.line?.let { Text(R.string.local_request_line_format, listOf(it, reason)) } ?: reason
                code.line != null -> Text(R.string.local_request_custom_line_format, listOf(section, code.line, reason))
                else -> Text(R.string.local_request_custom_format, listOf(section, reason))
            }
        }
        return Text(R.string.local_request_body_format, listOf(located, Text(R.string.local_request_not_sent)))
    }

    fun render(text: Text, context: Context): String =
        context.getString(text.res, *text.args.map { if (it is Text) render(it, context) else it }.toTypedArray())

    private fun reasonText(code: Code): Text {
        if (code.owner == AdditionalRequestBody.OWNER) {
            return when (code.reason) {
                "too_large" -> Text(R.string.additional_body_reason_too_large)
                "invalid_json" -> Text(R.string.additional_body_reason_invalid_json)
                "not_object" -> Text(R.string.additional_body_reason_not_object)
                "too_deep" -> Text(R.string.additional_body_reason_too_deep)
                "blocked_segment" -> Text(R.string.additional_body_reason_blocked_segment, listOfNotNull(code.field))
                "protected_field" -> Text(R.string.additional_body_reason_protected_field, listOfNotNull(code.field))
                else -> Text(R.string.additional_body_check)
            }
        }
        // Same classification and the same sentence as the editor page; only an unknown field carries the allowed-field list, the other path reasons plainly report a conflict.
        return when (val rejection = customRequestFieldRejection(code.reason, code.allowed)) {
            CustomRequestFieldRejection.InvalidJson -> Text(R.string.model_control_custom_invalid_json)
            CustomRequestFieldRejection.TooLarge -> Text(R.string.model_control_custom_too_large)
            CustomRequestFieldRejection.ConflictsManaged -> Text(R.string.model_control_custom_conflicts_managed)
            is CustomRequestFieldRejection.NotAllowed ->
                Text(R.string.model_control_custom_field_not_allowed, listOf(rejection.allowedPaths.joinToString(" · ")))
        }
    }

    private fun sectionTitle(owner: String): Text? = when (owner) {
        "web" -> Text(R.string.model_control_web_search)
        "reasoning" -> Text(R.string.model_control_thinking)
        else -> null
    }
}
