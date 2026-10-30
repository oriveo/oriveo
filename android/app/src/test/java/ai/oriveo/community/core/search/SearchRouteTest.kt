package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.obj
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Test

/** Web row, web card and this turn's route (contract sections 4 / 4a / 5): each case compared with the expect in web-route-resolution.v1.json. */
class SearchRouteTest {
    private val doc = SearchContractFixtures.load("search-contracts/web-route-resolution.v1.json")

    /** This app's bundled catalog snapshot (the source of truth for model-contracts/search_catalog_view.v1.json packed into the APK). */
    private val builtinCatalog = SearchContractFixtures.load("search-contracts/search_catalog_view.v1.json")
        .getValue("data").jsonObject

    private fun input(c: JsonObject) = c.getValue("input").jsonObject

    private fun expect(c: JsonObject) = c.getValue("expect").jsonObject

    private fun caseId(c: JsonObject) = str(c["caseId"])!!

    private fun nonNull(e: JsonElement?): JsonElement? = e?.takeIf { it != JsonNull }

    private fun selectable(e: JsonElement?): List<SelectableSearchService> = (e as? JsonArray).orEmpty().map {
        val o = it.jsonObject
        SelectableSearchService(str(o["id"])!!, str(o["status"])!!)
    }

    private fun stored(e: JsonElement?): SearchSourceStored? = nonNull(e)?.let { SearchSourceStored.fromJson(it) }

    private fun storedOrNull(e: JsonElement?): SearchSourceStored? = stored(e)

    private fun args(e: JsonElement?): Map<String, String?> =
        (e as? JsonObject).orEmpty().mapValues { str(it.value) }

    private fun text(e: JsonElement?): WebSearchCardText? =
        obj(nonNull(e))?.let { WebSearchCardText(str(it["key"])!!, args(it["args"])) }

    private fun action(e: JsonElement?): WebSearchCardAction? =
        obj(nonNull(e))?.let { WebSearchCardAction(str(it["key"])!!, args(it["args"]), str(it["action"])!!) }

    @Test
    fun SRCH_ROUTE_01() {
        val all = cases(doc, "cases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val actual = resolveWebSearchRoute(
                WebSearchRouteInput(
                    form = str(i["form"])!!,
                    nativeWeb = str(i["nativeWeb"]),
                    relayWebRecord = str(i["relayWebRecord"]),
                    toolCall = str(i["toolCall"]) ?: "unknown",
                    webOn = bool(i["webOn"]) == true,
                    externalServices = int(i["externalServices"]) ?: 0,
                    reusableConnection = bool(i["reusableConnection"]) == true,
                    method = str(i["method"]),
                ),
            )
            val expected = WebSearchRoute(
                row = str(e["row"])!!,
                path = str(e["path"])!!,
                primaryAction = str(e["primaryAction"]),
                secondaryAction = str(e["secondaryAction"]),
                sourceAction = str(e["sourceAction"]),
                fragmentAttached = bool(e["fragmentAttached"]),
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_02() {
        val all = cases(doc, "turnCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val actual = resolveSearchTurnPath(
                SearchTurnInput(
                    path = str(i["path"])!!,
                    thinkingOn = bool(i["thinkingOn"]),
                    continuationStateAvailable = bool(i["continuationStateAvailable"]),
                    upstreamRejectedTools = bool(i["upstreamRejectedTools"]),
                    thinkingWithTools = str(i["thinkingWithTools"]),
                    hostMaxSteps = int(i["hostMaxSteps"]),
                ),
            )
            val expected = SearchTurnPath(
                path = str(e["path"])!!,
                fallbackReason = str(e["fallbackReason"]),
                noticeOnce = bool(e["noticeOnce"])!!,
                requestHasNativeSearchFields = bool(e["requestHasNativeSearchFields"])!!,
                requestHasWebSearchTool = bool(e["requestHasWebSearchTool"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_03() {
        val all = cases(doc, "selectableCases")
        val m = Mismatches()
        for (c in all) {
            m.check(caseId(c), bool(expect(c)["selectable"]), searchServiceSelectable(str(input(c)["status"])!!))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_04() {
        val all = cases(doc, "oneTapCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = oneTapReuseTarget(
                catalogAvailable = bool(i["catalogAvailable"])!!,
                entries = i.getValue("serviceIds").jsonArray.map { SearchContractFixtures.catalogEntry(builtinCatalog, str(it)!!) },
                connections = (i["connections"] as? JsonArray).orEmpty().map {
                    val o = it.jsonObject
                    SearchConnectionRef(str(o["id"])!!, str(o["name"]) ?: "", str(o["providerKind"]), str(o["baseUrl"]))
                },
                currentProviderKind = str(i["currentProviderKind"]),
            )
            val expected = obj(nonNull(expect(c)["target"]))?.let {
                OneTapReuseTarget(str(it["serviceId"])!!, str(it["regionId"])!!, str(it["connectionRef"])!!, str(it["connectionName"]))
            }
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_05() {
        val all = cases(doc, "sourceCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val actual = resolveSearchSource(
                stored = stored(i["stored"]),
                modelKey = str(i["modelKey"])!!,
                selectable = selectable(i["selectable"]),
                defaultServiceId = str(i["defaultServiceId"]),
            )
            val expected = SearchSourceResolution(
                method = str(e["method"])!!,
                serviceId = str(e["serviceId"]),
                notice = obj(nonNull(e["notice"]))?.let { SearchSourceNotice(str(it["fromName"])!!) },
                nextStored = storedOrNull(e["nextStored"]),
                changed = bool(e["changed"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_06() {
        val all = cases(doc, "sourceUpdateCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val ev = i.getValue("event").jsonObject
            val event = when (val type = str(ev["type"])) {
                "pick_native" -> SearchSourceEvent.PickNative
                "pick_service" -> SearchSourceEvent.PickService(str(ev["serviceId"])!!, str(ev["serviceName"]))
                "acknowledge_notice" -> SearchSourceEvent.AcknowledgeNotice
                "disarm" -> SearchSourceEvent.Disarm
                else -> error("unknown event $type")
            }
            val actual = updateSearchSource(stored(i["stored"]), str(i["modelKey"])!!, event)
            m.check(caseId(c), storedOrNull(expect(c)["nextStored"]), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_07() {
        val all = cases(doc, "pickerCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = searchSourcePickerItems(
                nativeCapable = bool(i["nativeCapable"])!!,
                selectable = selectable(i["selectable"]),
                defaultServiceId = str(i["defaultServiceId"]),
                method = str(i["method"]) ?: "default",
                serviceId = str(i["serviceId"]),
            )
            val expected = expect(c).getValue("items").jsonArray.map {
                val o = it.jsonObject
                when (val kind = str(o["kind"])) {
                    "native" -> SearchSourcePickerItem.Native(bool(o["selected"])!!)
                    "service" -> SearchSourcePickerItem.Service(
                        str(o["serviceId"])!!,
                        bool(o["isDefault"])!!,
                        str(o["status"])!!,
                        bool(o["selected"])!!,
                    )
                    "add" -> SearchSourcePickerItem.Add
                    else -> error("unknown item $kind")
                }
            }
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    private fun route(r: JsonObject) = WebSearchRoute(
        row = str(r["row"])!!,
        path = str(r["path"])!!,
        primaryAction = str(r["primaryAction"]),
        secondaryAction = str(r["secondaryAction"]),
        sourceAction = str(r["sourceAction"]),
        fragmentAttached = bool(r["fragmentAttached"]),
    )

    private fun card(e: JsonObject) = if (bool(e["existing"]) == true) {
        WebSearchCardPresentation(existing = true)
    } else {
        WebSearchCardPresentation(
            existing = false,
            toggle = bool(e["toggle"])!!,
            status = text(e["status"]),
            notes = (e["notes"] as? JsonArray).orEmpty().map { text(it)!! },
            link = action(e["link"]),
            cta = action(e["cta"]),
            secondary = action(e["secondary"]),
        )
    }

    private fun pickerItems(e: JsonElement?): List<SearchSourcePickerItem> = (e as? JsonArray).orEmpty().map {
        val o = it.jsonObject
        when (val kind = str(o["kind"])) {
            "native" -> SearchSourcePickerItem.Native(bool(o["selected"])!!)
            "service" -> SearchSourcePickerItem.Service(str(o["serviceId"])!!, bool(o["isDefault"])!!, str(o["status"])!!, bool(o["selected"])!!)
            "add" -> SearchSourcePickerItem.Add
            else -> error("unknown item $kind")
        }
    }

    private fun sourceResolution(e: JsonObject) = SearchSourceResolution(
        method = str(e["method"])!!,
        serviceId = str(e["serviceId"]),
        notice = obj(nonNull(e["notice"]))?.let { SearchSourceNotice(str(it["fromName"])!!) },
        nextStored = storedOrNull(e["nextStored"]),
        changed = bool(e["changed"])!!,
    )

    @Test
    fun SRCH_ROUTE_09() {
        val all = cases(doc, "stateCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val f = i.getValue("facts").jsonObject
            val actual = resolveWebSearchState(
                WebSearchStateInput(
                    facts = WebSearchFacts(
                        form = str(f["form"])!!,
                        recipeWeb = str(f["recipeWeb"]),
                        nativeRejected = bool(f["nativeRejected"]) == true,
                        relayStatus = str(f["relayStatus"]),
                        managedWebAvailable = bool(f["managedWebAvailable"]) == true,
                        toolCall = str(f["toolCall"]),
                    ),
                    panelWritable = bool(i["panelWritable"]) ?: true,
                    webOn = bool(i["webOn"]) == true,
                    modelKey = str(i["modelKey"])!!,
                    services = (i["services"] as? JsonArray).orEmpty().map {
                        val o = it.jsonObject
                        WebSearchStateService(str(o["id"])!!, str(o["name"]).orEmpty(), str(o["status"])!!)
                    },
                    defaultServiceId = str(i["defaultServiceId"]),
                    stored = stored(i["stored"]),
                    oneTapTarget = obj(nonNull(i["oneTapTarget"]))?.let {
                        OneTapReuseTarget(str(it["serviceId"])!!, str(it["regionId"])!!, str(it["connectionRef"])!!, str(it["connectionName"]))
                    },
                    oneTapServiceName = str(i["oneTapServiceName"]),
                ),
            )
            val expected = WebSearchState(
                nativeWeb = str(e["nativeWeb"]),
                route = route(e.getValue("route").jsonObject),
                source = sourceResolution(e.getValue("source").jsonObject),
                shapeMode = str(e["shapeMode"])!!,
                card = card(e.getValue("card").jsonObject),
                pickerItems = pickerItems(e["pickerItems"]),
                toggleOn = bool(e["toggleOn"])!!,
                chipLit = bool(e["chipLit"]),
                toggleControls = str(e["toggleControls"]),
                armHint = bool(e["armHint"])!!,
                nativeFieldsSuppressed = bool(e["nativeFieldsSuppressed"])!!,
                oneTapArms = bool(e["oneTapArms"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_ROUTE_08() {
        val all = cases(doc, "cardCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val r = i.getValue("route").jsonObject
            val route = WebSearchRoute(
                row = str(r["row"])!!,
                path = str(r["path"])!!,
                primaryAction = str(r["primaryAction"]),
                secondaryAction = str(r["secondaryAction"]),
                sourceAction = str(r["sourceAction"]),
                fragmentAttached = bool(r["fragmentAttached"]),
            )
            val source = obj(nonNull(i["source"]))?.let {
                if (str(it["kind"]) == "service") WebSearchCardSource.Service(str(it["name"]), str(it["status"])) else WebSearchCardSource.Native
            }
            val actual = webSearchCardPresentation(
                route = route,
                nativeWeb = str(i["nativeWeb"]) ?: "unavailable",
                webOn = bool(i["webOn"]) == true,
                source = source,
                oneTapServiceName = str(i["oneTapServiceName"]),
                notice = obj(nonNull(i["notice"]))?.let { WebSearchCardNotice(str(it["fromName"])!!) },
                armHint = bool(i["armHint"]) == true,
            )
            val expected = if (bool(e["existing"]) == true) {
                WebSearchCardPresentation(existing = true)
            } else {
                WebSearchCardPresentation(
                    existing = false,
                    toggle = bool(e["toggle"])!!,
                    status = text(e["status"]),
                    notes = (e["notes"] as? JsonArray).orEmpty().map { text(it)!! },
                    link = action(e["link"]),
                    cta = action(e["cta"]),
                    secondary = action(e["secondary"]),
                )
            }
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CALL_01() {
        val all = cases(doc, "callCases")
        val m = Mismatches()
        for (c in all) {
            val legs = input(c).getValue("legs").jsonArray.map { leg ->
                leg.jsonArray.map { call ->
                    SearchCallAttempts(
                        (call.jsonObject["attempts"] as? JsonArray).orEmpty().map { a ->
                            int(a)?.let { SearchAttempt.Status(it) } ?: SearchAttempt.Failure(str(a)!!)
                        },
                    )
                }
            }
            val e = expect(c)
            val expected = SearchCallsPlan(
                requestsSent = int(e["requestsSent"])!!,
                calls = e.getValue("calls").jsonArray.map {
                    val o = it.jsonObject
                    SearchCallPlan(int(o["leg"])!!, int(o["call"])!!, int(o["requests"])!!, str(o["outcome"])!!)
                },
            )
            m.check(caseId(c), expected, planSearchCalls(legs))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CALL_02() {
        val all = cases(doc, "regenerateCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val actual = regenerateSearchPolicy(str(i["action"])!!, bool(i["previousResultsPersisted"]) == true)
            m.check(caseId(c), RegenerateSearchPolicy(bool(e["reusePrevious"])!!, bool(e["newSearchesAllowed"])!!), actual)
        }
        m.assertNone(all.size)
    }
}
