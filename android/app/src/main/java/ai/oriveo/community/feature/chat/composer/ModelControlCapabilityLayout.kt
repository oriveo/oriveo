package ai.oriveo.community.feature.chat.composer

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.canonicalCapabilityTransport
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlPresentation

enum class ModelControlCapabilityEscape {
    None,

    SupportedModels,

    AdvancedSettings,
}

data class ModelControlIntentOption(
    val id: String,
    @param:StringRes val labelRes: Int,
)

@StringRes
internal fun modelControlCapabilityTitleRes(capability: String): Int = when (capability) {
    "web" -> R.string.model_control_web_search
    "reasoning" -> R.string.model_control_thinking
    else -> R.string.generation_model_behavior
}

@StringRes
internal fun intentLabelRes(intent: String): Int = when (intent) {
    "off" -> R.string.model_control_off
    "low" -> R.string.reasoning_fast
    "balanced" -> R.string.reasoning_balanced
    "deep" -> R.string.reasoning_deep
    "max" -> R.string.reasoning_max
    else -> R.string.model_control_supplier_default
}

@StringRes
internal fun webIntentLabelRes(preference: CapabilityWebPreference): Int = when (preference) {
    CapabilityWebPreference.Off -> R.string.model_control_off
    CapabilityWebPreference.Automatic -> R.string.model_control_web_search_when_needed
    CapabilityWebPreference.Force -> R.string.model_control_web_search_every_message
    CapabilityWebPreference.Custom -> R.string.model_control_state_custom
}

@StringRes
internal fun modelControlStatusTextRes(status: CapabilityControlPresentation): Int = when (status) {
    CapabilityControlPresentation.AutomaticAvailable -> R.string.model_control_status_automatic_available

    CapabilityControlPresentation.ForceUnsupported -> R.string.model_control_force_unavailable
    CapabilityControlPresentation.CustomOnly -> R.string.model_control_custom_only_reason
    CapabilityControlPresentation.Pending -> R.string.model_control_status_pending
    CapabilityControlPresentation.ExternalConnectorOnly -> R.string.model_control_reason_external_connector_only
    CapabilityControlPresentation.Unsupported -> R.string.model_control_capability_unavailable_here
    CapabilityControlPresentation.Unknown -> R.string.model_control_status_unknown_route
}

internal fun modelControlShowsSupportedModelsAction(status: CapabilityControlPresentation): Boolean =
    when (status) {
        CapabilityControlPresentation.Unsupported,
        CapabilityControlPresentation.Unknown,
        CapabilityControlPresentation.Pending,
        CapabilityControlPresentation.ExternalConnectorOnly,
        CapabilityControlPresentation.CustomOnly,
        -> true
        CapabilityControlPresentation.AutomaticAvailable,
        CapabilityControlPresentation.ForceUnsupported,
        -> false
    }

enum class ModelControlBadgeClassification {
    None,
    Manual,
    NotReady,
    Unavailable;

    companion object {
        fun resolve(status: CapabilityControlPresentation): ModelControlBadgeClassification = when (status) {
            CapabilityControlPresentation.AutomaticAvailable,
            CapabilityControlPresentation.ForceUnsupported,
            -> None
            CapabilityControlPresentation.CustomOnly -> Manual
            CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown -> NotReady
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.Unsupported,
            -> Unavailable
        }

        fun capabilityCard(status: CapabilityControlPresentation): ModelControlBadgeClassification =
            resolve(status).takeIf { it != Unavailable } ?: None

        fun advancedSettingsCard(status: CapabilityControlPresentation): ModelControlBadgeClassification =
            resolve(status).takeIf { it != NotReady } ?: None
    }
}

enum class ModelControlsEditability {
    Writable,
    RuntimeIdentityUnavailable,
    RuntimeReadOnly;

    val canPersist: Boolean get() = this == Writable

    companion object {
        fun resolve(
            transportIdentity: String?,
            runtimeIsReadOnly: Boolean,
        ): ModelControlsEditability = when {
            transportIdentity.isNullOrEmpty() -> RuntimeIdentityUnavailable
            runtimeIsReadOnly -> RuntimeReadOnly
            else -> Writable
        }
    }
}

enum class ModelControlsIdentityGap {

    RuntimeSnapshotMissing,

    RelayTransportUndecided,

    ModelNotInCatalog;

    enum class RecoveryAction {

        RefetchRuntime,

        OpenConnectionSettings,

        ChooseAnotherModel,
    }

    val recoveryAction: RecoveryAction
        get() = when (this) {
            RuntimeSnapshotMissing -> RecoveryAction.RefetchRuntime
            RelayTransportUndecided -> RecoveryAction.OpenConnectionSettings
            ModelNotInCatalog -> RecoveryAction.ChooseAnotherModel
        }

    @get:StringRes
    val reasonTextRes: Int
        get() = when (this) {
            RuntimeSnapshotMissing -> R.string.model_control_identity_snapshot_missing
            RelayTransportUndecided -> R.string.model_control_identity_relay_transport_undecided
            ModelNotInCatalog -> R.string.model_control_identity_model_not_in_catalog
        }

    companion object {

        fun resolve(
            providerKind: ProviderKind,
            relayTransportIsDecided: Boolean,
            runtimeIsReady: Boolean,
        ): ModelControlsIdentityGap = when {
            !runtimeIsReady -> RuntimeSnapshotMissing
            providerKind == ProviderKind.Relay && !relayTransportIsDecided -> RelayTransportUndecided
            else -> ModelNotInCatalog
        }
    }
}

object CapabilityTransportLabel {
    fun display(transport: String): String? = when (canonicalCapabilityTransport(transport)) {
        "openai_responses" -> "Responses"

        "openai_chat", "openai_chat_completions" -> "Chat Completions"
        "anthropic_messages" -> "Messages"

        "gemini_generate_content" -> "generateContent"
        "dashscope_native" -> "DashScope"

        "openai_images" -> "Images"
        "gemini_image" -> "imageGen"
        "qwen_image" -> "DashScope Image"
        "grok_image" -> "xAI Image"
        "zhipu_image" -> "Zhipu Image"
        "llamacpp_native" -> "llama.cpp"
        else -> null
    }
}

object ModelControlReasoningLayout {

    const val AUTOMATIC_INTENT: String = "automatic"

    val tierOrder: List<String> = listOf("off", "low", "balanced", "deep", "max")

    enum class Form { PillRow, StatusRow }

    data class Layout(
        val form: Form,

        val options: List<ModelControlIntentOption>,
        val selection: String,

        @param:StringRes val selectedAnnotationRes: Int?,

        @param:StringRes val footnoteRes: Int?,

        @param:StringRes val statusTextRes: Int?,

        @param:StringRes val explanationRes: Int?,
        val escape: ModelControlCapabilityEscape,
    )

    fun layout(
        status: CapabilityControlPresentation,
        intents: List<String>,
        selectedIntent: String?,
        isEditable: Boolean,
        hasCustomSchema: Boolean = true,
    ): Layout {
        val selection = selectedIntent ?: AUTOMATIC_INTENT
        return when (status) {

            CapabilityControlPresentation.Unsupported, CapabilityControlPresentation.ExternalConnectorOnly ->
                statusRow(
                    R.string.model_control_not_supported_by_model,
                    R.string.model_control_capability_unavailable_here,
                    ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )
            CapabilityControlPresentation.CustomOnly ->
                statusRow(
                    R.string.model_control_custom_only_reason,
                    R.string.model_control_custom_only_reason,
                    if (hasCustomSchema) ModelControlCapabilityEscape.AdvancedSettings
                    else ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )

            CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown ->
                statusRow(
                    R.string.model_control_cannot_adjust_yet,
                    R.string.model_control_reasoning_no_official_config,
                    ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )
            CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.ForceUnsupported ->
                when {
                    !isEditable -> statusRow(
                        intentLabelRes(selection), null, ModelControlCapabilityEscape.None, selection,
                    )

                    intents.isEmpty() -> statusRow(
                        R.string.model_control_reasoning_fixed_level,
                        null,
                        ModelControlCapabilityEscape.None,
                        selection,
                    )
                    else -> pillRow(intents, selection)
                }
        }
    }

    @StringRes
    fun captionRes(intent: String): Int? = when (intent) {
        "off" -> R.string.model_control_reasoning_note_off
        AUTOMATIC_INTENT -> R.string.model_control_reasoning_note_automatic
        "low" -> R.string.model_control_reasoning_note_fast
        "balanced" -> R.string.model_control_reasoning_note_balanced
        "deep" -> R.string.model_control_reasoning_note_deep
        "max" -> R.string.model_control_reasoning_note_max
        else -> null
    }

    private fun pillRow(intents: List<String>, selection: String): Layout {
        val available = intents.toSet()
        val options = mutableListOf<ModelControlIntentOption>()

        if ("off" in available) options += option("off")

        options += option(AUTOMATIC_INTENT)
        tierOrder.filter { it != "off" && it in available }.forEach { options += option(it) }

        val effective = if (options.any { it.id == selection }) selection else AUTOMATIC_INTENT
        return Layout(
            form = Form.PillRow,
            options = options,
            selection = effective,
            selectedAnnotationRes = captionRes(effective),

            footnoteRes = if ("off" in available) null else R.string.model_control_reasoning_off_unavailable,
            statusTextRes = null,
            explanationRes = null,
            escape = ModelControlCapabilityEscape.None,
        )
    }

    private fun option(intent: String) = ModelControlIntentOption(intent, intentLabelRes(intent))

    private fun statusRow(
        @StringRes textRes: Int,
        @StringRes explanationRes: Int?,
        escape: ModelControlCapabilityEscape,
        selection: String,
    ) = Layout(
        form = Form.StatusRow,
        options = emptyList(),
        selection = selection,
        selectedAnnotationRes = null,
        footnoteRes = null,
        statusTextRes = textRes,
        explanationRes = explanationRes,
        escape = escape,
    )
}

object ModelControlWebLayout {
    enum class Form { Toggle, StatusRow }

    data class Layout(
        val form: Form,

        val isOn: Boolean,

        @param:StringRes val captionRes: Int?,

        val timingOptions: List<ModelControlIntentOption>,
        val timingSelection: String,

        @param:StringRes val statusTextRes: Int?,

        @param:StringRes val explanationRes: Int?,
        val escape: ModelControlCapabilityEscape,

        val effectiveSelection: CapabilityWebPreference,
    )

    fun clamp(
        selection: CapabilityWebPreference,
        status: CapabilityControlPresentation,
        availableIntents: List<String>,
    ): CapabilityWebPreference {
        if (selection != CapabilityWebPreference.Force) return selection
        return when (status) {
            CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.ForceUnsupported ->
                if ("force" in availableIntents) CapabilityWebPreference.Force
                else CapabilityWebPreference.Automatic
            CapabilityControlPresentation.CustomOnly,
            CapabilityControlPresentation.Pending,
            CapabilityControlPresentation.ExternalConnectorOnly,
            CapabilityControlPresentation.Unsupported,
            CapabilityControlPresentation.Unknown,
            -> selection
        }
    }

    fun layout(
        status: CapabilityControlPresentation,
        availableIntents: List<String>,
        rawSelection: CapabilityWebPreference,
        isEditable: Boolean,
        hasCustomSchema: Boolean = true,
    ): Layout {
        val selection = clamp(rawSelection, status, availableIntents)
        return when (status) {
            CapabilityControlPresentation.Unsupported, CapabilityControlPresentation.ExternalConnectorOnly ->
                statusRow(
                    R.string.model_control_not_supported_by_model,
                    R.string.model_control_web_no_official_config,
                    ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )
            CapabilityControlPresentation.CustomOnly ->
                statusRow(
                    R.string.model_control_custom_only_reason,
                    R.string.model_control_custom_only_reason,
                    if (hasCustomSchema) ModelControlCapabilityEscape.AdvancedSettings
                    else ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )

            CapabilityControlPresentation.Pending, CapabilityControlPresentation.Unknown ->
                statusRow(
                    R.string.model_control_cannot_adjust_yet,
                    R.string.model_control_web_no_official_config,
                    ModelControlCapabilityEscape.SupportedModels,
                    selection,
                )
            CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.ForceUnsupported ->
                if (!isEditable) {
                    statusRow(
                        webIntentLabelRes(selection), null, ModelControlCapabilityEscape.None, selection,
                    )
                } else {
                    toggle(availableIntents, selection)
                }
        }
    }

    fun preferenceFor(tierId: String): CapabilityWebPreference =
        CapabilityWebPreference.entries.firstOrNull { it.name == tierId } ?: CapabilityWebPreference.Off

    private fun toggle(availableIntents: List<String>, selection: CapabilityWebPreference): Layout {
        val isOn = selection != CapabilityWebPreference.Off
        val supportsForce = "force" in availableIntents
        return Layout(
            form = Form.Toggle,
            isOn = isOn,
            captionRes = R.string.model_control_web_switch_note,
            timingOptions = if (isOn && supportsForce) timingOptions() else emptyList(),
            timingSelection = timingSelection(selection),
            statusTextRes = null,
            explanationRes = null,
            escape = ModelControlCapabilityEscape.None,
            effectiveSelection = selection,
        )
    }

    private fun timingOptions(): List<ModelControlIntentOption> = listOf(
        ModelControlIntentOption(
            CapabilityWebPreference.Automatic.name, R.string.model_control_web_search_when_needed,
        ),
        ModelControlIntentOption(
            CapabilityWebPreference.Force.name, R.string.model_control_web_search_every_message,
        ),
    )

    private fun timingSelection(selection: CapabilityWebPreference): String =
        if (selection == CapabilityWebPreference.Force) CapabilityWebPreference.Force.name
        else CapabilityWebPreference.Automatic.name

    private fun statusRow(
        @StringRes textRes: Int,
        @StringRes explanationRes: Int?,
        escape: ModelControlCapabilityEscape,
        selection: CapabilityWebPreference,
    ) = Layout(
        form = Form.StatusRow,
        isOn = selection != CapabilityWebPreference.Off,
        captionRes = null,
        timingOptions = emptyList(),
        timingSelection = timingSelection(selection),
        statusTextRes = textRes,
        explanationRes = explanationRes,
        escape = escape,
        effectiveSelection = selection,
    )
}

object ModelControlCapabilityFooter {
    enum class Context { PanelCard, BehaviorPageHeader }

    enum class Tone { Tertiary, Warning }

    enum class NoteIcon { Lock, CustomFields, UpstreamRejected, Privacy, Cost }

    sealed interface Entry {
        data class Note(
            @param:StringRes val textRes: Int,
            val icon: NoteIcon?,
            val tone: Tone,
        ) : Entry

        data object SupportedModelsLink : Entry

        data object AdvancedSettingsLink : Entry
    }

    data class Input(
        val context: Context = Context.PanelCard,

        val overridden: Boolean = false,

        @param:StringRes val readOnlyReasonRes: Int? = null,
        val isConfigurable: Boolean = true,

        @param:StringRes val statusTextRes: Int? = null,
        val upstreamRejected: Boolean = false,
        val riskTiers: List<String> = emptyList(),
        val showsSupportedModelsAction: Boolean = false,
        val hasSupportedModelCandidates: Boolean = false,

        val showsAdvancedSettingsAction: Boolean = false,

        val statusRowEscape: ModelControlCapabilityEscape = ModelControlCapabilityEscape.None,
    )

    fun entries(input: Input): List<Entry> {
        val entries = mutableListOf<Entry>()

        val showsSupportedModels = !input.overridden && input.showsSupportedModelsAction &&
            input.statusRowEscape != ModelControlCapabilityEscape.SupportedModels

        val saysNoCandidates = showsSupportedModels && !input.hasSupportedModelCandidates

        when {
            input.overridden -> entries += Entry.Note(
                R.string.model_control_custom_fields_active_note, NoteIcon.CustomFields, Tone.Warning,
            )
            input.readOnlyReasonRes != null ->
                if (input.context == Context.BehaviorPageHeader) {
                    entries += Entry.Note(input.readOnlyReasonRes, NoteIcon.Lock, Tone.Tertiary)
                }

            !input.isConfigurable && !saysNoCandidates &&
                input.context == Context.BehaviorPageHeader && input.statusTextRes != null ->
                entries += Entry.Note(input.statusTextRes, null, Tone.Tertiary)
        }

        if (input.upstreamRejected) {
            entries += Entry.Note(
                R.string.model_control_upstream_rejected, NoteIcon.UpstreamRejected, Tone.Warning,
            )
        }

        if (input.overridden || input.context == Context.BehaviorPageHeader) {
            input.riskTiers.forEach { tier ->
                val privacy = tier == "privacy_impacting"
                entries += Entry.Note(
                    if (privacy) R.string.model_control_risk_privacy else R.string.model_control_risk_cost,
                    if (privacy) NoteIcon.Privacy else NoteIcon.Cost,
                    Tone.Warning,
                )
            }
        }

        if (showsSupportedModels) {
            entries += if (saysNoCandidates) {
                Entry.Note(R.string.model_control_no_supported_models, null, Tone.Tertiary)
            } else {
                Entry.SupportedModelsLink
            }
        }

        if (input.showsAdvancedSettingsAction) entries += Entry.AdvancedSettingsLink

        return entries
    }
}

fun modelControlWebAvailableIntents(
    control: ai.oriveo.community.core.data.remote.MetadataClient.CapabilityControlPresentation?,
): List<String> =
    if (control?.state == "auto_available") control.availableIntents else emptyList()
