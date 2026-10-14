package ai.oriveo.community.feature.providers.relay

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.navigation.ProviderSetupEntryPoint
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryFailureKind
import ai.oriveo.community.core.provider.RelayDiscoveryResult
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayProbeCandidates
import ai.oriveo.community.feature.providers.SetupBoardSlot
import ai.oriveo.community.feature.providers.detail.ProviderCatalogGroup
import ai.oriveo.community.feature.providers.detail.ProviderDetailNotice
import ai.oriveo.community.feature.providers.detail.buildProviderCatalogGroups
import java.text.NumberFormat
import java.util.Locale

/*
 * State and pure functions of the two-step relay add flow (Setup / SetupModels boards). The ViewModel only assembles, the Screen only renders.
 */

enum class RelaySetupStep { Address, Models }

enum class RelayCheckKind { Connection, Catalog, Protocols }

enum class RelayCheckState { Pending, Running, Done, Failed, Skipped }

/** The four one-line categories plus the step 2 empty-state line; other failures reuse the existing failure reason ([Other], with the body given separately). */
enum class RelaySetupFailureKind(@StringRes val messageRes: Int?) {
    Address(R.string.relay_setup_fail_address),
    InvalidKey(R.string.relay_setup_fail_key),
    Permission(R.string.relay_setup_fail_permission),
    Network(R.string.relay_setup_fail_network),
    ModelsEmpty(R.string.relay_setup_models_empty),
    Other(null),
}

/** One-line classification of step 1 detection failures: route unavailable / returned a web page -> address; 401 -> key; 403 -> no permission to list models; network -> cannot connect. */
fun relaySetupFailureKind(result: RelayDiscoveryResult): RelaySetupFailureKind = when (result.blockingFailure) {
    RelayDiscoveryFailureKind.RouteUnavailable, RelayDiscoveryFailureKind.InvalidResponse -> RelaySetupFailureKind.Address
    RelayDiscoveryFailureKind.AuthenticationRejected ->
        if (result.attempts.lastOrNull { it.failure == RelayDiscoveryFailureKind.AuthenticationRejected }?.statusCode == 403) {
            RelaySetupFailureKind.Permission
        } else {
            RelaySetupFailureKind.InvalidKey
        }
    RelayDiscoveryFailureKind.Network -> RelaySetupFailureKind.Network
    else -> RelaySetupFailureKind.Other
}

/** Failures when fetching the catalog per extra key use the same classification (empty status code = network / decode failure). */
fun relaySetupFailureKind(failed: RelayKeyBinding.CatalogFetch.Failed): RelaySetupFailureKind = when (failed.status) {
    null -> RelaySetupFailureKind.Network
    401 -> RelaySetupFailureKind.InvalidKey
    403 -> RelaySetupFailureKind.Permission
    404, 405 -> RelaySetupFailureKind.Address
    else -> RelaySetupFailureKind.Other
}

/** One item of the detection card; elapsed = start to end (to [now] while in progress). */
data class RelayCheckRow(
    val kind: RelayCheckKind,
    val state: RelayCheckState,
    val startedAt: Long? = null,
    val finishedAt: Long? = null,
    val failure: RelaySetupFailureKind? = null,
    /** Existing failure reason body for [RelaySetupFailureKind.Other]. */
    val failureText: String? = null,
    /** The reachable path on a successful connection (e.g. `/v1/models`). */
    val reachablePath: String? = null,
) {
    fun elapsedMs(now: Long): Long? {
        if (state == RelayCheckState.Pending || state == RelayCheckState.Skipped) return null
        val start = startedAt ?: return null
        return ((finishedAt ?: now) - start).coerceAtLeast(0)
    }

    val isFinished: Boolean
        get() = state == RelayCheckState.Done || state == RelayCheckState.Failed || state == RelayCheckState.Skipped
}

/** One row per key for "Fetch catalog": name (masked if unnamed; hidden when there is only one key) + model count or a one-line failure. */
data class RelayKeyCatalogLine(
    val keyID: String,
    val label: String?,
    val state: RelayCheckState,
    val modelCount: Int? = null,
    val failure: RelaySetupFailureKind? = null,
    val failureText: String? = null,
)

data class RelayDetectionBoard(
    val rows: List<RelayCheckRow>,
    val keyLines: List<RelayKeyCatalogLine>,
    /** The "requests tried" and the source of the upstream message kept below a failure's one-liner. */
    val attempts: List<RelayDiscoveryAttempt>,
) {
    val total: Int get() = rows.size
    val completed: Int get() = rows.count { it.isFinished }
    val isRunning: Boolean get() = rows.any { it.state == RelayCheckState.Running || it.state == RelayCheckState.Pending }

    fun row(kind: RelayCheckKind): RelayCheckRow = rows.first { it.kind == kind }
}

data class RelaySetupKeyRow(
    val id: String,
    val isPrimary: Boolean,
    val secret: String,
    val name: String,
    /** The name input is hidden with a single key; once a second key is added every key (including the primary) shows it. */
    val showsName: Boolean,
    /** The primary key cannot be deleted. */
    val removable: Boolean,
)

/** Step 1 board: address -> key -> "Add another key", with the primary button always "Next". */
data class RelaySetupBoard(
    val slots: List<SetupBoardSlot>,
    val keys: List<RelaySetupKeyRow>,
    /** The value of "Will request ..." under the address slot (already with `/...`); null hides it. */
    val willRequest: String?,
    val detection: RelayDetectionBoard?,
    val isPrimaryEnabled: Boolean,
    val showsCancelDetection: Boolean,
    @StringRes val primaryLabel: Int = R.string.relay_setup_next,
    @StringRes val keysFootnote: Int = R.string.relay_setup_keys_local,
    @StringRes val heroLabel: Int = R.string.relay_setup_hero_label,
    @StringRes val heroTitle: Int = R.string.relay_setup_hero_title,
    @StringRes val heroSubtitle: Int = R.string.relay_setup_hero_subtitle_two_step,
    @StringRes val secondaryRow: Int = R.string.relay_setup_manual_protocol,
)

data class RelaySetupModelRow(
    val id: String,
    val selected: Boolean,
    val protocol: RelayBoardProtocol,
    /** The bound key when there are 2 or more keys and something is selected (name, masked if unnamed); otherwise null. */
    val keyChip: String?,
)

data class RelaySetupModelGroup(
    val id: String,
    val title: String,
    /** Localized group name of the "Other" group (same projection as the model library). */
    @StringRes val titleRes: Int? = null,
    val modelCount: Int,
    val selectedCount: Int,
    val expanded: Boolean,
    /** Not tappable once everything is selected. */
    val canSelectAll: Boolean,
    /** Rows when expanded (only matching rows while searching); empty when collapsed. */
    val rows: List<RelaySetupModelRow>,
)

/** Step 2 board: selection is grouped by the same grouping projection as the model library, and saving only verifies the first selected model in display order. */
data class RelaySetupModelsBoard(
    val host: String?,
    val keyCount: Int,
    val totalModels: Int,
    val groups: List<RelaySetupModelGroup>,
    val isCatalogEmpty: Boolean,
    val selectedCount: Int,
    val firstSelected: String?,
    val isSaveEnabled: Boolean,
    val isSaving: Boolean,
    val saveFailure: String?,
    /** A manually added ID that collides with one already in the list: the line below the button reads "Already in the list, selected for you". */
    val manualAddNotice: Boolean = false,
)

/** Result of manually adding a model ID in step 2 (BOARD-SETUPMODELS-06 to 08). */
enum class RelayManualModelAddResult { Ignored, AlreadyListed, Added }

/** "Add" is enabled: non-empty after trim (BOARD-SETUPMODELS-06). */
fun relayManualModelAddable(raw: String): Boolean = raw.trim().isNotEmpty()

/** Protocol groups for the add page ratio bar / row chips; legend names are literals and not translated. Declaration order = the fixed legend order. */
enum class RelayBoardProtocol(val legend: String) {
    Chat("Chat"),
    Responses("Responses"),
    Messages("Messages"),
    Gemini("Gemini"),
    ;

    companion object {
        fun of(transport: RelayTransport): RelayBoardProtocol = when (transport) {
            RelayTransport.OpenAIResponses -> Responses
            RelayTransport.AnthropicMessages -> Messages
            RelayTransport.GeminiGenerateContent -> Gemini
            RelayTransport.OpenAIChatCompletions, RelayTransport.Auto, RelayTransport.LlamaCppNative -> Chat
        }
    }
}

/** Item 3 "Detect protocol": the first candidate for each model, reading only the catalog endpoint types and the cached families, with zero requests. */
fun relayFirstCandidate(
    supportedEndpointTypes: List<String>?,
    modelID: String,
    cachedFamily: (String) -> String?,
): RelayTransport =
    RelayProbeCandidates.fromEndpointTypes(supportedEndpointTypes).firstOrNull()
        ?: RelayProbeCandidates.forFamily(cachedFamily(modelID)).firstOrNull()
        ?: RelayTransport.OpenAIChatCompletions

/**
 * Step 2 grouping = the same projection as the model library ([buildProviderCatalogGroups], relay models grouped uniformly by family): a temporary connection is assembled from the catalog rows and default name that will exist after registration, so
 * group names, group order and in-group order match the post-registration model library verbatim.
 */
fun relaySetupCatalogGroups(rows: List<AIModel>, endpoint: String, searchQuery: String): List<ProviderCatalogGroup> {
    fun project(models: List<AIModel>) = buildProviderCatalogGroups(
        provider = Provider(
            id = "relay-setup-preview",
            kind = ProviderKind.Relay,
            baseUrlText = endpoint,
            customName = ai.oriveo.community.core.data.repository.ProviderRepository.relayDomainNameFromEndpoint(endpoint),
            catalogModels = models,
        ),
        searchQuery = searchQuery,
    )
    var groups = project(rows)
    // Relay models are identified by literal ID: the canonical dedup of the model library projection folds dated snapshot spellings, and step 2 selection and saving
    // must not swallow them: rows swallowed only by date-suffix folding are appended to the end of their group, projected on their own (group name and order rules unchanged).
    // IDs that differ only by case are still the same model and are not appended back.
    val shown = groups.flatMap { group -> group.models.map { it.id.lowercase() } }.toMutableSet()
    rows.forEach { model ->
        if (!shown.add(model.id.trim().lowercase())) return@forEach
        val own = project(listOf(model)).firstOrNull() ?: return@forEach
        groups = if (groups.any { it.id == own.id }) {
            groups.map { group -> if (group.id == own.id) group.copy(models = group.models + own.models) else group }
        } else {
            groups + own
        }
    }
    return groups
}

/** Elapsed time: seconds with one decimal, digits follow the UI language; wrapped in the existing "%s s". */
fun relaySetupSeconds(elapsedMs: Long, locale: Locale): String =
    NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = 1
        maximumFractionDigits = 1
    }.format(elapsedMs / 1000.0)

/**
 * Saved successfully from the providers entry: the detail page shows "n models added" once, and an unverified manual-setup save shows "Connection not verified yet" + reason once;
 * other entries keep the existing completion path.
 */
fun RelaySetupCompletionTarget.ProviderDetail.postAddedNotice(entryPoint: ProviderSetupEntryPoint) {
    if (entryPoint != ProviderSetupEntryPoint.Providers) return
    unverifiedReason?.let { ProviderDetailNotice.postUnverified(providerId, it) }
    addedModelCount?.let { ProviderDetailNotice.postAddedModels(providerId, it) }
}
