package ai.oriveo.community.core.data.remote

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.math.BigDecimal
import java.time.DateTimeException
import java.time.LocalDate

/**
 * Minimal validator for shared/model-contracts/metadata_payload.v2.schema.json.
 *
 * Only the keywords used by the shared schema are supported; any other keyword makes the
 * constructor throw, so a schema change that needs new semantics fails loudly instead of being
 * silently ignored.
 */
internal class MetadataPayloadSchemaValidator(schema: JsonElement) {

    data class SchemaError(val instancePath: String, val keyword: String)

    data class DroppedModel(val modelId: String, val error: SchemaError)

    data class DroppedProvider(val providerId: String, val error: SchemaError)

    data class DecodeResult(
        /** Non-null means the envelope is rejected and nothing else is usable. */
        val envelopeError: SchemaError?,
        /** Catalog view: model ids; full / index view: "provider/model". */
        val keptModels: List<String>,
        val droppedModels: List<DroppedModel>,
        val droppedProviders: List<DroppedProvider>,
    ) {
        val firstError: SchemaError?
            get() = envelopeError
                ?: droppedProviders.firstOrNull()?.error
                ?: droppedModels.firstOrNull()?.error
    }

    private val root: JsonObject = schema as? JsonObject
        ?: throw IllegalArgumentException("schema root must be an object")
    private val defs: JsonObject = root["\$defs"] as? JsonObject ?: JsonObject(emptyMap())

    init {
        checkSchema(root, "#")
        defs["provider"] ?: throw IllegalArgumentException("schema lacks \$defs/provider")
        defs["model"] ?: throw IllegalArgumentException("schema lacks \$defs/model")
    }

    /** Validates the response envelope `{ data: ... }` with every models / providers map emptied. */
    fun validateEnvelope(data: JsonObject): SchemaError? {
        val shell = JsonObject(
            data.mapValues { (key, value) ->
                if ((key == "models" || key == "providers") && value is JsonObject) JsonObject(emptyMap()) else value
            },
        )
        return validate(root, JsonObject(mapOf("data" to shell)), "")
    }

    /** Validates one provider entry (its models removed) against `$defs/provider`. */
    fun validateProvider(provider: JsonElement): SchemaError? {
        val stripped = if (provider is JsonObject) JsonObject(provider - "models") else provider
        return validate(defs.getValue("provider"), stripped, "")
    }

    /** Validates one model entry (refs already expanded) against `$defs/model`. */
    fun validateModel(model: JsonElement): SchemaError? =
        validate(defs.getValue("model"), model, "")

    /**
     * Decodes a schema-2 `data` object: envelope → each provider → each model.
     * A bad envelope rejects everything; a bad provider drops the whole provider;
     * a bad model (or a ref that does not resolve / resolves to a bad entry) drops only that model.
     */
    fun decode(data: JsonObject): DecodeResult {
        validateEnvelope(data)?.let { return DecodeResult(it, emptyList(), emptyList(), emptyList()) }
        val kept = mutableListOf<String>()
        val droppedModels = mutableListOf<DroppedModel>()
        val droppedProviders = mutableListOf<DroppedProvider>()
        val tables = data["tables"] as? JsonObject
        val catalogModels = data["models"] as? JsonObject
        if (catalogModels != null) {
            decodeModels(catalogModels, tables, "", kept, droppedModels)
        }
        val providers = data["providers"] as? JsonObject
        providers?.forEach { (providerId, provider) ->
            val providerError = validateProvider(provider)
            if (providerError != null) {
                droppedProviders += DroppedProvider(providerId, providerError)
                return@forEach
            }
            val rawModels = (provider as JsonObject)["models"] ?: return@forEach
            // Same as Web: a models value that is not an object drops the whole provider.
            val models = rawModels as? JsonObject ?: run {
                droppedProviders += DroppedProvider(providerId, SchemaError("/models", "type"))
                return@forEach
            }
            decodeModels(models, tables, "$providerId/", kept, droppedModels)
        }
        return DecodeResult(null, kept, droppedModels, droppedProviders)
    }

    private fun decodeModels(
        models: JsonObject,
        tables: JsonObject?,
        prefix: String,
        kept: MutableList<String>,
        dropped: MutableList<DroppedModel>,
    ) {
        models.forEach { (modelId, model) ->
            val id = prefix + modelId
            val expanded = expandRefs(model, tables)
            val error = when (expanded) {
                is RefExpansion.Unresolved -> SchemaError("/${escape(expanded.field)}", UNRESOLVED_REF)
                is RefExpansion.Expanded -> validateModel(withoutBadRegionPricing(expanded.model))
            }
            if (error == null) kept += id else dropped += DroppedModel(id, error)
        }
    }

    /**
     * A malformed regionPricing entry drops only that entry (contract §5.7): each entry is checked
     * against `$defs/regionPricingEntry` first and bad ones are removed; when none is left the key is
     * removed too, so the model is judged without it. A non-array value is left for the model schema.
     */
    private fun withoutBadRegionPricing(model: JsonElement): JsonElement {
        val entrySchema = defs[REGION_PRICING_ENTRY] ?: return model
        if (model !is JsonObject) return model
        val entries = model[REGION_PRICING] as? JsonArray ?: return model
        val good = entries.filter { validate(entrySchema, it, "") == null }
        if (good.size == entries.size) return model
        return if (good.isEmpty()) JsonObject(model - REGION_PRICING) else JsonObject(model + (REGION_PRICING to JsonArray(good)))
    }

    private sealed interface RefExpansion {
        data class Expanded(val model: JsonElement) : RefExpansion
        data class Unresolved(val field: String) : RefExpansion
    }

    /**
     * Expands only the refs listed in [MetadataCatalogAssembly.REF_FIELDS] (the same table the
     * catalog expansion uses); any other `*Ref` field is left untouched. The ref field itself is kept.
     * A listed ref that is not a string or does not hit its table is unresolved.
     */
    private fun expandRefs(model: JsonElement, tables: JsonObject?): RefExpansion {
        if (model !is JsonObject) return RefExpansion.Expanded(model)
        val out = model.toMutableMap()
        for ((refField, tableName, targetField) in MetadataCatalogAssembly.REF_FIELDS) {
            val value = model[refField] ?: continue
            val key = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: return RefExpansion.Unresolved(refField)
            val resolved = (tables?.get(tableName) as? JsonObject)?.get(key)
                ?: return RefExpansion.Unresolved(refField)
            out[targetField] = resolved
        }
        return RefExpansion.Expanded(JsonObject(out))
    }

    // ── schema walking ────────────────────────────────────────────────

    private fun checkSchema(schema: JsonElement, at: String) {
        if (schema is JsonPrimitive && schema.booleanOrNull != null) return
        val obj = schema as? JsonObject ?: throw IllegalArgumentException("schema at $at is not an object")
        for ((keyword, value) in obj) {
            if (keyword !in SUPPORTED && keyword !in IGNORED) {
                throw IllegalArgumentException("unsupported schema keyword '$keyword' at $at")
            }
            when (keyword) {
                "properties", "\$defs" -> (value as? JsonObject
                    ?: throw IllegalArgumentException("$keyword at $at must be an object"))
                    .forEach { (name, sub) -> checkSchema(sub, "$at/$keyword/$name") }
                "items", "additionalProperties" -> checkSchema(value, "$at/$keyword")
                "oneOf", "allOf" -> (value as? JsonArray
                    ?: throw IllegalArgumentException("$keyword at $at must be an array"))
                    .forEachIndexed { index, sub -> checkSchema(sub, "$at/$keyword/$index") }
                "\$ref" -> {
                    val ref = (value as? JsonPrimitive)?.content.orEmpty()
                    if (!ref.startsWith(DEF_PREFIX)) {
                        throw IllegalArgumentException("unsupported \$ref '$ref' at $at")
                    }
                }
                "format" -> if ((value as? JsonPrimitive)?.content != "date-time") {
                    throw IllegalArgumentException("unsupported format '$value' at $at")
                }
                // Contract regionPricing uses it; it must be a non-negative integer.
                "minItems" -> {
                    val bound = (value as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBigDecimalOrNull()
                    if (bound == null || bound.signum() < 0 || bound.stripTrailingZeros().scale() > 0) {
                        throw IllegalArgumentException("minItems at $at must be a non-negative integer")
                    }
                }
            }
        }
    }

    private fun resolveRef(ref: String): JsonElement =
        defs[ref.removePrefix(DEF_PREFIX)] ?: throw IllegalArgumentException("unresolved \$ref '$ref'")

    private fun validate(schema: JsonElement, instance: JsonElement, path: String): SchemaError? {
        if (schema is JsonPrimitive) {
            return if (schema.booleanOrNull == false) SchemaError(path, "false") else null
        }
        val s = schema as JsonObject

        s["\$ref"]?.let { ref ->
            validate(resolveRef((ref as JsonPrimitive).content), instance, path)?.let { return it }
        }
        (s["allOf"] as? JsonArray)?.forEach { sub ->
            validate(sub, instance, path)?.let { return it }
        }
        (s["oneOf"] as? JsonArray)?.let { branches ->
            val matched = branches.count { validate(it, instance, path) == null }
            if (matched != 1) return SchemaError(path, "oneOf")
        }
        s["type"]?.let { type ->
            val allowed = when (type) {
                is JsonArray -> type.map { (it as JsonPrimitive).content }
                else -> listOf((type as JsonPrimitive).content)
            }
            if (allowed.none { matchesType(it, instance) }) return SchemaError(path, "type")
        }
        s["const"]?.let { expected ->
            if (!jsonEquals(expected, instance)) return SchemaError(path, "const")
        }
        (s["enum"] as? JsonArray)?.let { values ->
            if (values.none { jsonEquals(it, instance) }) return SchemaError(path, "enum")
        }
        if (instance is JsonPrimitive && !instance.isString && instance != JsonNull) {
            s["minimum"]?.let { min ->
                val value = instance.content.toBigDecimalOrNull()
                val bound = (min as JsonPrimitive).content.toBigDecimalOrNull()
                if (value != null && bound != null && value < bound) return SchemaError(path, "minimum")
            }
        }
        if (instance is JsonPrimitive && instance.isString) {
            val text = instance.content
            s["minLength"]?.let { min ->
                val bound = (min as JsonPrimitive).content.toDouble()
                if (text.codePointCount(0, text.length) < bound) return SchemaError(path, "minLength")
            }
            s["pattern"]?.let { pattern ->
                if (!jsPatternRegex((pattern as JsonPrimitive).content).containsMatchIn(text)) {
                    return SchemaError(path, "pattern")
                }
            }
            s["format"]?.let {
                if (!isDateTime(text)) return SchemaError(path, "format")
            }
        }
        if (instance is JsonObject) {
            (s["required"] as? JsonArray)?.forEach { name ->
                val key = (name as JsonPrimitive).content
                if (key !in instance) return SchemaError(path, "required")
            }
            val properties = s["properties"] as? JsonObject
            for ((key, value) in instance) {
                val childPath = "$path/${escape(key)}"
                val propertySchema = properties?.get(key)
                if (propertySchema != null) {
                    validate(propertySchema, value, childPath)?.let { return it }
                } else {
                    s["additionalProperties"]?.let { additional ->
                        if (additional is JsonPrimitive && additional.booleanOrNull == false) {
                            return SchemaError(childPath, "additionalProperties")
                        }
                        validate(additional, value, childPath)?.let { return it }
                    }
                }
            }
        }
        if (instance is JsonArray) {
            s["minItems"]?.let { min ->
                val bound = (min as JsonPrimitive).content.toBigDecimal()
                if (instance.size.toBigDecimal() < bound) return SchemaError(path, "minItems")
            }
            s["items"]?.let { items ->
                instance.forEachIndexed { index, item ->
                    validate(items, item, "$path/$index")?.let { return it }
                }
            }
        }
        return null
    }

    private fun matchesType(type: String, instance: JsonElement): Boolean = when (type) {
        "object" -> instance is JsonObject
        "array" -> instance is JsonArray
        "null" -> instance is JsonNull
        "string" -> instance is JsonPrimitive && instance.isString
        "boolean" -> instance is JsonPrimitive && !instance.isString && instance.booleanOrNull != null
        "number" -> isNumber(instance)
        "integer" -> isNumber(instance) && (instance as JsonPrimitive).let { p ->
            p.longOrNull != null || p.content.toBigDecimalOrNull()?.let { it.stripTrailingZeros().scale() <= 0 } == true
        }
        else -> false
    }

    private fun isNumber(instance: JsonElement): Boolean =
        instance is JsonPrimitive && !instance.isString && instance != JsonNull &&
            instance.booleanOrNull == null && instance.doubleOrNull != null

    private fun jsonEquals(a: JsonElement, b: JsonElement): Boolean {
        if (isNumber(a) && isNumber(b)) {
            val x: BigDecimal? = (a as JsonPrimitive).content.toBigDecimalOrNull()
            val y: BigDecimal? = (b as JsonPrimitive).content.toBigDecimalOrNull()
            if (x != null && y != null) return x.compareTo(y) == 0
        }
        return when {
            a is JsonObject && b is JsonObject ->
                a.keys == b.keys && a.all { (k, v) -> jsonEquals(v, b.getValue(k)) }
            a is JsonArray && b is JsonArray ->
                a.size == b.size && a.indices.all { jsonEquals(a[it], b[it]) }
            a is JsonPrimitive && b is JsonPrimitive ->
                a.isString == b.isString && a.content == b.content
            else -> false
        }
    }

    private fun escape(key: String): String = key.replace("~", "~0").replace("/", "~1")

    /**
     * ajv-formats 3.0.1 `getDateTime(true)` (what the Web generator compiles): split on `t` or
     * whitespace into exactly two parts, a real calendar date, hour <= 23 / minute <= 59 / second < 60
     * with a mandatory time zone (offset hour <= 23, minute <= 59); second 60 only at 23:59 UTC.
     */
    private fun isDateTime(text: String): Boolean {
        val parts = text.split(DATE_TIME_SEPARATOR)
        return parts.size == 2 && isFullDate(parts[0]) && isStrictTime(parts[1])
    }

    private fun isFullDate(text: String): Boolean {
        val match = FULL_DATE.matchEntire(text) ?: return false
        return try {
            LocalDate.of(match.groupValues[1].toInt(), match.groupValues[2].toInt(), match.groupValues[3].toInt())
            true
        } catch (_: DateTimeException) {
            false
        }
    }

    private fun isStrictTime(text: String): Boolean {
        val match = TIME.matchEntire(text) ?: return false
        val hour = match.groupValues[1].toInt()
        val minute = match.groupValues[2].toInt()
        val second = match.groupValues[3].toDouble()
        val zone = match.groupValues[4]
        if (zone.isEmpty()) return false
        val sign = if (match.groupValues[5] == "-") -1 else 1
        val zoneHour = match.groupValues[6].ifEmpty { "0" }.toInt()
        val zoneMinute = match.groupValues[7].ifEmpty { "0" }.toInt()
        if (zoneHour > 23 || zoneMinute > 59) return false
        if (hour <= 23 && minute <= 59 && second < 60) return true
        // Leap second: only valid when the instant is 23:59 UTC.
        val utcMinute = minute - zoneMinute * sign
        val utcHour = hour - zoneHour * sign - (if (utcMinute < 0) 1 else 0)
        return (utcHour == 23 || utcHour == -1) && (utcMinute == 59 || utcMinute == -1) && second < 61
    }

    /**
     * Compiles a schema pattern with JS (ajv) semantics: an unescaped `$` outside a character class
     * matches only at the very end of the input (Java's `$` also matches before a final line break).
     */
    private fun jsPatternRegex(pattern: String): Regex = patternCache.getOrPut(pattern) {
        val out = StringBuilder(pattern.length + 4)
        var inClass = false
        var index = 0
        while (index < pattern.length) {
            val c = pattern[index]
            when {
                c == '\\' && index + 1 < pattern.length -> {
                    out.append(c).append(pattern[index + 1])
                    index += 2
                    continue
                }
                c == '[' -> inClass = true
                c == ']' -> inClass = false
                c == '$' && !inClass -> {
                    out.append("\\z")
                    index += 1
                    continue
                }
            }
            out.append(c)
            index += 1
        }
        Regex(out.toString())
    }

    private val patternCache = HashMap<String, Regex>()

    private companion object {
        const val DEF_PREFIX = "#/\$defs/"
        const val REGION_PRICING = "regionPricing"
        const val REGION_PRICING_ENTRY = "regionPricingEntry"
        val SUPPORTED = setOf(
            "type", "required", "oneOf", "allOf", "\$ref", "const", "minimum", "format",
            "additionalProperties", "minLength", "minItems", "pattern", "items", "enum", "properties",
            "\$defs",
        )
        val IGNORED = setOf("\$schema", "\$id", "\$comment")
        const val UNRESOLVED_REF = "unresolved_ref"
        val DATE_TIME_SEPARATOR = Regex("t|\\s", RegexOption.IGNORE_CASE)
        val FULL_DATE = Regex("^(\\d\\d\\d\\d)-(\\d\\d)-(\\d\\d)$")
        val TIME = Regex(
            "^(\\d\\d):(\\d\\d):(\\d\\d(?:\\.\\d+)?)(z|([+-])(\\d\\d)(?::?(\\d\\d))?)?$",
            RegexOption.IGNORE_CASE,
        )
    }
}
