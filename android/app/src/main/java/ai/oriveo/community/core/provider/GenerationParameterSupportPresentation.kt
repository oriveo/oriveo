package ai.oriveo.community.core.provider

import androidx.annotation.StringRes
import ai.oriveo.community.R

/**
 * Maps the eight engineering values of `support` onto the three classes a user can see,
 * plus one class that says nothing at all.
 *
 * The hand-written `supportLabel` switch this replaces only rendered five of the values;
 * `unsupported`, `accepted` and `future_supported` all fell through to the default and
 * were shown as "unknown". That collapsed "this model refuses this parameter and the
 * request will be rejected" and "we have not established anything yet" into the same
 * sentence, which is simply a false statement about the model.
 *
 * The source of truth is
 * `shared/model-contracts/generation_parameter_contract.v1.json#presentationClasses`;
 * this table is its projection, and
 * `GenerationParameterSupportPresentationContractTest` reconciles the two entry by
 * entry. When a ninth engineering value appears, failing to add a row here is a test
 * failure rather than a silent slide into "no data yet".
 */
object GenerationParameterSupportPresentation {

    /**
     * The classes a user can see. `silent` is the normal case: the vast majority of
     * parameters are `supported`, and hanging a "supported" note off every row would
     * bury the unverified, not-adjustable and no-data rows that actually need attention.
     */
    enum class PresentationClass(val id: String) {
        Silent("silent"),
        Unverified("unverified"),
        NotAdjustable("not_adjustable"),
        NoData("no_data"),
    }

    /** Whether the control itself can be edited. A `disabled` control must always come with a primary action, otherwise the user is at a dead end. */
    enum class Control(val id: String) {
        Editable("editable"),
        Disabled("disabled"),
    }

    data class Entry(
        val presentationClass: PresentationClass,
        val renders: Boolean,
        val control: Control,
        /** Class-level label, such as "will be sent, effect unverified", "not adjustable" or "no data"; null for `silent`. */
        @param:StringRes val labelRes: Int?,
        /** Value-level detail line, one per engineering value, kept separate from the class label. */
        @param:StringRes val detailRes: Int?,
        /** The actionable primary action a disabled row has to offer. */
        @param:StringRes val primaryActionRes: Int?,
    )

    /** Class-level copy. The keys correspond one to one with the contract's `classes[].labelKey`. */
    @StringRes
    private fun classLabelRes(presentationClass: PresentationClass): Int? = when (presentationClass) {
        PresentationClass.Silent -> null
        PresentationClass.Unverified -> R.string.generation_parameter_class_unverified
        PresentationClass.NotAdjustable -> R.string.generation_parameter_class_not_adjustable
        PresentationClass.NoData -> R.string.generation_parameter_class_no_data
    }

    /**
     * Which class each engineering value belongs to. This table is the projection of the
     * contract's `supportMap`, declared in the same order so the two can be reconciled
     * line by line.
     */
    private val classBySupport: Map<String, PresentationClass> = linkedMapOf(
        "supported" to PresentationClass.Silent,
        "accepted" to PresentationClass.Silent,
        "accepted_unverified" to PresentationClass.Unverified,
        "fixed" to PresentationClass.NotAdjustable,
        "unsupported" to PresentationClass.NotAdjustable,
        "mode_dependent" to PresentationClass.NotAdjustable,
        "unknown" to PresentationClass.NoData,
        "future_supported" to PresentationClass.NotAdjustable,
    )

    /** Value-level detail copy, from the contract's `supportMap[*].detailKey`. */
    @StringRes
    private fun detailRes(support: String): Int? = when (support) {
        "accepted_unverified" -> R.string.generation_parameter_detail_accepted_unverified
        "fixed" -> R.string.generation_parameter_detail_fixed
        "unsupported" -> R.string.generation_parameter_detail_unsupported
        "mode_dependent" -> R.string.generation_parameter_detail_mode_dependent
        "unknown" -> R.string.generation_parameter_detail_unknown
        "future_supported" -> R.string.generation_parameter_detail_future_supported
        else -> null
    }

    /** An unregistered value must NOT quietly degrade: returning null lets the caller, and the contract test, see the gap. */
    fun entryForRegistered(support: String): Entry? {
        val presentationClass = classBySupport[support] ?: return null
        return Entry(
            presentationClass = presentationClass,
            renders = presentationClass != PresentationClass.Silent,
            control = if (presentationClass == PresentationClass.NotAdjustable) {
                Control.Disabled
            } else {
                Control.Editable
            },
            labelRes = classLabelRes(presentationClass),
            detailRes = detailRes(support),
            primaryActionRes = if (presentationClass == PresentationClass.NotAdjustable) {
                R.string.model_control_view_supported_models
            } else {
                null
            },
        )
    }

    /**
     * UI entry point: a missing `support`, or one we have not registered, renders as "no
     * data". The gap still has to surface through [entryForRegistered] returning null at
     * test time; this fallback must never be what hides it.
     */
    fun entry(support: String?): Entry =
        support?.let(::entryForRegistered) ?: Entry(
            presentationClass = PresentationClass.NoData,
            renders = true,
            control = Control.Editable,
            labelRes = classLabelRes(PresentationClass.NoData),
            detailRes = detailRes("unknown"),
            primaryActionRes = null,
        )

    /** Every engineering value registered in this table, used to reconcile against the contract. */
    val registeredSupports: Set<String> get() = classBySupport.keys

    /**
     * Combines the engineering value a profile declares with observed evidence to decide
     * what the row should actually present.
     *
     * The evidence layer only ever produces three values, supported / unsupported /
     * unknown: [CapabilityEvidenceFacade.normalizeGenerationParameter] flattens
     * `accepted`, `accepted_unverified`, `fixed` and `mode_dependent` all down to
     * `unknown`. Feeding that three-valued result straight into presentation is exactly
     * what made the `accepted_unverified` label structurally unreachable.
     *
     * So the relationship is inverted here: evidence can only veto or downgrade, while
     * the engineering value itself still comes from the profile declaration.
     */
    fun effectiveSupport(declared: String?, resolved: String?): String {
        val declaredValue = declared?.trim().orEmpty()
        val evidence = resolved?.trim().orEmpty()
        // The profile's four explicit negatives keep their precise wording; none of them
        // is editable and none of them can go out on the wire.
        if (declaredValue in setOf("unsupported", "fixed", "mode_dependent", "future_supported")) {
            return declaredValue
        }
        if (evidence == "unsupported") return "unsupported"
        if (evidence == "supported") return "supported"
        // Evidence reached no conclusion, which includes a relay downgraded to a
        // connection-scoped unknown. A positive claim in the profile cannot stand in for a
        // conclusion, because that is precisely saying we know when we do not. Downgrade it
        // to "will be sent, effect unverified": unverified is not the same as unsupported,
        // and the value is still sent. Every other engineering value is already honest and
        // passes through unchanged.
        if (declaredValue == "supported") return "accepted_unverified"
        return if (declaredValue in classBySupport) declaredValue else "unknown"
    }
}
