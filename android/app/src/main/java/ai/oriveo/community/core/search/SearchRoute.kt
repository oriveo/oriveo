package ai.oriveo.community.core.search

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/*
 * External web search: web row resolution, web card and per-conversation selection, this turn's path.
 * Ported line by line from scripts/lib/search-route.mjs (same names, same semantics); fixture shared/search-contracts/web-route-resolution.v1.json.
 * All values are semantic names from the contract (row / action / path / card.*); the UI layer maps them to copy and actions.
 */

/** Input of resolveWebSearchRoute; field defaults match the destructuring defaults of the reference implementation. */
data class WebSearchRouteInput(
    val form: String,
    val nativeWeb: String? = null,
    val relayWebRecord: String? = null,
    val toolCall: String = "unknown",
    val webOn: Boolean = false,
    val externalServices: Int = 0,
    val reusableConnection: Boolean = false,
    val method: String? = null,
)

/** The web row and this turn's web path; a turn takes only one path. */
data class WebSearchRoute(
    val row: String,
    val path: String,
    val primaryAction: String? = null,
    val secondaryAction: String? = null,
    val sourceAction: String? = null,
    val fragmentAttached: Boolean? = null,
)

private val RELAY_NATIVE = setOf("searched", "supported")
private val RELAY_UNCHANGED = setOf("user_override_off", "local_engine", "protocol_undecided")

private fun externalPath(toolCall: String): String =
    if (toolCall == "unsupported") "external_presearch" else "external_tool"

fun resolveWebSearchRoute(input: WebSearchRouteInput): WebSearchRoute {
    val form = input.form
    val toolCall = input.toolCall
    val services = input.externalServices
    val method = if (services > 0) input.method ?: "default" else "default"
    val on = input.webOn

    if (form == "free") return WebSearchRoute("free_unchanged", "none")
    if (form == "managed") {
        return WebSearchRoute("managed_unchanged", if (on && input.nativeWeb == "available") "native" else "none")
    }
    if (form == "subscription_grok") return WebSearchRoute("always_on_unchanged", "native")

    var nativeKind: String? = null // the path taken when native web search is available
    var fragmentForbidden = false
    when (form) {
        "relay" -> {
            val record = input.relayWebRecord
            // User override web=false, local engine, protocol undecided: status quo, and no external search is offered either
            if (record in RELAY_UNCHANGED) return WebSearchRoute("relay_unchanged", "none")
            if (record in RELAY_NATIVE) nativeKind = "relay_fragment" else fragmentForbidden = true
        }
        "byok", "subscription_codex" -> if (input.nativeWeb == "available") nativeKind = "native"
        else -> throw IllegalArgumentException("unknown form: $form")
    }

    if (nativeKind != null) {
        if (services == 0) {
            return WebSearchRoute(
                if (form == "relay") "relay_unchanged" else "toggle_native_unchanged",
                if (on) nativeKind else "none",
            )
        }
        val path = when {
            !on -> "none"
            method == "external" -> externalPath(toolCall)
            else -> nativeKind
        }
        return WebSearchRoute("toggle_with_source_picker", path, sourceAction = "pick_source")
    }

    // Cannot search natively (including unknown, withdrawn / rejected, relay not confirmed)
    if (services > 0) {
        return WebSearchRoute(
            row = if (toolCall == "unsupported") "toggle_external_presearch_notice" else "toggle_external",
            path = if (on) externalPath(toolCall) else "none",
            sourceAction = "pick_source",
            fragmentAttached = if (fragmentForbidden) false else null,
        )
    }
    if (form == "relay") return WebSearchRoute("relay_unchanged", "none")
    // Do not look at webOn when this device has no service: the switch being on most likely means the model used just before could search natively, so it must not be treated as "synced from elsewhere"
    if (input.reusableConnection) return WebSearchRoute("one_tap_reuse_connection_key", "none", primaryAction = "one_tap_enable")
    return WebSearchRoute("cannot_search", "none", primaryAction = "add_search_service", secondaryAction = "open_supported_models")
}

// ───────────── Web card and per-conversation selection ─────────────

/**
 * Whether a service may appear on the web card and the "Search method" page (also determines the externalServices count). Only withdrawn does not count: catalog temporarily unavailable,
 * key needed, host changed, connection gone all still count; the card keeps the selection and explains the state with notes.
 */
fun searchServiceSelectable(status: String): Boolean = status != "withdrawn"

/** Target of "one-tap enable", also the prefill for entering onboarding page (reuses this connection's key, site decided by the connection address). */
data class OneTapReuseTarget(
    val serviceId: String,
    val regionId: String,
    val connectionRef: String,
    val connectionName: String?,
)

/**
 * Which vendor "one-tap enable" connects: an entry in catalog order that has reuse and a connection of the same providerKind whose address resolves to a site;
 * one from the same vendor as the current model is preferred, otherwise the first. Catalog unavailable or none = null. [entries] are the usable entries in the adopted catalog (catalog order).
 */
fun oneTapReuseTarget(
    catalogAvailable: Boolean,
    entries: List<JsonObject>,
    connections: List<SearchConnectionRef>,
    currentProviderKind: String?,
): OneTapReuseTarget? {
    if (!catalogAvailable) return null
    val candidates = mutableListOf<Pair<OneTapReuseTarget, String?>>()
    for (e in entries) {
        val reuseKind = SearchJson.string(SearchJson.obj(e["reuse"])?.get("providerKind")) ?: continue
        val id = SearchJson.string(e["id"]) ?: continue
        for (c in connections) {
            if (c.providerKind != reuseKind) continue
            val regionId = SearchCatalog.regionForConnection(e, c.baseUrl)
            if (regionId != null) {
                candidates += OneTapReuseTarget(id, regionId, c.id, c.name) to c.providerKind
                break
            }
        }
    }
    return (candidates.firstOrNull { it.second == currentProviderKind } ?: candidates.firstOrNull())?.first
}

/** One-shot notice for a source fallback (storage keeps only the name of the replaced service). */
data class SearchSourceStoredNotice(val fromName: String)

/**
 * Stored value of the per-conversation selection (normalized): [methods] remembered per "conversation × model" (modelKey → native / external),
 * [serviceId] / [serviceName] are the service chosen for the conversation, [notice] is the fallback notice. Not part of preference sync or backup.
 */
data class SearchSourceStored(
    val methods: Map<String, String> = emptyMap(),
    val serviceId: String? = null,
    val serviceName: String? = null,
    val notice: SearchSourceStoredNotice? = null,
) {
    val isEmpty: Boolean get() = methods.isEmpty() && serviceId == null && serviceName == null && notice == null

    fun toJson(): JsonObject = buildJsonObject {
        put("methods", buildJsonObject { methods.toSortedMap().forEach { (k, v) -> put(k, v) } })
        put("serviceId", serviceId)
        put("serviceName", serviceName)
        if (notice == null) put("notice", JsonNull) else put("notice", buildJsonObject { put("fromName", notice.fromName) })
    }

    companion object {
        /** Reference implementation normalizeStored: any JSON → normalized value; methods keeps only native / external, old shapes are ignored as garbage. */
        fun fromJson(stored: JsonElement?): SearchSourceStored {
            val o = stored as? JsonObject ?: return SearchSourceStored()
            fun s(key: String): String? = (o[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val methods = (o["methods"] as? JsonObject).orEmpty().mapNotNull { (k, v) ->
                (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it in METHOD_VALUES }?.let { k to it }
            }.toMap()
            val notice = (o["notice"] as? JsonObject)?.let { n ->
                (n["fromName"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.let(::SearchSourceStoredNotice)
            }
            return SearchSourceStored(methods, s("serviceId"), s("serviceName"), notice)
        }
    }
}

private val METHOD_VALUES = setOf("native", "external")

private fun Map<String, String>.withoutExternal(): Map<String, String> = filterValues { it != "external" }

/** Selectable services (id + status from searchServiceRowState), in storage order. */
data class SelectableSearchService(val id: String, val status: String)

data class SearchSourceNotice(val fromName: String)

/** When [changed] is false storage must not be written (prevents a self-triggering write loop); [nextStored] = null means delete the key. */
data class SearchSourceResolution(
    val method: String,
    val serviceId: String?,
    val notice: SearchSourceNotice?,
    val nextStored: SearchSourceStored?,
    val changed: Boolean,
)

/** Local storage key for the per-conversation selection: inside that account's search partition. */
fun searchSourceStorageKey(conversationId: String): String = "conversationSource:$conversationId"

/**
 * Which source this conversation uses this turn (read path). methods is remembered per "conversation × model" and is not cleared when switching models; if the service chosen for the conversation is deleted or withdrawn →
 * serviceId is cleared, all external entries are cleared, and one notice is recorded; if no service is selectable: external and serviceId are cleared with no notice.
 */
fun resolveSearchSource(
    stored: SearchSourceStored?,
    modelKey: String,
    selectable: List<SelectableSearchService>,
    defaultServiceId: String?,
): SearchSourceResolution {
    val s = stored ?: SearchSourceStored()
    var next = s
    val ids = selectable.map { it.id }
    val fallbackId = if (defaultServiceId != null && defaultServiceId in ids) defaultServiceId else ids.firstOrNull()
    var serviceId = fallbackId
    if (ids.isEmpty()) {
        next = next.copy(methods = next.methods.withoutExternal(), serviceId = null, serviceName = null, notice = null)
    } else if (!next.serviceId.isNullOrEmpty() && next.serviceId in ids) {
        serviceId = next.serviceId
    } else if (!next.serviceId.isNullOrEmpty()) {
        next = next.copy(
            notice = SearchSourceStoredNotice(next.serviceName ?: ""),
            methods = next.methods.withoutExternal(),
            serviceId = null,
            serviceName = null,
        )
    }
    return SearchSourceResolution(
        method = next.methods[modelKey] ?: "default",
        serviceId = serviceId,
        notice = next.notice?.let { SearchSourceNotice(it.fromName) },
        nextStored = next.takeUnless { it.isEmpty },
        changed = s != next,
    )
}

/** Actions on the web card / "Search method" page. */
sealed interface SearchSourceEvent {
    /** Choose "Built into the model" on the "Search method" page. */
    data object PickNative : SearchSourceEvent
    /** Explicitly choosing external = turn external on for this model. */
    data class PickService(val serviceId: String, val serviceName: String?) : SearchSourceEvent
    /** The notice has been seen once the model options panel is actually closed. */
    data object AcknowledgeNotice : SearchSourceEvent
    /** External switch turned off manually: only turns off external for this model, does not write conversation web. */
    data object Disarm : SearchSourceEvent
}

/** Write path of user actions: choosing any source clears the notice; returns the stored value to write (null = delete the key). */
fun updateSearchSource(stored: SearchSourceStored?, modelKey: String, event: SearchSourceEvent): SearchSourceStored? {
    val s = stored ?: SearchSourceStored()
    val next = when (event) {
        SearchSourceEvent.PickNative -> s.copy(methods = s.methods + (modelKey to "native"), notice = null)
        is SearchSourceEvent.PickService -> s.copy(
            methods = s.methods + (modelKey to "external"),
            serviceId = event.serviceId,
            serviceName = event.serviceName,
            notice = null,
        )
        SearchSourceEvent.Disarm -> if (s.methods[modelKey] == "external") s.copy(methods = s.methods - modelKey) else s
        SearchSourceEvent.AcknowledgeNotice -> s.copy(notice = null)
    }
    return next.takeUnless { it.isEmpty }
}

/** One row of the "Search method" page. */
sealed interface SearchSourcePickerItem {
    data class Native(val selected: Boolean) : SearchSourcePickerItem
    data class Service(val serviceId: String, val isDefault: Boolean, val status: String, val selected: Boolean) : SearchSourcePickerItem
    data object Add : SearchSourcePickerItem
}

/**
 * Rows of the "Search method" page. Selected: can search natively → the current service when method = external, otherwise "Built into the model";
 * cannot search natively → the current service when external is on, nothing selected when it is off.
 */
fun searchSourcePickerItems(
    nativeCapable: Boolean,
    selectable: List<SelectableSearchService>,
    defaultServiceId: String?,
    method: String,
    serviceId: String?,
): List<SearchSourcePickerItem> {
    val external = method == "external"
    return buildList {
        if (nativeCapable) add(SearchSourcePickerItem.Native(!external))
        for (s in selectable) {
            add(SearchSourcePickerItem.Service(s.id, s.id == defaultServiceId, s.status, external && s.id == serviceId))
        }
        add(SearchSourcePickerItem.Add)
    }
}

/** One piece of text on the card: semantic key (`card.*` / `row.*`) + named parameters. */
data class WebSearchCardText(val key: String, val args: Map<String, String?> = emptyMap())

/** One tappable thing on the card: text + action (`pick_source` / `one_tap_enable` / `add_search_service` / `open_supported_models`). */
data class WebSearchCardAction(val key: String, val args: Map<String, String?> = emptyMap(), val action: String)

/** Current source of the web card: built into the model or a service (display name + row status). */
sealed interface WebSearchCardSource {
    data object Native : WebSearchCardSource
    data class Service(val name: String?, val status: String? = null) : WebSearchCardSource
}

data class WebSearchCardNotice(val fromName: String)

/** When [existing] = true the other fields are meaningless and each platform renders as it already did. [notes] are all shown in order and do not displace one another. */
data class WebSearchCardPresentation(
    val existing: Boolean,
    val toggle: Boolean = false,
    val status: WebSearchCardText? = null,
    val notes: List<WebSearchCardText> = emptyList(),
    val link: WebSearchCardAction? = null,
    val cta: WebSearchCardAction? = null,
    val secondary: WebSearchCardAction? = null,
)

private val CARD_ROWS = setOf(
    "toggle_with_source_picker", "toggle_external", "toggle_external_presearch_notice",
    "one_tap_reuse_connection_key", "cannot_search",
)

private val STATUS_NOTE = mapOf(
    "needs_key" to "row.needsKey",
    "host_changed" to "row.hostChanged",
    "connection_missing" to "row.connectionMissing",
    "catalog_unavailable" to "row.catalogUnavailable",
)

/**
 * How to draw the web card. notes order: fallback notice → abnormal state of the current service → search-first-then-answer on every turn → not-enabled explanation → one-tap enable explanation;
 * when native capability is not explicitly unavailable, the two no-service row states keep the existing copy (status = null).
 */
fun webSearchCardPresentation(
    route: WebSearchRoute,
    nativeWeb: String = "unavailable",
    webOn: Boolean = false,
    source: WebSearchCardSource? = null,
    oneTapServiceName: String? = null,
    notice: WebSearchCardNotice? = null,
    armHint: Boolean = false,
): WebSearchCardPresentation {
    if (route.row !in CARD_ROWS) return WebSearchCardPresentation(existing = true)
    val service = source as? WebSearchCardSource.Service
    val nameArgs = mapOf("name" to service?.name)
    val notes = mutableListOf<WebSearchCardText>()
    notice?.let { notes += WebSearchCardText("card.fallbackNotice", mapOf("from" to it.fromName)) }
    val statusNote = service?.status?.let(STATUS_NOTE::get)
    val oneTapArgs = mapOf("name" to oneTapServiceName)
    return when (route.row) {
        "toggle_with_source_picker" -> {
            statusNote?.let { notes += WebSearchCardText(it) }
            WebSearchCardPresentation(
                existing = false,
                toggle = true,
                link = if (service != null) {
                    WebSearchCardAction("card.sourceLine", nameArgs, "pick_source")
                } else {
                    WebSearchCardAction("card.sourceLineNative", action = "pick_source")
                },
                notes = notes,
            )
        }
        "toggle_external", "toggle_external_presearch_notice" -> {
            statusNote?.let { notes += WebSearchCardText(it) }
            if (route.row == "toggle_external_presearch_notice") notes += WebSearchCardText("card.presearchNotice")
            if (armHint) notes += WebSearchCardText("card.armHint", nameArgs)
            WebSearchCardPresentation(
                existing = false,
                toggle = true,
                status = WebSearchCardText(if (webOn) "card.useService" else "card.offUseService", nameArgs),
                link = WebSearchCardAction("card.changeService", action = "pick_source"),
                notes = notes,
            )
        }
        "one_tap_reuse_connection_key" -> {
            if (nativeWeb != "unavailable") notes += WebSearchCardText("card.reuseDetail", oneTapArgs)
            WebSearchCardPresentation(
                existing = false,
                status = WebSearchCardText("card.reuseStatus", oneTapArgs).takeIf { nativeWeb == "unavailable" },
                notes = notes,
                cta = WebSearchCardAction("card.oneTap", action = "one_tap_enable"),
            )
        }
        "cannot_search" -> WebSearchCardPresentation(
            existing = false,
            status = WebSearchCardText("card.cannotSearch").takeIf { nativeWeb == "unavailable" },
            notes = notes,
            cta = WebSearchCardAction("card.addService", action = "add_search_service"),
            secondary = WebSearchCardAction("card.supportedModels", action = "open_supported_models"),
        )
        else -> WebSearchCardPresentation(existing = true)
    }
}

// ───────────── Single composition point: panel, send and input box preview all call only this ─────────────

/**
 * This platform's facts (after normalization): [form] connection form; [recipeWeb] recipe web control auto_available / unavailable / none / custom_only;
 * [nativeRejected] native withdrawn or tier rejected (the same fact for which the panel shows the rejection copy); [relayStatus] relay web-probe statusId,
 * or local_engine / protocol_undecided; [managedWebAvailable] hosted web search available; [toolCall] tri-state of catalog evidence.
 */
data class WebSearchFacts(
    val form: String,
    val recipeWeb: String? = null,
    val nativeRejected: Boolean = false,
    val relayStatus: String? = null,
    val managedWebAvailable: Boolean = false,
    val toolCall: String? = null,
)

/** A local service inside the composition point: [name] has already gone through searchServiceDisplayName, [status] is the status from searchServiceRowState. */
data class WebSearchStateService(val id: String, val name: String, val status: String)

data class WebSearchStateInput(
    val facts: WebSearchFacts,
    val panelWritable: Boolean = true,
    val webOn: Boolean = false,
    val modelKey: String,
    val services: List<WebSearchStateService> = emptyList(),
    val defaultServiceId: String? = null,
    val stored: SearchSourceStored? = null,
    val oneTapTarget: OneTapReuseTarget? = null,
    val oneTapServiceName: String? = null,
)

/**
 * [shapeMode]: existing = render exactly as before the change; existing_with_actions = old shape + card notes / actions;
 * search_notice = old row, with the status now given by card.status; toggle_with_source = new shape.
 * [toggleOn] switch shows on; [chipLit] whether the web chip in the input box is lit (null = follow the old liveness);
 * [toggleControls] external (on = pick_service the current service, off = disarm, neither writes conversation web) / conversation_web (writes conversation web) / null;
 * [armHint] conversation web is on but external is not yet on for this model; [nativeFieldsSuppressed] this turn goes external, the request suppresses native / relay web fields;
 * [oneTapArms] whether external can be recorded as on after a one-tap enable passes.
 */
data class WebSearchState(
    val nativeWeb: String?,
    val route: WebSearchRoute,
    val source: SearchSourceResolution,
    val shapeMode: String,
    val card: WebSearchCardPresentation,
    val pickerItems: List<SearchSourcePickerItem>,
    val toggleOn: Boolean,
    val chipLit: Boolean?,
    val toggleControls: String?,
    val armHint: Boolean,
    val nativeFieldsSuppressed: Boolean,
    val oneTapArms: Boolean,
)

private val RELAY_STATUS_TO_RECORD = mapOf(
    "web_probe_searched" to "searched",
    "web_user_on" to "supported",
    "web_probe_rejected" to "rejected",
    "web_probe_silent" to "silent",
    "web_probe_unverified" to "untested",
    "web_probe_untested" to "template_only",
    "web_user_off" to "user_override_off",
    "local_engine" to "local_engine",
    "protocol_undecided" to "protocol_undecided",
)

private fun nativeWebOf(facts: WebSearchFacts): String = when {
    facts.nativeRejected -> "withdrawn_or_rejected"
    facts.recipeWeb == "auto_available" -> "available"
    facts.recipeWeb == "unavailable" -> "unavailable"
    else -> "unknown"
}

private val TOGGLE_ROWS = setOf("toggle_with_source_picker", "toggle_external", "toggle_external_presearch_notice")
private val EXTERNAL_ROWS = setOf("toggle_external", "toggle_external_presearch_notice")

private fun isExternalPath(path: String) = path == "external_tool" || path == "external_presearch"

/** The single composition point for the web card and this turn's web path ("composition point"). Each platform only normalizes its own facts into [WebSearchFacts]. */
fun resolveWebSearchState(input: WebSearchStateInput): WebSearchState {
    val facts = input.facts
    val selectable = input.services.filter { searchServiceSelectable(it.status) }
    val selectableRefs = selectable.map { SelectableSearchService(it.id, it.status) }
    val resolved = resolveSearchSource(input.stored, input.modelKey, selectableRefs, input.defaultServiceId)
    // The panel cannot persist: per-conversation selection does not take effect
    val source = if (input.panelWritable) resolved else resolved.copy(method = "default")
    val nativeWeb = when (facts.form) {
        "byok", "subscription_codex" -> nativeWebOf(facts)
        "managed" -> if (facts.managedWebAvailable) "available" else "unavailable"
        else -> null
    }
    val relayRecord = if (facts.form == "relay") {
        RELAY_STATUS_TO_RECORD[facts.relayStatus] ?: throw IllegalArgumentException("unknown relayStatus: ${facts.relayStatus}")
    } else {
        null
    }
    val routeInput = WebSearchRouteInput(
        form = facts.form,
        nativeWeb = nativeWeb,
        relayWebRecord = relayRecord,
        toolCall = facts.toolCall ?: "unknown",
        webOn = input.webOn,
        externalServices = selectable.size,
        reusableConnection = input.oneTapTarget != null,
        method = source.method,
    )
    // First see which kind of row it is, then decide which state the switch reads: external row = whether external is on for this conversation × this model, otherwise = conversation web
    val probe = resolveWebSearchRoute(routeInput.copy(webOn = true))
    val externalRow = probe.row in EXTERNAL_ROWS
    val effectiveOn = if (externalRow) source.method == "external" else routeInput.webOn
    val route = resolveWebSearchRoute(routeInput.copy(webOn = effectiveOn))
    val armHint = externalRow && routeInput.webOn && !effectiveOn
    val current = selectable.firstOrNull { it.id == source.serviceId }
    val usesService = externalRow || (route.row == "toggle_with_source_picker" && source.method == "external")
    val card = webSearchCardPresentation(
        route = route,
        nativeWeb = nativeWeb ?: "unavailable",
        webOn = effectiveOn,
        source = if (usesService) {
            WebSearchCardSource.Service(current?.name?.takeIf { it.isNotEmpty() } ?: source.serviceId.orEmpty(), current?.status)
        } else {
            WebSearchCardSource.Native
        },
        oneTapServiceName = input.oneTapServiceName,
        notice = source.notice?.let { WebSearchCardNotice(it.fromName) },
        armHint = armHint,
    )
    val shapeMode = when {
        card.existing -> "existing"
        route.row in TOGGLE_ROWS -> if (input.panelWritable) "toggle_with_source" else "existing"
        card.status == null -> "existing_with_actions"
        else -> "search_notice"
    }
    val pickerItems = if (route.row in TOGGLE_ROWS) {
        searchSourcePickerItems(route.row == "toggle_with_source_picker", selectableRefs, input.defaultServiceId, source.method, source.serviceId)
    } else {
        emptyList()
    }
    val lit = route.row in TOGGLE_ROWS && route.path != "none"
    return WebSearchState(
        nativeWeb = nativeWeb,
        route = route,
        source = source,
        shapeMode = shapeMode,
        card = card,
        pickerItems = pickerItems,
        toggleOn = lit,
        // In the new shape = toggleOn; in the old shape (including the read-only panel) null = follow the old liveness
        chipLit = if (shapeMode == "toggle_with_source") lit else null,
        toggleControls = when {
            externalRow -> "external"
            route.row == "toggle_with_source_picker" -> "conversation_web"
            else -> null
        },
        armHint = armHint,
        nativeFieldsSuppressed = isExternalPath(route.path),
        oneTapArms = input.panelWritable,
    )
}

/** Input of resolveSearchTurnPath; null corresponds to the key being absent in the reference implementation. */
data class SearchTurnInput(
    val path: String,
    val thinkingOn: Boolean? = null,
    val continuationStateAvailable: Boolean? = null,
    val upstreamRejectedTools: Boolean? = null,
    val thinkingWithTools: String? = null,
    val hostMaxSteps: Int? = null,
)

data class SearchTurnPath(
    val path: String,
    val fallbackReason: String?,
    val noticeOnce: Boolean,
    val requestHasNativeSearchFields: Boolean,
    val requestHasWebSearchTool: Boolean,
)

/** How this turn is actually sent: whether the tool call switches to pre-search, and which web field appears in the request. */
fun resolveSearchTurnPath(input: SearchTurnInput): SearchTurnPath {
    val path = input.path
    if (path != "external_tool" && path != "external_presearch") {
        return SearchTurnPath(path, null, false, path == "native" || path == "relay_fragment", false)
    }
    var resolved = path
    var fallbackReason: String? = null
    if (path == "external_tool") {
        fallbackReason = when {
            input.hostMaxSteps == 0 -> "no_tool_continuation"
            input.thinkingOn == true && input.thinkingWithTools == "presearch" -> "thinking_tools_unsupported"
            input.thinkingOn == true && input.continuationStateAvailable == false -> "thinking_no_continuation"
            input.upstreamRejectedTools == true -> "tools_rejected"
            else -> null
        }
        if (fallbackReason != null) resolved = "external_presearch"
    }
    return SearchTurnPath(resolved, fallbackReason, fallbackReason == "tools_rejected", false, resolved == "external_tool")
}

/** Per-reply cap on search requests and retry policy. */
object SearchCallLimits {
    const val MAX_SEARCH_REQUESTS_PER_REPLY = 3
    val RETRYABLE_STATUSES: List<Int> = listOf(408, 502, 503)
    const val MAX_RETRIES_PER_CALL = 1
}

/** Outcome of one request: an HTTP status, or a local transport failure (timeout / network). */
sealed interface SearchAttempt {
    data class Status(val code: Int) : SearchAttempt
    data class Failure(val kind: String) : SearchAttempt
}

/** Request outcome sequence of one call (attempts). */
data class SearchCallAttempts(val attempts: List<SearchAttempt> = emptyList())

data class SearchCallPlan(val leg: Int, val call: Int, val requests: Int, val outcome: String)

data class SearchCallsPlan(val requestsSent: Int, val calls: List<SearchCallPlan>)

/**
 * Search calls within one reply: legs = [[call, …], …].
 * Only 408 / 502 / 503 are retried automatically once, and the retry counts toward the cap of 3 requests per reply; a call beyond the cap sends no request and returns cap_reached.
 */
fun planSearchCalls(legs: List<List<SearchCallAttempts>>): SearchCallsPlan {
    val max = SearchCallLimits.MAX_SEARCH_REQUESTS_PER_REPLY
    var sent = 0
    val calls = mutableListOf<SearchCallPlan>()
    legs.forEachIndexed { legIndex, leg ->
        leg.forEachIndexed { callIndex, call ->
            if (sent >= max) {
                calls += SearchCallPlan(legIndex, callIndex, 0, "cap_reached")
                return@forEachIndexed
            }
            var requests = 0
            var last: SearchAttempt? = null
            var i = 0
            while (i < call.attempts.size && i <= SearchCallLimits.MAX_RETRIES_PER_CALL) {
                if (sent >= max) break
                requests += 1
                sent += 1
                last = call.attempts[i]
                val retryable = last is SearchAttempt.Status && last.code in SearchCallLimits.RETRYABLE_STATUSES
                if (!retryable) break
                i += 1
            }
            val outcome = when (last) {
                null -> "cap_reached"
                is SearchAttempt.Status -> if (last.code in 200..299) "response" else last.code.toString()
                is SearchAttempt.Failure -> last.kind
            }
            calls += SearchCallPlan(legIndex, callIndex, requests, outcome)
        }
    }
    return SearchCallsPlan(sent, calls)
}

data class RegenerateSearchPolicy(val reusePrevious: Boolean, val newSearchesAllowed: Boolean)

/** Resend after regenerate / edit: by default reuses the previous result of that message, and only searches again when the user taps "Search again". action = send | regenerate | edit_resend | re_search. */
fun regenerateSearchPolicy(action: String, previousResultsPersisted: Boolean): RegenerateSearchPolicy {
    if (action == "re_search") return RegenerateSearchPolicy(reusePrevious = false, newSearchesAllowed = true)
    if ((action == "regenerate" || action == "edit_resend") && previousResultsPersisted) {
        return RegenerateSearchPolicy(reusePrevious = true, newSearchesAllowed = false)
    }
    return RegenerateSearchPolicy(reusePrevious = false, newSearchesAllowed = true)
}
