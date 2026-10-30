package ai.oriveo.community.core.search

import java.math.BigDecimal
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Small JS-semantics helpers shared by the external search modules: the reference implementation is scripts/lib/search-*.mjs,
 * and the JS rules for "string / integer / whitespace / value path" are ported one by one here so each module does not write its own.
 *
 * Convention: Kotlin `null` corresponds to JS `undefined` (key absent), [JsonNull] corresponds to JSON `null`.
 */
internal object SearchJson {
    /** 2^53 − 1: JS Number.MAX_SAFE_INTEGER. */
    private val MAX_SAFE = BigDecimal("9007199254740991")

    /** The whitespace set shared by JS `\s` and String.prototype.trim (WhiteSpace + LineTerminator). */
    private const val JS_WHITESPACE =
        "\u0009\u000A\u000B\u000C\u000D          " +
            "        　﻿"

    fun isJsWhitespace(c: Char): Boolean = JS_WHITESPACE.indexOf(c) >= 0

    /** JS String.prototype.trim. */
    fun jsTrim(s: String): String = s.trim(::isJsWhitespace)

    /** JS `\s` inside a regex character class (without the brackets). */
    val jsWhitespaceClass: String = JS_WHITESPACE.map { "\\u%04X".format(it.code) }.joinToString("")

    fun codePoints(s: String): List<String> {
        val out = ArrayList<String>(s.length)
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val n = Character.charCount(cp)
            out.add(s.substring(i, i + n))
            i += n
        }
        return out
    }

    fun codePointLength(s: String): Int = s.codePointCount(0, s.length)

    /** Numeric value of a JSON number; null if not a number. */
    private fun numberValue(e: JsonElement?): BigDecimal? {
        if (e !is JsonPrimitive || e is JsonNull || e.isString) return null
        if (e.content == "true" || e.content == "false") return null
        return e.content.toBigDecimalOrNull()
    }

    fun isNumber(e: JsonElement?): Boolean = numberValue(e) != null

    /** JS Number.isSafeInteger: returns the integer itself, otherwise null. */
    fun safeInteger(e: JsonElement?): Long? {
        val v = numberValue(e) ?: return null
        if (v.abs() > MAX_SAFE) return null
        return runCatching { v.toBigIntegerExact().toLong() }.getOrNull()
    }

    /** JS Number.isInteger (not limited to the safe range, but must be finite). */
    fun isInteger(e: JsonElement?): Boolean {
        val v = numberValue(e) ?: return false
        if (!v.toDouble().isFinite()) return false
        return runCatching { v.toBigIntegerExact() }.isSuccess
    }

    /** Integer value (within Int range), otherwise null. */
    fun intValue(e: JsonElement?): Int? = safeInteger(e)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

    fun string(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun isTrue(e: JsonElement?): Boolean = e is JsonPrimitive && !e.isString && e.content == "true"

    fun isBoolean(e: JsonElement?): Boolean =
        e is JsonPrimitive && e !is JsonNull && !e.isString && (e.content == "true" || e.content == "false")

    fun obj(e: JsonElement?): JsonObject? = e as? JsonObject

    fun array(e: JsonElement?): JsonArray? = e as? JsonArray

    /** JS truthiness (for JSON values). */
    fun truthy(e: JsonElement?): Boolean = when (e) {
        null, JsonNull -> false
        is JsonPrimitive -> when {
            e.isString -> e.content.isNotEmpty()
            e.content == "true" -> true
            e.content == "false" -> false
            else -> numberValue(e)?.signum() != 0
        }
        else -> true
    }

    /** Dotted path lookup; hitting a non-object midway (arrays included) returns null (= JS undefined). */
    fun getPath(obj: JsonElement?, dotted: String): JsonElement? {
        var cur: JsonElement? = obj
        for (part in dotted.split('.')) {
            if (cur !is JsonObject) return null
            cur = cur[part]
        }
        return cur
    }

    /** JS `Object.keys(o).sort()`: ascending by UTF-16 code unit. */
    fun sortedKeys(o: JsonObject): List<String> = o.keys.sorted()
}
