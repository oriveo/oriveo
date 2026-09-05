package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider

/** `Active` means the value still goes out under the current profile; `Dormant` means the value is kept but not sent. The two are mutually exclusive and exhaustive. */
enum class GenerationParameterLifecycle { Active, Dormant }

/**
 * One scope record split in two by the current profile.
 *
 * [dormantIds] only collects parameters that actually carry user intent, so `Inherit`
 * is excluded. The count in the summary line is its length; counting `Inherit` would
 * report a number the user never set.
 */
data class GenerationParameterPartition(
    val active: GenerationParameterOverrides,
    val dormant: GenerationParameterOverrides,
    val dormantIds: List<String>,
)

/**
 * Lifecycle of a stored parameter value: a per-field revalidation once the profile
 * changes.
 *
 * The contract asks for exactly that. After a profile revision or a mode change, every
 * field is rechecked individually: values that remain compatible keep working, values
 * that no longer are get kept as dormant but are not sent, and nothing may be silently
 * substituted. What used to happen here was all-or-nothing at record level:
 * `GenerationParameterSettingsStore` folded the whole `profileFingerprint` into the
 * scope identity, so changing transport or engine made the entire record unreadable
 * while it stayed on disk and kept syncing. From the user's side that reads as "but I
 * definitely saved this". This file pushes the judgement down to the individual
 * parameter id.
 *
 * The decisive property is that this judgement shares its source with the outbound
 * gate. [GenerationParameterResolver.apply] decides whether a value is actually sent
 * using "declared by the profile, non-empty wire path, and support within the outbound
 * whitelist, with relay unknown specially permitted". If the read side copied its own
 * version of that rule, you would get a summary claiming three values were retained
 * while one went out. So this mirrors the same predicate line for line, and
 * `shared/model-contracts/generation_parameter_contract.v1.json#lifecycleCases` locks
 * the two together, with `GenerationParameterLifecycleTest` as the consumer here.
 *
 * Dormant is a derived state, not a stored one: it is what the current profile on this
 * particular device concludes about an already stored value. It therefore never enters
 * the SharedPreferences record and never enters the `generation_parameter_sync.v1`
 * envelope. Putting it on the wire would let device A's profile switch off a value that
 * device B can perfectly well send, which is silent substitution across devices.
 */
object GenerationParameterLifecycleRules {

    /**
     * Revalidates a single parameter id. It deliberately does NOT look at the value
     * itself: a value out of range or outside an enum is a compatibility hint, shown so
     * the user can fix it, and is not a lifecycle question. Folding it in here would
     * quietly move a value the user stored into dormant, which is just another shape of
     * the silent substitution the contract forbids.
     *
     * A null [parameter] means the current profile no longer declares that id, which has
     * to be judged per field rather than invalidating the whole record.
     */
    internal fun lifecycle(
        parameter: GenerationParameterRef?,
        wirePath: String?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection?,
    ): GenerationParameterLifecycle {
        if (parameter == null || wirePath.isNullOrEmpty()) return GenerationParameterLifecycle.Dormant
        val id = parameter.id ?: return GenerationParameterLifecycle.Dormant
        // The predicate is the outbound gate itself (`permitsOutbound`), not `editable`.
        // `editable` answers "can this row be changed", and under the old reading it only
        // accepted support == "supported". Stored values sitting at `unknown`, `accepted`
        // or `accepted_unverified` were therefore all judged dormant: the panel said
        // editable while nothing went out, which is exactly the "what is shown is not what
        // happens" mismatch this is meant to kill.
        // `permitsOutbound` is the very predicate the request builders in AnthropicService,
        // QwenService, GeminiService and the rest actually ask
        // (`capabilityProjection.permitsOutbound("generation_parameter/<id>")`), so using
        // it satisfies the contract's outbound parity for free: the set the read side calls
        // active is identical to the set the send side will really write. Explicit intent
        // is carried by the projection's explicitKeys, which `generationParameterUiProjection`
        // fills from the values whose state is not Inherit, matching the contract's stored
        // state of value or omit. The four states `unsupported`, `fixed`, `mode_dependent`
        // and `future_supported` all take the same veto path in the facade and stay dormant.
        return if (capabilityProjection?.permitsOutbound("generation_parameter/$id") == true) {
            GenerationParameterLifecycle.Active
        } else {
            GenerationParameterLifecycle.Dormant
        }
    }

    /**
     * The parameter ids that still go out under this profile. The send chain uses it to
     * keep dormant values out of evaluation entirely.
     *
     * [profile] is passed in rather than looked up here on purpose: the send side,
     * [GenerationParameterResolver.apply], uses `activeModel.generationProfile` falling
     * back to what the catalog resolves, and the read side has to judge against that same
     * profile. Let the two drift apart and you are back to "the summary says N retained,
     * M actually went out".
     */
    internal fun activeParameterIds(
        profile: GenerationProfileRef?,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection?,
    ): Set<String> {
        val parameters = profile?.parameters ?: return emptySet()
        return parameters.mapNotNullTo(mutableSetOf()) { parameter ->
            val id = parameter.id ?: return@mapNotNullTo null
            id.takeIf { lifecycle(parameter, profile.wire[it], capabilityProjection) == GenerationParameterLifecycle.Active }
        }
    }

    /** Without a final Relay scope the panel is deliberately read-only; callers may pass in a UI projection from the same generation. */
    internal fun activeParameterIds(
        provider: Provider,
        model: AIModel,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    ): Set<String> = activeParameterIds(
        GenerationParameterAvailability.profile(provider, model),
        capabilityProjection ?: CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            keys = GenerationParameterAvailability.profile(provider, model)?.parameters.orEmpty()
                .mapNotNull { it.id?.takeIf(String::isNotBlank) }
                .mapTo(linkedSetOf()) { "generation_parameter/$it" },
        ),
    )

    /**
     * Send-side compatibility only: retain declared values until the final request projection
     * can judge the concrete Relay transport/URL. It deliberately does not authorize output.
     */
    internal fun declaredParameterIdsForFinalDispatch(
        profile: GenerationProfileRef?,
    ): Set<String> = profile?.let { current ->
        current.parameters.mapNotNullTo(linkedSetOf()) { parameter ->
            parameter.id?.takeIf { !current.wire[it].isNullOrEmpty() }
        }
    }.orEmpty()

    /**
     * Splits one scope record into its active and dormant halves under the current
     * profile.
     *
     * When the profile is absent altogether, because nothing has been established about
     * this connection yet, everything falls to dormant. "None of these can be sent" is
     * the truth, and a summary saying "kept, will not be sent right now" is more honest
     * than pretending nothing was ever stored.
     */
    internal fun partition(
        provider: Provider,
        model: AIModel,
        values: GenerationParameterOverrides,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection? = null,
    ): GenerationParameterPartition {
        val activeIds = activeParameterIds(provider, model, capabilityProjection)
        val active = LinkedHashMap<String, GenerationParameterOverride>()
        val dormant = LinkedHashMap<String, GenerationParameterOverride>()
        val dormantIds = mutableListOf<String>()
        values.values.forEach { (id, override) ->
            if (id in activeIds) {
                active[id] = override
                return@forEach
            }
            // `Inherit` carries no user intent; it means "defer to a lower priority", so it
            // stays on the active side and does not count towards the dormant total.
            if (override.state == GenerationOverrideState.Inherit) {
                active[id] = override
                return@forEach
            }
            dormant[id] = override
            dormantIds += id
        }
        return GenerationParameterPartition(
            active = GenerationParameterOverrides(active),
            dormant = GenerationParameterOverrides(dormant),
            dormantIds = dormantIds,
        )
    }
}
