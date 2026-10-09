package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
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
import kotlinx.serialization.json.longOrNull

/** The runtime's legacy template must equal profile.template before anything is injected; a blank template never matches. */
internal fun legacyGenerationTemplatesMatch(runtimeTemplate: String?, profileTemplate: String?): Boolean =
    !runtimeTemplate.isNullOrBlank() && !profileTemplate.isNullOrBlank() && runtimeTemplate == profileTemplate

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
    internal val builderOwnedRootFields = setOf(
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

    /** [dedupe]: metadata re-validates the same published entry on every parse, and without it repeats would crowd out other diagnostics. */
    internal fun recordWireRejection(parameterId: String, wirePath: String, reason: WireRejectionReason, dedupe: Boolean = false) {
        synchronized(wireDiagnostics) {
            val diagnostic = WireDiagnostic(parameterId, wirePath, reason)
            if (dedupe && diagnostic in wireDiagnostics) return
            wireDiagnostics.addLast(WireDiagnostic(parameterId, wirePath, reason))
            while (wireDiagnostics.size > DIAGNOSTIC_CAPACITY) wireDiagnostics.removeFirst()
        }
    }

    enum class DropReason(val wireName: String) {
        InvalidValue("invalid_value"),
        Conflict("conflict"),
        RequirementUnmet("requirement_unmet"),
        RequiredField("required_field"),
        ThinkingIncompatible("thinking_incompatible"),
        ThinkingBudget("thinking_budget"),
    }

    data class DroppedParameter(val parameterId: String, val reason: DropReason)

    data class Result(val body: String, val dropped: List<DroppedParameter>)

    // Shared contract outboundRules.requiredWireFields / anthropicThinking.
    private val requiredWireFields = mapOf("anthropic_messages" to setOf("max_tokens"))
    private val thinkingIncompatibleParameters = setOf("temperature", "top_k")
    private const val THINKING_TOP_P_MIN = 0.95
    private const val THINKING_MAX_TOKENS_HEADROOM = 4096L
    // Shared contract modelLevelFacts.maxTokensWire.aliases: both names address one upstream field, so a request body may carry only one.
    private val maxTokensAliases = setOf("max_tokens", "max_completion_tokens")

    /** Compatibility entry point for callers that only need the body. */
    fun apply(
        body: String,
        options: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
        outboundTemplate: String? = null,
    ): String = applyWithResult(body, options, resolved, capabilityProjection, outboundTemplate).body

    /**
     * Evaluates each parameter on its own: an invalid, conflicting or unmet item drops only itself.
     * [outboundTemplate] comes from a builder that knows its wire protocol, so the thinking guard
     * still holds when no profile is available.
     */
    fun applyWithResult(
        body: String,
        options: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
        outboundTemplate: String? = null,
    ): Result {
        val parsed = try {
            json.parseToJsonElement(body).jsonObject
        } catch (_: Exception) {
            return Result(body, emptyList())
        }
        val profile = authorizedProfile(options, resolved, capabilityProjection)
        val template = outboundTemplate ?: profile?.template
        val dropped = mutableListOf<DroppedParameter>()
        val builderMaxTokens = parsed["max_tokens"]
        var root = parsed
        val written = mutableMapOf<String, JsonElement>()
        val omittedKeys = mutableSetOf<String>()
        val overrides = options.generationParameters?.values
        if (profile != null && overrides != null) {
            val accepted = acceptValues(overrides, profile, toolsActive = root["tools"] is JsonArray, dropped)
            for (key in orderedKeys(overrides, profile)) {
                val override = overrides.getValue(key)
                if (override.state == GenerationOverrideState.Inherit) continue
                val wire = profile.wire[key] ?: continue
                // The request boundary may only consume the projection from this same facade. A
                // caller without a final dispatch scope must not resurrect a parameter through an
                // older carrier or an allowUnknown escape hatch, and tests have to supply the
                // projection explicitly.
                val allowed = when (capabilityProjection?.generationRuntimeAuthorized) {
                    true -> legacyGenerationTemplatesMatch(capabilityProjection.generationRuntimeTemplate, profile.template)
                    false -> false
                    null -> capabilityProjection?.permitsOutbound("generation_parameter/$key") == true
                }
                if (!allowed) continue
                val rejection = wireRejectionReason(wire)
                if (rejection != null) {
                    recordWireRejection(key, wire, rejection)
                    continue
                }
                when (override.state) {
                    GenerationOverrideState.Omit -> if (wire in template?.let(requiredWireFields::get).orEmpty()) {
                        dropped += DroppedParameter(key, DropReason.RequiredField)
                    } else {
                        root = remove(root, wire.split('.'))
                        omittedKeys += key
                    }
                    GenerationOverrideState.Value -> accepted[key]?.let {
                        val strict = profile.parameters.firstOrNull { parameter -> parameter.id == key }?.strict == true
                        root = applySpecializedOutputContract(root, profile.template, key, wire, it, strict)
                        written[key] = it
                    }
                    GenerationOverrideState.Inherit -> Unit
                }
            }
        }
        if (profile != null) root = keepSingleMaxTokensName(root, profile, omitted = "max_output_tokens" in omittedKeys)
        if (template == "anthropic_messages") {
            root = guardAnthropicThinking(root, profile, written, builderMaxTokens, dropped)
        }
        if (root === parsed && dropped.isEmpty()) return Result(body, emptyList())
        return Result(root.toString(), dropped.sortedBy { it.parameterId })
    }

    private fun authorizedProfile(
        options: ChatRequestOptions,
        resolved: MetadataClient.ResolvedModelMetadata?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection?,
    ): GenerationProfileRef? {
        val profile = if (capabilityProjection?.identity?.providerKind == ProviderKind.Relay.rawValue) {
            options.activeModel?.generationProfile ?: resolved?.profiles?.generation
        } else {
            resolved?.profiles?.generation
        } ?: return null
        // v2 exact recipe is the generation authorization source. Its legacy-template bridge
        // must match the profile that owns schema/wire; runtime miss/invalid is a hard zero delta.
        when (capabilityProjection?.generationRuntimeAuthorized) {
            false -> return null
            true -> if (!legacyGenerationTemplatesMatch(capabilityProjection.generationRuntimeTemplate, profile.template)) return null
            null -> Unit // runtime genuinely absent: retain the legacy evidence compatibility path.
        }
        return profile.takeIf { it.wire.isNotEmpty() }
    }

    /** Conflicts keep whichever item the profile declares first, so iteration follows declaration order. */
    private fun orderedKeys(
        overrides: Map<String, GenerationParameterOverride>,
        profile: GenerationProfileRef,
    ): List<String> {
        val declared = profile.parameters.mapNotNull { it.id }.filter(overrides::containsKey)
        return declared + overrides.keys.filterNot(declared::contains)
    }

    private fun acceptValues(
        overrides: Map<String, GenerationParameterOverride>,
        profile: GenerationProfileRef,
        toolsActive: Boolean,
        dropped: MutableList<DroppedParameter>,
    ): Map<String, JsonElement> {
        val parameters = profile.parameters.filter { it.id != null }.associateBy { it.id!! }
        val valid = linkedMapOf<String, JsonElement>()
        for (key in orderedKeys(overrides, profile)) {
            val override = overrides.getValue(key)
            if (override.state != GenerationOverrideState.Value) continue
            val value = override.value
            val parameter = parameters[key]
            if (value == null || (parameter != null && !isValidGenerationValue(value, parameter))) {
                dropped += DroppedParameter(key, DropReason.InvalidValue)
            } else {
                valid[key] = value
            }
        }
        val satisfied = valid.filterKeys { key ->
            val unmet = parameters[key]?.requires.orEmpty().any { requirement ->
                val requiredKey = requirement["key"]?.let { (it as? JsonPrimitive)?.contentOrNull } ?: return@any true
                requiredKey !in valid || requirement["value"]?.let { valid[requiredKey] != it } == true
            }
            if (unmet) dropped += DroppedParameter(key, DropReason.RequirementUnmet)
            !unmet
        }
        val accepted = linkedMapOf<String, JsonElement>()
        val present = if (toolsActive) mutableSetOf("tools") else mutableSetOf()
        for ((key, value) in satisfied) {
            val conflicts = parameters[key]?.conflictsWith.orEmpty().any(present::contains) ||
                present.any { other -> parameters[other]?.conflictsWith?.contains(key) == true }
            if (conflicts) {
                dropped += DroppedParameter(key, DropReason.Conflict)
            } else {
                accepted[key] = value
                present += key
            }
        }
        return accepted
    }

    /** Thinking is written by the capability layer before this resolver runs, so the value seen here is final. */
    private fun guardAnthropicThinking(
        source: JsonObject,
        profile: GenerationProfileRef?,
        written: Map<String, JsonElement>,
        builderMaxTokens: JsonElement?,
        dropped: MutableList<DroppedParameter>,
    ): JsonObject {
        val thinking = source["thinking"] as? JsonObject ?: return source
        val type = (thinking["type"] as? JsonPrimitive)?.contentOrNull
        if (type != "enabled" && type != "adaptive") return source
        var root = source
        for ((key, value) in written) {
            val wire = profile?.wire?.get(key) ?: continue
            val incompatible = key in thinkingIncompatibleParameters ||
                (key == "top_p" && ((value as? JsonPrimitive)?.doubleOrNull ?: 0.0) < THINKING_TOP_P_MIN)
            if (incompatible) {
                root = remove(root, wire.split('.'))
                dropped += DroppedParameter(key, DropReason.ThinkingIncompatible)
            }
        }
        // Decided on the request body: values the builder wrote itself (a legacy temperature and the like) are dropped too, but they are not panel values and stay off the dropped list.
        for (field in thinkingIncompatibleParameters) {
            if (field in root) root = JsonObject(root - field)
        }
        val budget = (thinking["budget_tokens"] as? JsonPrimitive)?.longOrNull ?: return root
        val maxTokensKey = profile?.wire?.entries?.firstOrNull { it.value == "max_tokens" }?.key
        val userMaxTokens = maxTokensKey?.let(written::get)
        if (userMaxTokens != null && ((userMaxTokens as? JsonPrimitive)?.doubleOrNull ?: 0.0) <= budget) {
            root = if (builderMaxTokens != null) set(root, listOf("max_tokens"), builderMaxTokens) else remove(root, listOf("max_tokens"))
            dropped += DroppedParameter(maxTokensKey, DropReason.ThinkingBudget)
        }
        val current = (root["max_tokens"] as? JsonPrimitive)?.doubleOrNull
        if (current == null || current <= budget) {
            root = set(root, listOf("max_tokens"), JsonPrimitive(budget + THINKING_MAX_TOKENS_HEADROOM))
        }
        return root
    }

    /**
     * Keeps one max-tokens name: a default the builder wrote under the other name moves to the resolved path; when the user set a value or chose omit, the other name is simply removed.
     */
    private fun keepSingleMaxTokensName(source: JsonObject, profile: GenerationProfileRef, omitted: Boolean): JsonObject {
        val resolvedWire = profile.wire["max_output_tokens"]?.takeIf { it in maxTokensAliases } ?: return source
        val other = (maxTokensAliases - resolvedWire).single()
        val builderValue = source[other] ?: return source
        val root = JsonObject(source - other)
        if (omitted || resolvedWire in root) return root
        return JsonObject(root + (resolvedWire to builderValue))
    }

    private fun applySpecializedOutputContract(
        source: JsonObject,
        template: String?,
        parameterID: String,
        wire: String,
        value: JsonElement,
        strict: Boolean,
    ): JsonObject {
        if (parameterID == "json_schema" && value is JsonObject) {
            return when (template) {
                "openai_chat_completions", "vllm_extra_body" -> set(
                    source,
                    listOf("response_format"),
                    JsonObject(mapOf(
                        "type" to JsonPrimitive("json_schema"),
                        "json_schema" to JsonObject(buildMap {
                            put("name", JsonPrimitive("oriveo_response"))
                            if (strict) put("strict", JsonPrimitive(true))
                            put("schema", value)
                        }),
                    )),
                )
                "openai_responses" -> set(
                    source,
                    listOf("text", "format"),
                    JsonObject(buildMap {
                        put("type", JsonPrimitive("json_schema"))
                        put("name", JsonPrimitive("oriveo_response"))
                        if (strict) put("strict", JsonPrimitive(true))
                        put("schema", value)
                    }),
                )
                // The top-level output_format is deprecated; the format shares one output_config object with the thinking effort.
                "anthropic_messages" -> set(
                    remove(source, listOf("output_format")),
                    listOf("output_config", "format"),
                    JsonObject(mapOf("type" to JsonPrimitive("json_schema"), "schema" to value)),
                )
                "gemini_generate_content" -> set(
                    set(source, listOf("generationConfig", "responseMimeType"), JsonPrimitive("application/json")),
                    listOf("generationConfig", "responseJsonSchema"),
                    value,
                )
                // The native /completion endpoint takes the bare schema and no response_format wrapper.
                "llamacpp_native" -> set(source, wire.split('.'), value)
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
        // doubleOrNull / booleanOrNull happily parse strings like "0.7" or "true"; reject strings first.
        val number = primitive?.takeUnless { it.isString }?.doubleOrNull
        when (parameter.valueSchema) {
            "number" -> if (number == null || !number.isFinite()) return false
            "integer" -> if (number == null || !number.isFinite() || number % 1.0 != 0.0) return false
            "string-list" -> if (value !is JsonArray || value.any { item ->
                    (item as? JsonPrimitive)?.isString != true
                }) return false
            "boolean" -> if (primitive == null || primitive.isString || primitive.booleanOrNull == null) return false
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
