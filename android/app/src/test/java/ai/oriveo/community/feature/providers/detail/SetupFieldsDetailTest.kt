package ai.oriveo.community.feature.providers.detail

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Setup fields of the region selector on the official detail page:
 * the fixture `shared/test-fixtures/provider-catalog/setup-fields.v1.json` goes through production metadata decoding,
 * and the form and save go through the production [ProviderDetailViewModel], asserting the address / source / value it hands to the repository.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupFieldsDetailTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val dispatcher = StandardTestDispatcher()
    private val repository = mockk<ProviderRepository>()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        MetadataTestFixtures.clear()
        coEvery { repository.updateBaseUrl(any(), any(), any(), any()) } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    private val fixture: JsonObject by lazy {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        json.parseToJsonElement(File(repoRoot, "shared/test-fixtures/provider-catalog/setup-fields.v1.json").readText()).jsonObject
    }

    private fun applyMetadata() {
        val entry = JsonObject(fixture.getValue("config").jsonObject + ("displayName" to JsonPrimitive("Qwen")))
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[$entry]}""")
        assertTrue(MetadataClient.publicProviderConfig(ProviderKind.Qwen) != null)
    }

    private fun formCase(caseId: String): JsonObject =
        fixture.getValue("formCases").jsonArray.map { it.jsonObject }.first { it.getValue("caseId").jsonPrimitive.content == caseId }

    private fun qwen(
        baseUrl: String = "https://dashscope-intl.aliyuncs.com",
        endpointSource: String? = null,
        setupValues: Map<String, String>? = null,
    ) = Provider(
        id = "provider-1",
        kind = ProviderKind.Qwen,
        apiKey = "sk-fixture",
        apiKeyPreview = "sk-••ture",
        baseUrlText = baseUrl,
        endpointSource = endpointSource,
        setupValues = setupValues,
    )

    private fun TestScope.viewModel(provider: Provider): ProviderDetailViewModel {
        every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
        val vm = ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
            providerRepository = repository,
            appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            defaultDispatcher = dispatcher,
        )
        backgroundScope.launch { vm.provider.collect {} }
        advanceUntilIdle()
        return vm
    }

    @Test
    fun `SETUP-FIELDS-DETAIL-01 detail region picker lists the template option and validates Workspace ID`() = runTest(dispatcher) {
        applyMetadata()
        // New semantics: the detail page also lists template entries that contain placeholders.
        assertEquals(listOf("sg", "sg-ws"), ProviderSetupCopy.detailRegionOptions(ProviderKind.Qwen).map { it.id })
        val vm = viewModel(qwen())
        assertTrue(vm.canEditEndpoint(qwen()))

        vm.startEditEndpoint()
        assertEquals("sg", vm.selectedEndpointId)
        assertEquals(emptyList<String>(), vm.endpointSetupFieldIds)
        assertTrue(vm.canSaveEndpoint)

        vm.selectEndpoint("sg-ws")
        assertEquals(listOf(OfficialEndpointSource.WORKSPACE_ID), vm.endpointSetupFieldIds)
        assertFalse("empty value cannot be saved", vm.canSaveEndpoint)
        listOf("invalid_underscore_blocks", "invalid_leading_hyphen_blocks", "invalid_dot_blocks", "invalid_too_long_blocks").forEach { caseId ->
            vm.updateEndpointSetupField(OfficialEndpointSource.WORKSPACE_ID, formCase(caseId).getValue("value").jsonPrimitive.content)
            assertFalse(caseId, vm.canSaveEndpoint)
        }
        vm.saveEndpoint()
        advanceUntilIdle()
        coVerify(exactly = 0) { repository.updateBaseUrl(any(), any(), any(), any()) }

        vm.updateEndpointSetupField(OfficialEndpointSource.WORKSPACE_ID, formCase("valid_value_builds_base").getValue("value").jsonPrimitive.content)
        assertTrue(vm.canSaveEndpoint)
    }

    @Test
    fun `SETUP-FIELDS-DETAIL-02 saving a template writes base URL region source and setup values once`() = runTest(dispatcher) {
        applyMetadata()
        val expect = formCase("valid_value_builds_base").getValue("expect").jsonObject
        val vm = viewModel(qwen())

        vm.startEditEndpoint()
        vm.selectEndpoint("sg-ws")
        vm.updateEndpointSetupField(OfficialEndpointSource.WORKSPACE_ID, formCase("valid_value_builds_base").getValue("value").jsonPrimitive.content)
        vm.saveEndpoint()
        advanceUntilIdle()

        coVerify(exactly = 1) {
            repository.updateBaseUrl(
                "provider-1",
                expect.getValue("baseURLText").jsonPrimitive.content,
                expect.getValue("endpointSource").jsonPrimitive.content,
                expect.getValue("setupValues").jsonObject.mapValues { it.value.jsonPrimitive.content },
            )
        }
        assertFalse(vm.showEndpointEditor)
    }

    @Test
    fun `SETUP-FIELDS-DETAIL-02 reopening prefills the stored Workspace ID and plain regions keep the literal save`() = runTest(dispatcher) {
        applyMetadata()
        val stored = qwen(
            baseUrl = "https://ws-old.ap-southeast-1.maas.aliyuncs.com",
            endpointSource = OfficialEndpointSource.region("sg-ws"),
            setupValues = mapOf(OfficialEndpointSource.WORKSPACE_ID to "ws-old"),
        )
        val vm = viewModel(stored)

        vm.startEditEndpoint()
        assertEquals("sg-ws", vm.selectedEndpointId)
        assertEquals("ws-old", vm.endpointSetupValues[OfficialEndpointSource.WORKSPACE_ID])
        assertTrue(vm.canSaveEndpoint)

        // Non-template entries are still saved with the original address (without source and value; classified on persistence).
        vm.selectEndpoint("sg")
        vm.saveEndpoint()
        advanceUntilIdle()
        coVerify(exactly = 1) { repository.updateBaseUrl("provider-1", "https://dashscope-intl.aliyuncs.com", null, null) }
    }
}
