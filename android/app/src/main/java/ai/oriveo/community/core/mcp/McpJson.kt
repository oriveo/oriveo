package ai.oriveo.community.core.mcp

import java.math.BigDecimal
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// JSON utilities for remote MCP (resource limits and canonical JSON).
//
// Parsing uses the kotlinx tree (`JsonObject` is backed by an insertion-ordered LinkedHashMap, so the key order of the
// source document is preserved; the parameter summary relies on the property order of `inputSchema.properties`).
// Serialization does not use kotlinx's own `toString()`: it emits short escapes for control characters such as `\n`,
// whereas canonical JSON always uses `\u00XX`, and hashes would diverge if the clients disagreed.

/** Parsing failed (including excessive nesting, non-finite numbers and invalid UTF-8). */
class McpJsonException(message: String) : Exception(message)

object McpJson {
    /** Nesting depth limit. Real tool schemas and results come nowhere near it; exceeding it counts as a parse failure. */
    const val MAX_NESTING_DEPTH = 64

    private val parser = Json { isLenient = false }

    /**
     * Parses JSON text. Nesting beyond [MAX_NESTING_DEPTH] and non-finite numbers (`1e999`) both count as failures:
     * the former defends against a malicious server, the latter cannot be expressed in JSON and would no longer serialize
     * to valid JSON.
     */
    fun parse(text: String): JsonElement {
        // The kotlinx tree parser is recursive: a run of `[` goes straight to StackOverflowError (an Error that upper layers
        // cannot catch). The depth is scanned linearly first so that overly deep input is rejected before it gets there.
        if (exceedsDepth(text)) throw McpJsonException("too deep")
        val element = try {
            parser.parseToJsonElement(text)
        } catch (error: Exception) {
            throw McpJsonException("invalid json")
        }
        validate(element)
        return element
    }

    /** UTF-8 bytes -> JSON. Invalid UTF-8 counts as a parse failure (same behaviour as `String(data:encoding:)` on iOS). */
    fun parse(bytes: ByteArray): JsonElement {
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (error: CharacterCodingException) {
            throw McpJsonException("not utf-8")
        }
        return parse(text)
    }

    fun parseOrNull(text: String): JsonElement? = try {
        parse(text)
    } catch (error: McpJsonException) {
        null
    }

    fun parseOrNull(bytes: ByteArray): JsonElement? = try {
        parse(bytes)
    } catch (error: McpJsonException) {
        null
    }

    /** Whether `[` / `{` nesting outside strings exceeds the limit (brackets only; syntax errors are left to the parser). */
    private fun exceedsDepth(text: String): Boolean {
        var depth = 0
        var inString = false
        var escaped = false
        for (char in text) {
            if (inString) {
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == '"' -> inString = false
                }
                continue
            }
            when (char) {
                '"' -> inString = true
                '[', '{' -> {
                    depth += 1
                    if (depth > MAX_NESTING_DEPTH) return true
                }
                ']', '}' -> depth -= 1
            }
        }
        return false
    }

    /** Checks depth and numbers iteratively (no recursion: the peer could blow the stack of a recursive check with a run of `[`). */
    private fun validate(root: JsonElement) {
        val stack = ArrayDeque<Pair<JsonElement, Int>>()
        stack.addLast(root to 0)
        while (stack.isNotEmpty()) {
            val (element, depth) = stack.removeLast()
            when (element) {
                is JsonObject -> {
                    if (depth >= MAX_NESTING_DEPTH) throw McpJsonException("too deep")
                    element.values.forEach { stack.addLast(it to depth + 1) }
                }
                is JsonArray -> {
                    if (depth >= MAX_NESTING_DEPTH) throw McpJsonException("too deep")
                    element.forEach { stack.addLast(it to depth + 1) }
                }
                is JsonPrimitive -> if (!element.isString && element !is JsonNull) {
                    val content = element.content
                    if (content != "true" && content != "false") {
                        val number = content.toDoubleOrNull()
                        if (number == null || !number.isFinite()) throw McpJsonException("invalid number")
                    }
                }
            }
        }
    }

    /** Canonical JSON: objects are recursively reordered by ascending key, arrays keep their order. */
    fun canonical(element: JsonElement): String = StringBuilder().also { encode(element, it, sortKeys = true) }.toString()

    /** Serializes in stored order (objects are not sorted). Used for request bodies and the persisted `inputSchema`, preserving the source order of properties. */
    fun ordered(element: JsonElement): String = StringBuilder().also { encode(element, it, sortKeys = false) }.toString()

    private fun encode(element: JsonElement, out: StringBuilder, sortKeys: Boolean) {
        when (element) {
            is JsonObject -> {
                out.append('{')
                val keys = if (sortKeys) element.keys.sorted() else element.keys.toList()
                keys.forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    out.append(encodeString(key)).append(':')
                    encode(element.getValue(key), out, sortKeys)
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                element.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    encode(item, out, sortKeys)
                }
                out.append(']')
            }
            is JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                element.isString -> out.append(encodeString(element.content))
                element.content == "true" || element.content == "false" -> out.append(element.content)
                else -> out.append(encodeNumber(element.content.toDouble()))
            }
        }
    }

    /**
     * Canonical escaping: only `"`, `\` and control characters (< 0x20, as `\u00xx`) are escaped; every other character is
     * emitted as is.
     * A lone UTF-16 surrogate is replaced with U+FFFD (matching scalar parsing on iOS; otherwise the same tool would hash
     * differently across clients).
     */
    fun encodeString(value: String): String {
        val out = StringBuilder(value.length + 2)
        out.append('"')
        var index = 0
        while (index < value.length) {
            val char = value[index]
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char.code < 0x20 -> out.append("\\u").append(String.format("%04x", char.code))
                char.isHighSurrogate() && index + 1 < value.length && value[index + 1].isLowSurrogate() -> {
                    out.append(char).append(value[index + 1])
                    index += 1
                }
                char.isSurrogate() -> out.append('�')
                else -> out.append(char)
            }
            index += 1
        }
        out.append('"')
        return out.toString()
    }

    /**
     * Number output matches the iOS `JSONValue.encodeNumber` and JS: integers within the safe integer range are written
     * as integers, everything else uses the shortest round-trip representation (exponent form as `1e+30` / `1e-7`).
     */
    fun encodeNumber(number: Double): String {
        if (number == Math.floor(number) && Math.abs(number) < 9.007199254740992e15) {
            return number.toLong().toString()
        }
        val decimal = BigDecimal(number.toString()).stripTrailingZeros()
        val magnitude = Math.abs(number)
        if (magnitude >= 1e21 || magnitude < 1e-6) {
            val unscaled = decimal.unscaledValue().abs().toString()
            val exponent = unscaled.length - 1 - decimal.scale()
            val mantissa = if (unscaled.length == 1) unscaled else unscaled[0] + "." + unscaled.substring(1)
            val sign = if (number < 0) "-" else ""
            val exponentSign = if (exponent >= 0) "+" else "-"
            return "$sign${mantissa}e$exponentSign${Math.abs(exponent)}"
        }
        return decimal.toPlainString()
    }
}

// -- Accessors: the data comes from third-party servers, so a wrong type is treated as absent --

val JsonElement?.jsonObjectOrNull: JsonObject? get() = this as? JsonObject

val JsonElement?.jsonArrayOrNull: JsonArray? get() = this as? JsonArray

val JsonElement?.stringOrNull: String?
    get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

val JsonElement?.booleanOrNull: Boolean?
    get() {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString || primitive is JsonNull) return null
        return when (primitive.content) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

val JsonElement?.doubleOrNull: Double?
    get() {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString || primitive is JsonNull) return null
        if (primitive.content == "true" || primitive.content == "false") return null
        return primitive.content.toDoubleOrNull()?.takeIf { it.isFinite() }
    }

/**
 * Accepts only finite numbers without a fraction that fit in `Long`. Numbers come from third-party servers (`"id":1e30`,
 * `"error":{"code":1e30}`); out-of-range values must count as "not an integer" so that a peer cannot crash the app
 * with a single message.
 */
val JsonElement?.longOrNull: Long?
    get() {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString || primitive is JsonNull) return null
        primitive.content.toLongOrNull()?.let { return it }
        val number = primitive.content.toDoubleOrNull() ?: return null
        if (!number.isFinite() || number != Math.floor(number)) return null
        if (number < -9.223372036854775E18 || number >= 9.223372036854775E18) return null
        return number.toLong()
    }

operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)

/** A literal `null` and a missing value both count as absent. */
val JsonElement?.isNullOrAbsent: Boolean get() = this == null || this is JsonNull
