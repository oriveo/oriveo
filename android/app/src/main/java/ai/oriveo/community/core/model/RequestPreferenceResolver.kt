package ai.oriveo.community.core.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull


object RequestPreferenceResolver {

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    
    val SCOPE_PRIORITY: List<String> = listOf(
        "single_send",
        "conversation_connection_model",
        "skill_agent",
        "connection_model",
        "connection",
        "provider_recipe",
        "provider_default",
    )

    
    val OWNER_IDS: List<String> = listOf("web", "reasoning", "generation")

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    enum class OverrideState { INHERIT, VALUE, OMIT }

    
    enum class TerminalState { VALUE, OMIT }

    data class Override(val state: OverrideState, val value: JsonElement? = null)

    data class ScopeLayer(val scope: String, val override: Override)

    data class ResolutionOutcome(
        val state: TerminalState,
        val value: JsonElement? = null,
        val source: String,
        val reason: String? = null,
    )

    
    fun resolveLayers(layers: List<ScopeLayer>): ResolutionOutcome {
        val sorted = layers.sortedBy { layer ->
            val index = SCOPE_PRIORITY.indexOf(layer.scope)
            require(index >= 0) { "unknown scope ${layer.scope}" }
            index
        }
        for (layer in sorted) {
            when (layer.override.state) {
                OverrideState.INHERIT -> continue
                OverrideState.OMIT -> return ResolutionOutcome(state = TerminalState.OMIT, source = layer.scope)
                OverrideState.VALUE -> {
                    val value = requireNotNull(layer.override.value) {
                        "${layer.scope}: value state requires a value"
                    }
                    return ResolutionOutcome(state = TerminalState.VALUE, value = value, source = layer.scope)
                }
            }
        }
        return ResolutionOutcome(
            state = TerminalState.OMIT,
            source = "provider_default",
            reason = "no_explicit_or_recipe_value",
        )
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    enum class ControlAvailability { AUTO_AVAILABLE, MANAGED_ONLY, CUSTOM_ONLY, UNAVAILABLE, UNKNOWN }

    enum class ValueMode { PRESET, CUSTOM }

    enum class ConnectionAccess { MANAGED, BYOK_DEVELOPER, RELAY_DEVELOPER }

    data class SelectionIntent(
        val availability: ControlAvailability,
        val selection: ValueMode,
        val access: ConnectionAccess,
    )

    data class SelectionResult(val allowed: Boolean, val reason: String? = null)

    fun resolveSelection(intent: SelectionIntent): SelectionResult {
        val (availability, selection, access) = intent
        if (selection == ValueMode.PRESET) {
            if (availability == ControlAvailability.AUTO_AVAILABLE) return SelectionResult(true)
            if (availability == ControlAvailability.MANAGED_ONLY && access == ConnectionAccess.MANAGED) {
                return SelectionResult(true)
            }
            if (availability == ControlAvailability.UNKNOWN) return SelectionResult(false, "control_unknown")
            return SelectionResult(false, "auto_recipe_unavailable")
        }
        if (availability == ControlAvailability.MANAGED_ONLY || access == ConnectionAccess.MANAGED) {
            return SelectionResult(false, "custom_forbidden")
        }
        if (
            availability == ControlAvailability.CUSTOM_ONLY &&
            (access == ConnectionAccess.BYOK_DEVELOPER || access == ConnectionAccess.RELAY_DEVELOPER)
        ) {
            return SelectionResult(true)
        }
        if (availability == ControlAvailability.AUTO_AVAILABLE && access != ConnectionAccess.MANAGED) {
            return SelectionResult(true)
        }
        if (availability == ControlAvailability.UNKNOWN) return SelectionResult(false, "control_unknown")
        return SelectionResult(false, "custom_unavailable")
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    data class Assignment(val owner: String, val pointer: String)

    data class ConflictResult(val accepted: Boolean, val reason: String? = null)

    fun validateAssignments(assignments: List<Assignment>, declaredConflicts: List<Pair<String, String>>): ConflictResult {
        val seen = mutableMapOf<String, String>()
        for (assignment in assignments) {
            require(assignment.owner in OWNER_IDS) { "unknown owner ${assignment.owner}" }
            val existingOwner = seen[assignment.pointer]
            if (existingOwner != null) {
                val reason = if (existingOwner == assignment.owner) "duplicate_pointer" else "owner_conflict"
                return ConflictResult(false, reason)
            }
            seen[assignment.pointer] = assignment.owner
        }
        val active = assignments.map { it.pointer }.toSet()
        if (declaredConflicts.any { (left, right) -> left in active && right in active }) {
            return ConflictResult(false, "semantic_conflict")
        }
        return ConflictResult(true)
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private val SAFE_OVERLAY_ALLOWED_OPERATIONS = setOf("set", "omit", "upsert_owned_element")
    private val SAFE_OVERLAY_BLOCKED_SEGMENTS = setOf("__proto__", "prototype", "constructor")
    private val SAFE_OVERLAY_BUILDER_OWNED_ROOTS = setOf(
        "model", "messages", "input", "contents", "prompt", "attachments",
        "instructions", "system", "stream", "stream_options", "tools", "tool_choice", "plugins",
    )
    private val SAFE_OVERLAY_TYPED_CONTRIBUTION_ONLY_ROOTS = setOf("tools", "plugins")
    private val SAFE_OVERLAY_SEGMENT_PATTERN = Regex("^[A-Za-z_][A-Za-z0-9_]*$")
    private const val SAFE_OVERLAY_MAX_BYTES = 65536
    private const val SAFE_OVERLAY_MAX_DEPTH = 32
    private const val SAFE_OVERLAY_MAX_NODES = 2048
    private const val SAFE_OVERLAY_MAX_OPERATIONS = 128

    data class OverlayMetrics(val bytes: Int, val depth: Int, val nodes: Int)

    
    data class OverlayOperation(val owner: String, val op: String, val pointer: String, val value: JsonElement? = null)

    data class OverlayIntent(
        val channel: String,
        val metrics: OverlayMetrics,
        val declaredOwners: Map<String, String>,
        val operations: List<OverlayOperation>,
    )

    data class OverlayResult(val accepted: Boolean, val reason: String? = null)

    fun validateOverlay(intent: OverlayIntent): OverlayResult {
        
        if (intent.channel != "body_fragment") return OverlayResult(false, "forbidden_channel")
        if (intent.metrics.bytes > SAFE_OVERLAY_MAX_BYTES) return OverlayResult(false, "size_exceeded")
        if (intent.metrics.depth > SAFE_OVERLAY_MAX_DEPTH) return OverlayResult(false, "depth_exceeded")
        if (intent.metrics.nodes > SAFE_OVERLAY_MAX_NODES) return OverlayResult(false, "node_limit_exceeded")
        if (intent.operations.size > SAFE_OVERLAY_MAX_OPERATIONS) {
            return OverlayResult(false, "operation_limit_exceeded")
        }

        val seenPointers = mutableSetOf<String>()
        for (operation in intent.operations) {
            if (operation.owner !in OWNER_IDS) return OverlayResult(false, "unknown_owner")
            if (operation.op !in SAFE_OVERLAY_ALLOWED_OPERATIONS) return OverlayResult(false, "unknown_operation")
            if (!seenPointers.add(operation.pointer)) return OverlayResult(false, "duplicate_pointer")

            val segments = operation.pointer.split("/").drop(1)
            if (!operation.pointer.startsWith("/") || segments.any { !SAFE_OVERLAY_SEGMENT_PATTERN.matches(it) }) {
                return OverlayResult(false, "invalid_pointer")
            }
            if (segments.any { it in SAFE_OVERLAY_BLOCKED_SEGMENTS }) {
                return OverlayResult(false, "blocked_segment")
            }
            val root = segments.firstOrNull()
            if (root in SAFE_OVERLAY_TYPED_CONTRIBUTION_ONLY_ROOTS && operation.op == "upsert_owned_element" && segments.size == 1) {
                if (operation.owner != "web") return OverlayResult(false, "cross_owner")
                continue
            }
            if (root != null && root in SAFE_OVERLAY_BUILDER_OWNED_ROOTS) {
                val reason = if (root in SAFE_OVERLAY_TYPED_CONTRIBUTION_ONLY_ROOTS) {
                    "typed_contribution_required"
                } else {
                    "builder_owned_root"
                }
                return OverlayResult(false, reason)
            }
            if (operation.value != null && hasBlockedValueKey(operation.value)) return OverlayResult(false, "blocked_value_key")

            val declaredOwner = intent.declaredOwners[operation.pointer] ?: return OverlayResult(false, "unknown_pointer")
            if (declaredOwner != operation.owner) return OverlayResult(false, "cross_owner")
        }
        return OverlayResult(true)
    }

    private fun hasBlockedValueKey(value: JsonElement): Boolean = when (value) {
        is JsonArray -> value.any { hasBlockedValueKey(it) }
        is JsonObject -> value.any { (key, item) -> key in SAFE_OVERLAY_BLOCKED_SEGMENTS || hasBlockedValueKey(item) }
        else -> false
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private val TYPED_CONTRIBUTION_TARGETS = setOf("tools", "plugins")
    private val TYPED_CONTRIBUTION_OPERATIONS = setOf("append_owned")
    private val TYPED_CONTRIBUTION_ALLOWED_OWNER_BY_TARGET = mapOf(
        "tools" to setOf("web"),
        "plugins" to setOf("web"),
    )

    data class ToolContribution(
        val owner: String,
        val target: String,
        val operation: String,
        val identity: String,
        val value: JsonElement? = null,
    )

    data class ContributionResult(val accepted: Boolean, val identities: List<String>? = null, val reason: String? = null)

    fun composeContributions(base: List<String>, contributions: List<ToolContribution>): ContributionResult {
        val identities = base.toMutableList()
        val seen = base.toMutableSet()
        for (contribution in contributions) {
            if (contribution.target !in TYPED_CONTRIBUTION_TARGETS) return ContributionResult(false, reason = "unknown_target")
            if (contribution.operation !in TYPED_CONTRIBUTION_OPERATIONS) {
                return ContributionResult(false, reason = "non_append_operation")
            }
            val allowedOwners = TYPED_CONTRIBUTION_ALLOWED_OWNER_BY_TARGET[contribution.target].orEmpty()
            if (contribution.owner !in allowedOwners) return ContributionResult(false, reason = "owner_not_allowed")
            if (!seen.add(contribution.identity)) return ContributionResult(false, reason = "duplicate_identity")
            identities += contribution.identity
        }
        return ContributionResult(true, identities = identities)
    }

    // ------------------------------------------------------------------
    // P3a transport-neutral owned patch compiler. P3b alone may wire this
    // delta into provider services.
    // ------------------------------------------------------------------

    data class OwnedPatchCompileResult(
        val accepted: Boolean,
        val reason: String? = null,
        val delta: JsonObject? = null,
        val preview: JsonObject? = null,
    )

    fun compileOwnedPatches(
        overlay: OverlayIntent,
        declaredConflicts: List<Pair<String, String>>,
        base: Map<String, List<JsonElement>>,
        contributions: List<ToolContribution>,
    ): OwnedPatchCompileResult {
        validateOverlay(overlay).also { if (!it.accepted) return OwnedPatchCompileResult(false, it.reason) }
        validateAssignments(overlay.operations.map { Assignment(it.owner, it.pointer) }, declaredConflicts).also {
            if (!it.accepted) return OwnedPatchCompileResult(false, it.reason)
        }
        val delta = linkedMapOf<String, JsonElement>()
        overlay.operations.filter { it.op != "omit" && it.op != "upsert_owned_element" }.forEach { operation ->
            if (!setPointer(delta, operation.pointer, operation.value ?: JsonPrimitive(null as String?))) {
                return OwnedPatchCompileResult(false, "pointer_parent_conflict")
            }
        }
        val normalized = contributions.toMutableList()
        for (operation in overlay.operations.filter { it.op == "upsert_owned_element" }) {
            val item = operation.value as? JsonObject ?: return OwnedPatchCompileResult(false, "invalid_typed_contribution")
            val identity = (item["identity"] as? JsonPrimitive)?.contentOrNull ?: return OwnedPatchCompileResult(false, "invalid_typed_contribution")
            val value = item["value"] ?: return OwnedPatchCompileResult(false, "invalid_typed_contribution")
            normalized += ToolContribution(operation.owner, operation.pointer.removePrefix("/"), "append_owned", identity, value)
        }
        for (target in listOf("tools", "plugins")) {
            val selected = normalized.filter { it.target == target }
            if (selected.isEmpty()) continue
            val baseItems = base[target].orEmpty()
            val check = composeContributions(baseItems.map(::canonicalIdentity), selected)
            if (!check.accepted) return OwnedPatchCompileResult(false, check.reason)
            if (selected.any { it.value == null }) return OwnedPatchCompileResult(false, "invalid_typed_contribution")
            delta[target] = JsonArray(baseItems + selected.map { it.value!! })
        }
        val compiled = JsonObject(delta)
        return OwnedPatchCompileResult(true, delta = compiled, preview = redactPreview(compiled) as JsonObject)
    }

    private fun setPointer(root: MutableMap<String, JsonElement>, pointer: String, value: JsonElement): Boolean {
        val segments = pointer.removePrefix("/").split("/")
        if (!pointer.startsWith("/") || segments.isEmpty()) return false
        fun descend(fields: MutableMap<String, JsonElement>, index: Int): Boolean {
            if (index == segments.lastIndex) { fields[segments[index]] = value; return true }
            val existing = fields[segments[index]]
            val child = when (existing) { null -> linkedMapOf(); is JsonObject -> existing.toMutableMap(); else -> return false }
            if (!descend(child, index + 1)) return false
            fields[segments[index]] = JsonObject(child); return true
        }
        return descend(root, 0)
    }

    private fun canonicalIdentity(value: JsonElement): String = when (value) {
        is JsonArray -> value.joinToString(prefix = "[", postfix = "]") { canonicalIdentity(it) }
        is JsonObject -> value.keys.sorted().joinToString(prefix = "{", postfix = "}") { "${JsonPrimitive(it)}:${canonicalIdentity(value[it]!!)}" }
        else -> value.toString()
    }

    private fun redactPreview(value: JsonElement): JsonElement = when (value) {
        is JsonArray -> JsonArray(value.map(::redactPreview))
        is JsonObject -> JsonObject(value.mapValues { (key, item) ->
            if (key.lowercase() in setOf("api_key", "authorization", "prompt", "messages", "attachments", "full_endpoint", "response", "raw_custom_fragment")) JsonPrimitive("[REDACTED]") else redactPreview(item)
        })
        else -> value
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private val OBSERVATION_EVIDENCE_KINDS = setOf(
        "provider_tool_result", "citation", "grounding", "thinking_block", "reasoning_usage",
    )

    data class ResultIntent(
        val wireApplied: Boolean,
        val providerAccepted: Boolean,
        val evidenceKinds: List<String>,
        val recovered: Boolean = false,
    )

    data class ResultClassification(val state: String, val requested: Boolean, val observed: Boolean)

    fun classifyResult(intent: ResultIntent): ResultClassification {
        if (!intent.wireApplied) return ResultClassification("not_requested", requested = false, observed = false)
        if (!intent.providerAccepted) return ResultClassification("rejected", requested = true, observed = false)
        if (intent.recovered) return ResultClassification("recovered", requested = true, observed = false)
        val observed = intent.evidenceKinds.any { it in OBSERVATION_EVIDENCE_KINDS }
        return if (observed) {
            ResultClassification("observed", requested = true, observed = true)
        } else {
            ResultClassification("unconfirmed", requested = true, observed = false)
        }
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    data class ContinuationSpec(val maxSteps: Int, val requiredStateFields: List<String>, val variants: List<String> = emptyList())

    
    val CONTINUATION_KINDS: Map<String, ContinuationSpec> = mapOf(
        "none" to ContinuationSpec(maxSteps = 0, requiredStateFields = emptyList()),
        "previous_id" to ContinuationSpec(maxSteps = 1, requiredStateFields = listOf("previousResponseId")),
        "replay_blocks" to ContinuationSpec(maxSteps = 8, requiredStateFields = listOf("blocks")),
        "replay_reasoning" to ContinuationSpec(maxSteps = 8, requiredStateFields = listOf("assistantMessages")),
        
        
        "tool_loop" to ContinuationSpec(maxSteps = 8, requiredStateFields = listOf("completedMessages"), variants = listOf("default", "fiber")),
    )

    data class ContinuationIntent(
        val kind: String,
        val variant: String? = null,
        val step: Int,
        val state: Map<String, JsonElement> = emptyMap(),
    )

    data class ContinuationResult(val accepted: Boolean, val reason: String? = null)

    fun validateContinuation(intent: ContinuationIntent): ContinuationResult {
        val spec = CONTINUATION_KINDS[intent.kind] ?: return ContinuationResult(false, "unknown_continuation_kind")
        if (intent.variant != null && intent.variant !in spec.variants) {
            return ContinuationResult(false, "unknown_variant")
        }
        if (intent.step < 0 || intent.step > spec.maxSteps) {
            return ContinuationResult(false, "step_limit_exceeded")
        }
        if (spec.requiredStateFields.any { it !in intent.state }) {
            return ContinuationResult(false, "missing_state_field")
        }
        if (intent.kind == "tool_loop" && !validCompletedToolLoop(intent.state["completedMessages"] as? JsonArray)) {
            return ContinuationResult(false, "invalid_tool_loop_state")
        }
        if (intent.kind == "replay_reasoning" && !validReasoningAssistantMessages(intent.state["assistantMessages"] as? JsonArray)) {
            return ContinuationResult(false, "invalid_reasoning_replay_state")
        }
        return ContinuationResult(true)
    }

    private fun validReasoningAssistantMessages(messages: JsonArray?): Boolean {
        messages ?: return false
        if (messages.isEmpty()) return false
        return messages.all { raw ->
            val message = raw as? JsonObject ?: return@all false
            if (isMistralReasoningAssistantMessage(message)) return@all true
            if ((message["role"] as? JsonPrimitive)?.contentOrNull != "assistant") return@all false
            val content = message["content"]
            if (content != null && (content !is JsonPrimitive || !content.isString)) return@all false
            val details = message["reasoning_details"] as? JsonArray
            val hasDetails = details?.isNotEmpty() == true && details.all { it is JsonObject }
            val reasoning = message["reasoning_content"] as? JsonPrimitive
            val hasReasoning = reasoning?.isString == true
            if (hasDetails == hasReasoning) return@all false
            val calls = message["tool_calls"]
            if (calls != null && (calls !is JsonArray || calls.isEmpty() || !calls.all(::validReasoningToolCall))) return@all false
            message.keys.all { it in setOf("role", "content", "reasoning_details", "reasoning_content", "tool_calls") }
        }
    }

    /** Exact Mistral assistant wire shape. Unknown fields and malformed content blocks are rejected;
     * the recipe-specific mapper still owns whether this known shape may reach a provider. */
    fun isMistralReasoningAssistantMessage(message: JsonObject): Boolean {
        if ((message["role"] as? JsonPrimitive)?.contentOrNull != "assistant") return false
        if (!message.keys.all { it in setOf("role", "content", "tool_calls") }) return false
        if (!isMistralAssistantContent(message["content"])) return false
        val calls = message["tool_calls"] ?: return true
        return calls is JsonArray && calls.isNotEmpty() && calls.all(::validMistralToolCall)
    }

    private fun isMistralAssistantContent(content: JsonElement?): Boolean = when (content) {
        is JsonPrimitive -> content.isString
        is JsonArray -> content.isNotEmpty() && content.all(::validMistralContentBlock)
        else -> false
    }

    private fun validMistralContentBlock(raw: JsonElement): Boolean {
        val block = raw as? JsonObject ?: return false
        return when ((block["type"] as? JsonPrimitive)?.contentOrNull) {
            "text" -> block.keys.all { it in setOf("type", "text") } &&
                (block["text"] as? JsonPrimitive)?.isString == true
            "thinking" -> {
                if (!block.keys.all { it in setOf("type", "thinking", "closed") }) return false
                val thinking = block["thinking"] as? JsonArray ?: return false
                val closed = block["closed"]
                (closed == null || ((closed as? JsonPrimitive)?.isString == false && closed.booleanOrNull != null)) && thinking.all { piece ->
                    val text = piece as? JsonObject ?: return@all false
                    text.keys.all { it in setOf("type", "text") } &&
                        (text["type"] as? JsonPrimitive)?.contentOrNull == "text" &&
                        (text["text"] as? JsonPrimitive)?.isString == true
                }
            }
            else -> false
        }
    }

    private fun validReasoningToolCall(raw: JsonElement): Boolean {
        val call = raw as? JsonObject ?: return false
        val function = call["function"] as? JsonObject ?: return false
        val id = call["id"] as? JsonPrimitive
        val type = call["type"] as? JsonPrimitive
        val name = function["name"] as? JsonPrimitive
        return id?.isString == true && id.content.isNotBlank() &&
            type?.isString == true && type.content == "function" &&
            name?.isString == true && name.content.isNotBlank() &&
            (function["arguments"] as? JsonPrimitive)?.isString == true
    }

    private fun validMistralToolCall(raw: JsonElement): Boolean {
        val call = raw as? JsonObject ?: return false
        val function = call["function"] as? JsonObject ?: return false
        return call.keys.all { it in setOf("id", "type", "function") } &&
            function.keys.all { it in setOf("name", "arguments") } && validReasoningToolCall(call)
    }

    private fun validCompletedToolLoop(messages: JsonArray?): Boolean {
        messages ?: return false
        val calls = mutableSetOf<String>(); val pending = mutableSetOf<String>()
        for (element in messages) {
            val message = element as? JsonObject ?: return false
            when ((message["role"] as? JsonPrimitive)?.contentOrNull) {
                "assistant" -> {
                    if (pending.isNotEmpty()) return false
                    (message["tool_calls"] as? JsonArray)?.forEach { raw ->
                    val call = raw as? JsonObject ?: return false
                    val id = (call["id"] as? JsonPrimitive)?.contentOrNull ?: return false
                    val function = call["function"] as? JsonObject ?: return false
                    if ((call["type"] as? JsonPrimitive)?.contentOrNull !in setOf("function", "builtin_function") ||
                        (function["name"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank() ||
                        (function["arguments"] as? JsonPrimitive)?.contentOrNull == null || !calls.add(id) || !pending.add(id)
                    ) return false
                }
                }
                "tool" -> {
                    val id = (message["tool_call_id"] as? JsonPrimitive)?.contentOrNull ?: return false
                    if ((message["content"] as? JsonPrimitive)?.contentOrNull == null || !pending.remove(id)) return false
                }
                else -> return false
            }
        }
        return calls.isNotEmpty() && pending.isEmpty()
    }

    // ------------------------------------------------------------------
    
    
    // ------------------------------------------------------------------

    private const val RETRY_AUTOMATIC_SOURCE = "provider_recipe"
    private const val RETRY_ALLOWED_STATUS = 400
    private const val RETRY_ALLOWED_ERROR_CLASS = "optional_parameter_rejected"
    private const val RETRY_EXPLICIT_RESEND_ACTION = "user_confirmed_resend_without_located_setting"

    data class RetryIntent(
        val source: String,
        val status: Int? = null,
        val errorClass: String,
        val owner: String? = null,
        val locatedPointers: List<String>,
        val preToken: Boolean,
        val streamStarted: Boolean,
        val sideEffects: Boolean,
        val automaticRetryCount: Int,
    )

    data class RetryResult(val retry: Boolean, val action: String)

    fun resolveRetry(intent: RetryIntent): RetryResult {
        val allowed = intent.source in setOf(RETRY_AUTOMATIC_SOURCE, "custom") &&
            intent.status == RETRY_ALLOWED_STATUS &&
            intent.errorClass == RETRY_ALLOWED_ERROR_CLASS &&
            intent.owner != null && intent.owner in OWNER_IDS &&
            intent.locatedPointers.isNotEmpty() &&
            intent.preToken &&
            !intent.streamStarted &&
            !intent.sideEffects &&
            intent.automaticRetryCount == 0
        return if (allowed) {
            RetryResult(false, RETRY_EXPLICIT_RESEND_ACTION)
        } else {
            RetryResult(false, "surface_error")
        }
    }

    // ==================================================================
    
    // ==================================================================

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private const val RUNTIME_ENVELOPE_KEY = "capabilityRuntime"
    private const val RUNTIME_SCHEMA_VERSION = 2
    private val RUNTIME_ENVELOPE_FIELDS = listOf(
        "schemaVersion", "revision", "generatedAt", "recipes", "controlDefinitions", "sourceIndex",
    )

    data class EnvelopeResult(
        val applied: Boolean,
        val action: String,
        val reason: String? = null,
        val chatContinues: Boolean = true,
    )

    
    fun validateEnvelope(payload: JsonObject): EnvelopeResult {
        fun fail(reason: String) = EnvelopeResult(applied = false, action = "ignore_runtime", reason = reason, chatContinues = true)

        val envelopeElement = payload[RUNTIME_ENVELOPE_KEY] ?: return fail("missing_runtime_envelope")
        val envelope = envelopeElement as? JsonObject ?: return fail("missing_runtime_envelope")
        val schemaVersion = (envelope["schemaVersion"] as? JsonPrimitive)?.intOrNull
        if (schemaVersion != RUNTIME_SCHEMA_VERSION) return fail("unknown_schema_version")
        for (field in RUNTIME_ENVELOPE_FIELDS) {
            if (field !in envelope) return fail("missing_envelope_field")
        }
        return EnvelopeResult(applied = true, action = "apply_runtime", chatContinues = true)
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    private val CAPABILITY_CONTROL_KEYS = listOf("web", "reasoning", "generation")
    private val CONTROL_STATES = listOf("auto_available", "managed_only", "custom_only", "unavailable", "unknown")
    private const val NON_AUTO_MIN_SOURCE_REFS = 1

    
    private data class FixedVerdict(val providerKind: String, val state: String, val reasonCode: String, val autoRecipeAllowed: Boolean)
    private val FIXED_VERDICTS = listOf(
        FixedVerdict("relay", "custom_only", "relay_user_directory", autoRecipeAllowed = false),
    )

    
    private data class SourceRefExemption(val providerKind: String, val state: String, val reasonCode: String)
    private val SOURCE_REF_EXEMPTIONS = listOf(
        SourceRefExemption("relay", "custom_only", "relay_user_directory"),
    )

    data class ControlEntry(
        val state: String,
        val recipeRef: String? = null,
        val reasonCode: String? = null,
        val sourceRefs: List<String>? = null,
        val availableIntents: List<String>? = null,
        
        val customControlRefs: List<String>? = null,
    )

    data class ControlResolutionOutcome(val valid: Boolean, val state: String, val action: String, val reason: String? = null)

    data class ControlsResolution(val unknownCapabilities: List<String>, val results: Map<String, ControlResolutionOutcome>)

    
    fun resolveControls(
        providerKind: String,
        capabilityControls: Map<String, ControlEntry>,
        recipes: List<String>,
        sourceIndexKeys: Set<String>,
        
        controlDefinitionOwners: Map<String, String> = emptyMap(),
    ): ControlsResolution {
        val results = linkedMapOf<String, ControlResolutionOutcome>()
        val unknownCapabilities = mutableListOf<String>()
        for ((capability, control) in capabilityControls) {
            if (capability !in CAPABILITY_CONTROL_KEYS) {
                unknownCapabilities += capability
                continue
            }
            results[capability] = resolveControl(providerKind, capability, control, recipes, sourceIndexKeys, controlDefinitionOwners)
        }
        return ControlsResolution(unknownCapabilities, results)
    }

    private fun resolveControl(
        providerKind: String,
        capability: String,
        control: ControlEntry,
        recipes: List<String>,
        sourceIndexKeys: Set<String>,
        controlDefinitionOwners: Map<String, String>,
    ): ControlResolutionOutcome {
        fun noAuto(valid: Boolean, state: String, reason: String?) = ControlResolutionOutcome(valid, state, "no_auto_config", reason)

        if (control.state !in CONTROL_STATES) return noAuto(true, "unknown", "unknown_state")

        val verdict = FIXED_VERDICTS.find { it.providerKind == providerKind }
        if (verdict != null && !verdict.autoRecipeAllowed && control.state == "auto_available") {
            return noAuto(false, verdict.state, "fixed_verdict_violation")
        }

        control.availableIntents?.let { intents ->
            val intentsResult = validateIntents(capability, intents)
            if (!intentsResult.valid) return noAuto(false, control.state, intentsResult.reason)
        }

        
        
        val customRefs = control.customControlRefs.orEmpty()
        if (customRefs.toSet().size != customRefs.size) return noAuto(false, control.state, "invalid_custom_control_refs")
        if (control.state == "managed_only" && customRefs.isNotEmpty()) {
            return noAuto(false, control.state, "managed_custom_control_forbidden")
        }
        for (ref in customRefs) {
            val owner = controlDefinitionOwners[ref] ?: return noAuto(false, control.state, "unresolved_custom_control_ref")
            if (owner != capability) return noAuto(false, control.state, "custom_control_owner_mismatch")
        }

        if (control.state == "auto_available") {
            val recipeRef = control.recipeRef ?: return noAuto(false, "unknown", "missing_recipe_ref")
            if (recipeRef !in recipes) {
                
                return noAuto(true, "unknown", "dangling_recipe_ref")
            }
            return ControlResolutionOutcome(true, "auto_available", "apply_recipe", null)
        }

        if (control.recipeRef != null) return noAuto(false, control.state, "unexpected_recipe_ref")
        if (control.reasonCode.isNullOrEmpty()) return noAuto(false, control.state, "missing_reason_code")

        val exempt = SOURCE_REF_EXEMPTIONS.any {
            it.providerKind == providerKind && it.state == control.state && it.reasonCode == control.reasonCode
        }
        if (!exempt) {
            val refs = control.sourceRefs.orEmpty()
            if (refs.size < NON_AUTO_MIN_SOURCE_REFS) return noAuto(false, control.state, "missing_source_refs")
            if (refs.any { it !in sourceIndexKeys }) return noAuto(false, control.state, "unresolved_source_ref")
        }
        return noAuto(true, control.state, null)
    }

    // ------------------------------------------------------------------
    
    // ------------------------------------------------------------------

    val REASONING_INTENT_LADDER: List<String> = listOf("off", "low", "balanced", "deep", "max")
    private const val REASONING_INTENTS_CAPABILITY = "reasoning"
    /** Force is the only web-search override the v2 catalog contract permits to be advertised. */
    private val WEB_INTENTS: Set<String> = setOf("force")

    data class IntentsResult(val valid: Boolean, val reason: String? = null, val intents: List<String>)

    
    fun validateIntents(capability: String, intents: List<String>): IntentsResult {
        fun fail(reason: String) = IntentsResult(false, reason, intents)

        if (capability == "web") {
            if (intents != WEB_INTENTS.toList()) return fail("invalid_available_intent")
            return IntentsResult(true, reason = null, intents = intents)
        }
        if (capability != REASONING_INTENTS_CAPABILITY) return fail("intents_not_applicable")
        if (intents.any { it !in REASONING_INTENT_LADDER }) return fail("invalid_available_intent")
        if (intents.toSet().size != intents.size) return fail("duplicate_available_intent")
        val positions = intents.map { REASONING_INTENT_LADDER.indexOf(it) }
        for (index in 1 until positions.size) {
            if (positions[index] <= positions[index - 1]) return fail("unordered_available_intents")
        }
        return IntentsResult(true, reason = null, intents = intents)
    }
}
