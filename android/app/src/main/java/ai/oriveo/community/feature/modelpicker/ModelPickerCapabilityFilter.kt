package ai.oriveo.community.feature.modelpicker

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter

/**
 * Capability visibility before the model picker opens.
 *
 * In production only 11% of models are `auto_available` for thinking and 47% for web search, so users currently hit a
 * wall only after picking a model.
 *
 * Badges and filters consume only the existing decision function ([CapabilityControlResolution.resolve]) and add no
 * second rule. The earlier fork cost us: of 757 production models, 45 had opposite conclusions on the two sides (the
 * model library said web search was supported, but the chat page could not open it).
 */
enum class ModelPickerCapabilityFilterKind(
    /** Owner name of `capabilityControls`, the same as the chat page's model control panel. */
    val owner: String,
    @param:StringRes val filterLabelRes: Int,
) {
    Web("web", R.string.model_picker_filter_web),
    Reasoning("reasoning", R.string.model_picker_filter_reasoning),
}

/**
 * The set of capabilities a model can actually use right now. The decision still comes from the single function the
 * chat page control uses, but badges and filters only accept `state == auto_available`: managed_only / custom_only /
 * unknown / unavailable never light up or match (same answer as outbound; Free never lights up web search).
 *
 * Filters offer only web search and thinking (realtime is computed separately), the same set as iOS. The tool badge on
 * a row does not go through here; ModelPickerRow reads [CapabilityEvidenceProductionAdapter.toolCallVerdict] directly.
 */
fun modelPickerCapabilityBadges(
    provider: Provider,
    model: AIModel,
    metadata: MetadataClient = MetadataClient.instance,
): Set<ModelPickerCapabilityFilterKind> = ModelPickerCapabilityFilterKind.entries
    .filterTo(mutableSetOf()) { kind ->
        CapabilityControlResolution.resolve(provider, model, kind.owner, metadata).state ==
            CapabilityControlResolution.STATE_AUTO_AVAILABLE
    }

/**
 * The real hit count on a filter chip. The counted rows must be the rows the filter actually leaves behind; never show
 * a made-up number (when it cannot be measured, show the "no data" placeholder, never a number that looks real).
 */
fun modelPickerCapabilityFilterCounts(
    sections: List<ModelPickerSection>,
    metadata: MetadataClient = MetadataClient.instance,
): Map<ModelPickerCapabilityFilterKind, Int> = ModelPickerCapabilityFilterKind.entries.associateWith { kind ->
    sections.sumOf { section ->
        section.models.count { model ->
            kind in modelPickerCapabilityBadges(section.provider, model, metadata)
        }
    }
}

/**
 * Hit count for the "Realtime voice" chip: the realtime filter leaves exactly all realtime rows, so this is the total
 * number of realtime rows before filtering (same basis as the `.realtime` case in iOS ModelPickerCapabilityFilter.counts).
 */
fun modelPickerRealtimeFilterCount(sections: List<ModelPickerSection>): Int =
    sections.sumOf { it.realtimeModels.size }

/**
 * Multi-select chips take the **intersection** (selecting "web search" + "thinking" means both are required); an empty
 * selection filters nothing. Provider sections left empty are removed entirely, and the caller renders an honest empty state.
 *
 * [realtimeSelected]: the "Realtime voice" filter matches only realtime rows; text rows never match it. Realtime rows
 * have no web search or thinking, so they are kept only when no capability filter is selected (selecting both = empty).
 * When the list has no realtime row at all, the chip does not appear and this selection has no effect (same as RealtimeModel.pickerRows).
 */
fun applyModelPickerCapabilityFilter(
    sections: List<ModelPickerSection>,
    selected: Set<ModelPickerCapabilityFilterKind>,
    metadata: MetadataClient = MetadataClient.instance,
    realtimeSelected: Boolean = false,
): List<ModelPickerSection> {
    val realtimeActive = realtimeSelected && sections.any { it.realtimeModels.isNotEmpty() }
    if (selected.isEmpty() && !realtimeActive) return sections
    return sections.mapNotNull { section ->
        val models = if (realtimeActive) {
            emptyList()
        } else {
            section.models.filter { model ->
                modelPickerCapabilityBadges(section.provider, model, metadata).containsAll(selected)
            }
        }
        val realtimeModels = if (selected.isEmpty()) section.realtimeModels else emptyList()
        if (models.isEmpty() && realtimeModels.isEmpty()) {
            null
        } else {
            section.copy(models = models, realtimeModels = realtimeModels)
        }
    }
}
