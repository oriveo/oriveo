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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Test

/** Settings page UI rules (contract section 11a): each case compared with the expect in search-settings.v1.json. */
class SearchSettingsTest {
    private val doc = SearchContractFixtures.load("search-contracts/search-settings.v1.json")
    private val catalog = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        .getValue("catalog").jsonObject

    private fun input(c: JsonObject) = c.getValue("input").jsonObject

    private fun caseId(c: JsonObject) = str(c["caseId"])!!

    private fun entryOrNull(serviceId: String?): JsonObject? =
        catalog.getValue("services").jsonArray.map { it.jsonObject }.firstOrNull { str(it["id"]) == serviceId }

    private fun connections(e: JsonElement?): List<SearchConnectionRef> = (e as? JsonArray).orEmpty().map {
        val o = it.jsonObject
        SearchConnectionRef(str(o["id"])!!, str(o["name"])!!, str(o["providerKind"]), str(o["baseUrl"]))
    }

    private fun long(e: JsonElement?): Long? = (e as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.longOrNull

    @Test
    fun SRCH_SET_01() {
        val all = cases(doc, "addSheetCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = c.getValue("expect").jsonObject
            val actual = SearchSettings.searchAddSheetSections(
                catalogAvailable = bool(i["catalogAvailable"])!!,
                entries = i.getValue("serviceIds").jsonArray.map { SearchContractFixtures.catalogEntry(catalog, str(it)!!) },
                connections = connections(i["connections"]),
                services = i.getValue("services").jsonArray.map {
                    val o = it.jsonObject
                    SearchServiceRef(str(o["id"])!!, str(o["kind"])!!, str(o["serviceId"]))
                },
            )
            val expected = SearchAddSheet(
                presets = str(e["presets"])!!,
                sections = e.getValue("sections").jsonArray.map { s ->
                    val so = s.jsonObject
                    SearchAddSection(
                        str(so["id"])!!,
                        so.getValue("rows").jsonArray.map { r ->
                            val ro = r.jsonObject
                            SearchAddRow(str(ro["serviceId"])!!, str(ro["regionId"]), str(ro["connectionRef"]), str(ro["connectionName"]), str(ro["addedServiceRef"]))
                        },
                    )
                },
                custom = bool(e["custom"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_02() {
        val all = cases(doc, "priceCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = c.getValue("expect").jsonObject
            val actual = SearchSettings.searchPriceSummary(entryOrNull(str(i["serviceId"])), str(i["regionId"]))
            val expected = SearchPriceSummary(
                regionId = str(e["regionId"]),
                price = obj(e["price"])?.let { SearchPrice(str(it["unit"]), str(it["label"])!!) },
                billing = str(e["billing"]),
                free = obj(e["free"])?.let { SearchFreeAllowance(str(it["kind"])!!, long(it["count"]), str(it["amountLabel"]), bool(it["cardRequired"])!!) },
                otherRegionCount = int(e["otherRegionCount"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_03() {
        val all = cases(doc, "rowCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val s = i.getValue("service").jsonObject
            val e = c.getValue("expect").jsonObject
            val actual = SearchSettings.searchServiceRowState(
                service = SearchRowServiceInput(
                    kind = str(s["kind"])!!,
                    serviceId = str(s["serviceId"]),
                    regionId = str(s["regionId"]),
                    boundHost = str(s["boundHost"]),
                    keySource = str(s["keySource"])!!,
                    connectionRef = str(s["connectionRef"]),
                    hasKey = bool(s["hasKey"]) == true,
                ),
                catalogAvailable = bool(i["catalogAvailable"])!!,
                entry = entryOrNull(str(s["serviceId"])),
                withdrawn = bool(i["withdrawn"]) == true,
                connections = connections(i["connections"]),
            )
            val expected = SearchRowState(str(e["status"])!!, str(e["label"])!!, str(e["keySource"])!!, str(e["connectionName"]))
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_04() {
        val all = cases(doc, "defaultCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = SearchSettings.resolveDefaultSearchService(
                serviceIds = i.getValue("serviceIds").jsonArray.map { str(it)!! },
                storedDefault = str(i["storedDefault"]),
            )
            m.check(caseId(c), str(c.getValue("expect").jsonObject["defaultId"]), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_05() {
        val all = cases(doc, "consentCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = SearchSettings.searchConsentLines(str(i["kind"])!!, str(i["platform"])!!, str(i["serviceName"]), str(i["host"]))
            val expected = c.getValue("expect").jsonArray.map { l ->
                val o = l.jsonObject
                SearchConsentLine(str(o["key"])!!, o.getValue("args").jsonObject.mapValues { str(it.value) })
            }
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_06() {
        val all = cases(doc, "testCases")
        val m = Mismatches()
        for (c in all) {
            val o = input(c).getValue("outcome").jsonObject
            val outcome = if (bool(o["ok"]) == true) {
                SearchTestOutcome.Ok(int(o["count"])!!, long(o["latencyMs"])!!)
            } else {
                val err = obj(o["error"])
                val card = obj(err?.get("card"))
                SearchTestOutcome.Error(
                    str(err?.get("errorClass")),
                    card?.let { SearchErrorCard(str(it["headline"]) ?: "", str(it["primaryAction"]) ?: "", str(it["secondaryAction"])) },
                )
            }
            val e = c.getValue("expect").jsonObject
            val expected = when (str(e["state"])) {
                "passed" -> SearchTestPresentation.Passed(int(e["count"])!!, long(e["latencyTenths"])!!)
                else -> SearchTestPresentation.Failed(str(e["errorClass"]), str(e["headline"])!!, str(e["action"])!!)
            }
            m.check(caseId(c), expected, SearchSettings.searchTestPresentation(outcome))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_07() {
        val all = cases(doc, "formCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = SearchSettings.customFormFieldErrors(
                errors = i.getValue("errors").jsonArray.map { str(it)!! },
                warnings = i.getValue("warnings").jsonArray.map { str(it)!! },
            )
            val e = c.getValue("expect").jsonObject
            val expected = SearchFormFieldErrors(
                fields = e.getValue("fields").jsonObject.mapValues { str(it.value)!! },
                warnings = e.getValue("warnings").jsonObject.mapValues { str(it.value)!! },
                blocking = bool(e["blocking"])!!,
            )
            m.check(caseId(c), expected, actual)
        }
        m.assertNone(all.size)
        // Constants match the fixture
        val k = doc.getValue("constants").jsonObject
        assertEquals(k.getValue("resultCountChoices").jsonArray.map { int(it) }, SearchSettings.RESULT_COUNT_CHOICES)
        assertEquals(int(k["resultCountDefault"]), SearchSettings.RESULT_COUNT_DEFAULT)
        assertEquals(str(k["searxngSetupGuideUrl"]), SearchSettings.SEARXNG_SETUP_GUIDE_URL)
    }

    @Test
    fun SRCH_SET_08() {
        val all = cases(doc, "countCases")
        val m = Mismatches()
        for (c in all) {
            m.check(caseId(c), int(c.getValue("expect").jsonObject["count"]), SearchSettings.searchResultCount(int(input(c)["stored"])))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_09() {
        val all = cases(doc, "nameCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val actual = SearchSettings.searchServiceDisplayName(str(i["kind"])!!, str(i["name"]), str(i["serviceId"]), str(i["catalogDisplayName"]))
            m.check(caseId(c), str(c.getValue("expect").jsonObject["name"]), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_10() {
        val all = cases(doc, "migrateDefaultCases")
        val m = Mismatches()
        fun ids(e: JsonElement?) = e!!.jsonArray.map { str(it)!! }
        for (c in all) {
            val i = input(c)
            val actual = SearchSettings.migratedDefaultSearchService(
                ids(i["accountServiceIds"]),
                ids(i["guestServiceIds"]),
                str(i["guestStoredDefault"]),
                ids(i["migratedIds"]),
            )
            val e = c.getValue("expect").jsonObject
            m.check(caseId(c), SearchMigratedDefault(bool(e["set"])!!, str(e["id"])), actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_SET_11() {
        val all = cases(doc, "editCases")
        val m = Mismatches()
        fun side(o: JsonObject) = SearchCustomEditSide(
            name = str(o["name"]),
            address = str(o["address"]),
            protocol = str(o["protocol"]),
            mapping = o["mapping"],
            presetId = str(o["presetId"]),
            regionId = str(o["regionId"]),
        )
        for (c in all) {
            val i = input(c)
            val e = c.getValue("expect").jsonObject
            val expected = SearchCustomEditPlan(
                mode = str(e["mode"])!!,
                clearsKey = bool(e["clearsKey"])!!,
                showKeyField = bool(e["showKeyField"])!!,
                resnapshot = bool(e["resnapshot"])!!,
                requirePreset = bool(e["requirePreset"])!!,
            )
            m.check(caseId(c), expected, SearchSettings.customServiceEditPlan(side(i.getValue("before").jsonObject), side(i.getValue("after").jsonObject)))
        }
        m.assertNone(all.size)
    }
}
