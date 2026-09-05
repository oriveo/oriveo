package ai.oriveo.community.core.provider

import android.content.Context
import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind

/**
 * The four empty states a generation-parameter container can be in.
 *
 * They are mutually exclusive and **every trigger is decidable locally on the client**; none of
 * them needs a new field from anywhere. Four states rather than one, because the user's next
 * move is completely different in each: A there is nothing to do yet, B the published profile
 * changed under them, C they can unlock it themselves, D this is simply the truth about this
 * connection.
 */
enum class GenerationParameterEmptyState(
    /**
     * Wording rule: attribute the situation to **this connection**, never to "this model".
     * The evidence is gathered per provider and model pair, so "the model does not support it"
     * is a claim we have no evidence for - it is a false capability reading in reverse.
     * Never show a percentage or a progress number here, and never promise a timeline.
     */
    @StringRes val titleRes: Int,
    /** Only state A needs to expand on why there is nothing here right now; the other three
     *  already say what to do next in a single line. */
    @StringRes val detailRes: Int? = null,
) {
    /** A - not verified yet: this model on this connection has never returned a non-empty
     *  profile. Fail safe rather than guess. */
    NotVerified(R.string.generation_empty_not_verified, R.string.generation_empty_not_verified_detail),

    /** B - the catalog took it over or withdrew it: the user has seen a non-empty profile for
     *  this pair on this device before, and it is empty now. */
    CatalogManaged(R.string.generation_empty_catalog_managed),

    /** C - runtime access is closed for this connection. */
    RuntimeAccessLocked(R.string.generation_empty_runtime_locked),

    /** D - nothing is adjustable: the profile is non-empty, but not one entry in the current
     *  scope can be changed. */
    AllUnsupported(R.string.generation_empty_all_unsupported),
    ;

    val showsUpgradeAction: Boolean get() = false
}

/**
 * The rendering predicates for the generation-parameter panel.
 *
 * Why this exists: the panel used to inline three separate judgements - which parameters are
 * visible, whether an empty container still renders, and whether an unknown entry gets a badge -
 * directly inside composables, where tests could not drive them. "Must not silently collapse"
 * and "the badge is mandatory" then had nothing but human review holding them up. As plain
 * functions, tests can assert against the production predicates themselves.
 */
object GenerationParameterPanelPresentation {

    /** Core-owned parameter-id → governed decision bridge; feature code never assembles evidence keys. */
    internal fun generationParameterDecision(
        parameter: GenerationParameterRef,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): CapabilityEvidenceProductionAdapter.Decision? = parameter.id
        ?.takeIf(String::isNotBlank)
        ?.let { id -> capabilityProjection.decision("generation_parameter/$id") }

    /**
     * The visible parameter set for the current scope. The panel **may only ask this one
     * function**; it must never inline its own copy of the support predicate.
     *
     * The session scope deliberately ignores the access flag: session-level actionability has no
     * access dimension by design, and the runtime-access filter only applies in the connection
     * scope, where the `engine_runtime` group lives.
     */
    internal fun visibleParameters(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        access: GenerationAccess,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = defaultProjection(provider, model),
    ): List<GenerationParameterRef> = when (scope) {
        GenerationParameterEntryScope.Session ->
            GenerationParameterAvailability.sessionActionable(provider, model, capabilityProjection)
        GenerationParameterEntryScope.ConnectionDefaults ->
            GenerationParameterAvailability.connectionConfigurable(provider, model, access, capabilityProjection)
    }

    /**
     * The candidate list behind the primary action on a "not adjustable" row: **which models on
     * this connection accept this parameter**.
     *
     * The predicate is **the same one the parameter rows use** - the same `visibleParameters`
     * projection plus the same [GenerationParameterSupportPresentation] table. Writing a second
     * definition of "accepted" is how you get "the list said this model works, but tapping
     * through leaves it greyed out"; the badge-versus-control split had exactly that shape, and
     * when it was measured dozens of models disagreed between the two paths.
     *
     * Read-only on purpose: it answers a question, it does not helpfully switch the user's model
     * on the way. The model-behaviour page already has its own model picker, and slipping a
     * destructive action in here brings back the old "looks like a list, one tap changed my
     * conversation" problem.
     */
    internal fun modelsAcceptingParameter(
        provider: Provider,
        parameterId: String,
        scope: GenerationParameterEntryScope,
        access: GenerationAccess,
    ): List<AIModel> = provider.models.filter { candidate ->
        val projection = defaultProjection(provider, candidate)
        val ref = visibleParameters(provider, candidate, scope, access, projection)
            .firstOrNull { it.id == parameterId }
            ?: return@filter false
        val supportKey = GenerationParameterSupportPresentation.effectiveSupport(
            ref.support,
            generationParameterDecision(ref, projection)?.resolution?.support,
        )
        GenerationParameterSupportPresentation.entry(supportKey).control ==
            GenerationParameterSupportPresentation.Control.Editable
    }

    /**
     * Which empty state applies. `null` means there are visible parameters and the container
     * renders normally.
     *
     * [hasSeenNonEmptyProfile] is the only thing separating A from B, and it comes from
     * [GenerationParameterProfileHistory].
     *
     * Known limitation: that history is local to this device, so after a reinstall, a device
     * change or a cache wipe, B degrades into A. Both say "not adjustable right now", which is
     * acceptable; making it exact would require an explicit withdrawal marker in the published
     * catalog, and the A/B distinction inherently depends on the client's own history anyway.
     */
    internal fun emptyState(
        provider: Provider,
        model: AIModel,
        scope: GenerationParameterEntryScope,
        access: GenerationAccess,
        hasSeenNonEmptyProfile: Boolean,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection = defaultProjection(provider, model),
    ): GenerationParameterEmptyState? {
        if (visibleParameters(provider, model, scope, access, capabilityProjection).isNotEmpty()) return null

        val declared = GenerationParameterAvailability.profile(provider, model)?.parameters.orEmpty()
        // (a) The profile is absent or declares nothing. Only the local history knows whether
        // this pair never had one or used to have one.
        if (declared.isEmpty()) {
            return if (hasSeenNonEmptyProfile) {
                GenerationParameterEmptyState.CatalogManaged
            } else {
                GenerationParameterEmptyState.NotVerified
            }
        }

        return GenerationParameterEmptyState.AllUnsupported
    }

    /**
     * The per-row "unverified" badge.
     *
     * Declarations that Relay **synthesises locally** from a protocol template have to say so on
     * every row: this was inferred from the protocol, nobody has actually tried it. The badge is
     * about **where the evidence came from**; it is not a licence for the provider kind to
     * redefine what support means. An official unknown uses the shared "no information yet"
     * presentation and does not masquerade as a locally synthesised Relay declaration.
     */
    internal fun showsUnverifiedBadge(
        parameter: GenerationParameterRef,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): Boolean = generationParameterDecision(parameter, capabilityProjection)?.isUnverified == true

    /** The group-level explanatory line: it must appear whenever any parameter in the currently
     *  rendered set carries the badge. */
    internal fun showsUnverifiedGroupNote(
        parameters: List<GenerationParameterRef>,
        capabilityProjection: CapabilityEvidenceProductionAdapter.Projection,
    ): Boolean = parameters.any { showsUnverifiedBadge(it, capabilityProjection) }

    private fun defaultProjection(
        provider: Provider,
        model: AIModel,
    ): CapabilityEvidenceProductionAdapter.Projection =
        CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = provider,
            model = model,
            localIdentity = null,
            parameters = GenerationParameterAvailability.profile(provider, model)?.parameters.orEmpty(),
            values = ai.oriveo.community.core.model.GenerationParameterOverrides(),
        )
}

/**
 * The history bit behind "has this device ever seen a non-empty profile for this model on this
 * connection".
 *
 * It exists purely to separate empty states A and B, and it takes part in no send-path decision
 * whatsoever. It is a pure UI history: wiping it only degrades B into A (see
 * [GenerationParameterPanelPresentation.emptyState]).
 */
class GenerationParameterProfileHistory(
    private val readPayload: () -> String?,
    private val writePayload: (String?) -> Unit,
) {
    fun hasSeenNonEmptyProfile(providerID: String, modelID: String): Boolean =
        entryKey(providerID, modelID) in entries()

    /**
     * Called once each time the panel actually renders a non-empty profile to the user.
     * `parameterCount == 0` is not recorded: "has seen an empty one" is not what B asks about,
     * B needs "has seen a non-empty one".
     */
    fun recordSeenProfile(providerID: String, modelID: String, parameterCount: Int) {
        if (parameterCount <= 0 || modelID.isEmpty()) return
        val key = entryKey(providerID, modelID)
        synchronized(this) {
            val current = entries()
            if (key in current) return
            // The cap is sized to the connection-and-model combinations a real user opens;
            // beyond that the oldest entry is dropped so this cannot grow without bound.
            // Stored as an ordered list rather than a Set because SharedPreferences string sets
            // are unordered, leaving no way to tell which entry is oldest.
            val next = (current + key).let { if (it.size > MAX_ENTRY_COUNT) it.takeLast(MAX_ENTRY_COUNT) else it }
            writePayload(next.joinToString(SEPARATOR))
        }
    }

    fun reset() = synchronized(this) { writePayload(null) }

    private fun entries(): List<String> =
        readPayload()?.split(SEPARATOR)?.filter(String::isNotEmpty).orEmpty()

    private fun entryKey(providerID: String, modelID: String): String = "$providerID|$modelID"

    companion object {
        private const val PREFS_NAME = "generation_parameter_profile_seen"
        private const val KEY_PAYLOAD = "entries.v1"
        private const val SEPARATOR = "\n"
        private const val MAX_ENTRY_COUNT = 300

        fun from(context: Context): GenerationParameterProfileHistory {
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return GenerationParameterProfileHistory(
                readPayload = { prefs.getString(KEY_PAYLOAD, null) },
                writePayload = { payload -> prefs.edit().putString(KEY_PAYLOAD, payload).apply() },
            )
        }
    }
}
