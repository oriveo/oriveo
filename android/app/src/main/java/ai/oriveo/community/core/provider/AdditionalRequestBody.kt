package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

/**
 * Additional request body (shared contract `additionalBodyRules`): a JSON object the user writes, merged in as the last step of every chat request body.
 *
 * The checks run in a fixed order shared by every client: size, syntax, root object, depth, forbidden segment names, protected root fields.
 * A local rejection throws [ProviderServiceError.LocalRequestRejected]: no request is sent and the connection state is left alone.
 */
object AdditionalRequestBody {
    const val OWNER = "additional_body"
    const val MAX_BYTES = 64 * 1024
    const val MAX_DEPTH = 32

    /** The same table as [GenerationParameterResolver.builderOwnedRootFields]: skeleton fields are rejected at the root level only. */
    val protectedRootFields: Set<String> get() = GenerationParameterResolver.builderOwnedRootFields
    val blockedSegments: Set<String> = setOf("__proto__", "prototype", "constructor")

    private val parser = Json

    sealed interface Validation {
        /** Blank content means the feature is not in use, not an error. */
        data object Empty : Validation
        data class Accepted(val patch: JsonObject) : Validation
        data class Rejected(val reason: String, val field: String? = null, val line: Int? = null) : Validation
    }

    fun validate(raw: String?): Validation {
        if (raw.isNullOrBlank()) return Validation.Empty
        if (raw.encodeToByteArray().size > MAX_BYTES) return Validation.Rejected("too_large")
        val parsed = try {
            parser.parseToJsonElement(raw)
        } catch (_: Exception) {
            // The line number is only taken from where the syntax scan really stopped; if it cannot be found none is given.
            val line = SyntaxScanner(raw).errorOffset()
                ?.let { offset -> raw.take(offset.coerceAtMost(raw.length)).count { it == '\n' } + 1 }
            return Validation.Rejected("invalid_json", line = line)
        }
        val root = parsed as? JsonObject ?: return Validation.Rejected("not_object")
        if (depth(root) > MAX_DEPTH) return Validation.Rejected("too_deep")
        blockedSegment(root)?.let { return Validation.Rejected("blocked_segment", field = it) }
        root.keys.filter { it in protectedRootFields }.minOrNull()
            ?.let { return Validation.Rejected("protected_field", field = it) }
        return Validation.Accepted(root)
    }

    /** Merged into a body already written by the builder, the panel parameters and the capability writers; on a name clash the additional request body wins. */
    fun apply(bodyJson: String, raw: String?): String = when (val result = validate(raw)) {
        Validation.Empty -> bodyJson
        is Validation.Rejected -> throw ProviderServiceError.LocalRequestRejected(
            owner = OWNER,
            reason = result.reason,
            fieldName = result.field,
            line = result.line,
        )
        is Validation.Accepted -> {
            if (result.patch.isEmpty()) {
                bodyJson
            } else {
                val body = parser.parseToJsonElement(bodyJson) as? JsonObject ?: return bodyJson
                merge(body, result.patch).toString()
            }
        }
    }

    fun merge(base: JsonObject, patch: JsonObject): JsonObject = buildJsonObject {
        (base.keys + patch.keys).forEach { key ->
            val b = base[key]
            val p = patch[key]
            when {
                p == null -> b?.let { put(key, it) }
                b is JsonObject && p is JsonObject -> put(key, merge(b, p))
                else -> put(key, p)
            }
        }
    }

    private fun depth(element: JsonElement): Int = when (element) {
        is JsonObject -> 1 + (element.values.maxOfOrNull(::depth) ?: 0)
        is JsonArray -> 1 + (element.maxOfOrNull(::depth) ?: 0)
        else -> 0
    }

    private fun blockedSegment(element: JsonElement): String? = when (element) {
        is JsonObject -> element.keys.firstOrNull { it in blockedSegments }
            ?: element.values.firstNotNullOfOrNull(::blockedSegment)
        is JsonArray -> element.firstNotNullOfOrNull(::blockedSegment)
        else -> null
    }

    /** Only used to locate the offset of the first syntax error; kotlinx parses the value itself. */
    private class SyntaxScanner(private val text: String) {
        private var index = 0

        fun errorOffset(): Int? = try {
            value()
            skipSpace()
            if (index < text.length) index else null
        } catch (_: Stop) {
            index
        }

        private object Stop : RuntimeException() {
            private fun readResolve(): Any = Stop
        }

        private fun skipSpace() {
            while (index < text.length && text[index] in " \t\r\n") index++
        }

        private fun expect(char: Char) {
            if (index >= text.length || text[index] != char) throw Stop
            index++
        }

        private fun value() {
            skipSpace()
            if (index >= text.length) throw Stop
            when (text[index]) {
                '{' -> container('}') { string(); skipSpace(); expect(':'); value() }
                '[' -> container(']') { value() }
                '"' -> string()
                't' -> literal("true")
                'f' -> literal("false")
                'n' -> literal("null")
                else -> number()
            }
        }

        private fun container(close: Char, element: () -> Unit) {
            index++
            skipSpace()
            if (index < text.length && text[index] == close) { index++; return }
            while (true) {
                skipSpace()
                element()
                skipSpace()
                if (index >= text.length) throw Stop
                when (text[index]) {
                    ',' -> index++
                    close -> { index++; return }
                    else -> throw Stop
                }
            }
        }

        private fun string() {
            skipSpace()
            expect('"')
            while (true) {
                if (index >= text.length) throw Stop
                when (text[index]) {
                    '"' -> { index++; return }
                    '\\' -> index += 2
                    else -> if (text[index] < ' ') throw Stop else index++
                }
            }
        }

        private fun literal(word: String) {
            if (!text.startsWith(word, index)) throw Stop
            index += word.length
        }

        private fun number() {
            val start = index
            while (index < text.length && (text[index].isDigit() || text[index] in "+-.eE")) index++
            if (index == start || text.substring(start, index).toDoubleOrNull() == null) {
                index = start
                throw Stop
            }
        }
    }
}
