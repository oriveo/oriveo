package ai.oriveo.community.feature.providers.detail

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayProbeCandidates
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol

/** Fixed order of the five capability icons on a row: vision / files / thinking / tools / web. */
enum class RelayCatalogCapability { Image, File, Thinking, Tool, Web }

enum class RelayCatalogCapabilityState { Supported, Unknown, Unsupported }

/** Status text on the right of a row (lazy verification adds three states; priority: no access > verifying > unreachable > existing). */
enum class RelayCatalogRowStatus(@StringRes val textRes: Int) {
    DeniedOnCurrentKey(R.string.relay_catalog_status_denied),
    Verifying(R.string.relay_catalog_status_verifying),
    /** Tappable; shows the reason from [RelayCatalogRow.unreachable]. */
    Unreachable(R.string.relay_catalog_status_unreachable),
    MissingFromCatalog(R.string.relay_model_missing_from_catalog),
    Verified(R.string.relay_catalog_status_verified),
    Reachable(R.string.relay_catalog_status_reachable),
    SetByYou(R.string.relay_catalog_status_set_by_you),
    UnknownUntilSent(R.string.model_options_vision_unknown),
    VerifyOnEnable(R.string.relay_catalog_status_verify_on_enable),
}

/** Trailing row actions: enabled rows [new chat, ...], catalog rows [plus] or [unavailable]. */
enum class RelayCatalogTrailing { NewChat, More, Add, Unavailable }

/** Row tap target: enabled rows open editable advanced, catalog rows open read-only advanced; non-board rows have none (legacy behavior). */
enum class RelayCatalogTapTarget { Advanced, ReadOnlyAdvanced }

/** What the view does after a row tap: provided only by [RelayCatalogBoardModel.rowTap]. */
sealed interface RelayCatalogRowTap {
    data class OpenAdvanced(val layer: RelayDetailLayer.Advanced) : RelayCatalogRowTap
    data object Enable : RelayCatalogRowTap
    data object StartChat : RelayCatalogRowTap
}

/** One item of the "..." menu: when only 1 enabled model remains, "Remove" is greyed out with a reason sentence. */
data class RelayCatalogMenuItem(
    val action: RelayEnabledRowMenuItem,
    val enabled: Boolean,
    @StringRes val disabledReasonRes: Int?,
)

/** One segment of a row's screen-reader value: "capability name status word". */
data class RelayCatalogReadoutPart(@StringRes val capabilityRes: Int, @StringRes val stateRes: Int)

sealed interface RelayCatalogFilter {
    data object All : RelayCatalogFilter {
        @StringRes val labelRes: Int = R.string.provider_category_all
    }

    data class Protocol(val protocol: RelayBoardProtocol) : RelayCatalogFilter

    /** Show only models listed by [keyID]; the chip appears only when active (placed after "All"). */
    data class Key(val keyID: String) : RelayCatalogFilter
}

/** One row: name comes from [model]; [protocol] is null for the local engine; [caps] holds five cells in [RelayCatalogCapability] order. */
data class RelayCatalogRow(
    val model: AIModel,
    val protocol: RelayBoardProtocol?,
    val caps: List<RelayCatalogCapabilityState>,
    val status: RelayCatalogRowStatus?,
    val trailing: List<RelayCatalogTrailing>,
    val tapTarget: RelayCatalogTapTarget? = null,
    /** Menu for the "..." of enabled rows; empty for catalog rows. */
    val menu: List<RelayCatalogMenuItem> = emptyList(),
    /** Five segments in icon order; the five icons themselves are hidden from screen readers. */
    val readout: List<RelayCatalogReadoutPart> = emptyList(),
    /** With 2+ keys, the key chip on enabled rows (name of the bound key in effect, masked when unnamed); otherwise null. */
    val keyChip: String? = null,
    /** Failure reason when the status is [RelayCatalogRowStatus.Unreachable]. */
    val unreachable: ProviderRepository.RelayModelProbeState.Failed? = null,
)

data class RelayCatalogEnabledSection(
    @StringRes val titleRes: Int,
    val count: Int,
    val rows: List<RelayCatalogRow>,
)

data class RelayCatalogLibraryGroup(
    val id: String,
    val title: String,
    val rows: List<RelayCatalogRow>,
    /** Localized group name of the "Other" group. */
    @StringRes val titleRes: Int? = null,
    /** Models the group header's "Add all" appends (same order as group rows); empty = no button. */
    val enableAllModelIDs: List<String> = emptyList(),
)

/** Model library page header: avatar + "Model Library" + "host · N models (enabled ∪ catalog) · K keys (2+ keys)" + refresh. */
data class RelayCatalogHeader(val host: String, val modelCount: Int, val keyCount: Int?)

sealed interface RelayCatalogKeyStripState {
    data object Ok : RelayCatalogKeyStripState

    /** Never checked: no checkmark and no Retry. */
    data object Unchecked : RelayCatalogKeyStripState

    /** "<code> <status word>" + Retry (refreshes only this key); while fetching, the status word is "Fetching". */
    data class Failed(val httpStatus: Int?, @StringRes val statusRes: Int?) : RelayCatalogKeyStripState
}

/** One row per key at the top of the catalog area (2+ keys): name or mask + catalog count + status. */
data class RelayCatalogKeyStripItem(
    val keyId: String,
    val title: String,
    val catalogCount: Int?,
    val state: RelayCatalogKeyStripState,
) {
    val showsRetry: Boolean get() = state is RelayCatalogKeyStripState.Failed
}

/** Sections of the model library page (fixed order, rendered as is); the whole page has a single manual-add at the end. */
enum class RelayCatalogPageSection {
    Header,
    Filters,
    Enabled,
    KeyStrip,
    Loading,
    /** Catalog fetch failed for a single key: full-width failure card (title + one-line reason + Retry), no manual add; the old catalog stays below as usual. */
    FailureCard,
    Library,
    EnableHint,
    ManualAdd,
    Legend,
}

data class RelayCatalogLibrarySection(
    @StringRes val titleRes: Int,
    val count: Int,
    val groups: List<RelayCatalogLibraryGroup>,
)

data class RelayCatalogBoard(
    /** Empty = the whole chip row is hidden (local engine, or fewer than two distinct transports). */
    val filters: List<RelayCatalogFilter>,
    val selected: RelayCatalogFilter,
    /** Key display name on the key filter chip (same function as the key row title); null when the filter is inactive. */
    val keyFilterTitle: String? = null,
    val enabled: RelayCatalogEnabledSection,
    val library: RelayCatalogLibrarySection,
    val legend: List<Pair<RelayCatalogCapabilityState, Int>>,
    @StringRes val footnoteRes: Int,
    val header: RelayCatalogHeader,
    /** Present only with 2+ keys. */
    val keyStrip: List<RelayCatalogKeyStripItem>,
    val sections: List<RelayCatalogPageSection>,
    /** Enable hint below a group: with connection auto it is the full sentence, with a chosen connection only the second half (no probing); null for a local connection. */
    @StringRes val enableHintRes: Int?,
)

/** Source of the five-capability tri-states; [RelayCatalogBoardModel.build] reads only through it; production uses [RelayCatalogCapabilityFacts], and the page wraps it in [RelayCatalogCapabilityMemo]. */
fun interface RelayCatalogCapabilitySource {
    fun states(provider: Provider, model: AIModel, nowSeconds: Long): List<RelayCatalogCapabilityState>
}

/**
 * Remembers the five capabilities per model object: search / transport filtering only filters already computed rows without re-running the criteria.
 * The caller swaps in a new instance when the provider, capability-observation revision, or tool-memory revision changes.
 */
class RelayCatalogCapabilityMemo(private val source: RelayCatalogCapabilitySource) : RelayCatalogCapabilitySource {
    private val memo = java.util.concurrent.ConcurrentHashMap<AIModel, List<RelayCatalogCapabilityState>>()

    fun isKnown(model: AIModel): Boolean = memo.containsKey(model)

    override fun states(provider: Provider, model: AIModel, nowSeconds: Long): List<RelayCatalogCapabilityState> =
        memo.getOrPut(model) { source.states(provider, model, nowSeconds) }
}

/**
 * Fact source of the five-capability tri-states: only calls the existing criteria of the chat page and evidence layer, without defining its own verdicts.
 * [identityFor] supplies the connection identity the Relay vision / thinking / web criteria need; when unavailable those criteria fail closed on their own terms.
 */
class RelayCatalogCapabilityFacts(
    private val metadata: MetadataClient = MetadataClient.instance,
    private val negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
    runtimeConfigProvider: () -> MetadataClient.RelayRuntimeConfig = metadata::relayRuntimeConfig,
    private val identityFor: (AIModel) -> CapabilityEvidenceIdentity? = { null },
    private val toolMemoryFor: (AIModel) -> Boolean? = { null },
) : RelayCatalogCapabilitySource {
    private val resolver = ChatModelCapabilityResolver(metadata, runtimeConfigProvider, negativeCache)

    override fun states(provider: Provider, model: AIModel, nowSeconds: Long): List<RelayCatalogCapabilityState> {
        val localIdentity = identityFor(model)
        // Same lookup as the chat page's vision entry: auto / no config takes identity from the effective transport (auto -> Chat).
        val queryIdentity = localIdentity?.let {
            CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
                provider,
                model.copy(relayTransport = RelayEndpointResolver.effectiveTransport(provider, model)),
                it,
            )
        }
        return RelayCatalogCapability.entries.map { capability ->
            when (capability) {
                RelayCatalogCapability.Image -> image(provider, model, localIdentity)
                RelayCatalogCapability.File -> file(provider, model, nowSeconds)
                RelayCatalogCapability.Thinking -> thinking(provider, model, queryIdentity)
                RelayCatalogCapability.Tool -> tool(provider, model)
                RelayCatalogCapability.Web -> web(provider, model, queryIdentity)
            }
        }
    }

    /** The same facts for the vision tri-state: entry-visibility function x no-positive-evidence predicate. */
    private fun image(provider: Provider, model: AIModel, localIdentity: CapabilityEvidenceIdentity?) =
        when (
            ModelOptionsTiles.vision(
                entryVisible = resolver.supportsImage(provider, model, localIdentity),
                relayWithoutPositiveEvidence = ModelOptionsPanelInput.visionUnknown(provider, model),
            )
        ) {
            ModelOptionsTiles.Vision.Available -> RelayCatalogCapabilityState.Supported
            ModelOptionsTiles.Vision.Unknown -> RelayCatalogCapabilityState.Unknown
            ModelOptionsTiles.Vision.Hidden -> RelayCatalogCapabilityState.Unsupported
        }

    /**
     * File override first: On -> supported, Off -> unsupported; otherwise unexpired negative cache -> unsupported;
     * otherwise non-empty native file allowlist on the model -> supported; otherwise unknown (rows show model facts, not the route).
     */
    private fun file(provider: Provider, model: AIModel, nowSeconds: Long): RelayCatalogCapabilityState {
        model.relayCapabilityOverrides?.file?.let { return it.toState() }
        val rejected = RelayNegativeCache.keyFor(provider, model)
            ?.let { negativeCache.isRejected(it, RelayNegativeCache.Kind.File, nowSeconds) } == true
        return when {
            rejected -> RelayCatalogCapabilityState.Unsupported
            model.nativeFileMimes.isNotEmpty() -> RelayCatalogCapabilityState.Supported
            else -> RelayCatalogCapabilityState.Unknown
        }
    }

    /**
     * Engine declares a thinking key -> follow it; otherwise adjustable thinking levels -> supported; everything else unknown.
     * The "evidence layer says unsupported" tier: the Relay thinking-level key yields only accepted / no candidate in the evidence layer (RelayTruthAdapter),
     * and the only source that can say unsupported is the engine declaration, already handled in the first tier.
     */
    private fun thinking(
        provider: Provider,
        model: AIModel,
        queryIdentity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity?,
    ): RelayCatalogCapabilityState {
        val declared = model.engineDeclaration?.thinking
            ?.takeUnless { provider.relayRequested?.engineProfile.isNullOrBlank() }
        if (declared != null) return declared.toState()
        val adjustable = CapabilityEvidenceProductionAdapter
            .supportedReasoningModes(provider, model, queryIdentity, metadata)
            .isNotEmpty()
        return if (adjustable) RelayCatalogCapabilityState.Supported else RelayCatalogCapabilityState.Unknown
    }

    /** Existing Relay tool verdict (override > negative cache > engine declaration > model > memory). */
    private fun tool(provider: Provider, model: AIModel): RelayCatalogCapabilityState =
        CapabilityEvidenceProductionAdapter.toolCallVerdict(
            provider = provider,
            model = model,
            memoryVerdict = toolMemoryFor(model),
            metadataClient = metadata,
            negativeCache = negativeCache,
        ).toState()

    /** The evidence facade's web_search tri-state; the web logic is read-only in this unit. */
    private fun web(
        provider: Provider,
        model: AIModel,
        queryIdentity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity?,
    ): RelayCatalogCapabilityState =
        when (
            CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider = provider,
                model = model,
                identity = queryIdentity,
                keys = setOf(WEB_SEARCH),
                metadataClient = metadata,
            ).decision(WEB_SEARCH)?.resolution?.support
        ) {
            "supported" -> RelayCatalogCapabilityState.Supported
            "unsupported" -> RelayCatalogCapabilityState.Unsupported
            else -> RelayCatalogCapabilityState.Unknown
        }

    private fun Boolean?.toState(): RelayCatalogCapabilityState = when (this) {
        true -> RelayCatalogCapabilityState.Supported
        false -> RelayCatalogCapabilityState.Unsupported
        null -> RelayCatalogCapabilityState.Unknown
    }

    private companion object {
        const val WEB_SEARCH = "web_search"
    }
}

/** Structure of the Relay / local "Model Library" subpage: the Screen only renders it. The official-provider model library does not go through here. */
object RelayCatalogBoardModel {
    val LEGEND: List<Pair<RelayCatalogCapabilityState, Int>> = listOf(
        RelayCatalogCapabilityState.Supported to R.string.relay_catalog_legend_supported,
        RelayCatalogCapabilityState.Unknown to R.string.relay_catalog_legend_unknown,
        RelayCatalogCapabilityState.Unsupported to R.string.relay_catalog_legend_unsupported,
    )

    /**
     * An enabled model is confirmed gone from the Relay catalog: the catalog is confirmed ([confirmedCatalogIndex] non-null), it is not manually entered, and it is absent from the index.
     * The legacy detail-page row and the model library row share this one criterion.
     */
    fun isMissingFromConfirmedCatalog(provider: Provider, model: AIModel, confirmedCatalogIndex: Set<String>?): Boolean =
        provider.kind == ProviderKind.Relay && !model.isManual &&
            confirmedCatalogIndex != null &&
            !ModelSelectionUtils.catalogIndexContains(confirmedCatalogIndex, model.id, provider.kind)

    fun build(
        provider: Provider,
        enabledModels: List<AIModel>,
        catalogGroups: List<ProviderCatalogGroup>,
        filter: RelayCatalogFilter,
        nowSeconds: Long,
        confirmedCatalogIndex: Set<String>?,
        facts: RelayCatalogCapabilitySource,
        catalogState: ProviderDetailViewModel.RelayCatalogUiState = ProviderDetailViewModel.RelayCatalogUiState.Available,
        /** Lazy verification states for this session (model id -> state), from [ProviderRepository.relayModelProbeStates]. */
        probeStates: Map<String, ProviderRepository.RelayModelProbeState> = emptyMap(),
        canAddManual: Boolean = true,
    ): RelayCatalogBoard {
        val local = RelayDetailBoardModel.isLocal(provider)
        // The connection transport was chosen by the user: models without their own transport follow the connection and are not probed; on rows they sit in the same tier as manually chosen model transports.
        val explicitConnection = RelayProbeCandidates.connectionIsExplicit(provider.relayRequested)
        val multiKey = RelayKeyBinding.showsKeyUI(provider)
        val keysBoard = RelayKeysBoardModel.build(provider)
        val keyTitles = keysBoard.rows.associate { it.id to it.title }
        // The delete threshold counts all enabled models, the same criterion as production removal (toggleModelEnabled).
        val removable = enabledModels.size > 1
        val enabledRows = enabledModels.map { model ->
            val caps = facts.states(provider, model, nowSeconds)
            val probe = probeStates[model.id]
            val status = when {
                RelayKeyBinding.modelState(provider, model.id).deniedOnCurrentKey -> RelayCatalogRowStatus.DeniedOnCurrentKey
                probe == ProviderRepository.RelayModelProbeState.InFlight -> RelayCatalogRowStatus.Verifying
                probe is ProviderRepository.RelayModelProbeState.Failed -> RelayCatalogRowStatus.Unreachable
                isMissingFromConfirmedCatalog(provider, model, confirmedCatalogIndex) -> RelayCatalogRowStatus.MissingFromCatalog
                local -> null
                // auto is treated as having no model-level transport; the source field does not count.
                else -> when (
                    model.relayTransportSource.takeIf {
                        model.relayTransport != null && model.relayTransport != RelayTransport.Auto
                    }
                ) {
                    RelayTransportSource.Observed -> RelayCatalogRowStatus.Verified
                    RelayTransportSource.Reachable -> RelayCatalogRowStatus.Reachable
                    RelayTransportSource.User -> RelayCatalogRowStatus.SetByYou
                    null -> if (explicitConnection) RelayCatalogRowStatus.SetByYou else RelayCatalogRowStatus.UnknownUntilSent
                }
            }
            row(provider, model, local, caps, status, listOf(RelayCatalogTrailing.NewChat, RelayCatalogTrailing.More)).copy(
                tapTarget = RelayCatalogTapTarget.Advanced,
                menu = listOf(
                    RelayCatalogMenuItem(
                        action = RelayEnabledRowMenuItem.Remove,
                        enabled = removable,
                        disabledReasonRes = if (removable) null else R.string.relay_catalog_remove_last_reason,
                    ),
                ),
                keyChip = if (multiKey) keyTitles[RelayKeyBinding.effectiveKeyID(provider, model.id)] else null,
                unreachable = (probe as? ProviderRepository.RelayModelProbeState.Failed)
                    ?.takeIf { status == RelayCatalogRowStatus.Unreachable },
            )
        }
        val libraryGroups = catalogGroups.map { group ->
            RelayCatalogLibraryGroup(
                id = group.id,
                title = group.title,
                titleRes = group.titleRes,
                rows = group.models.map { model ->
                    val caps = facts.states(provider, model, nowSeconds)
                    val status = when {
                        local -> null
                        explicitConnection -> RelayCatalogRowStatus.SetByYou
                        caps.any { it != RelayCatalogCapabilityState.Unknown } -> RelayCatalogRowStatus.VerifyOnEnable
                        else -> RelayCatalogRowStatus.UnknownUntilSent
                    }
                    val trailing = if (model.isAvailable) RelayCatalogTrailing.Add else RelayCatalogTrailing.Unavailable
                    row(provider, model, local, caps = caps, status = status, trailing = listOf(trailing))
                        .copy(tapTarget = RelayCatalogTapTarget.ReadOnlyAdvanced)
                },
            )
        }

        val present = (enabledRows + libraryGroups.flatMap { it.rows }).mapNotNull { it.protocol }.toSet()
        val protocolChips = if (local || present.size < 2) {
            emptyList()
        } else {
            RelayBoardProtocol.entries.filter { it in present }.map { RelayCatalogFilter.Protocol(it) }
        }
        // The key filter becomes a chip only when active (placed after "All"): if the key no longer exists or its catalog is 0 -> inactive, falling back to "All".
        val keyFilterRow = (filter as? RelayCatalogFilter.Key)?.let { key ->
            keysBoard.rows.firstOrNull { it.id == key.keyID && (it.catalogCount ?: 0) > 0 }
        }
        val keyChip = keyFilterRow?.let { RelayCatalogFilter.Key(it.id) }
        val filters = if (keyChip == null && protocolChips.isEmpty()) {
            emptyList()
        } else {
            listOf(RelayCatalogFilter.All) + listOfNotNull(keyChip) + protocolChips
        }
        // When the selected transport is no longer among the chips (connection default changed, model removed), fall back to "All".
        val selected = filter.takeIf { it in filters } ?: RelayCatalogFilter.All
        // Key filter: the entry's listers include that key (same criterion as the per-key catalog count); enabled rows are filtered the same way.
        fun passes(row: RelayCatalogRow) = when (selected) {
            is RelayCatalogFilter.Protocol -> row.protocol == selected.protocol
            is RelayCatalogFilter.Key -> selected.keyID in RelayKeyBinding.listingKeyIDs(provider, row.model.id)
            RelayCatalogFilter.All -> true
        }

        // Section header counts are totals: they do not change with transport filtering or search; catalog = deduplicated by id minus enabled.
        val enabledIds = enabledModels.map { it.id }.toSet()
        val libraryTotal = provider.catalogModels.map { it.id }.distinct().count { it !in enabledIds }
        val shownEnabled = enabledRows.filter(::passes)
        val shownGroups = libraryGroups
            .map { it.copy(rows = it.rows.filter(::passes)) }
            .filter { it.rows.isNotEmpty() }
            .map { it.copy(enableAllModelIDs = enableAllModelIDs(provider, it.rows.map(RelayCatalogRow::model))) }
        val keyStrip = if (!multiKey) {
            emptyList()
        } else {
            val statuses = RelayKeyBinding.keys(provider).associate { it.id to it.status }
            keysBoard.rows.map { row ->
                val status = statuses[row.id]
                RelayCatalogKeyStripItem(
                    keyId = row.id,
                    title = row.title,
                    catalogCount = row.catalogCount,
                    // Never-checked and unrecognized states both use the default: no checkmark, no status word.
                    state = when {
                        status?.state == "ok" -> RelayCatalogKeyStripState.Ok
                        status == null || RelayKeysBoardModel.statusRes(status.state) == null -> RelayCatalogKeyStripState.Unchecked
                        else -> RelayCatalogKeyStripState.Failed(status.httpStatus, row.statusRes)
                    },
                )
            }
        }
        val showsLibrary = when (catalogState) {
            ProviderDetailViewModel.RelayCatalogUiState.Available -> true
            // On failure the old catalog is still shown below the failure card / status bar.
            ProviderDetailViewModel.RelayCatalogUiState.Failed -> provider.catalogModels.isNotEmpty()
            ProviderDetailViewModel.RelayCatalogUiState.Loading,
            ProviderDetailViewModel.RelayCatalogUiState.Empty,
            -> false
        }
        val enableHintRes = when {
            local -> null
            explicitConnection -> R.string.relay_catalog_enable_hint_explicit
            else -> R.string.relay_catalog_enable_hint
        }
        val sections = listOfNotNull(
            RelayCatalogPageSection.Header,
            RelayCatalogPageSection.Filters.takeIf { filters.isNotEmpty() },
            RelayCatalogPageSection.Enabled,
            RelayCatalogPageSection.KeyStrip.takeIf { keyStrip.isNotEmpty() },
            RelayCatalogPageSection.Loading.takeIf { catalogState == ProviderDetailViewModel.RelayCatalogUiState.Loading },
            RelayCatalogPageSection.FailureCard.takeIf {
                !multiKey && catalogState == ProviderDetailViewModel.RelayCatalogUiState.Failed
            },
            RelayCatalogPageSection.Library.takeIf { showsLibrary },
            RelayCatalogPageSection.EnableHint.takeIf { showsLibrary && enableHintRes != null },
            RelayCatalogPageSection.ManualAdd.takeIf { canAddManual },
            RelayCatalogPageSection.Legend,
        )
        return RelayCatalogBoard(
            filters = filters,
            selected = selected,
            keyFilterTitle = keyFilterRow?.title?.takeIf { selected is RelayCatalogFilter.Key },
            enabled = RelayCatalogEnabledSection(R.string.relay_catalog_section_enabled, enabledModels.size, shownEnabled),
            library = RelayCatalogLibrarySection(
                R.string.relay_catalog_section_library,
                libraryTotal,
                shownGroups,
            ),
            legend = LEGEND,
            footnoteRes = R.string.relay_catalog_sources_footnote,
            header = RelayCatalogHeader(
                host = keysBoard.host,
                modelCount = (enabledModels.map { it.id } + provider.catalogModels.map { it.id }).distinct().size,
                keyCount = keysBoard.keyCount.takeIf { multiKey },
            ),
            keyStrip = keyStrip,
            sections = sections,
            enableHintRes = enableHintRes,
        )
    }

    /** First-frame filter: if the nearest model-library layer in the stack carries a key filter, open with it; otherwise "All". */
    fun initialFilter(stack: RelayDetailNavStack): RelayCatalogFilter =
        (stack.layers.lastOrNull { it is RelayDetailLayer.Library } as? RelayDetailLayer.Library)
            ?.keyFilter?.let { RelayCatalogFilter.Key(it) } ?: RelayCatalogFilter.All

    /** Tapping a catalog row = read-only advanced (zero requests); the plus is what enables. */
    fun libraryRowLayer(row: RelayCatalogRow): RelayDetailLayer.Advanced =
        RelayDetailLayer.Advanced(row.model.id, readOnly = row.tapTarget != RelayCatalogTapTarget.Advanced)

    /** Tapping an enabled row = editable advanced. */
    fun enabledRowLayer(row: RelayCatalogRow): RelayDetailLayer.Advanced =
        RelayDetailLayer.Advanced(row.model.id, readOnly = row.tapTarget != RelayCatalogTapTarget.Advanced)

    /** The view dispatches row taps only by [tapTarget]; rows without board context (official, home add-model) keep legacy behavior: catalog rows enable, enabled rows open chat. */
    fun rowTap(modelID: String, tapTarget: RelayCatalogTapTarget?, enabledRow: Boolean): RelayCatalogRowTap = when (tapTarget) {
        RelayCatalogTapTarget.Advanced -> RelayCatalogRowTap.OpenAdvanced(RelayDetailLayer.Advanced(modelID, readOnly = false))
        RelayCatalogTapTarget.ReadOnlyAdvanced -> RelayCatalogRowTap.OpenAdvanced(RelayDetailLayer.Advanced(modelID, readOnly = true))
        null -> if (enabledRow) RelayCatalogRowTap.StartChat else RelayCatalogRowTap.Enable
    }

    /** Row-level screen-reader value: "model name, capability name status word, ...", capabilities in icon order. */
    fun rowReadoutText(modelName: String, parts: List<RelayCatalogReadoutPart>, string: (Int) -> String): String =
        (listOf(modelName) + parts.map { "${string(it.capabilityRes)} ${string(it.stateRes)}" }).joinToString(", ")

    /**
     * Models the group's "Add all" can add: not enabled, catalog marks them available, and the key they would land on after enabling is not judged as lacking access
     * (no-access marks on other keys are still accepted); same order as group rows. Which key it lands on uses the same [RelayKeyBinding.bind] as single enabling, and models added earlier count as enabled.
     */
    fun enableAllModelIDs(
        provider: Provider,
        rows: List<AIModel>,
        family: (String) -> String? = RelayKeyBinding::cachedFamily,
    ): List<String> {
        val keyIDs = RelayKeyBinding.keyIDs(provider)
        val enabled = provider.models.toMutableList()
        val result = mutableListOf<String>()
        for (model in rows) {
            if (!model.isAvailable || enabled.any { it.id == model.id }) continue
            val entry = provider.catalogModels.firstOrNull { it.id == model.id } ?: model
            val landing = RelayKeyBinding.bind(keyIDs, provider.catalogModels, enabled, model.id, family) ?: keyIDs.first()
            if (entry.relayDeniedKeyID != null && entry.relayDeniedKeyID == landing) continue
            enabled += model.copy(relayKeyID = landing)
            result += model.id
        }
        return result
    }

    private val READOUT_TITLES = listOf(
        R.string.capability_image,
        R.string.capability_file,
        R.string.local_setup_tile_thinking,
        R.string.relay_model_advanced_tool_calls,
        R.string.model_control_web_search,
    )

    @StringRes
    private fun readoutState(state: RelayCatalogCapabilityState): Int = when (state) {
        RelayCatalogCapabilityState.Supported -> R.string.relay_capability_test_supported
        RelayCatalogCapabilityState.Unknown -> R.string.relay_model_advanced_unknown
        RelayCatalogCapabilityState.Unsupported -> R.string.relay_capability_test_unsupported
    }

    private fun row(
        provider: Provider,
        model: AIModel,
        local: Boolean,
        caps: List<RelayCatalogCapabilityState>,
        status: RelayCatalogRowStatus?,
        trailing: List<RelayCatalogTrailing>,
    ) = RelayCatalogRow(
        model = model,
        // Model-level transport, otherwise the connection default, auto -> Chat; catalog rows are not drawn by candidate order. The local channel is connection-level and not drawn.
        protocol = if (local) null else RelayBoardProtocol.of(RelayEndpointResolver.effectiveTransport(provider, model)),
        caps = caps,
        status = status,
        trailing = trailing,
        readout = READOUT_TITLES.mapIndexed { index, title ->
            RelayCatalogReadoutPart(title, readoutState(caps.getOrNull(index) ?: RelayCatalogCapabilityState.Unknown))
        },
    )
}
