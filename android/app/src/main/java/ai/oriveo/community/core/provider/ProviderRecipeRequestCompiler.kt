package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RequestPreferenceResolver
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Compilation boundary that turns a capability recipe into an owned request delta.
 *
 * It recognizes no provider and no model id: the exact selector in the model catalog has already
 * made that choice. All this does is check that the choice matches the transport actually in use,
 * and hand the safe requestOps to the shared overlay compiler.
 */
internal object ProviderRecipeRequestCompiler {
    data class Input(
        val providerKind: String,
        val transport: String,
        val recipeRef: String,
        val capability: String,
        val selectedIntent: String? = null,
        val availableIntents: List<String>? = null,
        val baseOwnedArrays: Map<String, List<JsonElement>> = emptyMap(),
    )

    data class Result(
        val accepted: Boolean,
        val reason: String? = null,
        val delta: JsonObject? = null,
        val redactedPreview: JsonObject? = null,
    )

    // Every leg of a client_tool_loop is still the same safe body delta; coordinating the network
    // side of the loop is left to MoonshotService.
    private val supportedExecutionKinds = setOf("request_overlay", "server_tool", "model_route", "client_tool_loop", "endpoint_route")
    private val allowedToolChoices = setOf("auto", "none", "required")

    fun compile(runtime: JsonObject, input: Input): Result {
        val recipes = runtime["recipes"] as? JsonObject ?: return rejected("recipe_not_found")
        val recipe = recipes[input.recipeRef] as? JsonObject ?: return rejected("recipe_not_found")
        if (recipe.string("id") != input.recipeRef) return rejected("recipe_not_found")
        if (recipe.string("providerKind") != input.providerKind) return rejected("provider_mismatch")
        if (recipe.string("capability") != input.capability) return rejected("capability_mismatch")
        if ((recipe["transport"] as? JsonObject)?.string("protocol") != input.transport) {
            return rejected("transport_mismatch")
        }
        val executionKind = recipe.string("executionKind") ?: return rejected("unknown_execution_kind")
        if (executionKind !in supportedExecutionKinds) return rejected("unknown_execution_kind")
        if (input.selectedIntent != null && input.selectedIntent !in input.availableIntents.orEmpty()) {
            return rejected("intent_not_available")
        }

        val rawOps = recipe["requestOps"] as? JsonArray ?: return rejected("invalid_request_ops")
        if (executionKind == "model_route" && rawOps.isNotEmpty()) return rejected("model_route_must_not_patch_body")
        val legacyTemplateOps = rawOps.mapNotNull { it as? JsonObject }
            .filter { it.string("op") == "legacy_generation_template" }
        if (legacyTemplateOps.isNotEmpty() && (
                input.capability != "generation" || executionKind != "request_overlay" ||
                    rawOps.size != 1 || legacyTemplateOps.size != 1 ||
                    legacyTemplateOps.single().string("template").isNullOrBlank()
                )) return rejected("invalid_request_ops")

        val owner = when (input.capability) {
            "web" -> "web"
            "reasoning" -> "reasoning"
            "generation" -> "generation"
            else -> return rejected("capability_mismatch")
        }
        val declarations = linkedMapOf<String, String>()
        val operations = mutableListOf<RequestPreferenceResolver.OverlayOperation>()
        var toolChoice: JsonElement? = null
        // requestOpMerge from the shared contract: last-specific-wins. It has to be resolved before
        // the operations are executed one by one, otherwise the forced setting would run the base op
        // and the specialized op both.
        val mergedOps = mergeRequestOps(rawOps, input.selectedIntent) ?: return rejected("invalid_request_ops")
        val appendedIdentities = mutableSetOf<String>()
        mergedOps.forEach { raw ->
            when (raw.string("op")) {
                "set" -> {
                    val pointer = raw.string("pointer") ?: return rejected("invalid_request_ops")
                    val value = raw["value"] ?: return rejected("invalid_request_ops")
                    // `tool_choice` is the only builder-owned field a server_tool recipe is allowed
                    // to touch. The generic overlay defence deliberately rejects it, and that global
                    // rule must not be relaxed. Here it is confined to OpenAI's fixed vocabulary and
                    // then merged into the delta the overlay compiler produced.
                    if (pointer == "/tool_choice") {
                        if (owner != "web" || toolChoice != null ||
                            (value as? JsonPrimitive)?.contentOrNull !in allowedToolChoices
                        ) return rejected("invalid_request_ops")
                        toolChoice = value
                        return@forEach
                    }
                    declarations[pointer] = owner
                    operations += RequestPreferenceResolver.OverlayOperation(owner, "set", pointer, value)
                }
                "append" -> {
                    val pointer = raw.string("pointer") ?: return rejected("invalid_request_ops")
                    val value = raw["value"] ?: return rejected("invalid_request_ops")
                    // Step 5 of the requestOpMerge contract: an append pointer must end in "/-",
                    // which means "append to the end of the array". Without the suffix the pointer
                    // refers to the whole array, which is a different thing entirely. This used to
                    // call removeSuffix unconditionally, so a malformed
                    // {"op":"append","pointer":"/tools"} was silently accepted as a valid append and
                    // the same recipe compiled into something the contract does not describe.
                    if (!pointer.endsWith("/-")) return rejected("invalid_request_ops")
                    val target = pointer.removeSuffix("/-")
                    if (target !in setOf("/tools", "/plugins")) return rejected("invalid_request_ops")
                    // Also step 5: skip an element whose stable JSON already appears in the target
                    // array, including the entries the builder owns in baseOwnedArrays, so no
                    // duplicate is produced. The overlay compiler's composeContributions rejects a
                    // duplicate identity outright, so deduplication has to be finished here first.
                    val identity = canonicalIdentity(value)
                    val baseIdentities = input.baseOwnedArrays[target.removePrefix("/")]
                        .orEmpty().map(::canonicalIdentity)
                    if (identity in baseIdentities || !appendedIdentities.add(identity)) return@forEach
                    operations += RequestPreferenceResolver.OverlayOperation(
                        owner = owner,
                        op = "upsert_owned_element",
                        pointer = target,
                        value = JsonObject(mapOf("identity" to JsonPrimitive(canonicalIdentity(value)), "value" to value)),
                    )
                }
                // Bridge: generation parameters are still emitted by the typed legacy template
                // resolver. The published capability recipe authorizes exactly that transport but
                // deliberately contributes no body delta of its own.
                "legacy_generation_template" -> {
                    if (owner != "generation" || raw.string("template").isNullOrBlank()) {
                        return rejected("invalid_request_ops")
                    }
                }
                else -> return rejected("invalid_request_ops")
            }
        }

        val metrics = metrics(operations)
        val compiled = RequestPreferenceResolver.compileOwnedPatches(
            overlay = RequestPreferenceResolver.OverlayIntent(
                channel = "body_fragment",
                metrics = metrics,
                declaredOwners = declarations,
                operations = operations,
            ),
            declaredConflicts = emptyList(),
            base = input.baseOwnedArrays,
            contributions = emptyList(),
        )
        if (!compiled.accepted || compiled.delta == null) {
            return Result(compiled.accepted, compiled.reason, compiled.delta, compiled.preview)
        }
        val delta = JsonObject(compiled.delta + listOfNotNull(toolChoice?.let { "tool_choice" to it }).toMap())
        // tool_choice has already been constrained to a fixed, non-sensitive vocabulary; the rest of
        // the preview still comes from the overlay compiler's redactor.
        val preview = JsonObject((compiled.preview ?: JsonObject(emptyMap())) + listOfNotNull(toolChoice?.let { "tool_choice" to it }).toMap())
        return Result(accepted = true, delta = delta, redactedPreview = preview)
    }

    private fun rejected(reason: String) = Result(accepted = false, reason = reason)

    /**
     * requestOpMerge from the shared request-compiler contract.
     *
     * 1. Drop every foreign op: one whose intent is present and differs from selectedIntent. When
     *    selectedIntent is null, only base ops survive.
     * 2. Group by pointer: if a group contains even one specific op, every base op in that group is
     *    dropped - regardless of the order they were written in. That independence from write order
     *    is exactly what separates last-specific-wins from last-write-wins.
     * 3. The remaining ops keep their original relative order from requestOps.
     */
    private fun mergeRequestOps(rawOps: JsonArray, selectedIntent: String?): List<JsonObject>? {
        val objects = rawOps.map { it as? JsonObject ?: return null }
        val applicable = objects.filter { op ->
            val intent = op.string("intent")
            intent == null || intent == selectedIntent
        }
        val pointersWithSpecificOp = applicable
            .filter { it.string("intent") != null }
            .mapNotNull { it.string("pointer") }
            .toSet()
        return applicable.filter { op ->
            op.string("intent") != null || op.string("pointer") !in pointersWithSpecificOp
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun metrics(operations: List<RequestPreferenceResolver.OverlayOperation>): RequestPreferenceResolver.OverlayMetrics {
        val bytes = operations.sumOf { it.pointer.length + (it.value?.toString()?.length ?: 0) }
        val values = operations.mapNotNull { it.value }
        return RequestPreferenceResolver.OverlayMetrics(
            bytes = bytes,
            depth = values.maxOfOrNull(::depth) ?: 0,
            nodes = values.sumOf(::nodes),
        )
    }

    private fun depth(value: JsonElement): Int = when (value) {
        is JsonObject -> 1 + (value.values.maxOfOrNull(::depth) ?: 0)
        is JsonArray -> 1 + (value.maxOfOrNull(::depth) ?: 0)
        else -> 1
    }

    private fun nodes(value: JsonElement): Int = when (value) {
        is JsonObject -> 1 + value.values.sumOf(::nodes)
        is JsonArray -> 1 + value.sumOf(::nodes)
        else -> 1
    }

    private fun canonicalIdentity(value: JsonElement): String = when (value) {
        is JsonArray -> value.joinToString(prefix = "[", postfix = "]", transform = ::canonicalIdentity)
        is JsonObject -> value.keys.sorted().joinToString(prefix = "{", postfix = "}") {
            "${JsonPrimitive(it)}:${canonicalIdentity(value[it]!!)}"
        }
        else -> value.toString()
    }
}
