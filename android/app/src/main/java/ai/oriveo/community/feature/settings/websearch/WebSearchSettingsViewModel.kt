package ai.oriveo.community.feature.settings.websearch

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.FeatureBadges
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import ai.oriveo.community.core.provider.transport.EndpointResolver
import ai.oriveo.community.core.search.CustomSearchServiceForm
import ai.oriveo.community.core.search.SavedSearchService
import ai.oriveo.community.core.search.SearchAddSheet
import ai.oriveo.community.core.search.SearchCatalog
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchConnectionRef
import ai.oriveo.community.core.search.SearchCustomEditPlan
import ai.oriveo.community.core.search.SearchCustomEditSide
import ai.oriveo.community.core.search.SearchCustomService
import ai.oriveo.community.core.search.SearchExecution
import ai.oriveo.community.core.search.SearchExecutor
import ai.oriveo.community.core.search.SearchFormFieldErrors
import ai.oriveo.community.core.search.SearchJson
import ai.oriveo.community.core.search.SearchRowServiceInput
import ai.oriveo.community.core.search.SearchRowState
import ai.oriveo.community.core.search.SearchServiceRef
import ai.oriveo.community.core.search.SearchServiceStore
import ai.oriveo.community.core.search.SearchSettings
import ai.oriveo.community.core.search.SearchTestOutcome
import ai.oriveo.community.core.search.SearchTestPresentation
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** One saved service as the list and detail pages render it. */
data class WebSearchServiceItem(
    val saved: SavedSearchService,
    val displayName: String,
    val rowState: SearchRowState,
    val isDefault: Boolean,
    val hasKey: Boolean,
    val keyTail: String?,
    /** Catalog entry of a preset (null for custom, withdrawn, or catalog unavailable). */
    val entry: JsonObject?,
)

data class WebSearchUiState(
    val loaded: Boolean = false,
    val catalogAvailable: Boolean = false,
    val services: List<WebSearchServiceItem> = emptyList(),
    val addSheet: SearchAddSheet = SearchAddSheet("unavailable", emptyList()),
    val connections: List<SearchConnectionRef> = emptyList(),
    /** Active catalog entries by serviceId (catalog order). */
    val entries: Map<String, JsonObject> = emptyMap(),
)

/** A test search in flight or finished (memory only, never persisted). */
sealed interface WebSearchTestState {
    data object Idle : WebSearchTestState
    data object Testing : WebSearchTestState
    data class Done(val presentation: SearchTestPresentation, val becameDefault: Boolean = false) : WebSearchTestState
}

/** Preset connect / re-key draft. [editingId] != null = change the key of a saved service. */
data class PresetDraft(
    val serviceId: String,
    val regionId: String?,
    val connectionRef: String?,
    val connectionName: String?,
    val editingId: String? = null,
)

/** Custom service form draft. Field names follow [SearchSettings.customFormFieldErrors]. */
data class CustomDraft(
    val name: String = "",
    val address: String = "",
    val key: String = "",
    val protocol: String = "searxng",
    val sameAsId: String? = null,
    val method: String = "GET",
    val auth: String = "bearer",
    val headerName: String = "",
    val queryField: String = "q",
    val countField: String = "",
    val params: List<Pair<String, String>> = emptyList(),
    val resultsPath: String = "",
    val titlePath: String = "",
    val urlPath: String = "",
    val snippetPath: String = "",
    val sitePath: String = "",
    val datePath: String = "",
    val editingId: String? = null,
)

/**
 * Settings › Web search: saved services, add flow (preset / reuse / custom), consent + test-before-save, and detail edits.
 * Every presentation decision comes from [SearchSettings]; this class only gathers inputs and persists results.
 */
class WebSearchSettingsViewModel(
    private val store: SearchServiceStore,
    private val catalog: SearchCatalogRepository,
    private val executor: SearchExecutor,
    private val providerRepository: ProviderRepository,
    private val preferences: AppPreferencesRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(WebSearchUiState())
    val state: StateFlow<WebSearchUiState> = _state.asStateFlow()

    private val _test = MutableStateFlow<WebSearchTestState>(WebSearchTestState.Idle)
    /** Consent / save test of the current add or edit flow. */
    val test: StateFlow<WebSearchTestState> = _test.asStateFlow()

    private val _detailTests = MutableStateFlow<Map<String, WebSearchTestState>>(emptyMap())
    /** Detail-page test results by service id (memory only). */
    val detailTests: StateFlow<Map<String, WebSearchTestState>> = _detailTests.asStateFlow()

    private val _formErrors = MutableStateFlow(SearchFormFieldErrors(emptyMap(), emptyMap(), false))
    val formErrors: StateFlow<SearchFormFieldErrors> = _formErrors.asStateFlow()

    /** Background dispatcher for store / catalog / DNS work; tests swap in their test dispatcher right after construction. */
    internal var io: CoroutineDispatcher = Dispatchers.IO

    /** Debug sample screens only: fixed connections instead of the provider repository (no key is read). */
    internal var connectionsOverride: List<SearchConnectionRef>? = null

    private var providers: List<Provider> = emptyList()
    private val accountId: String get() = LOCAL_PARTITION_ID

    init {
        viewModelScope.launch {
            withContext(io) { if (catalog.current() == null) catalog.loadLocal() }
            reload()
            withContext(io) { runCatching { catalog.refresh() } }
            reload()
        }
        viewModelScope.launch {
            providerRepository.observeAll().collect {
                providers = it
                reload()
            }
        }
    }

    /** Debug sample screens only: show an already finished test (no search is sent). */
    internal fun presetTestState(state: WebSearchTestState, detailId: String? = null) {
        if (detailId != null) _detailTests.update { it + (detailId to state) } else _test.value = state
    }

    fun markBadgeSeen() {
        viewModelScope.launch { preferences.markFeatureBadgeSeen(FeatureBadges.SETTINGS_WEB_SEARCH) }
    }

    /** Rebuilds the whole state from store + catalog + connections. */
    fun reload() {
        viewModelScope.launch {
            val next = withContext(io) { buildState() }
            _state.value = next
        }
    }

    private fun buildState(): WebSearchUiState {
        val connections = connectionsOverride ?: webSearchConnections(providers)
        val services = webSearchServiceItems(store, catalog, accountId, connections)
        val saved = store.services(accountId)
        val sheet = SearchSettings.searchAddSheetSections(
            catalogAvailable = services.catalogAvailable,
            entries = services.entries.values.toList(),
            connections = connections,
            services = saved.map { SearchServiceRef(it.id, it.kind, it.serviceId) },
        )
        return WebSearchUiState(true, services.catalogAvailable, services.items, sheet, connections, services.entries)
    }
    fun resetFlow() {
        _test.value = WebSearchTestState.Idle
        _formErrors.value = SearchFormFieldErrors(emptyMap(), emptyMap(), false)
    }

    fun clearFieldError(field: String) {
        _formErrors.update { e ->
            if (field !in e.fields && field !in e.warnings) e else e.copy(fields = e.fields - field, warnings = e.warnings - field)
        }
    }

    // ── Preset connect / re-key ──────────────────────────────

    /**
     * Agree and test: the key (connection or pasted) is tested against the chosen site; only a passed test saves.
     * Pasted keys go through normalizeSearchKey first; its error lands on the `key` field.
     */
    fun testAndSavePreset(draft: PresetDraft, useConnection: Boolean, pastedKey: String, regionId: String?, query: String) {
        val entry = _state.value.entries[draft.serviceId] ?: return
        val reuseMode = useConnection && draft.connectionRef != null
        // Reuse: the site is fixed by the connection address; paste: the picked site, defaulting to the catalog's first.
        val region = if (reuseMode) {
            draft.regionId
        } else {
            regionId ?: SearchJson.array(entry["regions"])?.firstOrNull()?.let { SearchJson.string((it as? JsonObject)?.get("id")) }
        }
        val key: String?
        if (reuseMode) {
            key = providers.firstOrNull { it.id == draft.connectionRef }?.let { ProviderCredentialResolver.apiKey(it, null) }
        } else {
            val normalized = SearchCustomService.normalizeSearchKey(pastedKey)
            if (!normalized.ok) {
                _formErrors.value = SearchSettings.customFormFieldErrors(listOfNotNull(normalized.error), emptyList())
                return
            }
            key = normalized.key
        }
        val host = SearchCatalog.presetTarget(entry, region)?.host ?: return
        _formErrors.value = SearchFormFieldErrors(emptyMap(), emptyMap(), false)
        _test.value = WebSearchTestState.Testing
        viewModelScope.launch {
            val outcome = runTest {
                executor.executePreset(entry, region ?: "", host, withdrawn = false, key = key, query = query, count = SearchSettings.RESULT_COUNT_DEFAULT)
            }
            val presentation = SearchSettings.searchTestPresentation(outcome)
            if (presentation !is SearchTestPresentation.Passed) {
                _test.value = WebSearchTestState.Done(presentation)
                return@launch
            }
            val reuse = useConnection && draft.connectionRef != null
            val becameDefault = withContext(io) {
                val existing = draft.editingId?.let { store.service(accountId, it) }
                val service = (existing ?: SavedSearchService(id = UUID.randomUUID().toString(), kind = SavedSearchService.KIND_PRESET))
                    .copy(
                        serviceId = draft.serviceId,
                        regionId = region,
                        boundHost = host,
                        keySource = if (reuse) SavedSearchService.KEY_SOURCE_CONNECTION else SavedSearchService.KEY_SOURCE_OWN,
                        connectionRef = if (reuse) draft.connectionRef else null,
                        name = SearchJson.string(entry["displayName"]),
                    )
                store.save(accountId, service)
                if (!reuse) store.setKey(accountId, service.id, key)
                existing == null && store.defaultServiceId(accountId) == service.id
            }
            _test.value = WebSearchTestState.Done(presentation, becameDefault)
            reload()
        }
    }

    /** Host changed: the user confirms the new catalog host; the key stays. */
    fun reconfirmHost(id: String) {
        val item = _state.value.services.firstOrNull { it.saved.id == id } ?: return
        val entry = item.entry ?: return
        val host = SearchCatalog.presetTarget(entry, item.saved.regionId)?.host ?: return
        viewModelScope.launch {
            withContext(io) { store.rebindPresetHost(accountId, id, host) }
            reload()
        }
    }

    // ── Custom ───────────────────────────────────────────────

    /** Re-key draft of a preset (same as the detail page's "Update key"); null for custom or a missing service. */
    fun rekeyDraftOf(id: String): PresetDraft? {
        val s = _state.value.services.firstOrNull { it.saved.id == id }?.saved
            ?.takeIf { it.kind != SavedSearchService.KIND_CUSTOM } ?: return null
        val row = _state.value.addSheet.sections.flatMap { it.rows }.firstOrNull { it.serviceId == s.serviceId }
        return PresetDraft(s.serviceId.orEmpty(), s.regionId, row?.connectionRef, row?.connectionName, editingId = id)
    }

    fun customDraftOf(id: String): CustomDraft? {
        val s = store.service(accountId, id)?.takeIf { it.kind == SavedSearchService.KIND_CUSTOM } ?: return null
        val m = s.mapping
        fun path(k: String) = SearchJson.array(SearchJson.obj(m?.get("response"))?.get(k))?.firstOrNull()?.let(SearchJson::string).orEmpty()
        val manual = s.protocol == "manual" && m != null
        return CustomDraft(
            name = s.name.orEmpty(),
            address = s.address.orEmpty(),
            protocol = s.protocol ?: "searxng",
            sameAsId = if (s.protocol == "same_as") SearchJson.string(SearchJson.obj(m?.get("snapshotOf"))?.get("serviceId")) else null,
            method = if (manual) SearchJson.string(m!!["method"]) ?: "GET" else "GET",
            auth = if (manual) SearchJson.string(SearchJson.obj(m!!["auth"])?.get("kind")) ?: "bearer" else "bearer",
            headerName = if (manual) SearchJson.string(SearchJson.obj(m!!["auth"])?.get("name")).orEmpty() else "",
            queryField = if (manual) SearchJson.string(SearchJson.obj(m!!["query"])?.get("field")).orEmpty() else "q",
            countField = if (manual) SearchJson.string(SearchJson.obj(m!!["count"])?.get("field")).orEmpty() else "",
            params = if (manual) {
                SearchJson.obj(SearchJson.obj(m!!["static"])?.get("params"))?.map { (k, v) -> k to ((v as? JsonPrimitive)?.content ?: "") }.orEmpty()
            } else {
                emptyList()
            },
            resultsPath = if (manual) SearchJson.string(SearchJson.obj(m!!["response"])?.get("results")).orEmpty() else "",
            titlePath = if (manual) path("title") else "",
            urlPath = if (manual) path("url") else "",
            snippetPath = if (manual) path("snippet") else "",
            sitePath = if (manual) path("site") else "",
            datePath = if (manual) path("date") else "",
            editingId = id,
        )
    }

    private fun manualMapping(d: CustomDraft): JsonObject {
        val where = if (d.method == "GET") "query" else "body"
        return buildJsonObject {
            put("method", d.method)
            putJsonObject("auth") {
                put("kind", d.auth)
                if (d.auth == "header") put("name", d.headerName.trim())
            }
            putJsonObject("query") {
                put("field", d.queryField.trim())
                put("in", where)
            }
            if (d.countField.isNotBlank()) {
                putJsonObject("count") {
                    put("field", d.countField.trim())
                    put("in", where)
                }
            }
            if (d.params.isNotEmpty()) {
                putJsonObject("static") {
                    put("in", where)
                    putJsonObject("params") { d.params.forEach { (k, v) -> put(k.trim(), v) } }
                }
            }
            putJsonObject("response") {
                put("results", d.resultsPath.trim())
                for ((k, v) in listOf("title" to d.titlePath, "url" to d.urlPath, "snippet" to d.snippetPath)) {
                    put(k, JsonArray(listOf(JsonPrimitive(v.trim()))))
                }
                for ((k, v) in listOf("site" to d.sitePath, "date" to d.datePath)) {
                    if (v.isNotBlank()) put(k, JsonArray(listOf(JsonPrimitive(v.trim()))))
                }
            }
        }
    }

    private fun mappingOf(d: CustomDraft): JsonObject? = when (d.protocol) {
        "manual" -> manualMapping(d)
        "same_as" -> {
            // Keep the saved snapshot while the user stays on the same preset; a new pick snapshots the current catalog.
            val saved = d.editingId?.let { store.service(accountId, it) }?.takeIf { it.protocol == "same_as" }?.mapping
            val savedOf = SearchJson.string(SearchJson.obj(saved?.get("snapshotOf"))?.get("serviceId"))
            if (saved != null && savedOf == d.sameAsId) {
                saved
            } else {
                d.sameAsId?.let { id -> _state.value.entries[id]?.let { SearchCustomService.snapshotPresetMapping(it, null) } }
            }
        }
        else -> null
    }

    /** Address class from the existing LAN policy (DNS resolved): lan | public | unresolved. */
    private fun addressClass(address: String): String? {
        val parsed = SearchCustomService.parseServiceAddress(address) ?: return null
        val host = if (parsed.host.contains(':') && !parsed.host.startsWith("[")) "[${parsed.host}]" else parsed.host
        val origin = "http://$host${parsed.port?.let { ":$it" }.orEmpty()}"
        val ips = RelayEndpointPolicy.resolveHostIPs(origin)
        if (ips.isEmpty()) return "unresolved"
        return if (RelayEndpointPolicy.classify(origin, RelayConnectionSecurityMode.LocalHttp, ips).allowed) "lan" else "public"
    }

    /** Continue / save: validate (address class resolved on IO) and the optional key; true = no blocking errors. */
    fun validateCustom(d: CustomDraft, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            val cls = withContext(io) { addressClass(d.address.trim()) }
            // Editing a same_as service whose reference did not change reuses the saved snapshot: the preset need not be available.
            val keepsSnapshot = d.protocol == "same_as" && withContext(io) { editPlan(d) }?.requirePreset == false
            val sameAsActive = keepsSnapshot || d.sameAsId?.let { _state.value.entries.containsKey(it) } == true
            val v = SearchCustomService.validateCustomSearchService(
                CustomSearchServiceForm(
                    name = d.name,
                    address = d.address.trim(),
                    protocol = d.protocol,
                    platform = "android",
                    addressClass = cls,
                    presetId = d.sameAsId,
                    catalogAvailable = keepsSnapshot || _state.value.catalogAvailable,
                    presetActive = sameAsActive,
                    manual = if (d.protocol == "manual") manualMapping(d) else null,
                ),
            )
            val keyError = if (d.key.isNotBlank()) SearchCustomService.normalizeSearchKey(d.key).error else null
            val errors = SearchSettings.customFormFieldErrors(v.errors + listOfNotNull(keyError), v.warnings)
            _formErrors.value = errors
            onResult(!errors.blocking)
        }
    }

    private fun sideOf(s: SavedSearchService): SearchCustomEditSide {
        val of = SearchJson.obj(s.mapping?.get("snapshotOf"))
        val sameAs = s.protocol == "same_as"
        return SearchCustomEditSide(
            name = s.name,
            address = s.address,
            protocol = s.protocol,
            mapping = s.mapping,
            presetId = if (sameAs) SearchJson.string(of?.get("serviceId")) else null,
            regionId = if (sameAs) SearchJson.string(of?.get("region")) else null,
        )
    }

    /** Edit plan of the draft against the saved service; null when not editing. */
    fun editPlan(d: CustomDraft): SearchCustomEditPlan? {
        val s = d.editingId?.let { store.service(accountId, it) } ?: return null
        val before = sideOf(s)
        val after = SearchCustomEditSide(
            name = d.name,
            address = d.address,
            protocol = d.protocol,
            mapping = if (d.protocol == "manual") manualMapping(d) else null,
            presetId = if (d.protocol == "same_as") d.sameAsId else null,
            // Same reference keeps the saved snapshot's site; a new reference snapshots the first site.
            regionId = if (d.protocol == "same_as" && d.sameAsId == before.presetId && before.protocol == "same_as") before.regionId else null,
        )
        return SearchSettings.customServiceEditPlan(before, after)
    }

    /** Only the name changed (edit mode) and no new key: saved directly, no test. */
    fun onlyNameChanged(d: CustomDraft): Boolean = editPlan(d)?.mode == "save" && d.key.isBlank()

    fun saveCustomName(d: CustomDraft) {
        val id = d.editingId ?: return
        viewModelScope.launch {
            withContext(io) {
                store.service(accountId, id)?.let { store.save(accountId, it.copy(name = SearchJson.jsTrim(d.name))) }
            }
            reload()
        }
    }

    /** Consent agree (add) or save (edit): one test search, then save only when it passed. */
    fun testAndSaveCustom(d: CustomDraft, query: String) {
        val address = d.address.trim()
        val mapping = mappingOf(d)
        val existing = d.editingId?.let { store.service(accountId, it) }
        // Edit without a new key keeps the saved one unless the address origin changed (the store clears it then).
        val key = d.key.takeIf { it.isNotBlank() }?.let { SearchCustomService.normalizeSearchKey(it).key }
            ?: existing?.takeIf { !SearchCustomService.addressChangeClearsKey(it.address, address) }?.let { store.key(accountId, it.id) }
        _test.value = WebSearchTestState.Testing
        viewModelScope.launch {
            val outcome = runTest {
                executor.executeCustom(d.protocol, address, mapping, key, query, SearchSettings.RESULT_COUNT_DEFAULT)
            }
            val presentation = SearchSettings.searchTestPresentation(outcome)
            if (presentation !is SearchTestPresentation.Passed) {
                _test.value = WebSearchTestState.Done(presentation)
                return@launch
            }
            val becameDefault = withContext(io) {
                val service = (existing ?: SavedSearchService(id = UUID.randomUUID().toString(), kind = SavedSearchService.KIND_CUSTOM))
                    .copy(
                        name = SearchJson.jsTrim(d.name),
                        address = address,
                        protocol = d.protocol,
                        mapping = mapping,
                        keySource = SavedSearchService.KEY_SOURCE_OWN,
                    )
                store.save(accountId, service)
                if (d.key.isNotBlank()) store.setKey(accountId, service.id, d.key)
                existing == null && store.defaultServiceId(accountId) == service.id
            }
            _test.value = WebSearchTestState.Done(presentation, becameDefault)
            reload()
        }
    }

    // ── Detail ───────────────────────────────────────────────

    fun setDefault(id: String) {
        viewModelScope.launch {
            withContext(io) { store.setDefaultServiceId(accountId, id) }
            reload()
        }
    }

    fun setResultCount(id: String, count: Int) {
        if (count !in SearchSettings.RESULT_COUNT_CHOICES) return
        viewModelScope.launch {
            withContext(io) {
                store.service(accountId, id)?.let { store.save(accountId, it.copy(resultCount = count)) }
            }
            reload()
        }
    }

    /** Name of the service that becomes default if [id] is deleted (null = no change / list becomes empty). */
    fun defaultAfterDelete(id: String): String? {
        val items = _state.value.services
        if (items.firstOrNull { it.saved.id == id }?.isDefault != true) return null
        val remaining = items.filter { it.saved.id != id }
        val next = SearchSettings.resolveDefaultSearchService(remaining.map { it.saved.id }, null) ?: return null
        return remaining.firstOrNull { it.saved.id == next }?.displayName
    }

    fun delete(id: String) {
        viewModelScope.launch {
            withContext(io) { store.remove(accountId, id) }
            _detailTests.update { it - id }
            reload()
        }
    }

    /** Detail-page test with the saved configuration; nothing is written. */
    fun testSaved(id: String, query: String) {
        val item = _state.value.services.firstOrNull { it.saved.id == id } ?: return
        val s = item.saved
        _detailTests.update { it + (id to WebSearchTestState.Testing) }
        viewModelScope.launch {
            val count = SearchSettings.searchResultCount(s.resultCount)
            val outcome = runTest {
                if (s.kind == SavedSearchService.KIND_CUSTOM) {
                    val key = withContext(io) { store.key(accountId, id) }
                    executor.executeCustom(s.protocol ?: "", s.address ?: "", s.mapping, key, query, count)
                } else {
                    val entry = item.entry
                    val key = if (s.keySource == SavedSearchService.KEY_SOURCE_CONNECTION) {
                        providers.firstOrNull { it.id == s.connectionRef }?.let { ProviderCredentialResolver.apiKey(it, null) }
                    } else {
                        withContext(io) { store.key(accountId, id) }
                    }
                    if (entry == null) {
                        SearchExecution.Failed(
                            ai.oriveo.community.core.search.SearchTransport.classifySearchError(
                                ai.oriveo.community.core.search.SearchErrorInput(preflight = "service_withdrawn"),
                            ),
                        )
                    } else {
                        executor.executePreset(entry, s.regionId ?: "", s.boundHost ?: "", withdrawn = false, key = key, query = query, count = count)
                    }
                }
            }
            _detailTests.update { it + (id to WebSearchTestState.Done(SearchSettings.searchTestPresentation(outcome))) }
        }
    }

    private suspend fun runTest(block: suspend () -> SearchExecution): SearchTestOutcome {
        val started = System.nanoTime()
        val result = runCatching { block() }.getOrNull()
        val latencyMs = (System.nanoTime() - started) / 1_000_000
        return when (result) {
            is SearchExecution.Results -> SearchTestOutcome.Ok(result.results.size, latencyMs)
            SearchExecution.Empty -> SearchTestOutcome.Ok(0, latencyMs)
            is SearchExecution.Failed -> SearchTestOutcome.Error(result.outcome.errorClass, result.outcome.card)
            null -> SearchTestOutcome.Error(null, null)
        }
    }
}
