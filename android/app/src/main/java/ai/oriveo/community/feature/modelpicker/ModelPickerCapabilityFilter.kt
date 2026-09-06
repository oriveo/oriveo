package ai.oriveo.community.feature.modelpicker

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter

enum class ModelPickerCapabilityFilterKind(

    val owner: String,
    @param:StringRes val filterLabelRes: Int,
    @param:StringRes val badgeLabelRes: Int,
) {
    Web("web", R.string.model_picker_filter_web, R.string.web_search),
    Reasoning("reasoning", R.string.model_picker_filter_reasoning, R.string.capability_reasoning),
    Tool("tool_call", R.string.capability_tool_call, R.string.capability_tool_call),
}

fun modelPickerCapabilityBadges(
    provider: Provider,
    model: AIModel,
    metadata: MetadataClient = MetadataClient.instance,
    toolCallMemoryVerdict: Boolean? = null,
): Set<ModelPickerCapabilityFilterKind> = ModelPickerCapabilityFilterKind.entries
    .filterTo(mutableSetOf()) { kind ->
        if (kind == ModelPickerCapabilityFilterKind.Tool) {
            CapabilityEvidenceProductionAdapter.toolCallVerdict(
                provider = provider,
                model = model,
                memoryVerdict = toolCallMemoryVerdict,
                metadataClient = metadata,
            ) == true
        } else {
            CapabilityControlResolution.resolve(provider, model, kind.owner, metadata).isAvailable
        }
    }

fun modelPickerCapabilityFilterCounts(
    sections: List<ModelPickerSection>,
    metadata: MetadataClient = MetadataClient.instance,
    toolCallMemoryVerdict: (Provider, AIModel) -> Boolean? = { _, _ -> null },
): Map<ModelPickerCapabilityFilterKind, Int> = ModelPickerCapabilityFilterKind.entries.associateWith { kind ->
    sections.sumOf { section ->
        section.models.count { model ->
            kind in modelPickerCapabilityBadges(
                section.provider,
                model,
                metadata,
                toolCallMemoryVerdict(section.provider, model),
            )
        }
    }
}

fun applyModelPickerCapabilityFilter(
    sections: List<ModelPickerSection>,
    selected: Set<ModelPickerCapabilityFilterKind>,
    metadata: MetadataClient = MetadataClient.instance,
    toolCallMemoryVerdict: (Provider, AIModel) -> Boolean? = { _, _ -> null },
): List<ModelPickerSection> {
    if (selected.isEmpty()) return sections
    return sections.mapNotNull { section ->
        val models = section.models.filter { model ->
            modelPickerCapabilityBadges(
                section.provider,
                model,
                metadata,
                toolCallMemoryVerdict(section.provider, model),
            ).containsAll(selected)
        }
        if (models.isEmpty()) null else section.copy(models = models)
    }
}
