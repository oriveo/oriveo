package ai.oriveo.community.core.search

import ai.oriveo.community.core.search.SearchContractFixtures.Mismatches
import ai.oriveo.community.core.search.SearchContractFixtures.bool
import ai.oriveo.community.core.search.SearchContractFixtures.cases
import ai.oriveo.community.core.search.SearchContractFixtures.catalogEntry
import ai.oriveo.community.core.search.SearchContractFixtures.int
import ai.oriveo.community.core.search.SearchContractFixtures.obj
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Custom service: form validation / key binding / "same as X" snapshot / request / response / catalog unavailable. */
class SearchCustomServiceContractTest {
    private val doc = SearchContractFixtures.load("search-contracts/custom-service.v1.json")
    private val catalog = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        .getValue("catalog").jsonObject

    private fun input(c: JsonObject) = c.getValue("input").jsonObject

    private fun expect(c: JsonObject) = c.getValue("expect").jsonObject

    @Test
    fun SRCH_CUS_01() {
        val all = cases(doc, "validateCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val actual = SearchCustomService.validateCustomSearchService(
                CustomSearchServiceForm(
                    name = str(i["name"]),
                    address = str(i["address"]),
                    protocol = str(i["protocol"]),
                    platform = str(i["platform"])!!,
                    addressClass = str(i["addressClass"]),
                    presetId = str(i["presetId"]),
                    catalogAvailable = bool(i["catalogAvailable"]),
                    presetActive = bool(i["presetActive"]),
                    manual = i["manual"],
                ),
            )
            val expected = CustomSearchServiceValidation(
                ok = bool(e["ok"])!!,
                errors = e.getValue("errors").jsonArray.map { str(it)!! },
                warnings = e.getValue("warnings").jsonArray.map { str(it)!! },
                origin = str(e["origin"]),
                requestPath = str(e["requestPath"]),
            )
            m.check(str(c["caseId"])!!, expected, actual)
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_02() {
        val all = cases(doc, "bindingCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            val old = str(i["old"])
            val next = str(i["next"])
            m.check(
                str(c["caseId"])!!,
                Triple(str(e["oldOrigin"]), str(e["nextOrigin"]), bool(e["clearsKey"])),
                Triple(
                    SearchCustomService.keyBindingOrigin(old),
                    SearchCustomService.keyBindingOrigin(next),
                    SearchCustomService.addressChangeClearsKey(old, next),
                ),
            )
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_03() {
        val all = cases(doc, "snapshotCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val entry = catalogEntry(catalog, str(i["serviceId"])!!)
            m.check(str(c["caseId"])!!, expect(c), SearchCustomService.snapshotPresetMapping(entry, str(i["regionId"])))
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_04() {
        val all = cases(doc, "requestCases")
        val m = Mismatches()
        for (c in all) {
            val id = str(c["caseId"])!!
            val i = input(c)
            val protocol = str(i["protocol"])
            val mapping = when (protocol) {
                "same_as" -> SearchCustomService.snapshotPresetMapping(catalogEntry(catalog, str(i["presetId"])!!), str(i["regionId"]))
                else -> obj(i["manual"])
            }
            val spec = SearchCustomService.customServiceSpec(protocol, mapping)
            val target = SearchCustomService.customServiceTarget(protocol, str(i["address"]))
            if (spec == null || target == null) {
                m.fail(id, "no spec or target")
                continue
            }
            val actual = SearchTransport.buildSearchRequest(spec, target, str(i["query"])!!, int(i["count"]), str(i["key"]))
            SearchContractFixtures.requestMismatch(expect(c), actual)?.let { m.fail(id, it) }
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_05() {
        val all = cases(doc, "responseCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val spec = SearchCustomService.customServiceSpec(str(i["protocol"]), obj(i["manual"]))
            if (spec == null) {
                m.fail(str(c["caseId"])!!, "no spec")
                continue
            }
            m.check(
                str(c["caseId"])!!,
                SearchContractFixtures.parseResultOf(expect(c)),
                SearchTransport.parseSearchResponse(spec, i["body"], int(i["count"])),
            )
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_06() {
        val all = cases(doc, "catalogUnavailableCases")
        val m = Mismatches()
        for (c in all) {
            val i = input(c)
            val e = expect(c)
            m.check(
                str(c["caseId"])!!,
                CatalogOutageBehavior(bool(e["usable"])!!, bool(e["creatable"])!!, str(e["presentation"])),
                SearchCustomService.catalogOutageBehavior(str(i["protocol"])!!, bool(i["saved"]) == true, bool(i["catalogAvailable"]) == true),
            )
        }
        m.assertNone(all.size)
    }

    @Test
    fun SRCH_CUS_07() {
        val all = cases(doc, "keyCases")
        val m = Mismatches()
        for (c in all) {
            val e = expect(c)
            m.check(
                str(c["caseId"])!!,
                SearchKeyNormalization(bool(e["ok"])!!, str(e["key"]), str(e["error"])),
                SearchCustomService.normalizeSearchKey(str(input(c)["raw"])),
            )
        }
        m.assertNone(all.size)
    }

    @Test
    fun `protocols, searxng spec and custom timeout match fixture constants`() {
        val constants = doc.getValue("constants").jsonObject
        assertEquals(setOf("protocols", "searxng", "timeoutSec", "webAllowedPorts"), constants.keys)
        assertEquals(constants.getValue("webAllowedPorts").jsonArray.map { int(it) }, SearchCustomService.WEB_ALLOWED_PORTS)
        assertEquals(constants.getValue("protocols").jsonArray.map { str(it) }, SearchCustomService.CUSTOM_PROTOCOLS)
        assertEquals(constants.getValue("searxng"), SearchCustomService.SEARXNG_SPEC)
        assertEquals(int(constants["timeoutSec"]), SearchCustomService.CUSTOM_TIMEOUT_SEC)
        assertEquals(int(constants["timeoutSec"]), SearchCustomService.customTimeoutSec)
    }
}
