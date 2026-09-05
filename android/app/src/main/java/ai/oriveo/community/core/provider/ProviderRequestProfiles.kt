package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.CapabilityRejectionRule
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.deepMergeJsonObject
import ai.oriveo.community.core.provider.transport.parseJsonObjectOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

internal fun MetadataClient.ResolvedModelMetadata?.allowsTemperature(): Boolean =
    this?.supportsTemperature != false

internal fun capabilityRuntimeContinuationSelection(
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String,
    webRequested: Boolean,
    reasoningMode: ReasoningMode,
): MetadataClient.CapabilityRecipeSelection? = MetadataClient.capabilityRuntimeRequest(
    providerKind, modelID, finalTransport, webRequested, reasoningMode,
)?.selections?.firstOrNull { it.continuationKind != null && it.continuationKind != "none" }

internal fun reasoningMergeParams(
    resolved: MetadataClient.ResolvedModelMetadata?,
    mode: ReasoningMode,
): JsonObject? {
    val profileName = resolved?.profiles?.reasoning ?: return null
    return MetadataClient.reasoningMergeParams(profileName, mode)
}

internal fun effectiveReasoningMode(
    resolved: MetadataClient.ResolvedModelMetadata?,
    requested: ReasoningMode,
): ReasoningMode = MetadataClient.clampReasoningMode(requested, resolved?.profiles?.reasoning)

internal fun mergeParamsIntoBody(bodyJson: String, mergeParams: JsonObject?): String {
    if (mergeParams == null || mergeParams.isEmpty()) return bodyJson
    val base = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
    return deepMergeJsonObject(base, mergeParams).toString()
}

/** Result of compiling a recipe. An unknown case never falls back to guessing a legacy profile. */
internal data class CapabilityRuntimeApplication(
    val body: String,
    val authoritativeRuntime: Boolean,
    val appliedCapabilities: Set<String> = emptySet(),
    val redactedPreviews: List<JsonObject> = emptyList(),
)

/**
 * Compiles the catalog's exact selection into the body the builder has already produced.
 *
 * A missing runtime or exact recipe, a control that cannot be executed, a recipe that oversteps its
 * bounds, and a failed compilation all leave the request as an ordinary one; none of them fall back
 * to guessing a legacy mapping. An explicit local Relay configuration does not come through here.
 */
internal fun applyCapabilityRuntimeRecipes(
    bodyJson: String,
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String,
    webRequested: Boolean,
    reasoningMode: ReasoningMode,
    requestOptions: ChatRequestOptions = ChatRequestOptions(),
): CapabilityRuntimeApplication {
    val customOwners = requestOptions.allLocalCustomFragments().keys
    val request = MetadataClient.capabilityRuntimeRequest(
        providerKind = providerKind,
        modelID = modelID,
        finalTransport = finalTransport,
        webRequested = webRequested || "web" in customOwners,
        reasoningMode = if ("reasoning" in customOwners && reasoningMode == ReasoningMode.Automatic) ReasoningMode.Deep else reasoningMode,
        // Automatic uses the base op, which carries no intent; only force is an explicit intent.
        typedWebIntent = "force".takeIf {
            requestOptions.capabilityPreferences?.web == CapabilityWebPreference.Force
        },
        typedReasoningIntent = requestOptions.capabilityPreferences?.reasoningIntent,
    ) ?: return CapabilityRuntimeApplication(bodyJson, authoritativeRuntime = true)
    var body = parseJsonObjectOrNull(bodyJson)
        ?: return CapabilityRuntimeApplication(bodyJson, authoritativeRuntime = true)
    val previews = mutableListOf<JsonObject>()
    val applied = linkedSetOf<String>()
    for (selection in request.selections.filterNot {
        it.capability in customOwners || it.capability in requestOptions.dormantCapabilityOwners
    }) {
        val baseArrays = mapOf("tools" to body.arrayItems("tools"), "plugins" to body.arrayItems("plugins"))
        val compiled = ProviderRecipeRequestCompiler.compile(
            runtime = request.runtime,
            input = ProviderRecipeRequestCompiler.Input(
                providerKind = selection.providerKind,
                transport = finalTransport,
                recipeRef = selection.id,
                capability = selection.capability,
                selectedIntent = selection.selectedIntent,
                availableIntents = selection.availableIntents,
                baseOwnedArrays = baseArrays,
            ),
        )
        // The recipes of a single send must not take effect partially: otherwise one malicious or
        // drifted neighbouring capability drags the whole request back to the old mapping.
        if (!compiled.accepted || compiled.delta == null) {
            return CapabilityRuntimeApplication(bodyJson, authoritativeRuntime = true)
        }
        val ownedPointers = selection.requestOps.mapNotNull { it.pointer }.toSet()
        val rejectedPointers = requestOptions.rejectedRecipeSettings[selection.capability]
            ?.get(selection.id).orEmpty()
            .intersect(ownedPointers)
        val effectiveDelta = omitExactObjectPointers(compiled.delta, rejectedPointers)
        if (effectiveDelta.isEmpty()) continue
        body = deepMergeJsonObject(body, effectiveDelta)
        val rejectionRules = providerRecipeRejectionRules(
            runtime = request.runtime,
            selection = selection,
            finalTransport = finalTransport,
            ownedPointers = ownedPointers,
            appliedRootKeys = effectiveDelta.keys,
        )
        // The generation owner deliberately stays out of the execution-fact / response-evidence
        // state machine. Every generation recipe in the catalog binds responseEvidenceDefinitions
        // whose signals are an empty array - no provider API echoes back "your temperature took
        // effect" - so such a fact could only ever sit at unconfirmed. And a generation control is
        // present on every assistant message for every provider, so that would pin a constant badge
        // of zero information onto every single message, which reads as "this never got confirmed".
        // Only the after-the-fact badge is turned off here: the recipe still takes part in request
        // compilation as usual, authorizing the legacy template, validating custom fragment paths
        // and transport, and sending the generation parameters.
        // It still registers a private rejection plan: generation's exact recipe-owned setting
        // must be recoverable without inventing a requested/observed badge.
        requestOptions.capabilityExecutionCollector?.recordCompiled(
            owner = selection.capability,
            evidenceSignals = selection.responseEvidenceSignals,
            revision = selection.runtimeRevision,
            recipeRef = selection.id,
            rejectionRules = rejectionRules,
            includeExecutionFact = selection.capability != "generation",
        )
        compiled.redactedPreview
            ?.let { preview -> omitExactObjectPointers(preview, rejectedPointers) }
            ?.takeIf { it.isNotEmpty() }
            ?.let(previews::add)
        applied += selection.capability
    }
    if (requestOptions.localContinuationExplicit && requestOptions.localContinuationState != null) {
        val continuation = request.selections.firstOrNull {
            it.executionKind != "client_tool_loop" && it.continuationKind != null && it.continuationKind != "none"
        }
        if (continuation != null) {
            val mapped = ProviderRecipeExecution.continuation(
                kind = continuation.continuationKind!!,
                variant = continuation.continuationVariant,
                protocol = finalTransport,
                responseParserKind = continuation.responseParserKind,
                intent = RequestPreferenceResolver.ContinuationIntent(
                    kind = continuation.continuationKind,
                    variant = continuation.continuationVariant,
                    step = 1,
                    state = requestOptions.localContinuationState,
                ),
            )
            body = when (mapped) {
                is ProviderRecipeExecution.ContinuationWire.Body -> {
                    val clean = if (continuation.continuationKind == "previous_id") body.onlyNewestUserInput() else body
                    deepMergeJsonObject(clean, mapped.delta)
                }
                is ProviderRecipeExecution.ContinuationWire.Messages -> body.insertBeforeNewestUser("messages", mapped.append)
                is ProviderRecipeExecution.ContinuationWire.Contents -> body.insertBeforeNewestUser("contents", mapped.append)
                is ProviderRecipeExecution.ContinuationWire.Rejected -> body
            }
        }
    }
    return CapabilityRuntimeApplication(
        body = body.toString(),
        authoritativeRuntime = true,
        appliedCapabilities = applied,
        redactedPreviews = previews,
    )
}

/** Resolve a reviewed locator only from the exact envelope/recipe that produced this delta. */
private fun providerRecipeRejectionRules(
    runtime: JsonObject,
    selection: MetadataClient.CapabilityRecipeSelection,
    finalTransport: String,
    ownedPointers: Set<String>,
    appliedRootKeys: Set<String>,
): List<CapabilityRejectionRule> {
    val recipe = (runtime["recipes"] as? JsonObject)?.get(selection.id) as? JsonObject ?: return emptyList()
    val recoveryRef = recipe["errorRecoveryRef"]?.jsonPrimitive?.contentOrNull ?: return emptyList()
    val definition = (runtime["errorRecoveryDefinitions"] as? JsonObject)?.get(recoveryRef) as? JsonObject
        ?: return emptyList()
    if (definition["capability"]?.jsonPrimitive?.contentOrNull != selection.capability) return emptyList()
    if (canonicalCapabilityTransport(definition["protocol"]?.jsonPrimitive?.contentOrNull) !=
        canonicalCapabilityTransport(finalTransport)
    ) return emptyList()
    if (definition["responseParserKind"]?.jsonPrimitive?.contentOrNull != selection.responseParserKind) return emptyList()
    val rules = definition["locatorRules"] as? JsonArray ?: return emptyList()
    return rules.mapNotNull { rawRule ->
        val rule = rawRule as? JsonObject ?: return@mapNotNull null
        val status = rule["status"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null
        val owner = rule["owner"]?.jsonPrimitive?.contentOrNull ?: return@mapNotNull null
        val pointers = (rule["pointers"] as? JsonArray)?.mapNotNull {
            (it as? JsonPrimitive)?.contentOrNull
        }?.toSet().orEmpty()
        val errorFields = rule["errorFields"] as? JsonObject ?: return@mapNotNull null
        val rejectedParameter = (errorFields["/error/param"] as? JsonPrimitive)?.contentOrNull
            ?: return@mapNotNull null
        if (status != 400 || owner != selection.capability || pointers.isEmpty() ||
            !ownedPointers.containsAll(pointers) || errorFields.size != 1 ||
            pointers.any { pointer -> pointerRoot(pointer) !in appliedRootKeys }
        ) return@mapNotNull null
        CapabilityRejectionRule(status, pointers, rejectedParameter)
    }
}

private fun pointerRoot(pointer: String): String? = pointer.takeIf { it.startsWith('/') }
    ?.removePrefix("/")?.substringBefore('/')?.takeIf(String::isNotBlank)

/** Removes only exact recipe-owned object pointers from this send's compiled delta. */
private fun omitExactObjectPointers(body: JsonObject, pointers: Set<String>): JsonObject {
    if (pointers.isEmpty()) return body
    fun remove(current: JsonObject, segments: List<String>): JsonObject? {
        if (segments.isEmpty()) return current
        if (segments.size == 1) return JsonObject(current - segments.first()).takeIf { it.isNotEmpty() }
        val child = current[segments.first()] as? JsonObject ?: return current
        val nextChild = remove(child, segments.drop(1))
        val next = if (nextChild == null) current - segments.first() else current + (segments.first() to nextChild)
        return JsonObject(next).takeIf { it.isNotEmpty() }
    }
    return pointers.fold(body) { current, pointer ->
        val segments = pointer.removePrefix("/").split('/').filter { it.isNotBlank() }
        if (!pointer.startsWith('/') || segments.isEmpty()) current else remove(current, segments) ?: JsonObject(emptyMap())
    }
}

/** Re-applies local-only owner fragments after typed overrides. Each owner is rechecked against
 * the exact final runtime/model/transport and is mutually exclusive with its runtime recipe. */
internal fun applyCapabilityRuntimeCustomFragment(
    bodyJson: String,
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String,
    requestOptions: ChatRequestOptions,
): String {
    val fragments = requestOptions.allLocalCustomFragments().filterKeys { owner ->
        owner !in requestOptions.dormantCapabilityOwners && owner !in requestOptions.rejectedCustomSettings
    }
    if (fragments.isEmpty()) return bodyJson
    var body = parseJsonObjectOrNull(bodyJson) ?: return bodyJson
    fragments.toSortedMap().forEach { (owner, raw) ->
        val authority = safeCustomFragmentAuthority(providerKind, modelID, finalTransport, requestOptions.activeModel?.generationProfile, owner)
            ?: throw ProviderServiceError.InvalidConfiguration("Custom request fragment does not match this model transport.")
        val custom = ProviderRecipeExecution.compileSafeCustom(raw, owner, authority.owners)
        if (!custom.accepted || custom.delta == null) {
            throw ProviderServiceError.InvalidConfiguration("Custom request fragment rejected: ${custom.reason ?: "invalid_fragment"}.")
        }
        if ((custom.delta.leafPointers() intersect body.leafPointers()).isNotEmpty()) {
            throw ProviderServiceError.InvalidConfiguration("Custom request fragment conflicts with a typed request field.")
        }
        body = deepMergeJsonObject(body, custom.delta)
        // Authorization comes from this one snapshot read of `authority`, so revision and owners are
        // read from the same source at the same instant. Hardcoding null would leave this execution
        // fact unable to point back at the revision that authorized it, and if the catalog refreshes
        // before the dispatch is settled, local diagnostics would have no way to tell which version
        // of the recipe approved this outbound request. A Relay has no catalog revision to start
        // with,
        // so null stays the honest value there.
        requestOptions.capabilityExecutionCollector?.recordCustom(
            owner,
            authority.runtimeRevision,
            custom.delta.leafPointers(),
        )
    }
    return body.toString()
}

/** The developer editor calls this production authorization path before it writes local-only JSON.
 * The preview contains JSON pointers only, never the user's values. */
internal fun previewCapabilityRuntimeCustomFragment(
    raw: String,
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String,
    activeProfile: GenerationProfileRef? = null,
    owner: String = "generation",
): ProviderRecipeExecution.CustomResult {
    val owners = safeCustomFragmentAuthority(providerKind, modelID, finalTransport, activeProfile, owner)?.owners
        ?: return ProviderRecipeExecution.CustomResult(false, "transport_or_schema_mismatch")
    return ProviderRecipeExecution.compileSafeCustom(raw, owner, owners)
}

/**
 * The single test for "can this owner really be customized right now" - the entry point and the
 * outbound path must ask the same question.
 *
 * The UI once carried its own, looser test (for a relay it checked only `owner == "generation"`,
 * elsewhere only that owners was non-null) while [applyCapabilityRuntimeCustomFragment] goes through
 * [safeCustomFragmentAuthority]. The result was a dead end: the entry point lit up, but the request
 * could not be sent. Every entry point must ask this function, and no relay/owner branch may be
 * inlined anywhere else.
 */
internal fun capabilityCustomFragmentAvailable(
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
    owner: String,
): Boolean {
    val transport = finalTransport?.takeIf { it.isNotBlank() } ?: return false
    return safeCustomFragmentAuthority(providerKind, modelID, transport, activeProfile, owner) != null
}

/**
 * Which field paths this owner is actually allowed to write for this connection, model and
 * transport.
 *
 * A path-level rejection has to answer the follow-up question, "then what may I write". Saying only
 * "this field is not allowed" leaves the user guessing, and the allowed set is already known on the
 * device because the schema is there, so there is no reason to withhold it. It follows the same rule
 * as [capabilityCustomFragmentAvailable] and [applyCapabilityRuntimeCustomFragment]; no wider or
 * narrower set is maintained separately on the UI side.
 */
internal fun safeCustomAllowedPaths(
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String?,
    activeProfile: GenerationProfileRef?,
    owner: String,
): List<String> {
    val transport = finalTransport?.takeIf { it.isNotBlank() } ?: return emptyList()
    return safeCustomFragmentAuthority(providerKind, modelID, transport, activeProfile, owner)
        ?.owners?.keys?.sorted().orEmpty()
}

/**
 * One source of truth for both editor lint and final body mutation.  Official connections require
 * the catalog's exact generation recipe. Relay has no catalog model recipe, so it may only use the
 * concrete, already-selected local generation profile for the final transport—never a model-id
 * guess or an automatic relay transport.
 */
private data class CustomFragmentAuthority(val owners: Map<String, String>, val runtimeRevision: String?)

private fun safeCustomFragmentAuthority(
    providerKind: ProviderKind,
    modelID: String,
    finalTransport: String,
    activeProfile: GenerationProfileRef?,
    owner: String = "generation",
): CustomFragmentAuthority? {
    if (providerKind == ProviderKind.Relay && owner == "generation") {
        val profile = activeProfile?.takeIf { canonicalCustomTransport(it.transport) == canonicalCustomTransport(finalTransport) }
            ?: return null
        val supportedIds = profile.parameters.mapNotNull { it.id }.toSet()
        val owners = profile.wire.filterKeys(supportedIds::contains).values.associate { wire ->
            "/" + wire.split('.').joinToString("/") { segment -> segment.replace("~", "~0").replace("/", "~1") } to "generation"
        }.takeIf { it.isNotEmpty() } ?: return null
        return CustomFragmentAuthority(owners, runtimeRevision = null)
    }
    return MetadataClient.capabilityCustomControlAuthority(providerKind, modelID, finalTransport, owner)
        ?.let { CustomFragmentAuthority(it.owners, it.runtimeRevision) }
}

private fun ChatRequestOptions.allLocalCustomFragments(): Map<String, String> =
    (localCustomFragments + listOfNotNull(localCustomFragment?.let { localCustomOwner to it })).filterKeys {
        it in setOf("web", "reasoning", "generation")
    }

private fun canonicalCustomTransport(raw: String?): String = when (raw?.lowercase()) {
    "openai_chat", "openai_chat_completions" -> "openai_chat_completions"
    else -> raw?.lowercase().orEmpty()
}

private fun JsonElement.leafPointers(pointer: String = ""): Set<String> = when (this) {
    is JsonObject -> if (isEmpty()) setOf(pointer) else entries.flatMapTo(linkedSetOf()) { (key, value) ->
        value.leafPointers("$pointer/${key.replace("~", "~0").replace("/", "~1")}")
    }
    else -> setOf(pointer)
}

private fun JsonObject.arrayItems(key: String): List<JsonElement> =
    (this[key] as? JsonArray)?.toList().orEmpty()

private fun JsonObject.insertBeforeNewestUser(key: String, append: JsonArray): JsonObject {
    val items = (this[key] as? JsonArray)?.toMutableList() ?: return this
    val index = items.indexOfLast {
        (((it as? JsonObject)?.get("role")) as? JsonPrimitive)?.contentOrNull == "user"
    }.takeIf { it >= 0 } ?: items.size
    items.addAll(index, append)
    return JsonObject(toMutableMap().apply { put(key, JsonArray(items)) })
}

private fun JsonObject.onlyNewestUserInput(): JsonObject {
    val key = when {
        this["input"] is JsonArray -> "input"
        this["messages"] is JsonArray -> "messages"
        this["contents"] is JsonArray -> "contents"
        else -> return this
    }
    val items = (this[key] as JsonArray)
    val newest = items.lastOrNull {
        (((it as? JsonObject)?.get("role")) as? JsonPrimitive)?.contentOrNull == "user"
    } ?: items.lastOrNull() ?: return this
    return JsonObject(toMutableMap().apply { put(key, JsonArray(listOf(newest))) })
}

internal fun webSearchMergeParams(profileName: String?): JsonObject? =
    MetadataClient.webSearchMergeParams(profileName)

internal fun webSearchMaxToolLoops(profileName: String?): Int? =
    MetadataClient.webSearchMaxToolLoops(profileName)

/** Shared strict non-stream parser for the two bespoke OpenAI-chat services. */
internal fun parseOpenAIChatDone(json: kotlinx.serialization.json.Json, raw: String): StreamEvent.Done {
    val root = runCatching { json.parseToJsonElement(raw) as? JsonObject }.getOrNull()
        ?: throw ProviderServiceError.Upstream(200, "Invalid chat completion response.")
    val message = ((root["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)
        ?.get("message") as? JsonObject
    val text = (message?.get("content") as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
    if (text.isEmpty()) throw ProviderServiceError.EmptyResponse
    val usage = root["usage"] as? JsonObject
    return StreamEvent.Done(ProviderChatResult(
        text = text,
        promptTokens = usage?.get("prompt_tokens")?.jsonPrimitive?.intOrNull ?: 0,
        completionTokens = usage?.get("completion_tokens")?.jsonPrimitive?.intOrNull ?: 0,
        reasoningText = (message?.get("reasoning_content") as? JsonPrimitive)?.contentOrNull,
    ))
}

/**
 * The single generation projection entry point used when building a request for a built-in provider.
 *
 * Evidence for those is scoped by provider, model and transport, so no local Relay identity is
 * needed. When the current catalog is missing or the transport is unknown, the facade fails closed
 * by itself; an old support string must never be allowed to authorize an outbound request on its
 * own.
 *
 * Coupling worth knowing about: the legacy-path report of `web_search_used` hangs off exactly one
 * injection point, buildWebSearchJson in OpenAICompatibleService. That works only because this
 * function unconditionally sets permitsOutbound to false for `web_search` on a built-in kind, in
 * both the with-envelope and the without-envelope branch, which leaves a Relay without an envelope
 * as the only live legacy web path. If legacy web dispatch is ever opened up for built-in kinds, the
 * other eight permitsOutbound("web_search") gates (in the Qwen, OpenRouter, OpenAI, Gemini and
 * Anthropic services among others) each have to call noteLegacyWebSearchDispatched() as well, or web
 * search usage is silently under-recorded.
 */
internal fun officialRequestCapabilityProjection(
    providerKind: ProviderKind,
    modelID: String,
    options: ChatRequestOptions,
    reasoningMode: ReasoningMode = ReasoningMode.Automatic,
    webSearchEnabled: Boolean = false,
    messages: List<ChatMessage> = emptyList(),
    toolCallRequested: Boolean = false,
    finalTransport: String,
    runtimeTransport: String = finalTransport,
): CapabilityEvidenceProductionAdapter.Projection {
    val model = options.activeModel?.takeIf { it.id == modelID }
        ?: AIModel(id = modelID, name = modelID)
    val resolved = MetadataClient.resolveCatalogModel(modelID, providerKind)
    val effectiveReasoning = MetadataClient.clampReasoningMode(reasoningMode, resolved?.profiles?.reasoning)
    val keys = buildSet {
        add("generation_parameter/temperature")
        add("generation_parameter/max_tokens")
        add("generation_parameter/max_output_tokens")
        resolved?.profiles?.generation?.parameters.orEmpty().forEach { parameter ->
            parameter.id?.takeIf(String::isNotBlank)?.let { add("generation_parameter/$it") }
        }
        options.generationParameters?.values.orEmpty().keys.forEach { id ->
            if (id.isNotBlank()) add("generation_parameter/$id")
        }
        add("vision_input")
        add("web_search")
        add("tool_call")
        if (reasoningMode != ReasoningMode.Automatic) add("reasoning_level/${effectiveReasoning.rawValue}")
    }
    val explicitKeys = buildSet {
        options.generationParameters?.values.orEmpty().forEach { (id, override) ->
            if (id.isNotBlank() && override.state != GenerationOverrideState.Inherit) {
                add("generation_parameter/$id")
            }
        }
        if (options.temperature != null) add("generation_parameter/temperature")
        if (options.maxTokens != null) {
            add("generation_parameter/max_tokens")
            add("generation_parameter/max_output_tokens")
        }
        if (reasoningMode != ReasoningMode.Automatic) add("reasoning_level/${effectiveReasoning.rawValue}")
        if (webSearchEnabled) add("web_search")
        if (messages.any { it.attachments.orEmpty().any { attachment -> attachment.kind == AttachmentKind.Image } }) {
            add("vision_input")
        }
        if (toolCallRequested) add("tool_call")
    }
    val legacyProjection = CapabilityEvidenceProductionAdapter.capabilityProjection(
        provider = Provider(id = "runtime-${providerKind.rawValue}", kind = providerKind),
        model = model,
        keys = keys,
        explicitKeys = explicitKeys,
        finalTransport = finalTransport,
    )
    val runtime = MetadataClient.capabilityRuntimeRequest(
        providerKind, modelID, runtimeTransport, webRequested = false, reasoningMode = ReasoningMode.Automatic,
    ) ?: return if (providerKind == ProviderKind.Relay) {
        legacyProjection
    } else {
        legacyProjection.copy(
            decisions = legacyProjection.decisions.mapValues { (key, decision) ->
                when {
                    key.startsWith("generation_parameter/") || key.startsWith("reasoning_level/") || key == "web_search" ->
                        decision.copy(permitsOutbound = false)
                    else -> decision
                }
            },
            generationRuntimeAuthorized = false,
            generationRuntimeTemplate = null,
        )
    }
    val generationSelection = runtime.selections.firstOrNull { it.capability == "generation" }
    val generationRawOps = generationSelection?.let { selection ->
        val recipe = (runtime.runtime["recipes"] as? JsonObject)?.get(selection.id) as? JsonObject
        recipe?.get("requestOps") as? JsonArray
    }
    val generationOps = generationRawOps?.mapNotNull { it as? JsonObject }
    val generationTemplate = generationOps?.singleOrNull()
        ?.takeIf { (it["op"] as? JsonPrimitive)?.contentOrNull == "legacy_generation_template" }
        ?.get("template")
        ?.let { it as? JsonPrimitive }
        ?.contentOrNull
    val generationAuthorized = generationSelection?.executionKind == "request_overlay" &&
        generationRawOps?.size == 1 && generationOps?.size == 1 && !generationTemplate.isNullOrBlank()
    return legacyProjection.copy(
        decisions = legacyProjection.decisions.mapValues { (key, decision) ->
            when {
                key.startsWith("generation_parameter/") -> decision.copy(
                    permitsOutbound = generationAuthorized && "generation" !in options.dormantCapabilityOwners,
                )
                // Once a reviewed runtime envelope exists, official web/reasoning fields are
                // written only by applyCapabilityRuntimeRecipes. Letting a legacy projection
                // pre-populate them would make an empty/unknown exact selection non-authoritative.
                key.startsWith("reasoning_level/") ->
                    decision.copy(permitsOutbound = false)
                key == "web_search" ->
                    decision.copy(permitsOutbound = false)
                else -> decision
            }
        },
        generationRuntimeAuthorized = generationAuthorized,
        generationRuntimeTemplate = generationTemplate,
    )
}

/**
 * Runtime self-healing identity for a request to a built-in provider. It must be called after both
 * the dispatch branch and the final URL are settled, and be given the protocol transport and the
 * endpoint actually used for this request. When the local identity is incomplete it returns null.
 * The legacy identity reader is still in place, but a new send does not consume it to drop
 * parameters automatically or to retry.
 */
internal fun officialSelfHealIdentity(
    providerKind: ProviderKind,
    modelID: String,
    options: ChatRequestOptions,
    finalTransport: String,
    finalUrl: String,
): CapabilityEvidenceFacade.QueryIdentity? = CapabilityEvidenceProductionAdapter.officialDispatchIdentity(
    localIdentity = options.capabilityEvidenceIdentity,
    providerKind = providerKind,
    modelId = modelID,
    effectiveTransport = finalTransport,
    finalUrl = finalUrl,
)

/** Final writer vision gate: omit only image attachments; text/file content remains untouched. */
internal fun messagesForCapabilityProjection(
    messages: List<ChatMessage>,
    projection: CapabilityEvidenceProductionAdapter.Projection,
): List<ChatMessage> = if (projection.permitsOutbound("vision_input")) {
    messages
} else {
    messages.map { message ->
        message.copy(attachments = message.attachments.orEmpty().filter { it.kind != AttachmentKind.Image })
    }
}
