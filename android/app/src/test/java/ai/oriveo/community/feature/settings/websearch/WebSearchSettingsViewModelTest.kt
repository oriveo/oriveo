package ai.oriveo.community.feature.settings.websearch

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.search.AdoptedSearchCatalog
import ai.oriveo.community.core.search.CatalogServiceState
import ai.oriveo.community.core.search.CatalogSnapshot
import ai.oriveo.community.core.search.SavedSearchService
import ai.oriveo.community.core.search.SearchCatalogRepository
import ai.oriveo.community.core.search.SearchContractFixtures
import ai.oriveo.community.core.search.SearchCustomService
import ai.oriveo.community.core.search.SearchExecution
import ai.oriveo.community.core.search.SearchExecutor
import ai.oriveo.community.core.search.SearchServiceStore
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/** Settings > Web search ViewModel: connect-page sites, editing same_as, deleting the default (fake executor / catalog, real store). */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class WebSearchSettingsViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val uid = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
    private lateinit var prefs: SharedPreferences
    private lateinit var store: SearchServiceStore
    private val executor = mockk<SearchExecutor>()
    private val catalog = mockk<SearchCatalogRepository>(relaxed = true)
    private val providers = mockk<ProviderRepository>()
    private val preferences = mockk<AppPreferencesRepository>(relaxed = true)

    private val catalogDoc: JsonObject = SearchContractFixtures.load("search-contracts/search_catalog_contract.v1.json")
        .getValue("catalog").jsonObject
    private fun entry(id: String) = SearchContractFixtures.catalogEntry(catalogDoc, id)

    // The Kimi connection is on the international site (api.moonshot.ai -> intl); the first Kimi site in the catalog is cn
    private val kimiConnection = Provider(
        id = "conn-kimi",
        kind = ProviderKind.Moonshot,
        apiKey = "sk-connection",
        baseUrlText = "api.moonshot.ai/v1",
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        prefs = RuntimeEnvironment.getApplication().getSharedPreferences("web-search-vm-test", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        store = SearchServiceStore(prefs)
        every { providers.observeAll() } returns flowOf(listOf(kimiConnection))
        catalogAvailable(true)
        coEvery { executor.executePreset(any(), any(), any(), any(), any(), any(), any(), any()) } returns SearchExecution.Empty
        coEvery { executor.executeCustom(any(), any(), any(), any(), any(), any(), any()) } returns SearchExecution.Empty
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun catalogAvailable(available: Boolean) {
        val ids = catalogDoc.getValue("services").jsonArray.map { SearchContractFixtures.str(it.jsonObject["id"])!! }
        every { catalog.current() } returns if (available) {
            AdoptedSearchCatalog(catalogDoc, CatalogSnapshot(1L, ids.map { CatalogServiceState(it, "active") }), "builtin")
        } else {
            null
        }
        every { catalog.presetsWithdrawn() } returns false
        every { catalog.entry(any()) } answers { if (available) entry(firstArg()) else null }
        every { catalog.serviceState(any()) } returns null
    }

    private fun TestScope.viewModel(): WebSearchSettingsViewModel =
        WebSearchSettingsViewModel(store, catalog, executor, providers, preferences).also {
            it.io = dispatcher
            advanceUntilIdle()
        }

    private fun regionOfLastPresetTest(): String {
        val region = slot<String>()
        coVerify { executor.executePreset(any(), capture(region), any(), any(), any(), any(), any(), any()) }
        return region.captured
    }

    @Test
    fun `reuse mode always tests the site the connection fixed, whatever site was picked`() = runTest(dispatcher) {
        val vm = viewModel()
        val draft = PresetDraft("kimi", regionId = "intl", connectionRef = "conn-kimi", connectionName = "Kimi")

        // Picked cn in paste mode, then switched back to reuse: still tests against the connection's intl site, using the connection's key
        vm.testAndSavePreset(draft, useConnection = true, pastedKey = "", regionId = "cn", query = "q")
        advanceUntilIdle()

        val key = slot<String>()
        coVerify { executor.executePreset(any(), "intl", "api.moonshot.ai", false, capture(key), any(), any(), any()) }
        assertEquals("sk-connection", key.captured)
        assertEquals("intl", store.services(uid).single().regionId)
    }

    @Test
    fun `paste mode defaults to the catalog's first site`() = runTest(dispatcher) {
        val vm = viewModel()
        val draft = PresetDraft("kimi", regionId = "intl", connectionRef = "conn-kimi", connectionName = "Kimi")

        vm.testAndSavePreset(draft, useConnection = false, pastedKey = "sk-pasted", regionId = null, query = "q")
        advanceUntilIdle()

        assertEquals("cn", regionOfLastPresetTest())
        val saved = store.services(uid).single()
        assertEquals("cn", saved.regionId)
        assertEquals("sk-pasted", store.key(uid, saved.id))
    }

    @Test
    fun `renaming a same_as service saves without a test while the catalog is unavailable`() = runTest(dispatcher) {
        store.save(
            uid,
            SavedSearchService(
                id = "c1",
                kind = SavedSearchService.KIND_CUSTOM,
                name = "Old",
                address = "https://93.184.216.34/search",
                protocol = "same_as",
                mapping = SearchCustomService.snapshotPresetMapping(entry("tavily"), null),
            ),
        )
        catalogAvailable(false)
        val vm = viewModel()
        val draft = vm.customDraftOf("c1")!!.copy(name = "New")

        var ok: Boolean? = null
        vm.validateCustom(draft) { ok = it }
        advanceUntilIdle()
        assertEquals(true, ok)
        assertTrue(vm.onlyNameChanged(draft))
        vm.saveCustomName(draft)
        advanceUntilIdle()

        assertEquals("New", store.service(uid, "c1")!!.name)
        coVerify(exactly = 0) { executor.executeCustom(any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `deleting the default service clears the stored default key`() = runTest(dispatcher) {
        val preset = SavedSearchService(id = "a", kind = SavedSearchService.KIND_PRESET, serviceId = "tavily", regionId = "global", boundHost = "api.tavily.com")
        store.save(uid, preset)
        store.save(uid, preset.copy(id = "b"))
        store.setDefaultServiceId(uid, "b")
        assertTrue(prefs.all.keys.any { it.startsWith("defaultService") })
        val vm = viewModel()

        assertEquals("Tavily", vm.defaultAfterDelete("b"))
        vm.delete("b")
        advanceUntilIdle()

        assertFalse(prefs.all.keys.any { it.startsWith("defaultService") })
        assertEquals("a", store.defaultServiceId(uid))
        assertNull(store.service(uid, "b"))
    }

    @Test
    fun `the default service opens its detail with use-as-default on and locked`() = runTest(dispatcher) {
        val preset = SavedSearchService(id = "a", kind = SavedSearchService.KIND_PRESET, serviceId = "tavily", regionId = "global", boundHost = "api.tavily.com")
        store.save(uid, preset)
        store.save(uid, preset.copy(id = "b"))
        store.setDefaultServiceId(uid, "b")
        val vm = viewModel()

        // Detail page switch: checked = isDefault, enabled = !isDefault; both come from the same source as the list page's Default label
        val items = vm.state.value.services.associateBy { it.saved.id }
        assertTrue(items.getValue("b").isDefault)
        assertFalse(items.getValue("a").isDefault)
        assertEquals(store.defaultServiceId(uid), vm.state.value.services.single { it.isDefault }.saved.id)
    }
}
