package ai.oriveo.community.feature.chat.modelcontrols

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterProfileFingerprint
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.GenerationAccess
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.provider.GenerationParameterEntryScope
import ai.oriveo.community.core.provider.GenerationParameterPanelPresentation
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation
import ai.oriveo.community.core.provider.GenerationParameterThinkingPreview
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/** Grouping of the advanced settings page: common first, then more (subgroups). Rows are arranged only by the row model and the profile's group; values are never judged. */
internal object AdvancedSettingsLayout {
    data class Group(
        val key: String,
        val rowIds: List<String>,
        /** The rows in this group that have a value (changed in this conversation or using the model default); feeds the subgroup row's summary. */
        val adjustedIds: List<String>,
        /** What takes over the rows of this group that are taken over; stated once at the end of the group. */
        val takenOverBy: List<String>,
    )

    data class Layout(val common: List<String>, val commonTakenOverBy: List<String>, val more: List<Group>)

    /** The fixed order of the common group; the extra Top K / Min P of a local engine are placed here too. */
    val COMMON_IDS = listOf("max_output_tokens", "temperature", "top_k", "top_p", "min_p")
    private val GROUP_ORDER = listOf(
        "budget", "reasoning", "more_sampling", "mirostat", "dynamic_temperature",
        "repetition", "reproducibility", "output_contract", "engine_runtime",
    )

    fun layout(page: GenerationParameterRowModel.Page, profile: GenerationProfileRef): Layout {
        val rows = page.rows.associateBy { it.id }
        val common = COMMON_IDS.filter { it in rows }
        val groupOf = profile.parameters.mapNotNull { p -> p.id?.let { it to AdvancedSubgroups.subgroupOf(it, p.group) } }.toMap()
        val rest = page.rows.filter { it.id !in common }.groupBy { groupOf[it.id] ?: AdvancedSubgroups.subgroupOf(it.id, null) }
        val keys = GROUP_ORDER.filter { it in rest } + rest.keys.filterNot { it in GROUP_ORDER }
        return Layout(
            common = common,
            commonTakenOverBy = common.mapNotNull { rows.getValue(it).takenOverBy }.distinct(),
            more = keys.map { key ->
                val groupRows = rest.getValue(key)
                Group(
                    key = key,
                    rowIds = groupRows.map { it.id },
                    adjustedIds = groupRows.filter { it.source != GenerationParameterRowModel.Source.ModelDecides }.map { it.id },
                    takenOverBy = groupRows.mapNotNull { it.takenOverBy }.distinct(),
                )
            },
        )
    }

    /** Row titles for this page: stop sequences use this page's own string, the rest share the title table of the connection-defaults sheet. */
    @StringRes
    fun rowTitleRes(id: String): Int =
        if (id == "stop") R.string.advanced_stop_sequences else ai.oriveo.community.feature.providers.detail.generationParameterTitleRes(id)

    @StringRes
    fun groupTitleRes(key: String): Int = when (key) {
        "budget" -> R.string.generation_group_budget
        "reasoning" -> R.string.generation_group_reasoning
        "more_sampling" -> R.string.advanced_more_sampling
        "mirostat" -> R.string.generation_parameter_name_mirostat
        "dynamic_temperature" -> R.string.advanced_dynamic_temperature
        "repetition" -> R.string.advanced_repetition
        "reproducibility" -> R.string.generation_group_reproducibility
        "output_contract" -> R.string.generation_group_output_contract
        else -> R.string.generation_group_engine_runtime
    }
}

/** Subgroups inside "more": membership, subgroup note, summary and takeover note. Only parameter ids and groups are read, never an engine name or a model id. */
internal object AdvancedSubgroups {
    /** The summary on the right of a subgroup row. */
    sealed interface Summary {
        data object NotAdjusted : Summary
        data class Count(val count: Int) : Summary
        /** Only one item was adjusted: its title plus the value. */
        data class Single(val id: String, val value: SingleValue) : Summary
    }

    sealed interface SingleValue {
        data class Text(val text: String) : SingleValue
        data class Entries(val count: Int) : SingleValue
        data object On : SingleValue
        data object Set : SingleValue
        data object Omitted : SingleValue
    }

    /** Stated once at the end of the group: what took over how many items. */
    data class TakenOverNote(val takers: List<String>, val crossedCount: Int)

    private val KNOWN_GROUPS = setOf("budget", "reasoning", "reproducibility", "output_contract", "engine_runtime")

    /**
     * Membership: Mirostat and dynamic temperature each form a group (each carries its own note and they are interrelated),
     * DRY belongs with repetition control and XTC with further sampling; the rest follow the profile's group, and an unrecognized group goes into engine experiments.
     */
    fun subgroupOf(id: String, group: String?): String = when {
        id.startsWith("mirostat") -> "mirostat"
        id.startsWith("dynatemp_") -> "dynamic_temperature"
        id.startsWith("dry_") || group == "repetition" -> "repetition"
        id.startsWith("xtc_") || group == "sampling" -> "more_sampling"
        group in KNOWN_GROUPS -> group!!
        else -> "engine_runtime"
    }

    @StringRes
    fun groupNoteRes(key: String): Int? = when (key) {
        "mirostat" -> R.string.advanced_mirostat_note
        "dynamic_temperature" -> R.string.advanced_dynamic_temperature_note
        else -> null
    }

    /** The strength item of DRY / XTC is also their switch (0 means off), so the note hangs on this row. */
    @StringRes
    fun rowNoteRes(id: String): Int? = when (id) {
        "dry_multiplier" -> R.string.advanced_dry_note
        "xtc_probability" -> R.string.advanced_xtc_note
        else -> null
    }

    fun summary(
        group: AdvancedSettingsLayout.Group,
        rows: Map<String, GenerationParameterRowModel>,
        rawValues: Map<String, kotlinx.serialization.json.JsonElement?>,
        valueSchemas: Map<String, String?>,
    ): Summary = when (group.adjustedIds.size) {
        0 -> Summary.NotAdjusted
        1 -> {
            val id = group.adjustedIds.single()
            val raw = rawValues[id]
            val value = when {
                rows[id]?.display == GenerationParameterRowModel.DisplayValue.Omitted -> SingleValue.Omitted
                raw is kotlinx.serialization.json.JsonArray -> SingleValue.Entries(raw.size)
                raw is kotlinx.serialization.json.JsonPrimitive && !raw.isString && raw.content == "true" -> SingleValue.On
                valueSchemas[id] == "json-schema" || raw is kotlinx.serialization.json.JsonObject -> SingleValue.Set
                else -> SingleValue.Text((rows[id]?.display as? GenerationParameterRowModel.DisplayValue.Value)?.text.orEmpty())
            }
            Summary.Single(id, value)
        }
        else -> Summary.Count(group.adjustedIds.size)
    }

    fun takenOverNote(rows: List<GenerationParameterRowModel>): TakenOverNote? {
        val crossed = rows.filter { it.takenOverBy != null }
        if (crossed.isEmpty()) return null
        return TakenOverNote(crossed.mapNotNull { it.takenOverBy }.distinct(), crossed.size)
    }
}

/** Reset: the button label and the action to run come from one place, so a label saying "this conversation" never clears the model default. */
internal object AdvancedReset {
    data class Plan(
        @StringRes val titleRes: Int,
        @StringRes val bodyRes: Int,
        @StringRes val confirmRes: Int,
        val execute: () -> Unit,
    )

    fun plan(
        store: GenerationParameterSettingsStore,
        providerId: String,
        modelId: String,
        conversationId: String?,
        profileFingerprint: String?,
    ): Plan = if (conversationId != null) {
        // The chat page clears only what was changed in this conversation; model defaults and the additional request body stay untouched.
        Plan(
            R.string.advanced_reset_conversation_title,
            R.string.advanced_reset_conversation_body,
            R.string.advanced_reset_conversation_action,
        ) { store.setSessionOverrides(null, providerId, modelId, conversationId, profileFingerprint) }
    } else {
        Plan(
            R.string.advanced_reset_model_title,
            R.string.advanced_reset_model_body,
            R.string.advanced_reset_model_action,
        ) { store.setModelDefaults(null, providerId, modelId, profileFingerprint) }
    }
}

/**
 * Data of the advanced settings in the chat: layered evaluation, the editable set from the outbound gate, outbound drops and the thinking preview, all taken from production functions,
 * so the UI only renders [Loaded.page].
 */
internal object AdvancedSettingsData {
    data class Loaded(
        val profile: GenerationProfileRef,
        val page: GenerationParameterRowModel.Page,
        val profileFingerprint: String,
        /** Parameter id to the "see models that support it" action label; only rows that cannot be adjusted have one. */
        val supportedModelsActions: Map<String, Int> = emptyMap(),
    )

    fun load(
        provider: Provider,
        model: AIModel,
        conversationId: String,
        store: GenerationParameterSettingsStore,
        localIdentity: CapabilityEvidenceIdentity?,
        reasoningMode: ReasoningMode,
        access: GenerationAccess,
    ): Loaded? {
        val profile = GenerationParameterAvailability.profile(provider, model) ?: return null
        val fingerprint = GenerationParameterProfileFingerprint.make(provider, model)
        val sourced = store.resolveWithSources(
            transient = null,
            providerID = provider.id,
            modelID = model.id,
            conversationID = conversationId,
            profileFingerprint = fingerprint,
            reasoningMode = reasoningMode,
            activeParameterIds = profile.parameters.mapNotNull { it.id }.toSet(),
        )
        val overrides = GenerationParameterOverrides(sourced.mapValues { it.value.override })
        val projection = CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = provider,
            model = model,
            localIdentity = localIdentity,
            parameters = profile.parameters,
            values = overrides,
        )
        val visible = GenerationParameterPanelPresentation.visibleParameters(
            provider = provider,
            model = model,
            scope = GenerationParameterEntryScope.Session,
            access = access,
            capabilityProjection = projection,
        ).mapNotNull { it.id }.toSet()
        // The session scope normally lists no reasoning group; a reasoning row without a write path stays only to tell the user where thinking is set.
        val shown = profile.copy(
            parameters = profile.parameters.filter { parameter ->
                parameter.id in visible ||
                    (GenerationParameterAvailability.isReasoningParameter(parameter) && profile.wire[parameter.id].isNullOrEmpty())
            },
        )
        val options = ChatRequestOptions(generationParameters = overrides, activeModel = model)
        val resolved = if (provider.kind == ProviderKind.Relay) null else MetadataClient.resolveCatalogModel(model.id, provider.kind)
        val skeleton = buildJsonObject {
            put("model", JsonPrimitive(model.id))
            put("messages", kotlinx.serialization.json.JsonArray(emptyList()))
        }.toString()
        val outbound = GenerationParameterResolver.applyWithResult(skeleton, options, resolved, projection).dropped
        val thinking = GenerationParameterThinkingPreview.dropped(
            provider = provider,
            modelID = model.id,
            reasoningMode = reasoningMode,
            requestOptions = options,
            relayProfile = profile,
            relayProjection = projection,
        )
        val dropped = (thinking + outbound).distinctBy { it.parameterId }
        val page = GenerationParameterRowModel.page(shown, sourced, dropped, visible) {
            GenerationParameterPanelPresentation.showsUnverifiedBadge(it, projection)
        }
        return Loaded(shown, page, fingerprint, AdvancedSettingsOutlets.supportedModelsActions(shown, projection))
    }
}

/** The ways out the connection-defaults sheet already offers, mirrored on the advanced settings page; every criterion is a shared function and the page only draws the result. */
internal object AdvancedSettingsOutlets {
    enum class CustomFieldsTap { Open, OfferSupportedModels, NoModelWouldHelp }

    fun supportedModelsActions(
        profile: GenerationProfileRef,
        projection: ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter.Projection,
    ): Map<String, Int> = profile.parameters.mapNotNull { parameter ->
        val id = parameter.id ?: return@mapNotNull null
        // A reasoning-group row without a write path only says thinking is set in the model options, and attaches no candidate models.
        if (GenerationParameterAvailability.isReasoningParameter(parameter) && profile.wire[id].isNullOrEmpty()) {
            return@mapNotNull null
        }
        // Same as the connection-defaults sheet: the action key comes straight from primaryActionRes of the shared presentation table.
        val supportKey = GenerationParameterSupportPresentation.effectiveSupport(
            parameter.support,
            GenerationParameterPanelPresentation.generationParameterDecision(parameter, projection)?.resolution?.support,
        )
        val entry = GenerationParameterSupportPresentation.entry(supportKey)
        entry.primaryActionRes?.takeIf { entry.renders }?.let { id to it }
    }.toMap()

    /** An unavailable entry row stays tappable: with candidates it offers a way out, without any it says plainly that switching models would not help (same as the connection-defaults sheet). */
    fun customFieldsTap(
        entry: ai.oriveo.community.feature.providers.detail.CustomFieldsEntry,
        candidates: List<AIModel>,
    ): CustomFieldsTap = when {
        entry != ai.oriveo.community.feature.providers.detail.CustomFieldsEntry.Unsupported -> CustomFieldsTap.Open
        candidates.isNotEmpty() -> CustomFieldsTap.OfferSupportedModels
        else -> CustomFieldsTap.NoModelWouldHelp
    }
}
