package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceConnection
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineOption
import ai.oriveo.community.core.voice.VoiceEngineResolver
import ai.oriveo.community.core.voice.VoiceEngineSelection

/** One row of the engine sheet; connectionName is set only when a provider lists several connections (the UI shows it as "model · connection name"). */
data class VoiceEngineSheetRow(
    val option: VoiceEngineOption,
    val connectionName: String? = null,
    val isChecked: Boolean,
)

/** Footer below the card. */
sealed interface VoiceEngineSheetFooter {
    /** No footer: the catalog has no verdict yet, or there are no providers awaiting support. */
    data object None : VoiceEngineSheetFooter

    /** Catalog returned 404 -> voice_engine_catalog_empty. */
    data object CatalogEmpty : VoiceEngineSheetFooter

    /** Load failed with no cache -> voice_engine_catalog_load_failed. */
    data object LoadFailed : VoiceEngineSheetFooter

    /** voice_engine_pending_providers; the UI layer joins each displayName with a ListFormatter. */
    data class PendingProviders(val kinds: List<ProviderKind>) : VoiceEngineSheetFooter
}

/** [systemTitle] / [systemSubtitle]: copy of the system row; for the conversation engine direction they read "follow the current model" and "dictation -> current model -> read aloud". */
data class VoiceEngineSheetModel(
    val rows: List<VoiceEngineSheetRow>,
    val footer: VoiceEngineSheetFooter,
    val systemTitle: UiText = UiText.Resource(R.string.voice_engine_system),
    val systemSubtitle: UiText = UiText.Resource(R.string.voice_engine_system_subtitle),
)

object VoiceEngineSheetModels {
    /**
     * [catalogState] null = the catalog has no verdict yet: only the system row, no footer.
     * [connectionNames] connection id -> display name, used to tell apart several connections of one provider.
     */
    fun build(
        catalogState: VoiceCatalogState?,
        direction: VoiceDirection,
        selection: VoiceEngineSelection,
        connections: List<VoiceConnection>,
        connectionNames: Map<String, String>,
    ): VoiceEngineSheetModel {
        val catalog = (catalogState as? VoiceCatalogState.Available)?.catalog
        val options = catalog?.let { VoiceEngineResolver.options(it, direction, connections) }
            ?: listOf(VoiceEngineOption.System)
        return VoiceEngineSheetModel(
            rows = rows(options, selection, connectionNames),
            systemTitle = UiText.Resource(
                if (direction == VoiceDirection.Realtime) R.string.voice_realtime_follow_model else R.string.voice_engine_system,
            ),
            systemSubtitle = UiText.Resource(
                if (direction == VoiceDirection.Realtime) {
                    R.string.voice_realtime_follow_model_subtitle
                } else {
                    R.string.voice_engine_system_subtitle
                },
            ),
            footer = when (catalogState) {
                null -> VoiceEngineSheetFooter.None
                VoiceCatalogState.Unavailable -> VoiceEngineSheetFooter.CatalogEmpty
                VoiceCatalogState.LoadFailed -> VoiceEngineSheetFooter.LoadFailed
                is VoiceCatalogState.Available -> pendingKinds(catalogState.catalog, direction, connections)
                    .takeIf { it.isNotEmpty() }
                    ?.let { VoiceEngineSheetFooter.PendingProviders(it) }
                    ?: VoiceEngineSheetFooter.None
            },
        )
    }

    fun rows(
        options: List<VoiceEngineOption>,
        selection: VoiceEngineSelection,
        connectionNames: Map<String, String>,
    ): List<VoiceEngineSheetRow> {
        val connectionsPerKind = options.filterIsInstance<VoiceEngineOption.Cloud>()
            .groupBy { it.providerKind }
            .mapValues { (_, cloud) -> cloud.map { it.connectionId }.distinct().size }
        return options.map { option ->
            when (option) {
                VoiceEngineOption.System -> VoiceEngineSheetRow(
                    option = option,
                    isChecked = selection is VoiceEngineSelection.System,
                )
                is VoiceEngineOption.Cloud -> VoiceEngineSheetRow(
                    option = option,
                    connectionName = if ((connectionsPerKind[option.providerKind] ?: 0) > 1) {
                        connectionNames[option.connectionId]
                    } else {
                        null
                    },
                    isChecked = selection is VoiceEngineSelection.Cloud &&
                        selection.providerKind == option.providerKind &&
                        selection.connectionId == option.connectionId &&
                        selection.model == option.model,
                )
            }
        }
    }

    /** Providers with no catalog entry for this direction, in connection order and de-duplicated (auth method and key are ignored). */
    fun pendingKinds(
        catalog: VoiceCatalog,
        direction: VoiceDirection,
        connections: List<VoiceConnection>,
    ): List<ProviderKind> = connections.asSequence()
        .map { it.providerKind }
        .distinct()
        .filter { catalog.entries(it, direction).isEmpty() }
        .toList()
}
