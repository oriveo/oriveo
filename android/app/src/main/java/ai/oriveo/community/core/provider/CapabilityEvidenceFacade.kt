package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.ModelCapability
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Pure resolution entry point for the shared capability-evidence contract v1.
 *
 * It only consumes already normalised local evidence. Nothing here may read storage,
 * touch credentials or issue a request while resolving.
 */
internal object CapabilityEvidenceFacade {
    private val sourcePriority = listOf(
        "operator_override",
        "server_typed",
        "server_profile",
        "free_catalog",
        "upstream_declaration",
        "model_facts",
        "relay_verification",
        "relay_declaration",
        "legacy_metadata",
    )

    /**
     * Source marker for the catalog having been fetched but not containing this model; it is also its reasonCode.
     *
     * Deliberately not in [sourcePriority]: it is not a piece of capability evidence and cannot be ranked against other sources in the evidence priority;
     * it takes effect only when there is no valid prioritized candidate, and is resolved to an unknown that is not sent out.
     */
    const val CATALOG_ABSENT = "catalog_absent"

    // The three input capability keys: callers reference the constants instead of writing bare literals.
    const val VISION_INPUT = "vision_input"
    const val FILE_INPUT = "file_input"
    const val VIDEO_INPUT = "video_input"

    /**
     * Can only generate images, no text: the metadata declares ImageGen without Text.
     * An empty capability list (unknown) does not count, so a text model whose metadata has not arrived yet is not treated as image-only.
     */
    fun isImageOnlyModel(model: AIModel): Boolean =
        ModelCapability.ImageGen in model.capabilities && ModelCapability.Text !in model.capabilities

    /** A query must carry the full local isolation identity, so a call site cannot construct a "current connection with no generation". */
    data class QueryIdentity(
        val partitionId: String,
        val connectionInstanceId: String,
        val connectionGeneration: String,
        val credentialEpoch: String,
        val providerKind: String,
        /** `ProviderAuthMode.rawValue`. The form is derived from kind + authMode together; kind alone cannot recognize a subscription. */
        val authMode: String,
        val modelId: String,
        val canonicalModelId: String? = null,
        val effectiveTransport: String,
        val endpointFingerprint: String? = null,
        val metadataRevision: String? = null,
        val generationRevision: String? = null,
    )

    /** Older provider-scope evidence may omit the local fields; connection and exact scopes fail closed during eligibility instead. */
    data class CandidateIdentity(
        val partitionId: String? = null,
        val connectionInstanceId: String? = null,
        val connectionGeneration: String? = null,
        val credentialEpoch: String? = null,
        val providerKind: String,
        val modelId: String,
        val effectiveTransport: String,
        val endpointFingerprint: String? = null,
        val metadataRevision: String? = null,
        val generationRevision: String? = null,
    )

    data class Query(
        val identity: QueryIdentity,
        val now: Long,
        val hasExplicitValue: Boolean,
    )

    data class Candidate(
        val key: String,
        val support: String,
        val source: String,
        val grade: String,
        val scope: String,
        val identity: CandidateIdentity,
        val observedAt: Long? = null,
        val expiresAt: Long? = null,
        val policy: String? = null,
    )

    data class PolicyEvidence(val source: String, val grade: String)

    /**
     * Marks a negative that rests on an authoritative declaration.
     *
     * The shared support vocabulary has only three values, supported / unsupported /
     * unknown, which cannot express `fixed`, where the model pins the value, or
     * `mode_dependent`, where it turns on the current thinking tier. Calling those
     * `unsupported` would hide the whole row, since `Decision.visible` is computed as
     * support != unsupported, and they are supposed to keep rendering their "not
     * adjustable" label together with a primary action. Calling them a bare `unknown`
     * lets the explicit-intent escape hatch wave them through, and then the panel says
     * not adjustable while the request carries the field anyway.
     *
     * So support stays `unknown` for presentation purposes, and this policy marker pulls
     * the outbound decision onto the same veto path as `unsupported`. It deliberately
     * does not look at providerKind, which takes no part in the pass decision.
     */
    const val OFFICIAL_NEGATIVE_POLICY = "official_negative"

    /** Negatives a profile asserts outright. The three-valued evidence vocabulary cannot express them, so they are named here explicitly. */
    private val officialNegativeSupports = setOf("fixed", "mode_dependent", "future_supported")

    data class Resolution(
        val key: String,
        val support: String,
        val source: String,
        val grade: String,
        val requestPolicy: String,
        val reasonCode: String,
        val policyEvidence: PolicyEvidence? = null,
    )

    /** The one shape runtime self-healing may take: it produces a request-policy overlay and never alters a support verdict. */
    fun runtimeRejectedCandidate(
        key: String,
        identity: QueryIdentity,
        observedAt: Long,
        expiresAt: Long,
    ): Candidate = Candidate(
        key = key,
        support = "unknown",
        source = "runtime_observation",
        grade = "observed",
        scope = "exact_request",
        identity = CandidateIdentity(
            partitionId = identity.partitionId,
            connectionInstanceId = identity.connectionInstanceId,
            connectionGeneration = identity.connectionGeneration,
            credentialEpoch = identity.credentialEpoch,
            providerKind = identity.providerKind,
            modelId = identity.modelId,
            effectiveTransport = identity.effectiveTransport,
            endpointFingerprint = identity.endpointFingerprint,
            metadataRevision = identity.metadataRevision,
            generationRevision = identity.generationRevision,
        ),
        observedAt = observedAt,
        expiresAt = expiresAt,
        policy = "runtime_rejected",
    )

    /**
     * Adapts a generation parameter produced by the catalog deserializer into a shared
     * evidence candidate.
     *
     * `accepted_unverified` is a support value from the older generation shape. The
     * capability verdict stays `unknown` and its user-confirmed meaning is carried by the
     * grade instead, so it is never dressed up as verified support.
     */
    fun normalizeGenerationParameter(
        raw: GenerationParameterRef,
        identity: CandidateIdentity,
        source: String = raw.source.toEvidenceSource(),
        scope: String = "connection_model_transport",
    ): Candidate? {
        val id = raw.id?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val rawSupport = raw.support?.trim()
        val support = when {
            source == "relay_declaration" && rawSupport != "unsupported" -> "unknown"
            rawSupport in setOf("supported", "unsupported", "unknown") -> rawSupport.orEmpty()
            rawSupport in setOf("accepted", "accepted_unverified") -> "unknown"
            else -> "unknown"
        }
        // A Relay declaration is only an explicit user acceptance when it declares a mutable
        // parameter. Legacy `fixed` / `mode_dependent` / `future_supported` entries remain visible declarations but
        // must never become editable or outbound merely because a complete Relay identity exists.
        val acceptedRelayDeclaration = source == "relay_declaration" &&
            rawSupport !in setOf("unsupported", "fixed", "mode_dependent", "future_supported")
        val grade = when {
            acceptedRelayDeclaration -> "accepted_unverified"
            raw.source == "provider_metadata" -> "declared"
            source == "server_profile" -> "effect_verified"
            source == "server_typed" -> "machine_verified"
            source == "relay_verification" -> "observed"
            source == "relay_declaration" -> "declared"
            source == "operator_override" -> "operator"
            else -> "legacy_unverified"
        }
        return Candidate(
            key = "generation_parameter/$id",
            support = support,
            source = source,
            grade = grade,
            scope = scope,
            identity = identity,
            policy = OFFICIAL_NEGATIVE_POLICY.takeIf { rawSupport in officialNegativeSupports },
        )
    }

    fun resolve(key: String, query: Query, candidates: List<Candidate>): Resolution {
        val verdictCandidates = candidates.filter { it.key == key && it.source != "runtime_observation" }
        val valid = verdictCandidates.filter { candidate -> isUsable(candidate, query) }
        val resolution = resolveVerdict(key, query, valid, verdictCandidates)
        val runtimeRejection = candidates.firstOrNull { candidate ->
            candidate.key == key &&
                candidate.source == "runtime_observation" &&
                candidate.policy == "runtime_rejected" &&
                isUsable(candidate, query)
        }
        return if (runtimeRejection == null) {
            resolution
        } else {
            resolution.copy(
                requestPolicy = "omit_runtime_rejected",
                reasonCode = "runtime_rejected",
                policyEvidence = PolicyEvidence(runtimeRejection.source, runtimeRejection.grade),
            )
        }
    }

    private fun resolveVerdict(
        key: String,
        query: Query,
        valid: List<Candidate>,
        all: List<Candidate>,
    ): Resolution {
        if (valid.isEmpty()) return noUsableEvidence(key, unavailableReason(all, query), query)

        val ranked = valid.mapNotNull { candidate ->
            sourcePriority.indexOf(candidate.source).takeIf { it >= 0 }?.let { candidate to it }
        }
        if (ranked.isEmpty()) {
            // A model outside the catalog is not a case of us having no evidence but of the other side not accepting it, so it does not enter the explicit escape hatch:
            // even if the user expressed explicit intent it is still not sent out.
            if (valid.any { it.source == CATALOG_ABSENT }) {
                return Resolution(
                    key = key,
                    support = "unknown",
                    source = CATALOG_ABSENT,
                    grade = "none",
                    requestPolicy = "omit_unknown",
                    reasonCode = CATALOG_ABSENT,
                )
            }
            return noUsableEvidence(key, "missing_evidence", query)
        }
        val highest = ranked.minOf { it.second }
        val selected = ranked.filter { it.second == highest }.map { it.first }
        // A conflict is not "we do not know": it is "the evidence we hold disagrees with
        // itself", and one of those pieces may well be a definite no. So it does not take
        // the permissive path.
        if (selected.map { it.support }.distinct().size > 1) return unknown(key, "conflict")

        val candidate = selected.first()

        // Same veto path as `unsupported`: `fixed` and `mode_dependent` are conclusions a
        // profile asserts directly, not gaps in the metadata, so they do not reach the
        // explicit-intent escape hatch either.
        if (selected.any { it.policy == OFFICIAL_NEGATIVE_POLICY }) {
            return candidate.resolution("omit_unsupported", "unsupported")
        }

        return when (candidate.support) {
            "supported" -> candidate.resolution("allow", "supported")
            "unsupported" -> candidate.resolution("omit_unsupported", "unsupported")
            // The test is only "the user expressed this intent explicitly" plus "this is not
            // an authoritatively evidenced no". Not providerKind, not source ==
            // relay_declaration, not candidate.scope: those three gates were each guessed at
            // locally while the contract had a hole, and the contract cases decide it now.
            else -> if (query.hasExplicitValue) {
                candidate.resolution("allow_explicit_unverified", "user_accepted_unverified")
            } else {
                candidate.resolution("omit_unknown", "missing_evidence")
            }
        }
    }

    /**
     * We have no evidence is NOT the same as the user may not do this. When this was
     * measured, hundreds of combinations, about a quarter of them, were cases of "we do
     * not know" being executed as "you cannot". An explicitly expressed intent is let
     * through, but source and grade stay honestly at `none`: the authorisation comes from
     * what the user asked for this time, not from a candidate that identity checking threw
     * out.
     */
    private fun noUsableEvidence(key: String, reason: String, query: Query): Resolution {
        // Letting it through presupposes that the identity of THIS request holds up. With no
        // concrete transport for this request we do not even know where it would be sent;
        // a relay that has not yet resolved a connection identity is in exactly that state,
        // and `incompleteIdentity` reports its transport as "unknown". Identity isolation
        // and evidence quality are two separate axes, and only the latter is relaxed here,
        // otherwise one account's scope could be attached to another account's connection.
        val dispatchable = isConcreteTransport(query.identity.effectiveTransport) &&
            query.identity.providerKind.isNotBlank() &&
            query.identity.resolvedModelId().isNotBlank()
        // And only when we genuinely hold nothing. `transport_mismatch`, `stale_generation`
        // and `expired` do not mean "unknown"; they mean the evidence we hold does not belong
        // to this request at all. Letting a responses declaration through on the chat branch
        // is a wire shape error, not an opportunity for the user to try it once.
        val ignorant = reason == "missing_evidence"
        return if (query.hasExplicitValue && dispatchable && ignorant) {
            Resolution(
                key = key,
                support = "unknown",
                source = "none",
                grade = "none",
                requestPolicy = "allow_explicit_unverified",
                reasonCode = "user_accepted_unverified",
            )
        } else {
            unknown(key, reason)
        }
    }

    private fun unavailableReason(candidates: List<Candidate>, query: Query): String {
        val identityMatched = candidates.filter { candidate -> providerModelMatches(candidate.identity, query.identity) }
        if (identityMatched.isEmpty()) return "missing_evidence"
        if (identityMatched.any { it.identity.effectiveTransport != query.identity.effectiveTransport }) {
            return "transport_mismatch"
        }
        val transportMatched = identityMatched.filter {
            it.identity.effectiveTransport == query.identity.effectiveTransport
        }
        val revisionMatched = transportMatched.filter { !revisionMismatch(it.identity, query.identity) }
        if (transportMatched.size != revisionMatched.size) return "stale_generation"
        val scopeMatched = revisionMatched.filter { scopeMatches(it, query.identity) }
        if (scopeMatched.any { it.expiresAt != null && it.expiresAt <= query.now }) return "expired"
        return "missing_evidence"
    }

    private fun isUsable(candidate: Candidate, query: Query): Boolean =
        hasConcreteBaseIdentity(candidate.identity, query.identity) &&
            providerModelMatches(candidate.identity, query.identity) &&
            candidate.identity.effectiveTransport == query.identity.effectiveTransport &&
            scopeMatches(candidate, query.identity) &&
            !revisionMismatch(candidate.identity, query.identity) &&
            (candidate.expiresAt == null || candidate.expiresAt > query.now)

    private fun providerModelMatches(candidate: CandidateIdentity, query: QueryIdentity): Boolean {
        if (candidate.providerKind != query.providerKind) return false
        if (candidate.modelId != query.modelId && candidate.modelId != query.canonicalModelId) return false
        return true
    }

    private fun hasConcreteBaseIdentity(candidate: CandidateIdentity, query: QueryIdentity): Boolean =
        query.providerKind.isNotBlank() &&
            query.resolvedModelId().isNotBlank() &&
            candidate.providerKind.isNotBlank() &&
            candidate.modelId.isNotBlank() &&
            isConcreteTransport(query.effectiveTransport) &&
            isConcreteTransport(candidate.effectiveTransport)

    private fun scopeMatches(candidate: Candidate, query: QueryIdentity): Boolean = when (candidate.scope) {
        "provider_model_transport" -> true
        "connection_model_transport", "exact_request" ->
            query.partitionId.isNotBlank() &&
                query.connectionInstanceId.isNotBlank() &&
                query.connectionGeneration.isNotBlank() &&
                query.credentialEpoch.isNotBlank() &&
                !query.endpointFingerprint.isNullOrBlank() &&
                !candidate.identity.partitionId.isNullOrBlank() &&
                !candidate.identity.connectionInstanceId.isNullOrBlank() &&
                !candidate.identity.connectionGeneration.isNullOrBlank() &&
                !candidate.identity.credentialEpoch.isNullOrBlank() &&
                !candidate.identity.endpointFingerprint.isNullOrBlank() &&
                candidate.identity.partitionId == query.partitionId &&
                candidate.identity.connectionInstanceId == query.connectionInstanceId &&
                candidate.identity.connectionGeneration == query.connectionGeneration &&
                candidate.identity.credentialEpoch == query.credentialEpoch &&
                candidate.identity.endpointFingerprint == query.endpointFingerprint
        else -> false
    }

    private fun revisionMismatch(candidate: CandidateIdentity, query: QueryIdentity): Boolean =
        !optionalIdentityMatches(candidate.metadataRevision, query.metadataRevision) ||
            !optionalIdentityMatches(candidate.generationRevision, query.generationRevision)

    private fun optionalIdentityMatches(candidate: String?, query: String?): Boolean =
        candidate == null || candidate == query

    fun isConcreteTransport(value: String?): Boolean =
        value?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
            ?.let { it !in setOf("unknown", "auto", "unavailable") } == true

    private fun QueryIdentity.resolvedModelId(): String = canonicalModelId?.takeIf { it.isNotBlank() } ?: modelId

    private fun Candidate.resolution(policy: String, reason: String) = Resolution(
        key = key,
        support = support,
        source = source,
        grade = grade,
        requestPolicy = policy,
        reasonCode = reason,
    )

    private fun unknown(key: String, reason: String) = Resolution(
        key = key,
        support = "unknown",
        source = "none",
        grade = "none",
        requestPolicy = "omit_unknown",
        reasonCode = reason,
    )

    private fun String?.toEvidenceSource(): String = when (this) {
        "authoritative_metadata", "provider_metadata" -> "server_profile"
        "relay_verification" -> "relay_verification"
        "relay_declared", "user_declared", "engine_profile" -> "relay_declaration"
        else -> "legacy_metadata"
    }

    // ---- Three-valued input capability projection (same semantics as Web capability-evidence-facade.ts) ----

    /** Input capability verdict from the payload; a missing entry is passed as null by the caller and projected as unknown. */
    data class InputCapabilityVerdict(
        val state: String,
        val reasonCode: String? = null,
        val wireFamily: String? = null,
    )

    /** The Relay user's manual override of an input capability; ignored on official connections. */
    @Serializable
    enum class InputCapabilityOverride {
        @SerialName("add") ADD,
        @SerialName("remove") REMOVE,
    }

    @Serializable
    enum class InputCapabilityConnection {
        @SerialName("official") OFFICIAL,
        @SerialName("relay") RELAY,
    }

    @Serializable
    enum class InputCapabilityOutbound {
        @SerialName("native_part") NATIVE_PART,
        @SerialName("placeholder") PLACEHOLDER,
    }

    @Serializable
    enum class InputCapabilityHint {
        /** Hint only once per device per model. */
        @SerialName("first_attach_once") FIRST_ATTACH_ONCE,
    }

    @Serializable
    enum class InputCapabilityDisabledReason {
        @SerialName("disabled.kill_switch") KILL_SWITCH,
        @SerialName("disabled.wire_not_implemented") WIRE_NOT_IMPLEMENTED,
        @SerialName("disabled.user_removed") USER_REMOVED,
        @SerialName("disabled.rejected_recently") REJECTED_RECENTLY,
        @SerialName("disabled.model_absent") MODEL_ABSENT,
    }

    /**
     * Input capability projection. The constructor is private and instances come only from [projectInputCapability]
     * (the rule body lives in the companion because the outer Kotlin object cannot see a nested class's private constructor);
     * not a data class, so copy is not exposed.
     */
    class InputCapabilityProjection private constructor(
        val visible: Boolean,
        val editable: Boolean,
        val outbound: InputCapabilityOutbound,
        val hint: InputCapabilityHint?,
        val disabledReason: InputCapabilityDisabledReason?,
    ) {
        override fun equals(other: Any?): Boolean =
            other is InputCapabilityProjection &&
                visible == other.visible &&
                editable == other.editable &&
                outbound == other.outbound &&
                hint == other.hint &&
                disabledReason == other.disabledReason

        override fun hashCode(): Int = listOf(visible, editable, outbound, hint, disabledReason).hashCode()

        override fun toString(): String =
            "InputCapabilityProjection(visible=$visible, editable=$editable, outbound=$outbound, " +
                "hint=$hint, disabledReason=$disabledReason)"

        internal companion object {
            // The control-state vocabulary lives only in CapabilityControlResolution.
            private const val STATE_AUTO_AVAILABLE = CapabilityControlResolution.STATE_AUTO_AVAILABLE
            private const val STATE_UNKNOWN = "unknown"
            private const val STATE_UNAVAILABLE = "unavailable"

            /** Priority: kill_switch > not implemented on this platform > Relay remove > Relay add > negative cache > verdict. */
            internal fun project(
                verdict: InputCapabilityVerdict?,
                endImplements: Boolean,
                override: InputCapabilityOverride?,
                negativeCacheHit: Boolean,
                connection: InputCapabilityConnection,
            ): InputCapabilityProjection {
                val reasonCode = verdict?.reasonCode?.takeIf { verdict.state == STATE_UNAVAILABLE }
                // Hard block: no override can flip it.
                if (reasonCode == "provider_kill_switch") return disabled(InputCapabilityDisabledReason.KILL_SWITCH)
                if (
                    !endImplements ||
                    (verdict?.wireFamily != null && !endImplementsWireFamily(verdict.wireFamily)) ||
                    reasonCode == "transport_not_supported" ||
                    reasonCode == "transport_not_implemented"
                ) {
                    return disabled(InputCapabilityDisabledReason.WIRE_NOT_IMPLEMENTED)
                }
                if (connection == InputCapabilityConnection.RELAY && override != null) {
                    return when (override) {
                        InputCapabilityOverride.ADD -> available()
                        InputCapabilityOverride.REMOVE -> disabled(InputCapabilityDisabledReason.USER_REMOVED)
                    }
                }
                if (negativeCacheHit) return disabled(InputCapabilityDisabledReason.REJECTED_RECENTLY)
                return when (verdict?.state ?: STATE_UNKNOWN) {
                    STATE_AUTO_AVAILABLE -> available()
                    STATE_UNKNOWN -> InputCapabilityProjection(
                        visible = false,
                        editable = true,
                        outbound = InputCapabilityOutbound.NATIVE_PART,
                        hint = InputCapabilityHint.FIRST_ATTACH_ONCE,
                        disabledReason = null,
                    )
                    // Every other unavailable reason (model_capability_absent etc.) means the model lacks the capability.
                    else -> disabled(InputCapabilityDisabledReason.MODEL_ABSENT)
                }
            }

            private fun available() = InputCapabilityProjection(
                visible = true,
                editable = true,
                outbound = InputCapabilityOutbound.NATIVE_PART,
                hint = null,
                disabledReason = null,
            )

            private fun disabled(reason: InputCapabilityDisabledReason) = InputCapabilityProjection(
                visible = false,
                editable = false,
                outbound = InputCapabilityOutbound.PLACEHOLDER,
                hint = null,
                disabledReason = reason,
            )
        }
    }

    /**
     * The single entry for input capability projection. [key] is [VISION_INPUT] / [FILE_INPUT] / [VIDEO_INPUT];
     * a null [verdict] means the payload lacks the key and is projected as unknown.
     */
    fun projectInputCapability(
        key: String,
        verdict: InputCapabilityVerdict?,
        endImplements: Boolean,
        override: InputCapabilityOverride?,
        negativeCacheHit: Boolean,
        connection: InputCapabilityConnection,
    ): InputCapabilityProjection {
        require(key == VISION_INPUT || key == FILE_INPUT || key == VIDEO_INPUT) { "not an input capability key: $key" }
        return InputCapabilityProjection.project(verdict, endImplements, override, negativeCacheHit, connection)
    }

    /**
     * Input wire families implemented at compile time on Android; aligned item by item with the families whose implementedBy
     * includes android in shared/model-contracts/wire_families.v1.json, locked by ProtocolImplementationsTest,
     * so change both together when protocol implementations are added or removed.
     */
    object ProtocolImplementations {
        val android: Set<String> = setOf(
            "openai_chat.image_url",
            "openai_chat.file",
            "openai_chat.video_url",
            "openai_responses.input_image",
            "openai_responses.input_file",
            "anthropic.image",
            "anthropic.document",
            "gemini.inline_data",
        )
    }

    /** Whether this platform implements the wire family; missing or not in the table counts as not implemented. */
    fun endImplementsWireFamily(id: String?): Boolean = id != null && id in ProtocolImplementations.android
}
