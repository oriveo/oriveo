package ai.oriveo.community.feature.providers.relay

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.remote.RelayModelFamilyLookup
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.model.hasStoredCredential
import ai.oriveo.community.core.provider.ProviderKeyInput
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.core.provider.RelayFormDraft
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayDetectedConfiguration
import ai.oriveo.community.core.provider.RelayDetectionEvidence
import ai.oriveo.community.core.provider.RelayDiscoveryFailureKind
import ai.oriveo.community.core.provider.RelayDiscoveryResult
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayModelProbe
import ai.oriveo.community.core.provider.relay.RelayModelProbeOutcome
import ai.oriveo.community.core.provider.relay.RelayModelProbePass
import ai.oriveo.community.core.provider.relay.RelayProbeCandidates
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.providers.CustomLLMConnectionEvidence
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import ai.oriveo.community.feature.providers.CustomLLMSetupPhase
import ai.oriveo.community.feature.providers.CustomLLMVerificationEvidence
import ai.oriveo.community.feature.providers.SetupBoardSlot
import ai.oriveo.community.feature.providers.detail.ProviderCatalogGroup
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.net.URI
import java.util.UUID

sealed interface RelaySetupCompletionTarget {
    /**
     * [addedModelCount]: the number of models enabled at save time, for the one-shot notice on the detail page reached from the providers entry;
     * [unverifiedReason]: the already localized reason line on the failure card when manual setup is saved with "Save anyway (unverified)".
     */
    data class ProviderDetail(
        val providerId: String,
        val addedModelCount: Int? = null,
        val unverifiedReason: String? = null,
    ) : RelaySetupCompletionTarget
}

enum class RelaySetupMode { Quick, Manual }

/** Draft of an extra key (the primary key = [RelaySetupViewModel.apiKey] + [RelaySetupViewModel.primaryKeyName]). */
data class RelaySetupKeyDraft(val id: String, val name: String = "", val secret: String = "")

/** Snapshot of the input when a manual setup verification starts; the name is not included (renaming does not invalidate the failure card). */
private data class RelayManualSnapshot(
    val endpoint: String,
    val secrets: List<Pair<String, String>>,
    val model: String,
    val transport: RelayTransport,
    val authMode: RelayAuthMode,
    val userAgent: String,
    val headers: List<RelayKeyValue>,
    val queryParams: List<RelayKeyValue>,
)

/**
 * ViewModel of the relay setup page. The quick path is a two-step add: step 1 is address + key -> detection (connectivity / catalog fetch / protocol recognition, zero 1-token requests),
 * step 2 selects models by group, and saving sends a single 1-token request for the first selected model in display order; manual setup is merged into one page and shares the address and all keys with step 1.
 */
class RelaySetupViewModel(
    private val context: Context,
    private val providerRepository: ProviderRepository,
    private val discoveryService: RelayDiscoveryService,
    /** Family lookup for per-model probe candidates; the injection point exists only so unit tests do not hit production metadata. */
    private val modelFamily: suspend (String) -> String? = { RelayModelFamilyLookup.shared.family(it) },
    /** The third item, "recognize protocol", reads only the cached family and sends no request for it; the injection point exists only for unit tests. */
    private val cachedModelFamily: (String) -> String? = { RelayModelFamilyLookup.shared.cachedFamily(it) },
    /** Clock for the per-item elapsed time of the detection card; the injection point exists only for unit tests. */
    private val clock: () -> Long = System::currentTimeMillis,
    /** Placeholder of the manual setup model slot (the delivered flagship model ID); the injection point exists only so unit tests do not read production metadata. */
    private val modelPlaceholder: () -> String = RelayFlagshipModel::current,
    /** Non-blocking catalog refresh / last-used recording after saving: the page is left right away, so this must not hang on viewModelScope where it would be cancelled. */
    private val backgroundScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    /** After manual setup verification passes, mark that model as the last used one. */
    private val rememberLastUsedModel: suspend (providerId: String, modelId: String) -> Unit = { _, _ -> },
) : ViewModel() {

    companion object {
        fun normalizedRelayEndpoint(raw: String): String? = RelayEndpointPolicy.normalize(raw)
    }

    private fun requestSafeRelayEndpoint(raw: String): String? {

        if (raw != endpoint) return null
        val normalized = RelayFormValidation.normalizedEndpoint(formDraft, RelayFormValidation.FormMode.Create)
            ?: return null
        endpointHighlightRange = RelaySecurityModePolicy.addedSchemeHighlightRange(raw, normalized)
        if (normalized != endpoint) endpoint = normalized
        return normalized
    }

    /** Connection name for manual setup (optional; empty = the address domain). */
    var name: String by mutableStateOf("")
        private set
    var endpoint: String by mutableStateOf("")
    var endpointHighlightRange: IntRange? by mutableStateOf(null)
        private set

    val securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps
    var apiKey: String by mutableStateOf("")
    /** Model input for manual setup (the verification sample + the only enabled model); the quick path no longer has a default-model slot. */
    var defaultModel: String by mutableStateOf("")
        internal set
    var mode: RelaySetupMode by mutableStateOf(RelaySetupMode.Quick)
        private set
    var discoveryResult: RelayDiscoveryResult? by mutableStateOf(null)
        private set

    // -- Manual setup: the default transport starts as automatic and so does authentication; the remaining advanced items are changed in edit connection after saving --
    var manualTransport: RelayTransport by mutableStateOf(RelayTransport.Auto)
        private set
    var manualAuthMode: RelayAuthMode by mutableStateOf(RelayAuthMode.Auto)
        private set
    var manualUserAgent: String by mutableStateOf("")
        private set
    var manualHeaders: List<RelayKeyValue> by mutableStateOf(emptyList())
        private set
    var manualQueryParams: List<RelayKeyValue> by mutableStateOf(emptyList())
        private set
    private var manualAdvancedExpanded: Boolean by mutableStateOf(false)
    private var manualFailure: RelayManualFailure? by mutableStateOf(null)
    /** The input that the failure card belongs to; "Save anyway" is not accepted when it differs from the current input. */
    private var manualFailureSnapshot: RelayManualSnapshot? = null
    /** The current verification / save attempt; it is invalidated as soon as the coordinator generation changes. */
    private var manualAttempt: ai.oriveo.community.feature.providers.CustomLLMSetupAttempt? by mutableStateOf(null)
    /** Completion latch: between persisting and leaving the page, neither the primary button nor "Save anyway" is accepted. */
    private var manualCompleted: Boolean by mutableStateOf(false)

    var registeredProvider: Provider? by mutableStateOf(null)
        private set

    var completionTarget: RelaySetupCompletionTarget? by mutableStateOf(null)
        private set

    // -- Two-step add state --

    var step: RelaySetupStep by mutableStateOf(RelaySetupStep.Address)
        private set
    /** Name of the primary key; shown and written only with two or more keys. */
    var primaryKeyName: String by mutableStateOf("")
        private set
    var extraKeys: List<RelaySetupKeyDraft> by mutableStateOf(emptyList())
        private set
    /** Input problems that can be reported on the spot, such as a key containing non-printable characters (detection does not start). */
    var keyInputIssue: String? by mutableStateOf(null)
        private set
    private var detection: RelayDetectionBoard? by mutableStateOf(null)
    /** Catalog result per key in this detection round (key = key id), handed to registration at save time to be merged. */
    private var keyCatalogs: Map<String, RelayKeyBinding.CatalogFetch> = emptyMap()
    /** Merged catalog rows (including who listed them); manually added ones are recorded separately. */
    private var catalogRows: List<AIModel> by mutableStateOf(emptyList())
    private var manualModelIDs: List<String> by mutableStateOf(emptyList())
    /** First candidate of each model (computed locally by the third item); used only by the row chips. */
    private var firstCandidates: Map<String, RelayTransport> by mutableStateOf(emptyMap())
    private var selectedModelIDs: Set<String> by mutableStateOf(emptySet())
    var modelSearch: String by mutableStateOf("")
        private set
    /** Groups the user has expanded / collapsed manually follow the user's choice. */
    private var groupExpansion: Map<String, Boolean> by mutableStateOf(emptyMap())
    private var saveFailure: String? by mutableStateOf(null)
    /** One-line notice when a manual add on step 2 hits an ID already in the list. */
    private var manualAddNotice: Boolean by mutableStateOf(false)

    /** The single connection state machine shared by Relay and the local conditional block. */
    val customLLMCoordinator = CustomLLMSetupCoordinator()

    val isDiscovering: Boolean
        get() = customLLMCoordinator.phase == CustomLLMSetupPhase.Detecting
    val isSubmitting: Boolean
        get() = customLLMCoordinator.phase == CustomLLMSetupPhase.Saving
    /** A manual setup verification / persist is in flight (the primary button shows a spinner). */
    val isValidatingManual: Boolean
        get() = manualAttempt?.let { attempt ->
            customLLMCoordinator.isCurrent(attempt) &&
                (customLLMCoordinator.phase == CustomLLMSetupPhase.Testing || customLLMCoordinator.phase == CustomLLMSetupPhase.Saving)
        } == true

    /** Empty extra key rows are ignored during detection and saving and do not block Next (same as iOS). */
    private val activeExtraKeys: List<RelaySetupKeyDraft>
        get() = extraKeys.filter { it.secret.isNotBlank() }

    private val allKeyIDs: List<String>
        get() = listOf(RelayKeyBinding.IMPLICIT_KEY_ID) + activeExtraKeys.map { it.id }

    private fun keySecret(keyID: String): String =
        if (keyID == RelayKeyBinding.IMPLICIT_KEY_ID) apiKey.trim() else extraKeys.firstOrNull { it.id == keyID }?.secret?.trim().orEmpty()

    /** Display name of a key: the name if there is one, otherwise a mask (no new "Key N" copy is added). */
    private fun keyLabel(keyID: String): String {
        val name = if (keyID == RelayKeyBinding.IMPLICIT_KEY_ID) primaryKeyName else extraKeys.firstOrNull { it.id == keyID }?.name
        return name?.trim()?.takeIf(String::isNotEmpty) ?: SecureKeyStore.maskApiKey(keySecret(keyID))
    }

    private val detectedRoot: String?
        get() = discoveryResult?.detections?.firstOrNull()?.apiBaseUrl

    /** The same set of key slots shared by step 1 and manual setup. */
    private val keyRows: List<RelaySetupKeyRow>
        get() {
            val multi = extraKeys.isNotEmpty()
            return listOf(
                RelaySetupKeyRow(RelayKeyBinding.IMPLICIT_KEY_ID, true, apiKey, primaryKeyName, multi, removable = false),
            ) + extraKeys.map { RelaySetupKeyRow(it.id, false, it.secret, it.name, true, removable = true) }
        }

    val board: RelaySetupBoard
        get() {
            val keys = keyRows
            val running = detection?.isRunning == true || isDiscovering
            return RelaySetupBoard(
                slots = listOf(SetupBoardSlot.Address, SetupBoardSlot.ApiKey, SetupBoardSlot.AddKey),
                keys = keys,
                willRequest = (detectedRoot ?: RelayEndpointResolver.previewAPIRoot(endpoint, securityMode))?.let { "$it/…" },
                detection = detection,
                isPrimaryEnabled = !running && !isSubmitting && formIssues.isEmpty(),
                showsCancelDetection = running,
            )
        }

    // -- Step 2 projection --

    private val step2Rows: List<AIModel>
        get() = catalogRows + manualModelIDs.filter { id -> catalogRows.none { it.id == id } }
            .map { ProviderRepository.relayCatalogRow(it).copy(isManual = true) }

    /** The group projection runs a full catalog resolution: cache the latest two results keyed by (catalog rows, address, search term) (the full list + the current search), so recomposition does not recompute. */
    private val groupsCache = LinkedHashMap<Triple<List<AIModel>, String, String>, List<ProviderCatalogGroup>>()

    private fun catalogGroups(query: String): List<ProviderCatalogGroup> {
        val key = Triple(step2Rows, endpoint, query)
        groupsCache[key]?.let { return it }
        val groups = relaySetupCatalogGroups(key.first, key.second, query)
        groupsCache[key] = groups
        while (groupsCache.size > 2) groupsCache.remove(groupsCache.keys.first())
        return groups
    }

    /** Display order (independent of search): group order, then order within the group. */
    private fun displayOrder(): List<String> = catalogGroups("").flatMap { group -> group.models.map { it.id } }

    private fun orderedSelection(): List<String> = displayOrder().filter { it in selectedModelIDs }

    val modelsBoard: RelaySetupModelsBoard
        get() {
            val fullGroups = catalogGroups("")
            val searching = modelSearch.isNotBlank()
            val shown = if (searching) catalogGroups(modelSearch.trim()) else fullGroups
            val ordered = fullGroups.flatMap { g -> g.models.map { it.id } }.filter { it in selectedModelIDs }
            val bindings = if (activeExtraKeys.isEmpty()) {
                emptyMap()
            } else {
                RelayKeyBinding.bindInOrder(allKeyIDs, catalogRows, ordered, RelayKeyBinding::cachedFamily)
            }
            val groups = shown.map { group ->
                val members = fullGroups.firstOrNull { it.id == group.id }?.models?.map { it.id } ?: group.models.map { it.id }
                val selectedCount = members.count { it in selectedModelIDs }
                val expanded = groupExpansion[group.id] ?: (searching || selectedCount > 0)
                RelaySetupModelGroup(
                    id = group.id,
                    title = group.title,
                    titleRes = group.titleRes,
                    modelCount = members.size,
                    selectedCount = selectedCount,
                    expanded = expanded,
                    canSelectAll = selectedCount < members.size,
                    rows = if (!expanded) {
                        emptyList()
                    } else {
                        group.models.map { model ->
                            val selected = model.id in selectedModelIDs
                            RelaySetupModelRow(
                                id = model.id,
                                selected = selected,
                                protocol = RelayBoardProtocol.of(firstCandidates[model.id] ?: candidateFor(model.id)),
                                keyChip = bindings[model.id]?.takeIf { selected }?.let(::keyLabel),
                            )
                        }
                    },
                )
            }
            return RelaySetupModelsBoard(
                // Subtitle host = the relay domain (with more than two labels take the last two; localhost / IP are kept as is).
                host = ProviderRepository.relayDomainNameFromEndpoint(detectedRoot ?: endpoint)
                    ?: RelayEndpointResolver.previewAPIRoot(endpoint, securityMode)?.let(ProviderRepository::relayDomainNameFromEndpoint),
                keyCount = allKeyIDs.size,
                totalModels = step2Rows.size,
                groups = groups,
                isCatalogEmpty = catalogRows.isEmpty(),
                selectedCount = selectedModelIDs.size,
                firstSelected = ordered.firstOrNull(),
                isSaveEnabled = selectedModelIDs.isNotEmpty() && !isSubmitting,
                isSaving = isSubmitting,
                saveFailure = saveFailure,
                manualAddNotice = manualAddNotice,
            )
        }

    private fun candidateFor(modelID: String): RelayTransport =
        relayFirstCandidate(discoveryResult?.detections?.firstOrNull()?.supportedEndpointTypes?.get(modelID), modelID, cachedModelFamily)

    /**
     * The authentication mode of the current draft. Quick setup has not detected a protocol yet, so authentication is undecided and is treated as `auto`;
     * manual setup reads the one the user picked in the collapsible group (initially automatic).
     */
    private val draftAuthMode: RelayAuthMode
        get() = if (mode == RelaySetupMode.Manual) manualAuthMode else RelayAuthMode.Auto

    val requiresCredential: Boolean
        get() = draftAuthMode.requiresCredential

    val formDraft: RelayFormDraft
        get() = RelayFormDraft(
            endpoint = endpoint,
            apiKey = apiKey,
            authMode = draftAuthMode,
            securityMode = securityMode,
            transport = if (mode == RelaySetupMode.Manual) manualTransport else RelayTransport.Auto,
            modelID = defaultModel,
            // The same rule as edit connection: rows with an empty name are not validated.
            headers = if (mode == RelaySetupMode.Manual) manualHeaders.cleanRelayAdvancedPairs().orEmpty() else emptyList(),
            queryParams = if (mode == RelaySetupMode.Manual) manualQueryParams.cleanRelayAdvancedPairs().orEmpty() else emptyList(),
            hasSavedCredential = false,
        )

    val formIssues: List<RelayFormValidation.FieldIssue>
        get() = RelayFormValidation.validate(formDraft, RelayFormValidation.FormMode.Create)

    val displayableFormIssues: List<RelayFormValidation.FieldIssue>
        get() = RelayFormValidation.displayableIssues(formIssues)

    /** The manual setup board: the view renders strictly from it, and the primary button being tappable and a tap being accepted use the same criterion. */
    internal val manualBoard: RelayManualSetupBoard
        get() = RelayManualSetupBoardModel.make(
            RelayManualSetupInput(
                endpoint = endpoint,
                keys = keyRows,
                model = defaultModel,
                connectionName = name,
                transport = manualTransport,
                authMode = manualAuthMode,
                userAgent = manualUserAgent,
                headers = manualHeaders,
                queryParams = manualQueryParams,
                issues = formIssues,
                advancedExpanded = manualAdvancedExpanded,
                isValidating = isValidatingManual,
                failure = manualFailure,
                completed = manualCompleted,
                modelPlaceholder = modelPlaceholder(),
            ),
        )

    override fun onCleared() {
        customLLMCoordinator.invalidate()
        super.onCleared()
    }

    fun updateEndpoint(value: String) {
        endpoint = value
        endpointHighlightRange = null
        clearDiscovery()
    }

    fun updateApiKey(value: String) {
        apiKey = value
        clearDiscovery()
    }

    /** Changing only the name does not invalidate the detection. */
    fun updatePrimaryKeyName(value: String) {
        primaryKeyName = value
    }

    fun addKey() {
        extraKeys = extraKeys + RelaySetupKeyDraft(id = UUID.randomUUID().toString())
        clearDiscovery()
    }

    fun removeKey(id: String) {
        if (extraKeys.none { it.id == id }) return
        extraKeys = extraKeys.filterNot { it.id == id }
        clearDiscovery()
    }

    fun updateKeySecret(id: String, value: String) {
        extraKeys = extraKeys.map { if (it.id == id) it.copy(secret = value) else it }
        clearDiscovery()
    }

    fun updateKeyName(id: String, value: String) {
        extraKeys = extraKeys.map { if (it.id == id) it.copy(name = value) else it }
    }

    fun updateDefaultModel(value: String) {
        defaultModel = value
        retireManualAttempt()
    }

    /** Changing only the connection name does not invalidate the failure card. */
    fun updateConnectionName(value: String) {
        name = value
    }

    fun selectManualTransport(value: RelayTransport) {
        manualTransport = value
        retireManualAttempt()
    }

    fun selectManualAuthMode(value: RelayAuthMode) {
        manualAuthMode = value
        retireManualAttempt()
    }

    fun updateManualUserAgent(value: String) {
        manualUserAgent = value
        retireManualAttempt()
    }

    fun updateManualHeaders(value: List<RelayKeyValue>) {
        manualHeaders = value
        retireManualAttempt()
    }

    fun updateManualQueryParams(value: List<RelayKeyValue>) {
        manualQueryParams = value
        retireManualAttempt()
    }

    /** Tapping a collapsible group header: while it is held open by a validation hint it counts as expanded (same criterion as edit connection). */
    fun toggleManualAdvanced() {
        val group = manualBoard.advancedGroup
        val forced = group.rows.any { it.issues.isNotEmpty() }
        manualAdvancedExpanded = RelayEditBoardModel.toggledExpansion(group.expanded, forced)
    }

    /** Entering manual setup: cancel a quick-setup detection that is in flight; the address and keys are shared as they are. */
    fun showManualSetup() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        mode = RelaySetupMode.Manual
        clearDiscovery()
    }

    /** The top-left "Use quick setup instead" and system back: return to step 1, keep all input, and discard a verification in flight. */
    fun showQuickSetup() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        mode = RelaySetupMode.Quick
        clearDiscovery()
    }

    fun selectRelayMethod() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Relay)
        clearDiscovery()
        clearRelayCompletionForMethodChange()
    }

    fun selectLocalMethod() {
        customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Local)
        clearDiscovery()
        clearRelayCompletionForMethodChange()
    }

    private fun clearRelayCompletionForMethodChange() {
        registeredProvider = null
        completionTarget = null
    }

    /**
     * The primary button "Next": not detected yet -> start detection; not tappable while detecting; once a detection round has a result (success, failure or empty catalog) -> go to step 2.
     * On success with a non-empty catalog, step 2 is entered automatically when detection ends.
     */
    fun next() {
        if (step != RelaySetupStep.Address || isDiscovering || isSubmitting) return
        val finished = detection
        if (finished != null && !finished.isRunning) {
            step = RelaySetupStep.Models
            return
        }
        startDetection()
    }

    fun cancelDetection() {
        clearDiscovery()
    }

    fun backToAddress() {
        if (isSubmitting) return
        step = RelaySetupStep.Address
    }

    private fun startDetection() {
        if (!board.isPrimaryEnabled) return
        val keyIDs = allKeyIDs
        if (keyIDs.map(::keySecret).any { it.isNotEmpty() && !ProviderKeyInput.isPrintableAsciiKey(it) }) {
            keyInputIssue = context.getString(R.string.provider_api_key_illegal_chars)
            return
        }
        keyInputIssue = null
        // A new detection round does not inherit the per-key catalogs of the previous round (they are not written again on a connectivity failure).
        keyCatalogs = emptyMap()
        catalogRows = emptyList()
        val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: return
        val attempt = customLLMCoordinator.begin(
            method = CustomLLMConnectionMethod.Relay,
            phase = CustomLLMSetupPhase.Detecting,
        )
        val secrets = keyIDs.associateWith(::keySecret)
        val labels = keyIDs.associateWith { id -> keyLabel(id).takeIf { keyIDs.size >= 2 } }
        val started = clock()
        fun publish(
            connection: RelayCheckRow,
            catalog: RelayCheckRow,
            protocols: RelayCheckRow,
            lines: List<RelayKeyCatalogLine>,
            result: RelayDiscoveryResult?,
        ) {
            detection = RelayDetectionBoard(listOf(connection, catalog, protocols), lines, result?.attempts.orEmpty())
        }
        val pendingLines = keyIDs.map { RelayKeyCatalogLine(it, labels[it], RelayCheckState.Pending) }
        publish(
            RelayCheckRow(RelayCheckKind.Connection, RelayCheckState.Running, startedAt = started),
            RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Pending, startedAt = started),
            RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Pending),
            pendingLines,
            null,
        )
        val job = viewModelScope.launch {
            try {
                val result = discoveryService.discover(
                    endpoint = normalizedEndpoint,
                    apiKey = secrets.getValue(RelayKeyBinding.IMPLICIT_KEY_ID),
                    modelHint = null,
                    relayRequested = formDraft.requestedConfigForPolicy(),
                )
                if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                val connected = clock()
                discoveryResult = result
                val primary = result.detections.firstOrNull()
                if (primary == null) {
                    // Connectivity failure: one sentence + the other two items skipped; tapping Next again goes to the manual-add state of step 2.
                    val kind = relaySetupFailureKind(result)
                    publish(
                        RelayCheckRow(
                            RelayCheckKind.Connection,
                            RelayCheckState.Failed,
                            started,
                            connected,
                            failure = kind,
                            failureText = localizedDiscoveryFailure(result.blockingFailure).takeIf { kind == RelaySetupFailureKind.Other },
                        ),
                        RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Skipped),
                        RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Skipped),
                        keyIDs.map { RelayKeyCatalogLine(it, labels[it], RelayCheckState.Skipped) },
                        result,
                    )
                    finishDetection(attempt, catalogAvailable = false)
                    return@launch
                }
                val connection = RelayCheckRow(
                    RelayCheckKind.Connection,
                    RelayCheckState.Done,
                    started,
                    connected,
                    reachablePath = result.attempts.lastOrNull { it.failure == null }?.requestUrl
                        ?.let { runCatching { URI(it).path }.getOrNull() },
                )
                val fetched = LinkedHashMap<String, RelayKeyBinding.CatalogFetch>()
                fetched[RelayKeyBinding.IMPLICIT_KEY_ID] = RelayKeyBinding.CatalogFetch.Ok(primary.modelIDs.map { ProviderRepository.relayCatalogRow(it) })
                fun lines(): List<RelayKeyCatalogLine> = keyIDs.map { id ->
                    when (val fetch = fetched[id]) {
                        null -> RelayKeyCatalogLine(id, labels[id], RelayCheckState.Running)
                        is RelayKeyBinding.CatalogFetch.Ok -> if (fetch.models.isEmpty()) {
                            RelayKeyCatalogLine(id, labels[id], RelayCheckState.Failed, 0, RelaySetupFailureKind.ModelsEmpty)
                        } else {
                            RelayKeyCatalogLine(id, labels[id], RelayCheckState.Done, fetch.models.size)
                        }
                        is RelayKeyBinding.CatalogFetch.Failed -> {
                            val kind = relaySetupFailureKind(fetch)
                            RelayKeyCatalogLine(
                                id,
                                labels[id],
                                RelayCheckState.Failed,
                                failure = kind,
                                failureText = context.getString(R.string.error_generic_message).takeIf { kind == RelaySetupFailureKind.Other },
                            )
                        }
                        RelayKeyBinding.CatalogFetch.Skipped -> RelayKeyCatalogLine(id, labels[id], RelayCheckState.Skipped)
                    }
                }
                publish(connection, RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Running, started), RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Pending), lines(), result)
                // Extra keys fetch their catalogs one by one: through the same production path as catalog refresh (catalogAPIRoot + /models), changing only the key value.
                val catalogRequested = detectedRequestedConfig(primary)
                for (keyID in keyIDs.drop(1)) {
                    val fetch = providerRepository.fetchRelayKeyCatalog(secrets.getValue(keyID), normalizedEndpoint, catalogRequested)
                    if (!customLLMCoordinator.isCurrent(attempt)) return@launch
                    fetched[keyID] = (fetch as? RelayKeyBinding.CatalogFetch.Ok)
                        ?.let { ok -> RelayKeyBinding.CatalogFetch.Ok(ok.models.map { ProviderRepository.relayCatalogRow(it.id) }) }
                        ?: fetch
                    publish(connection, RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Running, started), RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Pending), lines(), result)
                }
                val cataloged = clock()
                val rows = if (keyIDs.size >= 2) {
                    RelayKeyBinding.mergeCatalog(keyIDs, emptyList(), fetched).catalog
                } else {
                    (fetched.getValue(RelayKeyBinding.IMPLICIT_KEY_ID) as RelayKeyBinding.CatalogFetch.Ok).models
                }
                keyCatalogs = fetched.toMap()
                catalogRows = rows
                if (rows.isEmpty()) {
                    // Empty catalog: stay on step 1 and use the step 2 empty-state sentence as the failure sentence.
                    val failedLine = lines().firstOrNull { it.state == RelayCheckState.Failed }
                    publish(
                        connection,
                        RelayCheckRow(
                            RelayCheckKind.Catalog,
                            RelayCheckState.Failed,
                            started,
                            cataloged,
                            failure = failedLine?.failure ?: RelaySetupFailureKind.ModelsEmpty,
                            failureText = failedLine?.failureText,
                        ),
                        RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Skipped),
                        lines(),
                        result,
                    )
                    finishDetection(attempt, catalogAvailable = false)
                    return@launch
                }
                val catalogRow = RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Done, started, cataloged)
                publish(connection, catalogRow, RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Running, cataloged), lines(), result)
                // Third item: compute the first candidate of each model locally, with zero chat requests.
                firstCandidates = rows.associate { it.id to relayFirstCandidate(primary.supportedEndpointTypes[it.id], it.id, cachedModelFamily) }
                publish(connection, catalogRow, RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Done, cataloged, clock()), lines(), result)
                finishDetection(attempt, catalogAvailable = true)
                step = RelaySetupStep.Models
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (customLLMCoordinator.isCurrent(attempt)) {
                    publish(
                        RelayCheckRow(
                            RelayCheckKind.Connection,
                            RelayCheckState.Failed,
                            started,
                            clock(),
                            failure = RelaySetupFailureKind.Other,
                            failureText = stableRelayFailureMessage(error),
                        ),
                        RelayCheckRow(RelayCheckKind.Catalog, RelayCheckState.Skipped),
                        RelayCheckRow(RelayCheckKind.Protocols, RelayCheckState.Skipped),
                        keyIDs.map { RelayKeyCatalogLine(it, labels[it], RelayCheckState.Skipped) },
                        discoveryResult,
                    )
                    finishDetection(attempt, catalogAvailable = false)
                }
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    /** Detection only gives evidence that "you can go pick models on step 2"; the generation verification is done on the first selected model at save time. */
    private fun finishDetection(attempt: ai.oriveo.community.feature.providers.CustomLLMSetupAttempt, catalogAvailable: Boolean) {
        customLLMCoordinator.acceptEvidence(
            attempt,
            CustomLLMConnectionEvidence(
                verification = CustomLLMVerificationEvidence.ManualModelRequired,
                catalogAvailable = catalogAvailable,
            ),
        )
        customLLMCoordinator.finish(attempt)
    }

    // -- Step 2 --

    fun toggleModel(id: String) {
        selectedModelIDs = if (id in selectedModelIDs) selectedModelIDs - id else selectedModelIDs + id
        saveFailure = null
        manualAddNotice = false
    }

    /** Select all in this group: while searching it still selects the whole group (not just the matching rows). */
    fun selectGroup(groupID: String) {
        val members = catalogGroups("").firstOrNull { it.id == groupID }?.models ?: return
        selectedModelIDs = selectedModelIDs + members.map { it.id }
        saveFailure = null
        manualAddNotice = false
    }

    fun toggleGroup(groupID: String) {
        val current = modelsBoard.groups.firstOrNull { it.id == groupID }?.expanded ?: return
        groupExpansion = groupExpansion + (groupID to !current)
    }

    fun updateSearch(value: String) {
        modelSearch = value
    }

    /** Opening the "Add model ID manually" input again: the previous duplicate notice disappears. */
    fun beginManualModelEntry() {
        manualAddNotice = false
    }

    /**
     * Add a model ID manually: duplicate = equal after trim ignoring case, the same criterion as the enabling done at save (dates are not folded, no canonical form is used).
     * Already in the list: do not add, select the existing entry as written and show a one-line notice; otherwise add and select it.
     */
    fun addManualModel(raw: String): RelayManualModelAddResult {
        val id = raw.trim()
        if (!relayManualModelAddable(id)) return RelayManualModelAddResult.Ignored
        saveFailure = null
        val existing = step2Rows.firstOrNull { it.id.equals(id, ignoreCase = true) }
        if (existing != null) {
            selectedModelIDs = selectedModelIDs + existing.id
            manualAddNotice = true
            return RelayManualModelAddResult.AlreadyListed
        }
        manualModelIDs = manualModelIDs + id
        firstCandidates = firstCandidates + (id to relayFirstCandidate(null, id, cachedModelFamily))
        selectedModelIDs = selectedModelIDs + id
        manualAddNotice = false
        return RelayManualModelAddResult.Added
    }

    /**
     * Save: the first selected model in display order is verified with the existing 1-token verification (candidate protocols), using the key bound to it;
     * a failure stays on step 2 with the failure card and nothing is persisted; on success: register (primary key) -> add the remaining keys -> merge the catalogs -> enable all selected models -> write the probe result onto the first model.
     */
    fun save() {
        val ordered = orderedSelection()
        val first = ordered.firstOrNull() ?: return
        if (isSubmitting || !customLLMCoordinator.canCommit) return
        val attempt = customLLMCoordinator.beginCommit(CustomLLMConnectionMethod.Relay) ?: return
        saveFailure = null
        val result = discoveryResult
        val detected = result?.detections?.firstOrNull()
        val explicitTransport = (result?.descriptor ?: runCatching { RelayEndpointResolver.describe(endpoint, securityMode) }.getOrNull())
            ?.explicitTransport
        val keyIDs = allKeyIDs
        val bindings = RelayKeyBinding.bindInOrder(keyIDs, catalogRows, ordered, RelayKeyBinding::cachedFamily)
        val verifySecret = keySecret(bindings[first] ?: RelayKeyBinding.IMPLICIT_KEY_ID)
        val extra = activeExtraKeys.map { RelayKey(id = it.id, name = it.name.trim().takeIf(String::isNotEmpty), apiKey = it.secret.trim()) }
        val catalogIDs = catalogRows.map { it.id }
        val job = viewModelScope.launch {
            val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: run {
                customLLMCoordinator.abortCommit(attempt)
                saveFailure = context.getString(R.string.relay_setup_invalid_endpoint_message)
                return@launch
            }
            val requested = detectedRequestedConfig(detected, explicitTransport)
            val relayKind = relayKindFor(requested.transport)
            var pass: RelayModelProbePass? = null
            val verifyError: Throwable? = try {
                if (explicitTransport != null) {
                    // The connection protocol comes with the URL = chosen by the user: verify once with it only and do not write a value onto the model.
                    providerRepository.pingRelayConnection(
                        apiKey = verifySecret,
                        baseUrl = detected?.apiBaseUrl ?: normalizedEndpoint,
                        modelID = first,
                        relayRequested = requested,
                        relayKind = relayKindFor(explicitTransport),
                    )
                    null
                } else {
                    val outcome = probeModel(first, verifySecret, requested, normalizedEndpoint, detected) {
                        customLLMCoordinator.isCurrent(attempt)
                    }
                    pass = outcome.pass
                    if (outcome.pass == null) outcome.lastError ?: IllegalStateException("no protocol verified") else null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                error
            }
            if (!customLLMCoordinator.isCurrent(attempt)) return@launch
            if (verifyError != null) {
                saveFailure = if (verifyError is ProviderServiceError) {
                    stableRelayFailureMessage(verifyError)
                } else {
                    context.getString(R.string.relay_quick_no_protocol_verified)
                }
                customLLMCoordinator.abortCommit(attempt)
                return@launch
            }
            try {
                val provider = providerRepository.registerRelayProvider(
                    apiKey = apiKey.trim(),
                    baseUrl = normalizedEndpoint,
                    customName = null,
                    // The persisted type follows the connection protocol: an auto connection with no chosen protocol is stored as fully custom and is not pinned to a preset by the detected protocol.
                    relayKind = relayKind,
                    relayRequested = requested,
                    catalogModelIDs = catalogIDs,
                    preferredModelID = first,
                    preferredCapabilities = setOf(ModelCapability.Text),
                    connectionVerified = true,
                    commitGuard = { customLLMCoordinator.canPersist(attempt) },
                    preferredModelProbe = pass,
                    extraKeys = extra,
                    primaryKeyName = primaryKeyName.trim().takeIf { it.isNotEmpty() && extra.isNotEmpty() },
                    keyCatalogs = keyCatalogs,
                    enabledModelIDs = ordered,
                )
                if (!customLLMCoordinator.canPersist(attempt)) return@launch
                if (!customLLMCoordinator.finishCommit(attempt)) return@launch
                registeredProvider = provider
                // Adding a connection only records a verified model as last used: here, the first model just verified.
                backgroundScope.launch { runCatching { rememberLastUsedModel(provider.id, first) } }
                completionTarget = RelaySetupCompletionTarget.ProviderDetail(
                    provider.id,
                    // The notice reports the actual enabled count, by the same criterion as persisting (deduplicated after trim, ignoring case).
                    addedModelCount = ordered.distinctBy { it.trim().lowercase() }.size,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (cause: Exception) {
                if (customLLMCoordinator.isCurrent(attempt)) {
                    // Quick mode must also make a save failure visible.
                    saveFailure = stableRelayFailureMessage(cause)
                    customLLMCoordinator.abortCommit(attempt)
                }
            }
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    /** Probe one model by its candidates: the candidates are the endpoint types brought back by detection, falling back to a family lookup when there are none. */
    private suspend fun probeModel(
        modelID: String,
        secret: String,
        requested: RelayRequestedConfig,
        normalizedEndpoint: String,
        detected: RelayDetectedConfiguration?,
        isCurrent: () -> Boolean,
    ): RelayModelProbeOutcome {
        // A protocol discovered only through the generation route (with no catalog) is added to the candidates and put first.
        val candidates = RelayProbeCandidates.withGenerationRoute(
            route = detected?.takeIf { it.detectionEvidence == RelayDetectionEvidence.GenerationProbe }?.transport,
            supportedEndpointTypes = detected?.supportedEndpointTypes?.get(modelID),
            modelID = modelID,
            family = modelFamily,
        )
        return RelayModelProbe.probe(
            provider = Provider(
                id = "",
                kind = ProviderKind.Relay,
                baseUrlText = normalizedEndpoint,
                relayRequested = requested,
            ),
            modelID = modelID,
            candidates = candidates,
        ) { candidate, _ ->
            if (!isCurrent()) throw CancellationException("stale relay setup save")
            providerRepository.pingRelayConnection(
                apiKey = secret,
                baseUrl = normalizedEndpoint,
                modelID = modelID,
                relayRequested = requested,
                relayKind = relayKindFor(detected?.transport ?: RelayTransport.OpenAIChatCompletions),
                modelTransport = candidate,
            )
        }
    }

    /**
     * The connection configuration persisted by quick setup. The connection default transport honors only what the user chose (the protocol that comes with the URL); with no choice it is `auto`,
     * and the detected protocol is written onto the model only. Authentication works the same way: when a protocol is chosen, the value detection resolved for that protocol is used,
     * and with `auto` the draft's authentication mode is kept so that each model takes the default authentication for its own protocol.
     * The discovery root is written as the single-value root only when the discovered protocol equals the effective connection default (auto means chat); otherwise it is recorded only in
     * resolvedAPIBaseURLs[discovered protocol], so that models following the connection do not get the root of another protocol.
     * When connectivity failed and there is no detection result, only the protocol the user chose is carried, and the root address is completed from the connection address.
     */
    private fun detectedRequestedConfig(
        detection: RelayDetectedConfiguration?,
        chosen: RelayTransport? = discoveryResult?.descriptor?.explicitTransport,
    ): RelayRequestedConfig {
        val connectionDefault = chosen ?: RelayTransport.OpenAIChatCompletions
        val rootIsConnectionDefault = detection?.transport == connectionDefault
        return RelayRequestedConfig(
            transport = chosen ?: RelayTransport.Auto,
            authMode = if (chosen != null && detection != null) detection.authMode else draftAuthMode,
            securityMode = securityMode,
            modelID = null,
            stream = true,
            // Any model on an auto connection may go through Responses, so keep the default of not storing, as when detection found Responses.
            disableResponseStorage = true.takeIf { chosen == null || chosen == RelayTransport.OpenAIResponses },
            codexCompatIdentity = true.takeIf { chosen == RelayTransport.OpenAIResponses },
            resolvedAPIBaseURL = detection?.apiBaseUrl?.takeIf { rootIsConnectionDefault },
            resolvedAPIBaseURLs = detection?.let { mapOf(it.transport.value to it.apiBaseUrl) }?.takeUnless { rootIsConnectionDefault },
        )
    }

    private fun relayKindFor(transport: RelayTransport): RelayKind = when (transport) {
        RelayTransport.OpenAIChatCompletions -> RelayKind.OpenAICompatible
        RelayTransport.Auto -> RelayKind.Custom
        RelayTransport.LlamaCppNative -> RelayKind.OpenAICompatible
        RelayTransport.OpenAIResponses -> RelayKind.CodexStyle
        RelayTransport.AnthropicMessages -> RelayKind.AnthropicCompatible
        RelayTransport.GeminiGenerateContent -> RelayKind.GeminiCompatible
    }

    private fun localizedDiscoveryFailure(failure: RelayDiscoveryFailureKind?): String = when (failure) {
        RelayDiscoveryFailureKind.EmbeddedQuery -> context.getString(R.string.relay_quick_embedded_query)
        RelayDiscoveryFailureKind.AuthenticationRejected -> context.getString(R.string.relay_quick_auth_rejected)
        RelayDiscoveryFailureKind.RateLimited -> context.getString(R.string.relay_quick_rate_limited)
        RelayDiscoveryFailureKind.TemporaryFailure -> context.getString(R.string.relay_quick_temporary_failure)
        RelayDiscoveryFailureKind.Network -> context.getString(R.string.relay_quick_network_failure)
        RelayDiscoveryFailureKind.InvalidEndpoint -> context.getString(R.string.relay_setup_invalid_endpoint_message)
        else -> context.getString(R.string.relay_quick_route_unavailable)
    }

    private fun stableRelayFailureMessage(error: Throwable): String = when (error) {
        is ProviderServiceError -> ErrorMapper.localizeProviderErrorMessage(error, context)
        else -> context.getString(R.string.error_generic_message)
    }

    /** Changing the address / any key / cancelling detection / entering manual setup: invalidate this round (generation) and clear the detection card and the step 2 state together. */
    private fun clearDiscovery(cancelRunning: Boolean = true) {

        if (cancelRunning) customLLMCoordinator.invalidate()
        discoveryResult = null
        detection = null
        keyCatalogs = emptyMap()
        catalogRows = emptyList()
        manualModelIDs = emptyList()
        firstCandidates = emptyMap()
        selectedModelIDs = emptySet()
        modelSearch = ""
        groupExpansion = emptyMap()
        saveFailure = null
        manualAddNotice = false
        keyInputIssue = null
        step = RelaySetupStep.Address
        // Once the address / a key changes, the manual setup failure card and any in-flight result are invalidated together (the coordinator has moved to a new generation).
        manualFailure = null
        manualFailureSnapshot = null
        manualAttempt = null
    }

    // -- Manual setup --

    private fun manualSnapshot(): RelayManualSnapshot = RelayManualSnapshot(
        endpoint = endpoint,
        secrets = listOf(RelayKeyBinding.IMPLICIT_KEY_ID to apiKey.trim()) + activeExtraKeys.map { it.id to it.secret.trim() },
        model = defaultModel.trim(),
        transport = manualTransport,
        authMode = manualAuthMode,
        userAgent = manualUserAgent.trim(),
        headers = manualHeaders.cleanRelayAdvancedPairs().orEmpty(),
        queryParams = manualQueryParams.cleanRelayAdvancedPairs().orEmpty(),
    )

    /** The manual setup input changed: dismiss the failure card, invalidate any in-flight result and restore the primary button immediately. */
    private fun retireManualAttempt() {
        manualFailure = null
        manualFailureSnapshot = null
        val attempt = manualAttempt ?: return
        manualAttempt = null
        if (customLLMCoordinator.isCurrent(attempt)) customLLMCoordinator.invalidate()
    }

    /**
     * The primary button "Verify and save / Re-verify": with a chosen protocol (or a protocol that comes with the address) it sends one 1-token request for the entered model using the primary key only, with no probing;
     * with automatic it probes by the vendor family candidates (at most 2) and the passing protocol is written onto that model. On success it persists first and then refreshes the catalog without blocking; on failure nothing is persisted and the failure card is shown.
     * The result is committed only if this attempt is still the current one and the input at launch equals the current input.
     */
    fun validateManual() {
        if (mode != RelaySetupMode.Manual || !manualBoard.primary.enabled) return
        // Input without a scheme is normalized before verification and written back to the input field; writing back does not count as changing the input.
        val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: return
        manualFailure = null
        manualFailureSnapshot = null
        val attempt = customLLMCoordinator.begin(CustomLLMConnectionMethod.Relay, CustomLLMSetupPhase.Testing)
        manualAttempt = attempt
        val snapshot = manualSnapshot()
        val model = snapshot.model
        val transport = RelayManualSetupBoardModel.effectiveTransport(manualTransport, normalizedEndpoint)
        val requested = RelayManualSetupBoardModel.requested(transport, manualAuthMode, manualUserAgent, manualHeaders, manualQueryParams)
        val relayKind = RelayKindDefaults.inferKind(requested)
        val primarySecret = apiKey.trim()
        fun stillCurrent(): Boolean = customLLMCoordinator.isCurrent(attempt) && snapshot == manualSnapshot()
        val job = viewModelScope.launch {
            var pass: RelayModelProbePass? = null
            val verifyError: Throwable? = try {
                if (transport != RelayTransport.Auto) {
                    providerRepository.pingRelayConnection(
                        apiKey = primarySecret,
                        baseUrl = normalizedEndpoint,
                        modelID = model,
                        relayRequested = requested,
                        relayKind = relayKind,
                    )
                    null
                } else {
                    val outcome = RelayModelProbe.probe(
                        provider = Provider(id = "", kind = ProviderKind.Relay, baseUrlText = normalizedEndpoint, relayRequested = requested),
                        modelID = model,
                        candidates = RelayProbeCandidates.candidates(null, model, modelFamily),
                    ) { candidate, _ ->
                        if (!stillCurrent()) throw CancellationException("stale relay manual setup")
                        providerRepository.pingRelayConnection(
                            apiKey = primarySecret,
                            baseUrl = normalizedEndpoint,
                            modelID = model,
                            relayRequested = requested,
                            relayKind = relayKind,
                            modelTransport = candidate,
                        )
                    }
                    pass = outcome.pass
                    if (outcome.pass == null) outcome.lastError ?: IllegalStateException("no protocol verified") else null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                error
            }
            if (!stillCurrent()) return@launch
            if (verifyError != null) {
                manualFailure = RelayManualFailure(
                    message = manualFailureMessage(verifyError),
                    presentation = RelayEditFailurePresenter.present(
                        manualCandidate(normalizedEndpoint, primarySecret, requested),
                        verifyError,
                    ),
                    error = (verifyError as? Exception)?.let { ErrorMapper.map(it, context) },
                )
                manualFailureSnapshot = snapshot
                customLLMCoordinator.acceptFailure(attempt)
                return@launch
            }
            customLLMCoordinator.acceptEvidence(
                attempt,
                CustomLLMConnectionEvidence(CustomLLMVerificationEvidence.GenerationVerified, catalogAvailable = false),
            )
            persistManual(normalizedEndpoint, primarySecret, model, requested, relayKind, pass, unverifiedReason = null)
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    /**
     * "Save anyway (unverified)" on the failure card: the only exit for persisting unverified. It sends no further request; the status is written with the same stable key as the unverified save of edit connection
     * ([ProviderRepository.RELAY_UNVERIFIED_MESSAGE]) and the raw error text is not stored. If the input was changed after the failure (the snapshot differs) it is not accepted.
     */
    fun saveManualUnverified() {
        val failure = manualFailure ?: return
        if (failure.persistFailed) return
        if (mode != RelaySetupMode.Manual || manualCompleted || isValidatingManual) return
        if (manualFailureSnapshot != manualSnapshot()) return
        val normalizedEndpoint = requestSafeRelayEndpoint(endpoint) ?: return
        val attempt = customLLMCoordinator.begin(CustomLLMConnectionMethod.Relay, CustomLLMSetupPhase.Testing)
        manualAttempt = attempt
        customLLMCoordinator.acceptEvidence(
            attempt,
            CustomLLMConnectionEvidence(CustomLLMVerificationEvidence.UnverifiedManual, catalogAvailable = false),
        )
        val transport = RelayManualSetupBoardModel.effectiveTransport(manualTransport, normalizedEndpoint)
        val requested = RelayManualSetupBoardModel.requested(transport, manualAuthMode, manualUserAgent, manualHeaders, manualQueryParams)
        val job = viewModelScope.launch {
            persistManual(
                normalizedEndpoint,
                apiKey.trim(),
                defaultModel.trim(),
                requested,
                RelayKindDefaults.inferKind(requested),
                pass = null,
                unverifiedReason = failure.message,
            )
        }
        customLLMCoordinator.registerCancellation(attempt, job)
    }

    /**
     * The persisted shape is the same as quick setup's "add manually after a connectivity failure": every key with a value is attached together with its name, and a single key is not stored as a multi-key list;
     * no detection was run, so "which key listed which model" and the per-key states are not written; relayKind is derived from the protocol; the persisted connection-level modelID is empty.
     */
    private suspend fun persistManual(
        normalizedEndpoint: String,
        primarySecret: String,
        model: String,
        requested: RelayRequestedConfig,
        relayKind: RelayKind,
        pass: RelayModelProbePass?,
        unverifiedReason: String?,
    ) {
        val verified = unverifiedReason == null
        val commit = customLLMCoordinator.beginCommit(CustomLLMConnectionMethod.Relay) ?: return
        val extra = activeExtraKeys.map { RelayKey(id = it.id, name = it.name.trim().takeIf(String::isNotEmpty), apiKey = it.secret.trim()) }
        try {
            val provider = providerRepository.registerRelayProvider(
                apiKey = primarySecret,
                baseUrl = normalizedEndpoint,
                customName = name.trim().takeIf { it.isNotEmpty() },
                relayKind = relayKind,
                relayRequested = requested,
                catalogModelIDs = emptyList(),
                preferredModelID = model,
                preferredCapabilities = setOf(ModelCapability.Text),
                connectionVerified = verified,
                commitGuard = { customLLMCoordinator.canPersist(commit) },
                preferredModelProbe = pass,
                extraKeys = extra,
                primaryKeyName = primaryKeyName.trim().takeIf { it.isNotEmpty() && extra.isNotEmpty() },
                keyCatalogs = emptyMap(),
                enabledModelIDs = listOf(model),
            )
            if (!customLLMCoordinator.canPersist(commit)) return
            if (!customLLMCoordinator.finishCommit(commit)) return
            manualCompleted = true
            registeredProvider = provider
            completionTarget = RelaySetupCompletionTarget.ProviderDetail(
                providerId = provider.id,
                addedModelCount = 1.takeIf { verified },
                unverifiedReason = unverifiedReason,
            )
            if (verified) {
                // Persist first, then refresh the catalog without blocking; a catalog failure does not roll back (the detail page's catalog failure state accounts for it).
                backgroundScope.launch {
                    runCatching { rememberLastUsedModel(provider.id, model) }
                    try {
                        providerRepository.refreshRelayCatalogOnly(provider.id)
                    } catch (error: CancellationException) {
                        throw error
                    } catch (_: Exception) {
                    }
                }
            } else {
            }
        } catch (error: CancellationException) {
            throw error
        } catch (cause: Exception) {
            if (customLLMCoordinator.isCurrent(commit)) {
                // Persist error: the technical details are built and redacted the same way as the verification failure card, with the raw exception text added; "Save anyway" is not offered.
                manualFailure = RelayManualFailure(
                    message = stableRelayFailureMessage(cause),
                    presentation = RelayEditFailurePresenter.presentLocalFailure(
                        manualCandidate(normalizedEndpoint, primarySecret, requested),
                        cause,
                    ),
                    persistFailed = true,
                    error = ErrorMapper.map(cause, context),
                )
                manualFailureSnapshot = manualSnapshot()
                customLLMCoordinator.abortCommit(commit)
            }
        }
    }

    /** The candidate connection used to redact the failure card: all keys, headers / query parameters and the UA are on the list. */
    private fun manualCandidate(normalizedEndpoint: String, primarySecret: String, requested: RelayRequestedConfig): Provider {
        val extra = activeExtraKeys.map { RelayKey(id = it.id, apiKey = it.secret.trim()) }
        return Provider(
            id = "",
            kind = ProviderKind.Relay,
            baseUrlText = normalizedEndpoint,
            apiKey = primarySecret,
            relayKeys = if (extra.isEmpty()) null else listOf(RelayKey(RelayKeyBinding.IMPLICIT_KEY_ID, apiKey = primarySecret)) + extra,
            relayRequested = requested,
        )
    }

    private fun manualFailureMessage(error: Throwable): String = when (error) {
        is ProviderServiceError -> ErrorMapper.localizeProviderErrorMessage(error, context)
        else -> context.getString(R.string.relay_quick_no_protocol_verified)
    }
}
