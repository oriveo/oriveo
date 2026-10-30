package ai.oriveo.community.core.search

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Model connection used by the add sheet / list rows: a BYOK connection with a key on this device (id, display name, providerKind, request address). */
data class SearchConnectionRef(
    val id: String,
    val name: String,
    val providerKind: String? = null,
    val baseUrl: String? = null,
)

/** Minimal reference to a saved search service (used by the add sheet to decide "already added"). */
data class SearchServiceRef(val id: String, val kind: String, val serviceId: String? = null)

data class SearchAddRow(
    val serviceId: String,
    val regionId: String?,
    val connectionRef: String?,
    val connectionName: String?,
    val addedServiceRef: String?,
)

data class SearchAddSection(val id: String, val rows: List<SearchAddRow>)

/** presets = available | unavailable; the "Custom" group is always present. */
data class SearchAddSheet(val presets: String, val sections: List<SearchAddSection>, val custom: Boolean = true)

data class SearchPrice(val unit: String?, val label: String)

/** kind = monthly_credits ([count] set) | monthly_usd ([amountLabel] set). */
data class SearchFreeAllowance(val kind: String, val count: Long?, val amountLabel: String?, val cardRequired: Boolean)

data class SearchPriceSummary(
    val regionId: String?,
    val price: SearchPrice?,
    val billing: String?,
    val free: SearchFreeAllowance?,
    val otherRegionCount: Int,
)

/** Input for the list row status: keySource = connection | own | none. */
data class SearchRowServiceInput(
    val kind: String,
    val serviceId: String? = null,
    val regionId: String? = null,
    val boundHost: String? = null,
    val keySource: String,
    val connectionRef: String? = null,
    val hasKey: Boolean,
)

/** status = ready | catalog_unavailable | withdrawn | host_changed | connection_missing | needs_key. */
data class SearchRowState(val status: String, val label: String, val keySource: String, val connectionName: String?)

/** Consent sentence: [key] is the second half of the copy key `consent.*`. */
data class SearchConsentLine(val key: String, val args: Map<String, String?>)

/** Raw result of a test search. */
sealed interface SearchTestOutcome {
    data class Ok(val count: Int, val latencyMs: Long) : SearchTestOutcome
    data class Error(val errorClass: String?, val card: SearchErrorCard?) : SearchTestOutcome
}

sealed interface SearchTestPresentation {
    data class Passed(val count: Int, val latencyTenths: Long) : SearchTestPresentation

    /** action = update_key | top_up | check_settings | view_setup_guide | reconfirm | retry | none. */
    data class Failed(val errorClass: String?, val headline: String, val action: String) : SearchTestPresentation
}

/** Default id the target should store after a local migration: [set] = false means leave the target default untouched. */
data class SearchMigratedDefault(val set: Boolean, val id: String? = null)

/** One side (before / after saving) of a custom-service edit. presetId / regionId only matter for same_as. */
data class SearchCustomEditSide(
    val name: String?,
    val address: String?,
    val protocol: String?,
    val mapping: JsonElement? = null,
    val presetId: String? = null,
    val regionId: String? = null,
)

/** mode = save | test_then_save. */
data class SearchCustomEditPlan(
    val mode: String,
    val clearsKey: Boolean,
    val showKeyField: Boolean,
    val resnapshot: Boolean,
    val requirePreset: Boolean,
)

/** fields: field → hint key (second half of `form.*`); warnings: address → cleartextLan. */
data class SearchFormFieldErrors(val fields: Map<String, String>, val warnings: Map<String, String>, val blocking: Boolean)

/**
 * External search services: UI rules for the settings page. Ported function by function from scripts/lib/search-settings.mjs,
 * the UI renders only from the results of these functions.
 */
object SearchSettings {
    /** Selectable values and default for the detail page "Advanced › Results per request". */
    val RESULT_COUNT_CHOICES: List<Int> = listOf(3, 5, 8, 10)
    const val RESULT_COUNT_DEFAULT = 5

    /** Official documentation opened by "View setup guide" when SearXNG does not have the JSON format enabled. */
    const val SEARXNG_SETUP_GUIDE_URL = "https://docs.searxng.org/admin/settings/settings_search.html"

    private val CURRENCY_PREFIX = mapOf("CNY" to "¥", "USD" to "$")

    private fun priceLabel(currency: String?, amount: String?): String? {
        val p = currency?.let(CURRENCY_PREFIX::get) ?: return null
        return amount?.let { "$p$it" }
    }

    private fun regionsOf(entry: JsonObject?): List<JsonObject> =
        SearchJson.array(entry?.get("regions"))?.mapNotNull { it as? JsonObject }.orEmpty()

    /** Price summary of a site; if the site is not found the first site is used. price = null means do not show a unit price (non-monetary pricing). */
    fun searchPriceSummary(entry: JsonObject?, regionId: String?): SearchPriceSummary {
        val regions = regionsOf(entry)
        val region = regions.firstOrNull { SearchJson.string(it["id"]) == regionId } ?: regions.firstOrNull()
            ?: return SearchPriceSummary(null, null, null, null, 0)
        val p = SearchJson.obj(region["pricing"])
        val label = priceLabel(SearchJson.string(p?.get("currency")), SearchJson.string(p?.get("amount")))
        val price = label?.let { SearchPrice(SearchJson.string(p?.get("unit")), it) }
        val f = SearchJson.obj(p?.get("free"))
        val cardRequired = SearchJson.isTrue(f?.get("cardRequired"))
        val free = when (SearchJson.string(f?.get("kind"))) {
            "monthly_credits" -> SearchJson.safeInteger(f?.get("amount"))
                ?.let { SearchFreeAllowance("monthly_credits", it, null, cardRequired) }
            "monthly_usd" -> priceLabel("USD", SearchJson.string(f?.get("amount")))
                ?.let { SearchFreeAllowance("monthly_usd", null, it, cardRequired) }
            else -> null
        }
        return SearchPriceSummary(
            regionId = SearchJson.string(region["id"]),
            price = price,
            billing = SearchJson.string(p?.get("billing")),
            free = free,
            otherRegionCount = regions.size - 1,
        )
    }

    /**
     * Add sheet grouping: an entry that has reuse and a connection with the same providerKind whose address resolves to a site → reuse (take the first, site decided by the connection);
     * the rest go into domestic / overseas by group, taking the first site; empty groups are omitted. Already added presets carry addedServiceRef.
     * [entries] are the entries in the adopted catalog that passed validation and are not withdrawn (catalog order).
     */
    fun searchAddSheetSections(
        catalogAvailable: Boolean,
        entries: List<JsonObject>,
        connections: List<SearchConnectionRef>,
        services: List<SearchServiceRef>,
    ): SearchAddSheet {
        if (!catalogAvailable) return SearchAddSheet("unavailable", emptyList())
        val buckets = linkedMapOf<String, MutableList<SearchAddRow>>("reuse" to mutableListOf(), "domestic" to mutableListOf(), "overseas" to mutableListOf())
        for (e in entries) {
            val id = SearchJson.string(e["id"]) ?: continue
            val added = services.firstOrNull { it.kind == SavedSearchService.KIND_PRESET && it.serviceId == id }?.id
            val reuseKind = SearchJson.string(SearchJson.obj(e["reuse"])?.get("providerKind"))
            var conn: SearchConnectionRef? = null
            var region: String? = null
            if (reuseKind != null) {
                for (c in connections) {
                    if (c.providerKind != reuseKind) continue
                    val r = SearchCatalog.regionForConnection(e, c.baseUrl)
                    if (r != null) {
                        conn = c
                        region = r
                        break
                    }
                }
            }
            val row = SearchAddRow(
                serviceId = id,
                regionId = region ?: regionsOf(e).firstOrNull()?.let { SearchJson.string(it["id"]) },
                connectionRef = conn?.id,
                connectionName = conn?.name,
                addedServiceRef = added,
            )
            val group = SearchJson.string(e["group"])
            when {
                conn != null -> buckets.getValue("reuse") += row
                group == "domestic" || group == "overseas" -> buckets.getValue(group) += row
            }
        }
        val sections = buckets.filterValues { it.isNotEmpty() }.map { (k, rows) -> SearchAddSection(k, rows.toList()) }
        return SearchAddSheet("available", sections)
    }

    /**
     * Status at the top of list rows and the detail page. Preset order: catalog unavailable → withdrawn / not in catalog → host changed → reused connection gone → own key missing → ready;
     * custom only has ready (keySource is own / none depending on whether a key exists).
     */
    fun searchServiceRowState(
        service: SearchRowServiceInput,
        catalogAvailable: Boolean,
        entry: JsonObject?,
        withdrawn: Boolean,
        connections: List<SearchConnectionRef>,
    ): SearchRowState {
        val custom = service.kind == SavedSearchService.KIND_CUSTOM
        val conn = if (service.keySource == SavedSearchService.KEY_SOURCE_CONNECTION) {
            connections.firstOrNull { it.id == service.connectionRef }
        } else {
            null
        }
        fun state(status: String, keySource: String = service.keySource) =
            SearchRowState(status, if (custom) "custom" else "preset", keySource, conn?.name)
        if (custom) return state("ready", if (service.hasKey) KEY_OWN else KEY_NONE)
        if (!catalogAvailable) return state("catalog_unavailable")
        if (withdrawn || entry == null) return state("withdrawn")
        if (SearchCatalog.presetHostCheck(service.boundHost, entry, service.regionId, withdrawn) == "host_changed") return state("host_changed")
        if (service.keySource == SavedSearchService.KEY_SOURCE_CONNECTION && conn == null) return state("connection_missing")
        if (service.keySource == SavedSearchService.KEY_SOURCE_OWN && !service.hasKey) return state("needs_key")
        return state("ready")
    }

    /** Default service: the stored default id if it still exists, otherwise the earliest in storage order; empty list = null. */
    fun resolveDefaultSearchService(serviceIds: List<String>, storedDefault: String?): String? {
        if (storedDefault != null && storedDefault in serviceIds) return storedDefault
        return serviceIds.firstOrNull()
    }

    /** Sentences on the consent page "Please confirm before enabling": custom has "cannot be verified" as its first sentence, Web adds one about relaying, the last sentence differs between preset / custom. */
    fun searchConsentLines(kind: String, platform: String, serviceName: String?, host: String?): List<SearchConsentLine> {
        val custom = kind == SavedSearchService.KIND_CUSTOM
        val lines = mutableListOf<SearchConsentLine>()
        if (custom) lines += SearchConsentLine("customUnverified", mapOf("host" to host))
        lines += if (custom) SearchConsentLine("sendsQueryCustom", emptyMap()) else SearchConsentLine("sendsQuery", mapOf("name" to serviceName))
        lines += if (custom) SearchConsentLine("billingCustom", emptyMap()) else SearchConsentLine("billing", mapOf("name" to serviceName))
        if (platform == "web") lines += SearchConsentLine("webForwarded", emptyMap())
        lines += if (custom) SearchConsentLine("testOnceSave", emptyMap()) else SearchConsentLine("testOnce", emptyMap())
        return lines
    }

    // Action for a failed test in settings: a switch-service class has nowhere to go in settings, so it falls back to "Retry", and a delisted one has no action
    private val TEST_ACTIONS = mapOf(
        "update_key" to "update_key",
        "top_up" to "top_up",
        "check_settings" to "check_settings",
        "view_setup_guide" to "view_setup_guide",
        "reconfirm" to "reconfirm",
        "retry" to "retry",
        "retry_later" to "retry",
        "switch_service" to "retry",
    )

    /** How a test result is displayed: 0 results also counts as passed; duration rounded to 0.1 s; a failure gives the error card's main sentence and the settings action. */
    fun searchTestPresentation(outcome: SearchTestOutcome): SearchTestPresentation = when (outcome) {
        is SearchTestOutcome.Ok -> SearchTestPresentation.Passed(
            count = outcome.count,
            // Same as JS Math.round: .5 rounds up
            latencyTenths = Math.floorDiv(maxOf(0L, outcome.latencyMs) + 50, 100),
        )
        is SearchTestOutcome.Error -> SearchTestPresentation.Failed(
            errorClass = outcome.errorClass,
            headline = outcome.card?.headline ?: "service_error",
            action = if (outcome.errorClass == "service_withdrawn") "none" else TEST_ACTIONS[outcome.card?.primaryAction] ?: "retry",
        )
    }

    // Validation error code → form field and hint key (`form.*`)
    private val FIELD_OF: Map<String, Pair<String, String>> = mapOf(
        "name_empty" to ("name" to "nameEmpty"),
        "name_too_long" to ("name" to "nameTooLong"),
        "address_invalid" to ("address" to "addressInvalid"),
        "scheme_not_allowed" to ("address" to "addressInvalid"),
        "address_has_query" to ("address" to "addressInvalid"),
        "http_public_not_allowed" to ("address" to "httpPublic"),
        "http_not_allowed_on_web" to ("address" to "httpOnWeb"),
        "private_address_on_web" to ("address" to "privateOnWeb"),
        "port_not_allowed_on_web" to ("address" to "portOnWeb"),
        "address_unresolved" to ("address" to "addressUnresolved"),
        "protocol_invalid" to ("protocol" to "protocolInvalid"),
        "preset_unavailable" to ("protocol" to "presetUnavailable"),
        "mapping_missing" to ("mapping" to "mappingIncomplete"),
        "method_invalid" to ("method" to "mappingIncomplete"),
        "auth_invalid" to ("auth" to "mappingIncomplete"),
        "header_name_invalid" to ("auth" to "headerName"),
        "query_field_invalid" to ("query" to "pathInvalid"),
        "count_field_invalid" to ("count" to "pathInvalid"),
        "get_has_body" to ("method" to "getBody"),
        "too_many_static_params" to ("params" to "tooManyParams"),
        "static_key_invalid" to ("params" to "pathInvalid"),
        "static_value_invalid" to ("params" to "paramValue"),
        "template_rejected" to ("params" to "template"),
        "results_path_invalid" to ("results" to "pathInvalid"),
        "title_path_invalid" to ("title" to "pathInvalid"),
        "url_path_invalid" to ("url" to "pathInvalid"),
        "snippet_path_invalid" to ("snippet" to "pathInvalid"),
        "site_path_invalid" to ("site" to "pathInvalid"),
        "date_path_invalid" to ("date" to "pathInvalid"),
        "path_conflict" to ("query" to "pathConflict"),
        "key_empty" to ("key" to "keyEmpty"),
        "key_invalid" to ("key" to "keyInvalid"),
    )

    /** Field hints on form "Continue" / "Save": only the first one per field is kept; cleartext_lan is only a warning. An unregistered error code throws (same as the reference implementation). */
    fun customFormFieldErrors(errors: List<String>, warnings: List<String>): SearchFormFieldErrors {
        val fields = linkedMapOf<String, String>()
        for (code in errors) {
            val hit = FIELD_OF[code] ?: throw IllegalArgumentException("unmapped form error $code")
            fields.putIfAbsent(hit.first, hit.second)
        }
        val w = if ("cleartext_lan" in warnings) mapOf("address" to "cleartextLan") else emptyMap()
        return SearchFormFieldErrors(fields, w, errors.isNotEmpty())
    }

    /** Stored result count: anything not among the allowed choices (missing, old data, hand-edited) falls back to the default 5. */
    fun searchResultCount(stored: Int?): Int = if (stored != null && stored in RESULT_COUNT_CHOICES) stored else RESULT_COUNT_DEFAULT

    /** Display name: a custom service uses its own name; a preset falls back catalog displayName -> stored name -> serviceId (an empty string counts as missing, like JS ||). */
    fun searchServiceDisplayName(kind: String, name: String?, serviceId: String?, catalogDisplayName: String?): String {
        if (kind == SavedSearchService.KIND_CUSTOM) return name ?: ""
        return catalogDisplayName?.takeIf { it.isNotEmpty() } ?: name?.takeIf { it.isNotEmpty() } ?: serviceId?.takeIf { it.isNotEmpty() } ?: ""
    }

    /** Local partition migration: carry over the source's effective default only when the target had no services and that service did migrate; a target that already has services is left alone. */
    fun migratedDefaultSearchService(
        accountServiceIds: List<String>,
        guestServiceIds: List<String>,
        guestStoredDefault: String?,
        migratedIds: List<String>,
    ): SearchMigratedDefault {
        if (accountServiceIds.isNotEmpty()) return SearchMigratedDefault(false)
        val guestDefault = resolveDefaultSearchService(guestServiceIds, guestStoredDefault)
        return if (guestDefault != null && guestDefault in migratedIds) SearchMigratedDefault(true, guestDefault) else SearchMigratedDefault(false)
    }

    /**
     * Saving an edited custom service: when the origin changed, clear the key and show the key field; when the path / protocol / manual mapping / same_as reference changed, test before saving;
     * a name-only change is saved directly. An unchanged same_as reference keeps the snapshot and does not require the preset to be available; a changed one (or a switch to same_as) re-snapshots and requires the preset to be available.
     */
    fun customServiceEditPlan(before: SearchCustomEditSide, after: SearchCustomEditSide): SearchCustomEditPlan {
        val originChanged = SearchCustomService.keyBindingOrigin(before.address) != SearchCustomService.keyBindingOrigin(after.address)
        val addressChanged = (before.address ?: "").let(SearchJson::jsTrim) != (after.address ?: "").let(SearchJson::jsTrim)
        val protocolChanged = before.protocol != after.protocol
        val sameAs = after.protocol == "same_as"
        val referenceChanged = sameAs && (protocolChanged || before.presetId != after.presetId || before.regionId != after.regionId)
        // Same comparison as JSON.stringify: kotlinx toString preserves key order
        val mappingChanged = after.protocol == "manual" && before.mapping.toString() != after.mapping.toString()
        val needsTest = addressChanged || protocolChanged || referenceChanged || mappingChanged
        return SearchCustomEditPlan(
            mode = if (needsTest) "test_then_save" else "save",
            clearsKey = originChanged,
            showKeyField = originChanged,
            resnapshot = referenceChanged,
            requirePreset = referenceChanged,
        )
    }

    private const val KEY_OWN = "own"
    private const val KEY_NONE = "none"
}
