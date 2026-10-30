package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.search.OneTapReuseTarget
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchJson
import ai.oriveo.community.core.search.SearchServiceStore
import ai.oriveo.community.core.search.SearchSettings
import ai.oriveo.community.core.search.SearchSourceEvent
import ai.oriveo.community.core.search.SelectableSearchService
import ai.oriveo.community.core.search.oneTapReuseTarget
import ai.oriveo.community.core.search.resolveSearchSource
import ai.oriveo.community.core.search.searchServiceSelectable
import ai.oriveo.community.core.search.toOutcome
import ai.oriveo.community.core.search.updateSearchSource
import ai.oriveo.community.feature.settings.websearch.WebSearchServiceItem
import ai.oriveo.community.feature.settings.websearch.webSearchProviderKindId
import ai.oriveo.community.feature.settings.websearch.webSearchServiceItems
import kotlinx.coroutines.launch

/**
 * The local search facts the web card needs right now (external search contract): selectable services (stored order), default service, this conversation's source, one-tap enable target, and the tool-call tri-state.
 * The UI renders only from this and the result of [ModelOptionCapabilityShape.resolve].
 */
data class WebSearchPanelSnapshot(
    /** Services with searchServiceSelectable true (the same [WebSearchServiceItem] as the list rows; the subtitle reuses the settings row text). */
    val services: List<WebSearchServiceItem>,
    val defaultServiceId: String?,
    /** The value of this conversation's conversationSource (draft conversation = in-memory value), before resolveSearchSource. */
    val stored: ai.oriveo.community.core.search.SearchSourceStored?,
    val oneTap: OneTapReuseTarget?,
    val oneTapServiceName: String?,
    /** Catalog-evidence tool-call tri-state: supported / unknown / unsupported. */
    val toolCall: String,
) {
    fun serviceName(id: String?): String? = services.firstOrNull { it.saved.id == id }?.displayName

    /** Input of resolveWebSearchState (the service name has already gone through searchServiceDisplayName). */
    fun stateInput(
        facts: ai.oriveo.community.core.search.WebSearchFacts,
        panelWritable: Boolean,
        webOn: Boolean,
        modelKey: String,
    ): ai.oriveo.community.core.search.WebSearchStateInput = ai.oriveo.community.core.search.WebSearchStateInput(
        facts = facts,
        panelWritable = panelWritable,
        webOn = webOn,
        modelKey = modelKey,
        services = services.map { ai.oriveo.community.core.search.WebSearchStateService(it.saved.id, it.displayName, it.rowState.status) },
        defaultServiceId = defaultServiceId,
        stored = stored,
        oneTapTarget = oneTap,
        oneTapServiceName = oneTapServiceName,
    )

    companion object {
        val EMPTY = WebSearchPanelSnapshot(emptyList(), null, null, null, null, "unknown")
    }
}

/**
 * The "switch service" action on the external search error card in chat: asks the input box to open model options and stop directly on the "Search via" page (external search contract).
 * A one-shot in-process request, claimed by conversation id; discarded if no input box is receiving it.
 */
object WebSearchMethodOpenRequests {
    private val flow = kotlinx.coroutines.flow.MutableSharedFlow<String>(extraBufferCapacity = 1)
    val requests: kotlinx.coroutines.flow.SharedFlow<String> get() = flow

    fun request(conversationId: String) {
        flow.tryEmit(conversationId)
    }
}

/** The modelKey selected per conversation: `<connection id>:<model id>`. */
fun webSearchModelKey(provider: Provider, model: AIModel): String = "${provider.id}:${model.id}"

/**
 * Local search reads and writes for the model options web card and for deciding the path before sending (external search contract). Storage is read fresh every time and only the already-cached catalog is used,
 * with no in-process cache as source of truth. [draft] = the conversation has not been created yet (the id is a draft id): the source stays in memory only, and when the conversation is created [adoptDraft] writes it once under the real id.
 * Everything except [acknowledgeNotice] reads or writes encrypted storage: call only on a background thread.
 */
interface ModelControlsWebSearch {
    /**
     * Read path (opening model options, every send, chip preview). [writeBack] = true only from the model options panel: when resolveSearchSource changed, write back
     * nextStored; sends and chips only read and never write.
     */
    suspend fun snapshot(
        provider: Provider,
        model: AIModel,
        conversationId: String,
        draft: Boolean = false,
        writeBack: Boolean = false,
    ): WebSearchPanelSnapshot

    /** Incremented on every write to the service list / source: the panel and chip observe it and recompute. */
    val revision: kotlinx.coroutines.flow.StateFlow<Long>

    /** Write path: actions on the card / "Search via" sheet (updateSearchSource). */
    fun update(provider: Provider, model: AIModel, conversationId: String, draft: Boolean, event: SearchSourceEvent)

    /** Marks the notice as seen when the model options panel closes: written in the implementation's own background scope so it is not cancelled with the panel; safe to call on the main thread. */
    fun acknowledgeNotice(provider: Provider, model: AIModel, conversationId: String, draft: Boolean)

    /** The first message creates the conversation: if the draft source is non-empty, write it once under the real id, then drop the draft. */
    fun adoptDraft(draftId: String, conversationId: String)

    /** Add / one-tap enable launched from the panel succeeded: send pick_service for the new service (service name via searchServiceDisplayName). Does nothing if the service is gone. */
    suspend fun pickAdded(provider: Provider, model: AIModel, conversationId: String, draft: Boolean, serviceId: String)

    /**
     * The external search service binding for this turn (executor + key + catalog entry); [serviceId] = resolveWebSearchState.source.serviceId.
     * Returns null if the service is not in the selectable list. Reads encrypted storage: call only on a background thread.
     */
    suspend fun searchBinding(snapshot: WebSearchPanelSnapshot, serviceId: String): ai.oriveo.community.core.search.ExternalSearchBinding? = null
}

/** Production implementation: the search service list and catalog come from the same place as the settings page ([webSearchServiceItems]). */
class StoreModelControlsWebSearch(
    private val store: SearchServiceStore,
    private val catalog: SearchCatalogRepository,
    /** Reusable model connections (production = webSearchConnections run over the connection list; shots = in-memory values from the manifest). */
    private val connections: suspend () -> List<ai.oriveo.community.core.search.SearchConnectionRef>,
    /** Catalog-evidence tool-call tri-state (true / false / null = unknown). */
    private val toolCallVerdict: (Provider, AIModel) -> Boolean?,
    /** The search executor used in chat (shared with the settings test); null = do not run external search. */
    private val executor: ai.oriveo.community.core.search.SearchExecutor? = null,
    /** The key of a reused model connection (connection id -> key); fetched only just before sending a request, never cached. */
    private val connectionKey: suspend (String) -> String? = { null },
) : ModelControlsWebSearch {
    private val accountId: String get() = LOCAL_PARTITION_ID
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    /** Source of a conversation not yet created (account + draft id -> value); in memory only. */
    private val drafts = java.util.concurrent.ConcurrentHashMap<String, ai.oriveo.community.core.search.SearchSourceStored>()

    private fun draftKey(id: String) = "$accountId\u0000$id"

    private fun read(conversationId: String, draft: Boolean): ai.oriveo.community.core.search.SearchSourceStored? =
        if (draft) drafts[draftKey(conversationId)] else store.conversationSource(accountId, conversationId)

    private fun write(conversationId: String, draft: Boolean, value: ai.oriveo.community.core.search.SearchSourceStored?) {
        if (!draft) return store.setConversationSource(accountId, conversationId, value)
        if (value == null) drafts.remove(draftKey(conversationId)) else drafts[draftKey(conversationId)] = value
    }

    override val revision: kotlinx.coroutines.flow.StateFlow<Long> get() = store.revision

    override suspend fun snapshot(
        provider: Provider,
        model: AIModel,
        conversationId: String,
        draft: Boolean,
        writeBack: Boolean,
    ): WebSearchPanelSnapshot {
        // Use only the already-cached catalog (adopted on this device / built-in snapshot); no network request
        if (catalog.current() == null) runCatching { catalog.loadLocal() }
        val connections = connections()
        val all = webSearchServiceItems(store, catalog, accountId, connections)
        val selectable = all.items.filter { searchServiceSelectable(it.rowState.status) }
        val defaultId = store.defaultServiceId(accountId)
        val stored = read(conversationId, draft)
        // Read path: only the panel writes back (resolveWebSearchState gets the same conclusion from the same stored value)
        val source = resolveSearchSource(
            stored = stored,
            modelKey = webSearchModelKey(provider, model),
            selectable = selectable.map { SelectableSearchService(it.saved.id, it.rowState.status) },
            defaultServiceId = defaultId,
        )
        if (writeBack && source.changed) write(conversationId, draft, source.nextStored)
        val oneTap = oneTapReuseTarget(
            catalogAvailable = all.catalogAvailable,
            entries = all.entries.values.toList(),
            connections = connections,
            currentProviderKind = webSearchProviderKindId(provider),
        )
        val oneTapName = oneTap?.let { t ->
            SearchSettings.searchServiceDisplayName(
                ai.oriveo.community.core.search.SavedSearchService.KIND_PRESET,
                null,
                t.serviceId,
                SearchJson.string(all.entries[t.serviceId]?.get("displayName")),
            )
        }
        val toolCall = when (toolCallVerdict(provider, model)) {
            true -> "supported"
            false -> "unsupported"
            null -> "unknown"
        }
        return WebSearchPanelSnapshot(selectable, defaultId, stored, oneTap, oneTapName, toolCall)
    }

    override fun update(provider: Provider, model: AIModel, conversationId: String, draft: Boolean, event: SearchSourceEvent) {
        write(conversationId, draft, updateSearchSource(read(conversationId, draft), webSearchModelKey(provider, model), event))
    }

    override fun acknowledgeNotice(provider: Provider, model: AIModel, conversationId: String, draft: Boolean) {
        scope.launch { runCatching { update(provider, model, conversationId, draft, SearchSourceEvent.AcknowledgeNotice) } }
    }

    override suspend fun pickAdded(provider: Provider, model: AIModel, conversationId: String, draft: Boolean, serviceId: String) {
        val item = snapshot(provider, model, conversationId, draft).services.firstOrNull { it.saved.id == serviceId } ?: return
        update(provider, model, conversationId, draft, SearchSourceEvent.PickService(item.saved.id, item.displayName))
    }

    override suspend fun searchBinding(
        snapshot: WebSearchPanelSnapshot,
        serviceId: String,
    ): ai.oriveo.community.core.search.ExternalSearchBinding? {
        val exec = executor ?: return null
        val item = snapshot.services.firstOrNull { it.saved.id == serviceId } ?: return null
        val s = item.saved
        val custom = s.kind == ai.oriveo.community.core.search.SavedSearchService.KIND_CUSTOM
        val others = snapshot.services.filter { it.saved.id != serviceId }
        val otherServices = others.map {
            ai.oriveo.community.core.search.SearchOtherService(
                id = it.saved.id,
                name = it.displayName,
                isDefault = it.saved.id == snapshot.defaultServiceId,
            )
        }
        val service = ai.oriveo.community.core.search.SearchTurnService(
            // Local service record id (used for jump-to-detail / pick_service); analytics reports the catalog id / custom separately
            id = s.id,
            name = item.displayName,
            protocol = if (custom) s.protocol.orEmpty() else "catalog",
            custom = custom,
        )
        val account = accountId
        return ai.oriveo.community.core.search.ExternalSearchBinding(
            service = service,
            otherServices = otherServices,
            defaultCount = SearchSettings.searchResultCount(s.resultCount),
            telemetryService = if (custom) "custom" else s.serviceId.orEmpty(),
            execute = { query, count ->
                val started = System.nanoTime()
                fun elapsed() = (System.nanoTime() - started) / 1_000_000
                try {
                    val result = if (custom) {
                        val key = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { store.key(account, s.id) }
                        exec.executeCustom(s.protocol.orEmpty(), s.address.orEmpty(), s.mapping, key, query, count, others.size)
                    } else {
                        val key = if (s.keySource == ai.oriveo.community.core.search.SavedSearchService.KEY_SOURCE_CONNECTION) {
                            s.connectionRef?.let { connectionKey(it) }
                        } else {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { store.key(account, s.id) }
                        }
                        val entry = item.entry
                        if (key.isNullOrBlank()) {
                            // A preset service whose key cannot be read (or whose reused connection was deleted): send no request and finish as an invalid key
                            ai.oriveo.community.core.search.missingKeySearchFailure(others.size)
                        } else if (entry == null) {
                            ai.oriveo.community.core.search.SearchExecution.Failed(
                                ai.oriveo.community.core.search.SearchTransport.classifySearchError(
                                    ai.oriveo.community.core.search.SearchErrorInput(preflight = "service_withdrawn", otherServices = others.size),
                                ),
                                sent = false,
                            )
                        } else {
                            exec.executePreset(entry, s.regionId.orEmpty(), s.boundHost.orEmpty(), withdrawn = false, key = key, query = query, count = count, otherServices = others.size)
                        }
                    }
                    result.toOutcome(elapsed())
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                    ai.oriveo.community.core.search.unexpectedSearchFailure(custom, others.size, elapsed())
                }
            },
        )
    }

    override fun adoptDraft(draftId: String, conversationId: String) {
        val value = drafts.remove(draftKey(draftId)) ?: return
        store.setConversationSource(accountId, conversationId, value)
    }
}
