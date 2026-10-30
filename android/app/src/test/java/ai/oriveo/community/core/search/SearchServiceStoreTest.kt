package ai.oriveo.community.core.search

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Service list and keys: account partitioning and guest migration, key normalization, custom service key binding source, reused connections do not store a key, zero writes for identical content, excluded from any backup. */
@RunWith(RobolectricTestRunner::class)
class SearchServiceStoreTest {
    private lateinit var prefs: SharedPreferences
    private lateinit var store: SearchServiceStore

    @Before
    fun setUp() {
        prefs = RuntimeEnvironment.getApplication().getSharedPreferences("search-service-store-test", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        store = SearchServiceStore(prefs)
    }

    private val custom = SavedSearchService(
        id = "c1",
        kind = SavedSearchService.KIND_CUSTOM,
        name = "NAS",
        address = "https://a.example/v1/search",
        protocol = "searxng",
    )

    private val uid = "uid-1"
    private val guest = LOCAL_PARTITION_ID

    @Test
    fun `custom key survives a path change and is cleared when the origin changes`() {
        store.save(uid, custom)
        assertEquals(SearchKeyNormalization(true, "tok", null), store.setKey(uid, "c1", "  tok\n"))

        store.save(uid, custom.copy(address = "https://a.example/v2/search"))
        assertEquals("tok", store.key(uid, "c1"))

        store.save(uid, custom.copy(address = "https://a.example:8443/v2/search"))
        assertNull(store.key(uid, "c1"))
    }

    @Test
    fun `invalid key is not stored and leaves the previous key untouched`() {
        store.save(uid, custom)
        store.setKey(uid, "c1", "tok")
        assertEquals("key_invalid", store.setKey(uid, "c1", "tvly-\u5BC6\u94A5").error)
        assertEquals("key_empty", store.setKey(uid, "c1", " \t ").error)
        assertEquals("tok", store.key(uid, "c1"))
    }

    @Test
    fun `preset reusing a connection keeps only the reference and host reconfirm keeps the key`() {
        val preset = SavedSearchService(
            id = "p1",
            kind = SavedSearchService.KIND_PRESET,
            serviceId = "kimi",
            regionId = "cn",
            boundHost = "api.moonshot.cn",
        )
        store.save(uid, preset)
        store.setKey(uid, "p1", "sk")
        store.rebindPresetHost(uid, "p1", "api.moonshot.ai")
        assertEquals("api.moonshot.ai", store.service(uid, "p1")!!.boundHost)
        assertEquals("sk", store.key(uid, "p1"))

        store.save(uid, store.service(uid, "p1")!!.copy(keySource = SavedSearchService.KEY_SOURCE_CONNECTION, connectionRef = "provider-kimi"))
        assertNull(store.key(uid, "p1"))
        assertEquals("key_source_not_own", store.setKey(uid, "p1", "sk2").error)
        assertNull(store.key(uid, "p1"))
        assertEquals("provider-kimi", store.service(uid, "p1")!!.connectionRef)
    }

    @Test
    fun `partitions are isolated and guest services move into the account with their keys`() {
        store.save(guest, custom)
        store.setKey(guest, "c1", "tok")
        assertEquals(emptyList<SavedSearchService>(), store.services(uid))
        assertNull(store.key(uid, "c1"))

        assertEquals(1, store.migratePartition(guest, uid))

        assertEquals(listOf(custom), store.services(uid))
        assertEquals("tok", store.key(uid, "c1"))
        assertEquals(emptyList<SavedSearchService>(), store.services(guest))
        assertNull(store.key(guest, "c1"))
        assertEquals(0, store.migratePartition(guest, uid))
    }

    @Test
    fun `saving the same content twice writes nothing the second time`() {
        store.save(uid, custom)
        store.setKey(uid, "c1", "tok")
        var writes = 0
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> writes += 1 }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        store.save(uid, custom)
        store.setKey(uid, "c1", "tok")
        prefs.unregisterOnSharedPreferenceChangeListener(listener)
        assertEquals(0, writes)
    }

    private fun preset(id: String) = SavedSearchService(id = id, kind = SavedSearchService.KIND_PRESET, serviceId = "tavily", regionId = "global", boundHost = "api.tavily.com")

    @Test
    fun `default service follows the first added, the user's pick, and falls back after delete`() {
        assertNull(store.defaultServiceId(uid))
        store.save(uid, preset("a"))
        assertEquals("a", store.defaultServiceId(uid))
        store.save(uid, preset("b"))
        store.save(uid, preset("c"))
        assertEquals("a", store.defaultServiceId(uid))

        store.setDefaultServiceId(uid, "c")
        assertEquals("c", store.defaultServiceId(uid))
        store.setDefaultServiceId(uid, "missing")
        assertEquals("c", store.defaultServiceId(uid))

        // Deleting the default -> falls back per resolveDefaultSearchService to the earliest-added remaining service
        store.remove(uid, "c")
        val expected = SearchSettings.resolveDefaultSearchService(store.services(uid).map { it.id }, null)
        assertEquals(expected, store.defaultServiceId(uid))
        assertEquals("a", store.defaultServiceId(uid))
    }

    @Test
    fun `default id is partitioned per account, same value writes nothing, and migrates with the guest services`() {
        store.save(guest, preset("g1"))
        store.save(guest, preset("g2"))
        store.setDefaultServiceId(guest, "g2")
        store.save(uid, preset("u1"))
        assertEquals("u1", store.defaultServiceId(uid))
        assertEquals("g2", store.defaultServiceId(guest))

        var writes = 0
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> writes += 1 }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        store.setDefaultServiceId(guest, "g2")
        prefs.unregisterOnSharedPreferenceChangeListener(listener)
        assertEquals(0, writes)

        // Target already has services: keep the target's own default
        store.migratePartition(guest, uid)
        assertEquals("u1", store.defaultServiceId(uid))
        assertNull(store.defaultServiceId(guest))

        // Target is empty: the default moves over with the services
        store.save(guest, preset("g3"))
        store.save(guest, preset("g4"))
        store.setDefaultServiceId(guest, "g4")
        store.migratePartition(guest, "uid-2")
        assertEquals("g4", store.defaultServiceId("uid-2"))
    }

    @Test
    fun `result count is stored on the service record and defaults to null`() {
        store.save(uid, preset("a"))
        assertNull(store.service(uid, "a")!!.resultCount)
        store.save(uid, preset("a").copy(resultCount = 8))
        assertEquals(8, store.service(uid, "a")!!.resultCount)
        assertEquals(8, SearchServiceStore(prefs).service(uid, "a")!!.resultCount)
        assertNull(store.service("uid-2", "a"))
    }

    @Test
    fun `service and catalog prefs files are excluded from every backup path`() {
        var dir = java.io.File(System.getProperty("user.dir") ?: ".")
        while (!java.io.File(dir, "app/src/main/res/xml").isDirectory) {
            dir = dir.parentFile ?: error("Android project root not found")
        }
        val xml = java.io.File(dir, "app/src/main/res/xml")
        val legacy = java.io.File(xml, "backup_rules.xml").readText()
        val extraction = java.io.File(xml, "data_extraction_rules.xml").readText()
        for (name in listOf(SearchServiceStore.PREFS_FILE_NAME, SearchCatalogRepository.PREFS_FILE_NAME)) {
            val marker = Regex(Regex.escape("domain=\"sharedpref\" path=\"$name.xml\""))
            assertEquals(name, 1, marker.findAll(legacy).count())
            assertEquals(name, 2, marker.findAll(extraction).count())
        }
    }

    // ── Per-conversation search source (external search contract)──

    @Test
    fun `deleting a conversation removes its search source in every partition and nothing else`() {
        val picked = SearchSourceStored(mapOf("c1:m1" to "external"), "s1", "DeepSeek")
        store.setConversationSource(uid, "conv-a", picked)
        store.setConversationSource(guest, "conv-a", picked)
        store.setConversationSource(uid, "conv-b", picked)
        store.removeConversationSource("conv-a")
        assertNull(store.conversationSource(uid, "conv-a"))
        assertNull(store.conversationSource(guest, "conv-a"))
        assertEquals(picked, store.conversationSource(uid, "conv-b"))
    }

    @Test
    fun `guest to account migration carries conversation search sources without overwriting`() {
        val guestPick = SearchSourceStored(mapOf("c1:m1" to "external"), "s1", "DeepSeek")
        val accountPick = SearchSourceStored(mapOf("c1:m1" to "native"))
        store.setConversationSource(guest, "conv-a", guestPick)
        store.setConversationSource(guest, "conv-b", guestPick)
        store.setConversationSource(uid, "conv-b", accountPick)
        store.migratePartition(guest, uid)
        assertEquals(guestPick, store.conversationSource(uid, "conv-a"))
        assertEquals(accountPick, store.conversationSource(uid, "conv-b"))
        assertNull(store.conversationSource(guest, "conv-a"))
        assertNull(store.conversationSource(guest, "conv-b"))
    }
}
