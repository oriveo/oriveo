package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
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
    ): ReasoningMode = if (provider.kind == ProviderKind.Relay) {
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
        val current = if (provider.kind == ProviderKind.Relay) {
            null
        } else {
            metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)
        }
        val evidenceModel = current?.metadata
        val effectiveTransport = if (provider.kind == ProviderKind.Relay) {
            identity?.effectiveTransport
        } else {
            // Final writers are authorised for their actual dispatch transport. The evidence
            // declaration remains the candidate identity, so a declared transport that differs
            // from this final branch fails closed as an identity mismatch.
            finalTransport ?: CapabilityControlResolution.subscriptionFinalTransport(provider, model)
                ?: evidenceModel?.transport
        }
        val queryIdentity = when {
            !CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport) -> null
            provider.kind == ProviderKind.Relay -> identity?.takeIf(::isCompleteRelayIdentity)
            evidenceModel == null -> CapabilityEvidenceFacade.QueryIdentity(
                partitionId = identity?.partitionId.orEmpty(),
                connectionInstanceId = identity?.connectionInstanceId.orEmpty(),
                connectionGeneration = identity?.connectionGeneration.orEmpty(),
                credentialEpoch = identity?.credentialEpoch.orEmpty(),
                providerKind = provider.kind.rawValue,
                modelId = model.id,
                canonicalModelId = MetadataClient.normalizeModelFactsID(model.id),
                effectiveTransport = effectiveTransport.orEmpty(),
                endpointFingerprint = identity?.endpointFingerprint,
                metadataRevision = metadataClient.currentMetadataRevision(),
            )
            else -> CapabilityEvidenceFacade.QueryIdentity(
                partitionId = identity?.partitionId.orEmpty(),
                connectionInstanceId = identity?.connectionInstanceId.orEmpty(),
                connectionGeneration = identity?.connectionGeneration.orEmpty(),
                credentialEpoch = identity?.credentialEpoch.orEmpty(),
                providerKind = provider.kind.rawValue,
                modelId = model.id,
                canonicalModelId = evidenceModel.canonicalModelId,
                effectiveTransport = effectiveTransport.orEmpty(),
                endpointFingerprint = identity?.endpointFingerprint,
                metadataRevision = current.metadataRevision,
                generationRevision = current.generationRevision,
            )
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
            val resolution = if (queryIdentity == null) {
                CapabilityEvidenceFacade.resolve(
                    key = key,
                    query = CapabilityEvidenceFacade.Query(
                        identity = incompleteIdentity(provider, model),
                        now = now,
                        hasExplicitValue = key in explicitKeys,
                    ),
                    candidates = candidates,
                )
            } else {
                CapabilityEvidenceFacade.resolve(
                    key = key,
                    query = CapabilityEvidenceFacade.Query(
                        identity = queryIdentity,
                        now = now,
                        hasExplicitValue = key in explicitKeys,
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
        if (provider.kind != ProviderKind.Relay) return null
        val requested = provider.relayRequested ?: return null
        val transport = requested.transport.takeIf { it != RelayTransport.Auto } ?: return null
        val rawBase = provider.baseUrlText?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val apiBase = runCatching {
            when (transport) {
                // Android dispatch adds a version only for these two transports; OpenAI chat /
                // responses and llama use the configured base verbatim.
                RelayTransport.AnthropicMessages -> RelayEndpointResolver.runtimeApiBaseUrl(
                    rawBase, requested, "v1", setOf("v1"),
                )
                RelayTransport.GeminiGenerateContent -> RelayEndpointResolver.runtimeApiBaseUrl(
                    rawBase, requested, "v1beta", setOf("v1", "v1beta"),
                )
                else -> requested.resolvedAPIBaseURL?.trim()?.takeIf { it.isNotEmpty() } ?: rawBase
            }
        }.getOrNull() ?: return null
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
        if (local.providerKind != ProviderKind.Relay.rawValue ||
            effectiveTransport == RelayTransport.Auto || model.id.isBlank()
        ) return null
        val endpointFingerprint = relayEndpointFingerprint(finalUrl) ?: return null
        return CapabilityEvidenceFacade.QueryIdentity(
            partitionId = local.partitionId,
            connectionInstanceId = local.connectionInstanceId,
            connectionGeneration = local.connectionGeneration,
            credentialEpoch = local.credentialEpoch,
            providerKind = ProviderKind.Relay.rawValue,
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
        if (providerKind == ProviderKind.Relay || modelId.isBlank()) return null
        if (local.providerKind != providerKind.rawValue) return null
        if (!CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport)) return null
        val endpointFingerprint = relayEndpointFingerprint(finalUrl) ?: return null
        return CapabilityEvidenceFacade.QueryIdentity(
            partitionId = local.partitionId,
            connectionInstanceId = local.connectionInstanceId,
            connectionGeneration = local.connectionGeneration,
            credentialEpoch = local.credentialEpoch,
            providerKind = providerKind.rawValue,
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
        val projectionModel = if (provider.kind == ProviderKind.Relay && model.generationProfile == null) {
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
        if (provider.kind == ProviderKind.Relay && base.identity == null) return base
        if (current.resolution.support != "unknown") return base
        val firstParty = toolCallVerdict(provider, model, memoryVerdict = null)
        val effectiveVerdict = firstParty ?: memoryVerdict
        val adapterReady = ToolCallTransportResolver.hasNativeAdapter(provider)
        if (effectiveVerdict == null) {
            // D2: unknown is allowed only for an explicit feature intent and a concrete local adapter.
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
        val source = if (firstParty != null) "relay_declaration" else "connection_memory"
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

    /** Badge / telemetry share the same first-party > catalog > modelFacts tri-state. */
    fun toolCallVerdict(
        provider: Provider,
        model: AIModel,
        memoryVerdict: Boolean? = null,
        metadataClient: MetadataClient = MetadataClient.instance,
    ): Boolean? {
        if (provider.kind == ProviderKind.Relay) return model.toolCall ?: memoryVerdict
        val current = metadataClient.currentCapabilityEvidenceModel(model.id, provider.kind)
        if (current != null) return current.metadata.toolCall
        model.toolCall?.let { return it }
        metadataClient.modelFacts(provider.kind, model.id)?.toolCall?.let { return it }
        return memoryVerdict
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
            keys = setOf("vision_input", "web_search") + reasoningKeys(),
            metadataClient = metadataClient,
        )
        // The badge has to share its source with the control on the chat screen: when the
        // capability contract says this transport and model cannot do it, the badge must not
        // stay lit. Vision has no such control, so it keeps its original test.
        val webControlAvailable = CapabilityControlResolution
            .resolve(provider, model, "web", metadataClient).isAvailable
        val reasoningControlAvailable = CapabilityControlResolution
            .resolve(provider, model, "reasoning", metadataClient).isAvailable
        val subscription = CapabilityControlResolution.isSubscriptionLink(provider)
        val governedAllowed = setOfNotNull(
            ModelCapability.Image.takeIf {
                if (subscription) ModelCapability.Image in model.capabilities
                else projection.decision("vision_input")?.editable == true
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
        val governed = setOf(ModelCapability.Image, ModelCapability.Web, ModelCapability.Reasoning)
        val result = model.capabilities.filterTo(linkedSetOf()) { capability ->
            capability !in governed || capability in governedAllowed
        }
        listOf(ModelCapability.Image, ModelCapability.Web, ModelCapability.Reasoning).forEach { capability ->
            if (capability in governedAllowed) result += capability
        }
        return result
    }

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
        if (provider.kind == ProviderKind.Relay) {
            val declared = relayCandidates(provider, persistedModel, queryIdentity, key)
            val runtime = queryIdentity
                ?.let { identity -> UnsupportedParamCache.runtimeRejectedEvidence(identity) }
                ?.filter { it.key == key }
                .orEmpty()
            return declared + runtime
        }
        if (current == null) {
            if (key != "tool_call" || queryIdentity == null) return emptyList()
            val firstParty = persistedModel.toolCall
            val modelFact = if (firstParty == null) {
                metadataClient.modelFacts(provider.kind, persistedModel.id)?.toolCall
            } else {
                null
            }
            val support = firstParty ?: modelFact ?: return emptyList()
            return listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = if (support) "supported" else "unsupported",
                    source = if (firstParty != null) "server_profile" else "model_facts",
                    grade = if (firstParty != null) "declared" else "external_declared",
                    scope = "provider_model_transport",
                    identity = CapabilityEvidenceFacade.CandidateIdentity(
                        providerKind = provider.kind.rawValue,
                        modelId = MetadataClient.normalizeModelFactsID(persistedModel.id),
                        effectiveTransport = queryIdentity.effectiveTransport,
                        metadataRevision = queryIdentity.metadataRevision,
                    ),
                ),
            )
        }
        val safe = current.metadata.capabilityEvidenceCandidates.orEmpty()
            .filter { it.key == key }
            .map(::facadeCandidate)
        if (current.metadata.capabilityEvidenceViewMalformed == true && isGovernedCapabilityKey(key)) {
            return emptyList()
        }
        if (safe.isNotEmpty() || current.metadata.capabilityEvidenceOwnedKeys?.contains(key) == true) return safe
        return officialLegacyCandidates(provider, current, persistedModel, key, finalTransport)
    }

    private fun officialLegacyCandidates(
        provider: Provider,
        current: MetadataClient.CurrentCapabilityEvidenceModel,
        persistedModel: AIModel,
        key: String,
        finalTransport: String?,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val model = current.metadata
        val transport = model.transport ?: finalTransport ?: return emptyList()
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            providerKind = provider.kind.rawValue,
            modelId = model.canonicalModelId,
            effectiveTransport = transport,
            metadataRevision = current.metadataRevision,
            generationRevision = current.generationRevision,
        )
        if (key.startsWith("generation_parameter/")) {
            val id = key.substringAfter('/')
            // A `supportsTemperature: false` in the catalog is an explicit negative
            // conclusion and has to enter the facade as an `unsupported` candidate. The
            // explicit-intent escape hatch relaxes "we have no evidence", not "the catalog
            // says unsupported"; without materialising the candidate, a temperature the user
            // set explicitly would go out anyway.
            if (id == "temperature" && model.supportsTemperature == false) {
                return listOf(
                    CapabilityEvidenceFacade.Candidate(
                        key = key,
                        support = "unsupported",
                        source = "server_profile",
                        grade = "declared",
                        scope = "provider_model_transport",
                        identity = identity,
                    ),
                )
            }
            val parameter = model.profiles.generation?.parameters?.firstOrNull { it.id == id } ?: return emptyList()
            return listOfNotNull(
                CapabilityEvidenceFacade.normalizeGenerationParameter(
                    raw = parameter,
                    identity = identity,
                    scope = "provider_model_transport",
                ),
            )
        }
        val support = when {
            key == "tool_call" -> when (model.toolCall) {
                true -> "supported"
                false -> "unsupported"
                null -> "unknown"
            }
            key == "web_search" -> if (
                ModelCapability.Web in model.capabilities && !model.profiles.webSearch.isNullOrBlank()
            ) "supported" else "unknown"
            key == "vision_input" -> if (ModelCapability.Image in model.capabilities) "supported" else "unknown"
            key.startsWith("reasoning_level/") -> if (
                key.substringAfter('/') in current.declaredReasoningLevels
            ) "supported" else "unknown"
            else -> return emptyList()
        }
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = key,
                support = support,
                source = "legacy_metadata",
                grade = "legacy_unverified",
                scope = "provider_model_transport",
                identity = identity,
            ),
        )
    }

    private fun relayCandidates(
        provider: Provider,
        model: AIModel,
        queryIdentity: CapabilityEvidenceFacade.QueryIdentity?,
        key: String,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val query = queryIdentity ?: return relayUnscopedDeclaration(provider, model, key)
        val identity = CapabilityEvidenceFacade.CandidateIdentity(
            partitionId = query.partitionId,
            connectionInstanceId = query.connectionInstanceId,
            connectionGeneration = query.connectionGeneration,
            credentialEpoch = query.credentialEpoch,
            providerKind = query.providerKind,
            modelId = query.canonicalModelId ?: query.modelId,
            effectiveTransport = query.effectiveTransport,
            endpointFingerprint = query.endpointFingerprint,
            metadataRevision = query.metadataRevision,
            generationRevision = query.generationRevision,
        )
        if (key.startsWith("generation_parameter/")) {
            val id = key.substringAfter('/')
            val parameter = model.generationProfile?.parameters?.firstOrNull { it.id == id } ?: return emptyList()
            return listOfNotNull(
                CapabilityEvidenceFacade.normalizeGenerationParameter(
                    raw = parameter,
                    identity = identity,
                    source = "relay_declaration",
                ),
            )
        }
        return relayDeclaration(provider, model, key)?.let { support ->
            listOf(
                CapabilityEvidenceFacade.Candidate(
                    key = key,
                    support = if (support == "unsupported") "unsupported" else "unknown",
                    source = "relay_declaration",
                    grade = if (support == "unsupported") "declared" else "accepted_unverified",
                    scope = "connection_model_transport",
                    identity = identity,
                ),
            )
        }.orEmpty()
    }

    /** With no scope only the UI declaration survives; the facade will not authorise anything on an incomplete identity. */
    private fun relayUnscopedDeclaration(
        provider: Provider,
        model: AIModel,
        key: String,
    ): List<CapabilityEvidenceFacade.Candidate> {
        val support = relayDeclaration(provider, model, key) ?: return emptyList()
        return listOf(
            CapabilityEvidenceFacade.Candidate(
                key = key,
                support = if (support == "unsupported") "unsupported" else "unknown",
                source = "relay_declaration",
                grade = if (support == "unsupported") "declared" else "accepted_unverified",
                scope = "connection_model_transport",
                identity = CapabilityEvidenceFacade.CandidateIdentity(
                    providerKind = ProviderKind.Relay.rawValue,
                    modelId = model.canonicalModelId ?: model.id,
                    effectiveTransport = provider.relayRequested?.transport?.value ?: "unknown",
                ),
            ),
        )
    }

    private fun relayDeclaration(provider: Provider, model: AIModel, key: String): String? = when {
        key == "tool_call" -> when (model.toolCall) {
            false -> "unsupported"
            true -> "accepted"
            null -> null
        }
        key == "web_search" && provider.relayRequested?.hasWebSearch == true &&
            !model.webSearchProfile.isNullOrBlank() -> "accepted"
        key == "vision_input" && ModelCapability.Image in model.capabilities -> "accepted"
        key.startsWith("reasoning_level/") && model.reasoningModeAvailable &&
            !model.reasoningProfile.isNullOrBlank() -> "accepted"
        else -> null
    }

    /** When the public capability namespace is malformed as a whole, no capability key may be resurrected from the older metadata shape. */
    private fun isGovernedCapabilityKey(key: String): Boolean =
        key in setOf("tool_call", "web_search", "vision_input") ||
            key.startsWith("generation_parameter/") ||
            key.startsWith("reasoning_level/")

    private fun facadeCandidate(raw: MetadataClient.CapabilityEvidenceCandidateView) =
        CapabilityEvidenceFacade.Candidate(
            key = raw.key,
            support = raw.support,
            source = raw.source,
            grade = raw.grade,
            scope = raw.scope,
            identity = CapabilityEvidenceFacade.CandidateIdentity(
                providerKind = raw.providerKind,
                modelId = raw.modelId,
                effectiveTransport = raw.transport,
                metadataRevision = raw.metadataRevision,
                generationRevision = raw.generationRevision,
            ),
            observedAt = raw.observedAt,
            expiresAt = raw.expiresAt,
        )

    private fun isCompleteRelayIdentity(identity: CapabilityEvidenceFacade.QueryIdentity): Boolean =
        identity.partitionId.isNotBlank() && identity.connectionInstanceId.isNotBlank() &&
            identity.connectionGeneration.isNotBlank() && identity.credentialEpoch.isNotBlank() &&
            identity.providerKind == ProviderKind.Relay.rawValue && identity.modelId.isNotBlank() &&
            CapabilityEvidenceFacade.isConcreteTransport(identity.effectiveTransport) &&
            !identity.endpointFingerprint.isNullOrBlank()

    private fun incompleteIdentity(provider: Provider, model: AIModel) = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "",
        connectionInstanceId = "",
        connectionGeneration = "",
        credentialEpoch = "",
        providerKind = provider.kind.rawValue,
        modelId = model.id,
        canonicalModelId = model.canonicalModelId,
        effectiveTransport = "unknown",
    )

}
