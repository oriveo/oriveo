package ai.oriveo.community.core.provider

import ai.oriveo.community.core.capability.truth.CapabilityTruthAdapter
import ai.oriveo.community.core.capability.truth.CapabilityTruthRegistry
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.capability.truth.SubscriptionTruthAdapter
import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayTransport

/** The single thin adapter from production provider, model and catalog data to the pure facade. */
internal object CapabilityEvidenceProductionAdapter {
    /** Current-publication reasoning clamp for presentation and request intent; Relay keeps its local selection. */
    fun effectiveReasoningMode(
        provider: Provider,
        model: AIModel,
        requested: ReasoningMode,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): ReasoningMode = if (ProviderForm.of(provider) == ProviderForm.Relay) {
        requested
    } else {
        val current = metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)
        metadataClient.clampReasoningMode(requested, current?.metadata?.profiles?.reasoning)
    }

    data class Decision(
        val resolution: CapabilityEvidenceFacade.Resolution,
        val visible: Boolean,
        val editable: Boolean,
        val permitsOutbound: Boolean,
        val isUnverified: Boolean = false,
    )

    data class Projection(
        val identity: CapabilityEvidenceFacade.QueryIdentity?,
        val decisions: Map<String, Decision>,
        val contentRevision: Long,
        val nextExpiryAt: Long?,
        /** null = runtime absent/legacy compatibility; true/false = v2 exact generation authority. */
        val generationRuntimeAuthorized: Boolean? = null,
        val generationRuntimeTemplate: String? = null,
    ) {
        fun decision(key: String): Decision? = decisions[key]
        fun permitsOutbound(key: String): Boolean = decisions[key]?.permitsOutbound == true
    }

    /**
     * Support level of an input key: supported / unsupported as is, a user-accepted but unverified declaration is accepted, anything else null.
     * The grade literal stays inside the evidence boundary so read sites do not judge it themselves.
     */
    fun inputSupportLevel(resolution: CapabilityEvidenceFacade.Resolution): String? = when {
        resolution.support == "supported" || resolution.support == "unsupported" -> resolution.support
        resolution.grade == "accepted_unverified" -> "accepted"
        else -> null
    }

    /**
     * The projection shared by the UI, the lifecycle rules and the request boundary. A
     * relay that lacks a final identity keeps the visibility its declaration implies, but
     * editable and outbound must fail closed.
     */
    fun capabilityProjection(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        keys: Set<String>,
        explicitKeys: Set<String> = emptySet(),
        finalTransport: String? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
        now: Long = System.currentTimeMillis(),
    ): Projection {
        val form = ProviderForm.of(provider)
        val current = when (form) {
            // Only the official form has its truth in the official metadata: a subscription has its own catalog
            // snapshot, and a relay's catalog comes from the user's own machine.
            ProviderForm.Official -> metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)
            else -> null
        }
        val evidenceModel = current?.metadata
        val effectiveTransport = when (form) {
            ProviderForm.Relay -> identity?.effectiveTransport
            // A subscription link has only one road and does not depend on the catalog (it is not in the catalog at all).
            ProviderForm.Subscription ->
                finalTransport ?: CapabilityControlResolution.subscriptionFinalTransport(provider, model)
            // Final writers are authorised for their actual dispatch transport. The evidence
            // declaration remains the candidate identity, so a declared transport that differs
            // from this final branch fails closed as an identity mismatch.
            else -> finalTransport ?: evidenceModel?.transport
        }
        // Identity when the official metadata has no entry for this model: a subscription always takes this path
        // (its truth is not in metadata; the revision follows the official metadata ETag), and for the official
        // form it is the fallback for an absent catalog.
        fun identityWithoutEvidenceModel() = CapabilityEvidenceFacade.QueryIdentity(
            partitionId = identity?.partitionId.orEmpty(),
            connectionInstanceId = identity?.connectionInstanceId.orEmpty(),
            connectionGeneration = identity?.connectionGeneration.orEmpty(),
            credentialEpoch = identity?.credentialEpoch.orEmpty(),
            providerKind = provider.kind.rawValue,
            authMode = provider.authMode.rawValue,
            modelId = model.id,
            canonicalModelId = MetadataClient.normalizeModelFactsID(model.id),
            effectiveTransport = effectiveTransport.orEmpty(),
            endpointFingerprint = identity?.endpointFingerprint,
            metadataRevision = metadataClient.currentMetadataRevision(),
        )
        // State 1 of the capability-truth contract: when this form's catalog snapshot has never been fetched (or the
        // fetch failed and it was cleared), the identity of the keys the catalog owns is incomplete. That is not
        // "we have no evidence", so the explicit-intent escape hatch must not let it through.
        val snapshotFetched = when (form) {
            ProviderForm.Subscription -> provider.catalogModels.isNotEmpty()
            else -> true
        }
        val queryIdentity = if (!CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport)) {
            null
        } else when (form) {
            ProviderForm.Relay -> identity?.takeIf(::isCompleteRelayIdentity)
            ProviderForm.Subscription -> identityWithoutEvidenceModel()
            else ->
                if (evidenceModel == null) identityWithoutEvidenceModel()
                else CapabilityEvidenceFacade.QueryIdentity(
                        partitionId = identity?.partitionId.orEmpty(),
                        connectionInstanceId = identity?.connectionInstanceId.orEmpty(),
                        connectionGeneration = identity?.connectionGeneration.orEmpty(),
                        credentialEpoch = identity?.credentialEpoch.orEmpty(),
                        providerKind = provider.kind.rawValue,
                        authMode = provider.authMode.rawValue,
                        modelId = model.id,
                        canonicalModelId = evidenceModel.canonicalModelId,
                        effectiveTransport = effectiveTransport.orEmpty(),
                        endpointFingerprint = identity?.endpointFingerprint,
                        metadataRevision = current.metadataRevision,
                        generationRevision = current.generationRevision,
                )
        }

        // Explicit intent of a closed-world form is dropped right here, so the facade need not know the form.
        val honoredExplicitKeys = if (CapabilityTruthRegistry.adapterFor(form).acceptsUnverifiedExplicitIntent) {
            explicitKeys
        } else {
            emptySet()
        }
        val decisions = keys.associateWith { key ->
            val candidates = candidatesForKey(
                provider = provider,
                persistedModel = model,
                current = current,
                queryIdentity = queryIdentity,
                key = key,
                finalTransport = finalTransport,
                metadataClient = metadataClient,
            )
            // Decide per key whether the identity holds: a catalog-owned key has an incomplete identity in state 1;
            // the keys a subscription catalog does not own (a subscription's tool_call goes through first-party
            // declarations and model facts) are not affected by the catalog state.
            val keyIdentity = queryIdentity?.takeIf {
                when (form) {
                    ProviderForm.Subscription -> snapshotFetched || !catalogOwnedKey(key)
                    else -> true
                }
            }
            val resolution = if (keyIdentity == null) {
                CapabilityEvidenceFacade.resolve(
                    key = key,
                    query = CapabilityEvidenceFacade.Query(
                        identity = incompleteIdentity(provider, model),
                        now = now,
                        hasExplicitValue = key in honoredExplicitKeys,
                    ),
                    candidates = candidates,
                )
            } else {
                CapabilityEvidenceFacade.resolve(
                    key = key,
                    query = CapabilityEvidenceFacade.Query(
                        identity = keyIdentity,
                        now = now,
                        hasExplicitValue = key in honoredExplicitKeys,
                    ),
                    candidates = candidates,
                )
            }
            val declaration = candidates.firstOrNull { it.key == key }
            val acceptedRelayDeclaration = declaration?.source == "relay_declaration" &&
                declaration.grade == "accepted_unverified" && declaration.support != "unsupported"
            Decision(
                resolution = resolution,
                // A connection scope is a RENDERING surface, not an actionable one. The old
                // reading deleted the whole `unsupported` row, which made the "not
                // adjustable" presentation class structurally unreachable on the connection
                // panel: instead of "this model does not accept this parameter" plus "show
                // me models that do", the user watched the row vanish, which is a dead end.
                // Only visibility changes here; `editable` and `permitsOutbound` are
                // untouched.
                visible = declaration != null,
                editable = resolution.support == "supported" ||
                    (acceptedRelayDeclaration && queryIdentity != null),
                permitsOutbound = resolution.requestPolicy in setOf("allow", "allow_explicit_unverified"),
                isUnverified = acceptedRelayDeclaration && queryIdentity != null,
            )
        }
        val expiry = decisions.keys.asSequence()
            .flatMap { key ->
                candidatesForKey(
                    provider, model, current, queryIdentity, key, finalTransport, metadataClient,
                ).asSequence()
            }
            .mapNotNull { it.expiresAt }
            .filter { it > now }
            .minOrNull()
        return Projection(
            identity = queryIdentity,
            decisions = decisions,
            contentRevision = current?.contentRevision ?: 0,
            nextExpiryAt = expiry,
        ).also(CapabilityEvidenceObservationBridge::observe)
    }

    /**
     * UI scope may derive the same endpoint only from a non-auto requested transport and the
     * discovery-confirmed API root. It uses the production resolver (including Gemini stream)
     * and returns null for every ambiguous input; the final request still uses dispatchIdentity.
     */
    fun uiDispatchIdentity(
        provider: Provider,
        model: AIModel,
        localIdentity: CapabilityEvidenceIdentity?,
    ): CapabilityEvidenceFacade.QueryIdentity? {
        if (ProviderForm.of(provider) != ProviderForm.Relay) return null
        val requested = provider.relayRequested ?: return null
        // A protocol that is not settled (the model and the connection both follow automatic) still counts as uncertain: no UI identity is pushed.
        val transport = RelayEndpointResolver.declaredTransport(provider, model) ?: return null
        // The root comes from the same resolver as the outbound path; the security mode is checked by endpointUrl below.
        val apiBase = RelayEndpointResolver.effectiveAPIRoot(provider, model) ?: return null
        val endpoint = when (transport) {
            RelayTransport.OpenAIChatCompletions -> "/chat/completions"
            RelayTransport.OpenAIResponses -> "/responses"
            RelayTransport.LlamaCppNative -> "/completion"
            RelayTransport.AnthropicMessages -> "/messages"
            RelayTransport.GeminiGenerateContent -> "/models/${model.id}:${if (requested.stream != false) "streamGenerateContent" else "generateContent"}"
            RelayTransport.Auto -> return null
        }
        val finalUrl = runCatching {
            RelayEndpointResolver.endpointUrl(apiBase, endpoint, requested.securityMode)
        }.getOrNull() ?: return null
        return dispatchIdentity(
        localIdentity = localIdentity,
        model = model,
        effectiveTransport = transport,
        finalUrl = finalUrl,
        )
    }

    /**
     * Identity for the request boundary only. Unlike [uiDispatchIdentity], the transport
     * and URL must come from the dispatch branch that was actually selected; the
     * transport the user requested and a guessed endpoint are not facts.
     */
    fun dispatchIdentity(
        localIdentity: CapabilityEvidenceIdentity?,
        model: AIModel,
        effectiveTransport: RelayTransport,
        finalUrl: String,
    ): CapabilityEvidenceFacade.QueryIdentity? {
        val local = localIdentity ?: return null
        if (formOf(local.providerKind, local.authMode) != ProviderForm.Relay ||
            effectiveTransport == RelayTransport.Auto || model.id.isBlank()
        ) return null
        val endpointFingerprint = relayEndpointFingerprint(finalUrl) ?: return null
        return CapabilityEvidenceFacade.QueryIdentity(
            partitionId = local.partitionId,
            connectionInstanceId = local.connectionInstanceId,
            connectionGeneration = local.connectionGeneration,
            credentialEpoch = local.credentialEpoch,
            providerKind = local.providerKind,
            authMode = local.authMode,
            modelId = model.id,
            canonicalModelId = local.canonicalModelId,
            effectiveTransport = effectiveTransport.value,
            endpointFingerprint = endpointFingerprint,
            metadataRevision = local.metadataRevision,
            generationRevision = local.generationRevision,
        ).takeIf(::isCompleteRelayIdentity)
    }

    /**
     * Request boundary identity for the non-relay providers, under the same discipline as
     * [dispatchIdentity]: the transport has to be the protocol actually dispatched this
     * time, neither the value the user requested nor the providerKind, and the URL has to
     * be the final address after resolveEndpoint, custom baseUrl included. Any missing
     * piece returns null, and runtime self-healing only ever affects this one retry.
     */
    fun officialDispatchIdentity(
        localIdentity: CapabilityEvidenceIdentity?,
        providerKind: ProviderKind,
        modelId: String,
        effectiveTransport: String,
        finalUrl: String,
    ): CapabilityEvidenceFacade.QueryIdentity? {
        val local = localIdentity ?: return null
        if (modelId.isBlank() || local.providerKind != providerKind.rawValue) return null
        // The form is derived from kind + authMode, not kind alone: a relay goes through [dispatchIdentity], not here.
        if (formOf(local.providerKind, local.authMode) == ProviderForm.Relay) return null
        if (!CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport)) return null
        val endpointFingerprint = relayEndpointFingerprint(finalUrl) ?: return null
        return CapabilityEvidenceFacade.QueryIdentity(
            partitionId = local.partitionId,
            connectionInstanceId = local.connectionInstanceId,
            connectionGeneration = local.connectionGeneration,
            credentialEpoch = local.credentialEpoch,
            providerKind = providerKind.rawValue,
            authMode = local.authMode,
            modelId = modelId,
            canonicalModelId = local.canonicalModelId,
            effectiveTransport = effectiveTransport,
            endpointFingerprint = endpointFingerprint,
            metadataRevision = local.metadataRevision,
            generationRevision = local.generationRevision,
        )
    }

    /**
     * The only request projection entry point once the real relay dispatch is settled.
     * Without a complete identity the visible semantics can still be computed, but
     * [Projection.permitsOutbound] stays false so an unknown cannot be resurrected through
     * a global switch.
     */
    fun dispatchCapabilityProjection(
        model: AIModel,
        relayRequested: ai.oriveo.community.core.model.RelayRequestedConfig?,
        identity: CapabilityEvidenceFacade.QueryIdentity?,
        keys: Set<String>,
        explicitKeys: Set<String>,
        now: Long = System.currentTimeMillis(),
    ): Projection = capabilityProjection(
        provider = Provider(
            id = identity?.connectionInstanceId ?: "runtime-relay",
            kind = ProviderKind.Relay,
            relayRequested = relayRequested,
        ),
        model = model,
        identity = identity,
        keys = keys,
        explicitKeys = explicitKeys,
        now = now,
    )

    /** UI generation panel's only schema adapter: ids/explicit overrides -> unified projection. */
    fun generationParameterUiProjection(
        provider: Provider,
        model: AIModel,
        localIdentity: CapabilityEvidenceIdentity?,
        parameters: List<GenerationParameterRef>,
        values: GenerationParameterOverrides,
    ): Projection {
        // Relay engine profiles are deliberately synthesized at the production availability
        // boundary. Candidate extraction must use that same effective profile, rather than the
        // sparse persisted catalog model that was used to obtain the parameter list.
        val projectionModel = if (ProviderForm.of(provider) == ProviderForm.Relay && model.generationProfile == null) {
            model.copy(generationProfile = GenerationParameterAvailability.profile(provider, model))
        } else {
            model
        }
        val profile = GenerationParameterAvailability.profile(provider, projectionModel)
        val base = capabilityProjection(
            provider = provider,
            model = projectionModel,
            identity = uiDispatchIdentity(provider, projectionModel, localIdentity),
            keys = parameters.mapNotNull { parameter ->
            parameter.id?.takeIf(String::isNotBlank)?.let { "generation_parameter/$it" }
            }.toSet(),
            explicitKeys = values.values
                .filterValues { it.state != GenerationOverrideState.Inherit }
                .keys
                .mapTo(linkedSetOf()) { "generation_parameter/$it" },
        )
        val byId = parameters.mapNotNull { parameter ->
            parameter.id?.takeIf(String::isNotBlank)?.let { it to parameter }
        }.toMap()
        val decisions = base.decisions.mapValues { (key, decision) ->
            val id = key.removePrefix("generation_parameter/")
            val parameter = byId[id] ?: return@mapValues decision
            val effective = GenerationParameterSupportPresentation.effectiveSupport(
                parameter.support,
                decision.resolution.support,
            )
            val editable = base.identity != null &&
                GenerationParameterSupportPresentation.entry(effective).control ==
                GenerationParameterSupportPresentation.Control.Editable
            decision.copy(
                visible = true,
                editable = editable,
                permitsOutbound = editable && decision.permitsOutbound && !profile?.wire?.get(id).isNullOrEmpty(),
                // The extra badge explains a Relay-local declaration. Official unknown already
                // has the shared no-data presentation and must not be relabelled as Relay-derived.
                isUnverified = editable && decision.isUnverified,
            )
        }
        return base.copy(decisions = decisions)
    }

    /** Library route/entry consumes this instead of constructing the tool_call schema key itself. */
    fun toolCallProjection(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        memoryVerdict: Boolean? = null,
        negativeCache: ai.oriveo.community.core.provider.relay.RelayNegativeCache =
            ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared,
    ): Projection {
        val base = capabilityProjection(
            provider = provider,
            model = model,
            identity = identity,
            keys = setOf("tool_call"),
            // The caller is deciding agent routing for the library, which is itself an
            // explicit tools intent. An unknown only fails open once the transport is known;
            // an explicit false is still vetoed by the candidate.
            explicitKeys = setOf("tool_call"),
            finalTransport = ToolCallTransportResolver.catalogExternalTransport(provider)
                .takeIf {
                    CapabilityControlResolution.isSubscriptionLink(provider) ||
                        model.isManual ||
                        MetadataClient.resolveCatalogModel(model.id, provider.kind) == null
                },
        )
        val current = base.decision("tool_call") ?: return base
        // Relay declaration and connection memory are scoped to the repository-owned identity.
        // Without it (or while an account/model switch is still resolving it), keep the base
        // projection pending instead of turning an unscoped local boolean into outbound authority.
        val relay = ProviderForm.of(provider) == ProviderForm.Relay
        if (relay && base.identity == null) return base
        // The negative cache and toolCallVerdict make the same decision: a branch that already declared toolCall is vetoed by it too.
        val rejected = relay && relayToolCallRejected(provider, model, negativeCache)
        // Official / subscription: the memory goes into the same decision (a rejection memory comes before modelFacts), and base is kept only when it agrees.
        // Relay: declaration / negative cache decide first, and the memory only falls back to true.
        val verdict = when {
            rejected -> false
            relay -> toolCallVerdict(provider, model, memoryVerdict = null, negativeCache = negativeCache)
            else -> toolCallVerdict(provider, model, memoryVerdict = memoryVerdict, negativeCache = negativeCache)
        }
        val baseSupport = current.resolution.support
        if (!rejected && baseSupport != "unknown" && (relay || verdict == (baseSupport == "supported"))) return base
        val effectiveVerdict = if (relay) verdict ?: memoryVerdict?.takeIf { it } else verdict
        val adapterReady = ToolCallTransportResolver.hasNativeAdapter(provider, model)
        if (effectiveVerdict == null) {
            // Unknown is allowed only for an explicit feature intent and a concrete local adapter.
            if (!adapterReady) return base
            return base.copy(
                decisions = base.decisions + (
                    "tool_call" to current.copy(
                        editable = true,
                        permitsOutbound = true,
                    )
                ),
            )
        }
        val fromMemory = if (relay) rejected || verdict == null else memoryVerdict != null && verdict == memoryVerdict
        val source = if (fromMemory) "connection_memory" else "relay_declaration"
        val memoryResolution = CapabilityEvidenceFacade.Resolution(
            key = "tool_call",
            support = if (effectiveVerdict) "supported" else "unsupported",
            source = source,
            grade = if (source == "connection_memory") "observed" else "accepted_unverified",
            requestPolicy = if (effectiveVerdict && adapterReady) "allow" else "omit_unsupported",
            reasonCode = when {
                !adapterReady -> "tool_adapter_unavailable"
                source == "relay_declaration" && effectiveVerdict -> "relay_tool_call_declared"
                effectiveVerdict -> "runtime_tool_call_observed"
                else -> "runtime_tools_rejected"
            },
        )
        return base.copy(
            decisions = base.decisions + (
                "tool_call" to current.copy(
                    resolution = memoryResolution,
                    visible = source == "relay_declaration" || effectiveVerdict,
                    editable = effectiveVerdict && adapterReady,
                    permitsOutbound = effectiveVerdict && adapterReady,
                    isUnverified = source == "relay_declaration" && effectiveVerdict,
                )
            ),
        )
    }

    /**
     * Badge / telemetry share one tri-state: first-party / catalog evidence > rejection memory (false)
     * > modelFacts > hand-entered declaration > memory true > unknown. [memoryVerdict] comes from
     * [ToolCallMemoryStore.lookup], which already drops entries recorded under another modelFactsRevision.
     */
    fun toolCallVerdict(
        provider: Provider,
        model: AIModel,
        memoryVerdict: Boolean? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
        negativeCache: ai.oriveo.community.core.provider.relay.RelayNegativeCache =
            ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared,
        now: Long = System.currentTimeMillis(),
    ): Boolean? {
        if (ProviderForm.of(provider) == ProviderForm.Relay) {
            // Same order on all three platforms: override value > toolCall negative cache > engine declaration > model.toolCall > tool memory (only true counts).
            model.relayCapabilityOverrides?.toolCall?.let { return it }
            if (relayToolCallRejected(provider, model, negativeCache)) return false
            // A local engine declaration replaces the other sources of this key, and only takes effect when the connection carries an engineProfile.
            val engineDeclared = model.engineDeclaration?.toolCall
                ?.takeUnless { provider.relayRequested?.engineProfile.isNullOrBlank() }
            if (engineDeclared != null) return engineDeclared
            // A relay's "tools unsupported" is recorded only in the negative cache; a false in the old tool memory no longer counts.
            return model.toolCall ?: memoryVerdict?.takeIf { it }
        }
        // The subscription route is not covered by the official catalog's typed evidence (a recipe only describes the official API route):
        // modelFacts (model.id > canonical id) > connection memory.
        val current = if (ProviderForm.of(provider) == ProviderForm.Subscription) {
            null
        } else {
            metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)
        }
        if (current != null) {
            // In the catalog only typed evidence counts: once the namespace exists it is authoritative, and a malformed / empty / expired view is unknown,
            // never falling back to the top-level toolCall, model.toolCall or modelFacts. When the namespace is absent: a server with capability contract >= 2
            // omits the view key for a model without evidence, meaning unknown; only an older server with a missing / v1 version reads the legacy field.
            // When evidence is absent a rejection memory (false only) still applies, in the same order as the other platforms.
            val metadata = current.metadata
            val evidence = when {
                metadata.capabilityEvidenceViewMalformed == true -> null
                metadata.capabilityEvidenceCandidates == null ->
                    metadata.toolCall.takeIf { metadata.capabilityContractVersion < 2 }
                else -> metadata.capabilityEvidenceCandidates
                    .filter { it.key == "tool_call" && (it.expiresAt == null || it.expiresAt > now) }
                    .map { it.support }
                    .filter { it == "supported" || it == "unsupported" }
                    .distinct()
                    .singleOrNull()?.let { it == "supported" }
            }
            return evidence ?: memoryVerdict?.takeIf { !it }
        }
        // Subscription: the Codex / Grok subscription /models does not send a tool field, so the first-party layer is always empty; model.toolCall is the
        // server catalog bit carried in by buildCatalogModel and is not first-party. Only modelFacts > connection memory counts, and without either it is unknown.
        // A rejection memory (false only) comes before modelFacts and the local declaration, in the same order for subscription.
        if (memoryVerdict == false) return false
        if (ProviderForm.of(provider) == ProviderForm.Subscription) {
            SubscriptionTruthAdapter.modelFacts(metadataClient, provider.kind, model)?.toolCall?.let { return it }
            return memoryVerdict
        }
        // Outside the catalog: rejection memory > modelFacts > the hand-entered model's local declaration > memory true.
        metadataClient.modelFacts(provider.kind, model.id)?.toolCall?.let { return it }
        model.toolCall?.let { return it }
        return memoryVerdict
    }

    /** The upstream rejected tools before producing any output and the rejection has not expired; an override value of true overrides it. */
    private fun relayToolCallRejected(
        provider: Provider,
        model: AIModel,
        negativeCache: ai.oriveo.community.core.provider.relay.RelayNegativeCache,
    ): Boolean {
        if (model.relayCapabilityOverrides?.toolCall == true) return false
        val key = ai.oriveo.community.core.provider.relay.RelayNegativeCache.keyFor(provider, model) ?: return false
        return negativeCache.isRejected(key, ai.oriveo.community.core.provider.relay.RelayNegativeCache.Kind.ToolCall)
    }

    /** Feature callers consume modes, never re-create the reasoning-level key namespace. */
    fun supportedReasoningModes(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): List<ReasoningMode> {
        val projection = capabilityProjection(
            provider = provider,
            model = model,
            identity = identity,
            keys = reasoningKeys(),
            metadataClient = metadataClient,
        )
        return ReasoningMode.entries
            .filter { it != ReasoningMode.Automatic }
            .filter { mode -> projection.decision(reasoningKey(mode))?.editable == true }
    }

    /**
     * Badge verdict for a single input key (vision_input / file_input / video_input): the same rule as [governedMetadataCapabilities]
     * for that key, but without resolving the web search / reasoning controls. The subscription form has no input projection and keeps the raw capabilities.
     * Use this on per-model hot paths such as catalog sorting when only one key is needed.
     */
    fun governedInputVisible(
        provider: Provider,
        model: AIModel,
        key: String,
        identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): Boolean {
        val inputs = resolveInputCapabilityProjections(
            provider = provider,
            model = model,
            relayIdentity = identity,
            metadataClient = metadataClient,
        ) ?: return inputCapabilityOf(key) in model.capabilities
        return inputs[key].visible
    }

    private fun inputCapabilityOf(key: String): ModelCapability = when (key) {
        CapabilityEvidenceFacade.VISION_INPUT -> ModelCapability.Image
        CapabilityEvidenceFacade.FILE_INPUT -> ModelCapability.File
        CapabilityEvidenceFacade.VIDEO_INPUT -> ModelCapability.Video
        else -> throw IllegalArgumentException("not an input capability key: $key")
    }

    /** Single core mapping from governed evidence to metadata badges. */
    fun governedMetadataCapabilities(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceFacade.QueryIdentity? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): Set<ModelCapability> {
        val projection = capabilityProjection(
            provider = provider,
            model = model,
            identity = identity,
            keys = setOf("web_search") + reasoningKeys(),
            metadataClient = metadataClient,
        )
        // The image / file / video badges only trust the input capability projection's visible flag (auto_available and implemented on this platform);
        // unknown does not light the badge (the entry stays open). The subscription form has no projection and keeps the raw capabilities.
        val inputs = resolveInputCapabilityProjections(
            provider = provider,
            model = model,
            relayIdentity = identity,
            metadataClient = metadataClient,
        )
        // The web search / reasoning badges have to share their source with the control on the chat screen: when the
        // capability contract says this transport and model cannot do it, the badge must not
        // stay lit.
        val webControlAvailable = CapabilityControlResolution
            .resolve(provider, model, "web", metadataClient).isAvailable
        val reasoningControlAvailable = CapabilityControlResolution
            .resolve(provider, model, "reasoning", metadataClient).isAvailable
        val subscription = CapabilityControlResolution.isSubscriptionLink(provider)
        val governedAllowed = setOfNotNull(
            ModelCapability.Image.takeIf {
                if (inputs == null) ModelCapability.Image in model.capabilities else inputs.vision.visible
            },
            ModelCapability.File.takeIf {
                if (inputs == null) ModelCapability.File in model.capabilities else inputs.file.visible
            },
            ModelCapability.Video.takeIf {
                if (inputs == null) ModelCapability.Video in model.capabilities else inputs.video.visible
            },
            ModelCapability.Web.takeIf {
                webControlAvailable && if (subscription) ModelCapability.Web in model.capabilities
                else projection.decision("web_search")?.editable == true
            },
            ModelCapability.Reasoning.takeIf {
                reasoningControlAvailable &&
                    if (subscription) ModelCapability.Reasoning in model.capabilities
                    else reasoningKeys().any { key -> projection.decision(key)?.editable == true }
            },
        )
        // Keep allowed persisted badges in their existing priority order. Typed evidence may add a
        // capability absent from stale model metadata, appended in a stable canonical order.
        val governed = listOf(
            ModelCapability.Image,
            ModelCapability.File,
            ModelCapability.Video,
            ModelCapability.Web,
            ModelCapability.Reasoning,
        )
        val result = model.capabilities.filterTo(linkedSetOf()) { capability ->
            capability !in governed || capability in governedAllowed
        }
        governed.forEach { capability ->
            if (capability in governedAllowed) result += capability
        }
        return result
    }

    /** The keys the subscription catalog snapshot owns: image input, web search, reasoning tiers; tool_call and generation parameters are not the catalog's. */
    private fun catalogOwnedKey(key: String): Boolean =
        key == CapabilityEvidenceFacade.VISION_INPUT || key == "web_search" || key.startsWith("reasoning_level/")

    private fun reasoningKeys(): Set<String> = ReasoningMode.entries
        .filter { it != ReasoningMode.Automatic }
        .mapTo(linkedSetOf(), ::reasoningKey)

    private fun reasoningKey(mode: ReasoningMode): String = "reasoning_level/${mode.rawValue}"

    private fun candidatesForKey(
        provider: Provider,
        persistedModel: AIModel,
        current: MetadataClient.CurrentCapabilityEvidenceModel?,
        queryIdentity: CapabilityEvidenceFacade.QueryIdentity?,
        key: String,
        finalTransport: String?,
        metadataClient: MetadataClient,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val form = ProviderForm.of(provider)
        val truth = CapabilityTruthRegistry.adapterFor(form).candidates(
            CapabilityTruthAdapter.Input(
                provider = provider,
                model = persistedModel,
                key = key,
                queryIdentity = queryIdentity,
                current = current,
                finalTransport = finalTransport,
                metadataClient = metadataClient,
            ),
        )
        return when (form) {
            // A runtime rejection is an overlay on the outbound policy, not capability truth; it has to read the cache, so it stays outside the adapter.
            ProviderForm.Relay -> truth + queryIdentity
                ?.let { identity -> UnsupportedParamCache.runtimeRejectedEvidence(identity) }
                ?.filter { it.key == key }
                .orEmpty()
            else -> truth
        }
    }

    private fun isCompleteRelayIdentity(identity: CapabilityEvidenceFacade.QueryIdentity): Boolean =
        identity.partitionId.isNotBlank() && identity.connectionInstanceId.isNotBlank() &&
            identity.connectionGeneration.isNotBlank() && identity.credentialEpoch.isNotBlank() &&
            formOf(identity.providerKind, identity.authMode) == ProviderForm.Relay && identity.modelId.isNotBlank() &&
            CapabilityEvidenceFacade.isConcreteTransport(identity.effectiveTransport) &&
            !identity.endpointFingerprint.isNullOrBlank()

    /** The identity holds only raw strings; if kind or authMode is not recognized there is no form, and callers fail closed. */
    private fun formOf(providerKind: String, authMode: String): ProviderForm? {
        val kind = ProviderKind.fromRawValue(providerKind) ?: return null
        val mode = ProviderAuthMode.entries.firstOrNull { it.rawValue == authMode } ?: return null
        return ProviderForm.of(kind, mode)
    }

    private fun incompleteIdentity(provider: Provider, model: AIModel) = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "",
        connectionInstanceId = "",
        connectionGeneration = "",
        credentialEpoch = "",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
        modelId = model.id,
        canonicalModelId = model.canonicalModelId,
        effectiveTransport = "unknown",
    )

}
