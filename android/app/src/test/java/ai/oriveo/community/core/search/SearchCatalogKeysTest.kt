package ai.oriveo.community.core.search

import android.content.Context
import ai.oriveo.community.core.search.SearchContractFixtures.str
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** The production trusted public key verifies the bundled snapshot; the production load path reads the snapshot from APK assets and adopts it; if the network keeps failing, the previous catalog is kept. */
@RunWith(RobolectricTestRunner::class)
class SearchCatalogKeysTest {
    private val view = SearchContractFixtures.load("search-contracts/search_catalog_view.v1.json")
    private val data = view.getValue("data").jsonObject
    private val expectedIds = data.getValue("services").jsonArray.map { str(it.jsonObject["id"])!! }

    @Test
    fun `production keys accept the shared view snapshot with seven active services`() {
        val r = SearchCatalog.acceptSearchCatalog(CatalogAdoptionState(0, null), data, "builtin", SearchCatalogKeys.production)
        assertTrue(r.reason, r.accepted)
        assertEquals(emptyList<CatalogSkippedEntry>(), r.skipped)
        assertEquals(7, r.current!!.services.size)
        assertTrue(r.current!!.services.all { it.status == "active" && it.limits != null })
        assertEquals(expectedIds, r.current!!.services.map { it.id })
    }

    @Test
    fun `production load path reads bundled asset and adopts it once`() {
        val context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences(SearchCatalogRepository.PREFS_FILE_NAME, Context.MODE_PRIVATE).edit().clear().commit()
        val repo = SearchCatalogRepository(context)

        assertNotNull(repo.loadLocal())
        val adopted = repo.current()!!

        assertEquals(SearchCatalogRepository.SOURCE_BUILTIN, adopted.source)
        assertEquals((data.getValue("revision") as JsonPrimitive).content.toLong(), adopted.snapshot.revision)
        assertEquals(expectedIds, adopted.snapshot.services.map { it.id })
        assertEquals(adopted.snapshot.revision, repo.maxSeenRevision())
        assertNotNull(repo.entry("deepseek"))
    }

    @Test
    fun `cache then network keep previous on unchanged or tampered documents without rewriting`() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val prefs = context.getSharedPreferences("search-catalog-repo-test", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val viewText = view.toString()
        var served = viewText
        val repo = SearchCatalogRepository(
            prefs = prefs,
            transport = { SearchCatalogFetch(200, "\"e1\"", served) },
            builtin = SearchCatalogRepository.assetReader(context),
            trustedKeys = SearchCatalogKeys.production,
        )
        repo.loadLocal()
        var writes = 0
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> writes += 1 }
        prefs.registerOnSharedPreferenceChangeListener(listener)

        val unchanged = repo.refresh()!!
        assertEquals("unchanged", unchanged.reason)
        assertEquals("only the ETag is recorded", 1, writes)
        assertEquals("unchanged", repo.refresh()!!.reason)
        assertEquals("second identical merge writes nothing", 1, writes)

        val services = data.getValue("services").jsonArray
        val tamperedFirst = JsonObject(services[0].jsonObject + ("displayName" to JsonPrimitive("Tampered")))
        val tampered = JsonObject(
            data + ("revision" to JsonPrimitive(99)) +
                ("services" to kotlinx.serialization.json.JsonArray(listOf(tamperedFirst) + services.drop(1))),
        )
        served = tampered.toString()
        val rejected = repo.refresh()!!
        assertFalse(rejected.accepted)
        assertEquals("signature_invalid", rejected.reason)
        assertEquals(SearchCatalogRepository.SOURCE_BUILTIN, repo.current()!!.source)
        assertEquals(1, writes)
        prefs.unregisterOnSharedPreferenceChangeListener(listener)

        // Restart: the cached raw text is adopted first; the bundled snapshot with the same revision does not overwrite it
        val restarted = SearchCatalogRepository(prefs, { error("offline") }, SearchCatalogRepository.assetReader(context), SearchCatalogKeys.production)
        assertEquals(SearchCatalogRepository.SOURCE_CACHE, restarted.loadLocal()!!.source)
        assertEquals(null, restarted.refresh())
    }

    private fun repo(prefsName: String, trusted: Map<String, String>, builtin: () -> String?, transport: suspend (String?) -> SearchCatalogFetch) =
        RuntimeEnvironment.getApplication().getSharedPreferences(prefsName, Context.MODE_PRIVATE).let { prefs ->
            prefs.edit().clear().commit()
            prefs to SearchCatalogRepository(prefs, transport, builtin, trusted)
        }

    @Test
    fun `404 withdraws presets across restarts until a 200 is adopted, and ETag is only sent with a catalog in hand`() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val sentTags = mutableListOf<String?>()
        var status = 404
        val transport: suspend (String?) -> SearchCatalogFetch = { tag ->
            sentTags += tag
            SearchCatalogFetch(status, "\"e2\"", if (status == 200) view.toString() else null)
        }
        val (prefs, first) = repo("search-catalog-withdraw-test", SearchCatalogKeys.production, SearchCatalogRepository.assetReader(context), transport)
        prefs.edit().putString("catalog.etag", "\"stale\"").commit()
        assertNotNull(first.loadLocal())

        assertEquals(null, first.refresh())
        assertEquals("ETag is sent while a catalog is adopted", "\"stale\"", sentTags.last())
        assertTrue(first.presetsWithdrawn())
        assertEquals(null, first.current())
        assertEquals(null, first.entry("deepseek"))

        // Restart: neither cache nor bundled is used; with no adopted catalog, no If-None-Match is sent
        val restarted = SearchCatalogRepository(prefs, transport, SearchCatalogRepository.assetReader(context), SearchCatalogKeys.production)
        assertEquals(null, restarted.loadLocal())
        status = 503
        assertEquals(null, restarted.refresh())
        assertEquals(null, sentTags.last())
        assertTrue("503 keeps the withdrawal", restarted.presetsWithdrawn())

        // After a rollback, a 200 with the same revision -> recovers (does not get stuck on "unavailable" because it shares a revision with the cache / anti-rollback watermark)
        val sameRevision = (data.getValue("revision") as JsonPrimitive).content.toLong()
        assertEquals(sameRevision, restarted.maxSeenRevision())
        status = 200
        val adopted = restarted.refresh()!!
        assertTrue(adopted.reason, adopted.accepted)
        assertEquals(sameRevision, adopted.current!!.revision)
        assertFalse(restarted.presetsWithdrawn())
        assertNotNull(restarted.entry("deepseek"))
        assertEquals("unchanged", restarted.refresh()!!.reason)
        assertFalse(restarted.presetsWithdrawn())
    }

    @Test
    fun `entries skipped by validation cannot be looked up`() = runBlocking {
        val contract = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        val testKey = contract.getValue("testKeys").jsonObject.let { mapOf(str(it["keyId"])!! to str(it["publicKeyB64"])!!) }
        val case = SearchContractFixtures.cases(contract, "acceptCases").first { str(it["caseId"]) == "skip.static_param_not_whitelisted" }
        val incoming = case.getValue("incoming").toString()
        val (_, repo) = repo("search-catalog-skip-test", testKey, { null }, { SearchCatalogFetch(200, null, incoming) })

        val result = repo.refresh()!!

        assertTrue(result.accepted)
        assertEquals(listOf(CatalogSkippedEntry("deepseek", "static_param_not_allowed")), result.skipped)
        assertEquals(null, repo.entry("deepseek"))
        assertNotNull(repo.entry("tavily"))
    }
}
