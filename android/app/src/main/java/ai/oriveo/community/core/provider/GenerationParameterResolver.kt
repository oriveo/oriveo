package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/** The single outbound resolver for generation parameters. With no profile or wire path to go on it never injects an optional parameter. */
internal object GenerationParameterResolver {
    private val json = Json { ignoreUnknownKeys = true }
    // Wire path hardening, per the shared contract's #wireHardening section.
    // Thresholds, enums and tiers stay entirely under the catalog's authority, but a wire
    // path is a WRITE target: trust the semantics, not the shape. A structurally illegal
    // path drops that one parameter and records a local diagnostic; it never aborts the
    // whole request.
    private val wireSegmentPattern = Regex("^[A-Za-z_][A-Za-z0-9_]*$")
    private val blockedWireSegments = setOf("__proto__", "prototype", "constructor")
    private const val MAX_WIRE_SEGMENTS = 4
    /** Root fields the request builder owns. The request skeleton belongs to the builder, and a wire path may never overwrite it. */
    private val builderOwnedRootFields = setOf(
        "model", "messages", "input", "contents", "prompt", "attachments", "instructions", "system", "stream", "stream_options", "tools", "tool_choice", "plugins",
    )
    private const val JSON_SCHEMA_MAX_BYTES = 64 * 1024

    enum class WireRejectionReason(val wireName: String) {
        BlockedSegment("blocked_segment"),
        InvalidSegment("invalid_segment"),
        DepthExceeded("depth_exceeded"),
        OwnedRootField("owned_root_field"),
    }

    data class WireDiagnostic(
        val parameterId: String,
        val wirePath: String,
        val reason: WireRejectionReason,
    )

    private const val DIAGNOSTIC_CAPACITY = 50
    private val wireDiagnostics = ArrayDeque<WireDiagnostic>()

    /** Why a wire path was rejected, or null when it is structurally sound. The order of the checks follows the shared contract's evaluationOrder. */
    fun wireRejectionReason(wirePath: String): WireRejectionReason? {
        val segments = wirePath.split('.')
        segments.forEach { segment ->
            if (segment in blockedWireSegments) return WireRejectionReason.BlockedSegment
            if (!wireSegmentPattern.matches(segment)) return WireRejectionReason.InvalidSegment
        }
        if (segments.size > MAX_WIRE_SEGMENTS) return WireRejectionReason.DepthExceeded
        if (segments.first() in builderOwnedRootFields) return WireRejectionReason.OwnedRootField
        return null
    }

    /** Local diagnostics only, never sent anywhere and never shown in the UI. They exist so "I set a value in the panel and it did not go out" can be shown to be deliberate rather than a parameter randomly going missing. */
    fun readWireDiagnostics(): List<WireDiagnostic> = synchronized(wireDiagnostics) { wireDiagnostics.toList() }

    fun clearWireDiagnostics() = synchronized(wireDiagnostics) { wireDiagnostics.clear() }

    private fun recordWireRejection(parameterId: String, wirePath: String, reason: WireRejectionReason) {
        synchronized(wireDiagnostics) {
            wireDiagnostics.addLast(WireDiagnostic(parameterId, wirePath, reason))
            while (wireDiagnostics.size > DIAGNOSTIC_CAPACITY) wireDiagnostics.removeFirst()
        }
    }

    fun apply(
        body: String,
        options: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    ): String {
        val overrides = options.generationParameters?.values ?: return body
        val profile = if (capabilityProjection?.identity?.providerKind == ProviderKind.Relay.rawValue) {
            options.activeModel?.generationProfile ?: resolved?.profiles?.generation
        } else {
            resolved?.profiles?.generation
        } ?: return body
        // v2 exact recipe is the generation authorization source. Its legacy-template bridge
        // must match the profile that owns schema/wire; runtime miss/invalid is a hard zero delta.
        when (capabilityProjection?.generationRuntimeAuthorized) {
            false -> return body
            true -> if (capabilityProjection.generationRuntimeTemplate != profile.template) return body
            null -> Unit // runtime genuinely absent: retain the legacy evidence compatibility path.
        }
        if (profile.wire.isEmpty()) return body
        if (overrides.any { (key, override) ->
                override.state == GenerationOverrideState.Value &&
                    override.value?.let { value ->
                        profile.parameters.firstOrNull { it.id == key }?.let { parameter ->
                            !isValidGenerationValue(value, parameter)
                        } ?: false
                    } == true
            }) return body

        var root = try {
            json.parseToJsonElement(body).jsonObject
        } catch (_: Exception) {
            return body
        }
        if (hasConflict(overrides, profile, toolsActive = root["tools"] is JsonArray)) return body
        val active = overrides.filterValues { it.state == GenerationOverrideState.Value }.keys
        if (profile.parameters.any { parameter ->
                parameter.id in active && parameter.requires.any { requirement ->
                    val key = requirement["key"]?.let { (it as? JsonPrimitive)?.contentOrNull } ?: return@any true
                    key !in active || requirement["value"]?.let { overrides[key]?.value != it } == true
                }
            }) return body
        for ((key, override) in overrides) {
            if (override.state == GenerationOverrideState.Inherit) continue
            val wire = profile.wire[key] ?: continue
            // The request boundary may only consume the projection from this same facade. A
            // caller without a final dispatch scope must not resurrect a parameter through an
            // older carrier or an allowUnknown escape hatch, and tests have to supply the
            // projection explicitly.
            val allowed = when (capabilityProjection?.generationRuntimeAuthorized) {
                true -> capabilityProjection.generationRuntimeTemplate == profile.template
                false -> false
                null -> capabilityProjection?.permitsOutbound("generation_parameter/$key") == true
            }
            if (!allowed) continue
            val rejection = wireRejectionReason(wire)
            if (rejection != null) {
                recordWireRejection(key, wire, rejection)
                continue
            }
            root = when (override.state) {
                GenerationOverrideState.Omit -> remove(root, wire.split('.'))
                GenerationOverrideState.Value -> override.value?.let {
                    applySpecializedOutputContract(root, profile.template, key, wire, it)
                } ?: root
                GenerationOverrideState.Inherit -> root
            }
        }
        return root.toString()
    }

    private fun hasConflict(
        overrides: Map<String, ai.oriveo.community.core.model.GenerationParameterOverride>,
        profile: GenerationProfileRef,
        toolsActive: Boolean,
    ): Boolean {
        val active = overrides.filterValues { it.state == GenerationOverrideState.Value }.keys.toMutableSet()
        if (toolsActive) active += "tools"
        return profile.parameters.any { it.id in active && it.conflictsWith.any(active::contains) }
    }

    private fun applySpecializedOutputContract(
        source: JsonObject,
        template: String?,
        parameterID: String,
        wire: String,
        value: JsonElement,
    ): JsonObject {
        if (parameterID == "json_schema" && value is JsonObject) {
            return when (template) {
                "openai_chat_completions", "vllm_extra_body" -> set(
                    source,
                    listOf("response_format"),
                    JsonObject(mapOf(
                        "type" to JsonPrimitive("json_schema"),
                        "json_schema" to JsonObject(mapOf(
                            "name" to JsonPrimitive("oriveo_response"),
                            "strict" to JsonPrimitive(true),
                            "schema" to value,
                        )),
                    )),
                )
                "openai_responses" -> set(
                    source,
                    listOf("text", "format"),
                    JsonObject(mapOf(
                        "type" to JsonPrimitive("json_schema"),
                        "name" to JsonPrimitive("oriveo_response"),
                        "strict" to JsonPrimitive(true),
                        "schema" to value,
                    )),
                )
                "anthropic_messages" -> set(
                    source,
                    listOf("output_format"),
                    JsonObject(mapOf("type" to JsonPrimitive("json_schema"), "schema" to value)),
                )
                "gemini_generate_content" -> set(
                    set(source, listOf("generationConfig", "responseMimeType"), JsonPrimitive("application/json")),
                    listOf("generationConfig", "responseJsonSchema"),
                    value,
                )
                else -> source
            }
        }
        if (parameterID == "response_format" && value is JsonPrimitive && value.isString) {
            return when (template) {
                "openai_chat_completions", "vllm_extra_body" -> set(
                    source,
                    listOf("response_format"),
                    JsonObject(mapOf("type" to JsonPrimitive(if (value.content == "json") "json_object" else "text"))),
                )
                "gemini_generate_content" -> set(
                    source,
                    listOf("generationConfig", "responseMimeType"),
                    JsonPrimitive(if (value.content == "json") "application/json" else "text/plain"),
                )
                else -> set(source, wire.split('.'), value)
            }
        }
        return set(source, wire.split('.'), value)
    }

    private fun set(source: JsonObject, path: List<String>, value: JsonElement): JsonObject {
        val key = path.firstOrNull() ?: return source
        if (path.size == 1) return JsonObject(source + (key to value))
        val nested = source[key] as? JsonObject ?: JsonObject(emptyMap())
        return JsonObject(source + (key to set(nested, path.drop(1), value)))
    }

    private fun remove(source: JsonObject, path: List<String>): JsonObject {
        val key = path.firstOrNull() ?: return source
        if (path.size == 1) return JsonObject(source - key)
        val nested = source[key] as? JsonObject ?: return source
        return JsonObject(source + (key to remove(nested, path.drop(1))))
    }

    fun isValidGenerationValue(value: JsonElement, parameter: GenerationParameterRef): Boolean {
        val primitive = value as? JsonPrimitive
        val number = primitive?.doubleOrNull
        when (parameter.valueSchema) {
            "number" -> if (number == null || !number.isFinite()) return false
            "integer" -> if (number == null || !number.isFinite() || number % 1.0 != 0.0) return false
            "string-list" -> if (value !is JsonArray || value.any { item ->
                    (item as? JsonPrimitive)?.isString != true
                }) return false
            "boolean" -> if (primitive?.booleanOrNull == null) return false
            "json-schema" -> if (value !is JsonObject ||
                !isWithinJsonSchemaByteLimit(value) ||
                !isValidJsonSchema(value)
            ) return false
            "enum" -> if (primitive?.isString != true) return false
        }
        if (parameter.enumValues.isNotEmpty() && value !in parameter.enumValues) return false
        if (number != null) {
            if (parameter.range?.min?.let { number < it } == true) return false
            if (parameter.range?.max?.let { number > it } == true) return false
            if (parameter.range?.minExclusive?.let { number <= it } == true) return false
            if (parameter.range?.maxExclusive?.let { number >= it } == true) return false
        }
        return true
    }

    /**
     * A JSON Schema is an output contract, not a channel for overwriting the request body.
     * The same ceiling applies as everywhere else, 64 KiB and 32 levels of nesting, so one
     * oversized schema cannot blow up the entire request.
     */
    private fun isWithinJsonSchemaByteLimit(schema: JsonObject): Boolean =
        schema.toString().toByteArray(Charsets.UTF_8).size <= JSON_SCHEMA_MAX_BYTES

    private fun isValidJsonSchema(schema: JsonObject, depth: Int = 0): Boolean {
        if (depth > 32 || schema.isEmpty()) return false
        val type = schema["type"]
        if (type != null && type !is JsonPrimitive && type !is JsonArray) return false
        val properties = schema["properties"]
        if (properties != null && properties !is JsonObject) return false
        val required = schema["required"]
        if (required != null && (required !is JsonArray || required.any { (it as? JsonPrimitive)?.isString != true })) return false
        return properties?.values?.all {
            it is JsonObject && isValidJsonSchema(it, depth + 1)
        } != false
    }
}
