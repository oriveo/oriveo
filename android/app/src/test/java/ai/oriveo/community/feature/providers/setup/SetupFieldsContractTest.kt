package ai.oriveo.community.feature.providers.setup

import android.content.Context
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import ai.oriveo.community.core.provider.transport.EndpointResolver
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.slot
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
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
 * Cross-platform shared-name cases: `shared/test-fixtures/provider-catalog/setup-fields.v1.json`.
 *
 * One `SETUP-FIELDS-<caseId>` per fixture caseId. Metadata goes through production decoding and filtering, the form through the production [ProviderSetupViewModel],
 * persistence through [prepareProviderForUpsert], and the computed value through the production [EndpointResolver.resolveBaseUrl].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupFieldsContractTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readFixture("shared/test-fixtures/provider-catalog/setup-fields.v1.json") }

    private val dispatcher = StandardTestDispatcher()
    private val context = mockk<Context>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        MetadataTestFixtures.clear()
        every { globalSnackbarManager.show(any()) } just runs
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        coEvery {
            appPreferencesRepository.completeOnboarding()
        } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    // ── decodeCases ──

    @Test fun `SETUP-FIELDS-keeps_trusted_template_option`() = decodeCase("keeps_trusted_template_option")
    @Test fun `SETUP-FIELDS-drops_unknown_placeholder`() = decodeCase("drops_unknown_placeholder")
    @Test fun `SETUP-FIELDS-drops_untrusted_template`() = decodeCase("drops_untrusted_template")
    @Test fun `SETUP-FIELDS-drops_undeclared_placeholder`() = decodeCase("drops_undeclared_placeholder")

    // ── formCases ──

    @Test fun `SETUP-FIELDS-plain_region_shows_no_field`() = formCase("plain_region_shows_no_field")
    @Test fun `SETUP-FIELDS-template_region_shows_field`() = formCase("template_region_shows_field")
    @Test fun `SETUP-FIELDS-invalid_underscore_blocks`() = formCase("invalid_underscore_blocks")
    @Test fun `SETUP-FIELDS-invalid_leading_hyphen_blocks`() = formCase("invalid_leading_hyphen_blocks")
    @Test fun `SETUP-FIELDS-invalid_dot_blocks`() = formCase("invalid_dot_blocks")
    @Test fun `SETUP-FIELDS-invalid_too_long_blocks`() = formCase("invalid_too_long_blocks")
    @Test fun `SETUP-FIELDS-valid_value_builds_base`() = formCase("valid_value_builds_base")
    @Test fun `SETUP-FIELDS-no_setup_fields_in_metadata`() = formCase("no_setup_fields_in_metadata")

    // ── resolveCases ──

    @Test fun `SETUP-FIELDS-template_change_follows_with_stored_value`() = resolveCase("template_change_follows_with_stored_value")
    @Test fun `SETUP-FIELDS-missing_value_uses_literal`() = resolveCase("missing_value_uses_literal")

    // The default address may also be a template: it goes through the same decoding filter as region options, and an unusable one is treated as not delivered and falls back to the built-in default.
    @Test
    fun `SETUP-FIELDS-default_template_untrusted_dropped`() {
        val untrusted = "https://{workspaceId}.example.com"
        applyMetadata(JsonObject(config() + ("defaultBaseURL" to JsonPrimitive(untrusted))))
        val decoded = MetadataClient.trustedPublicProviderConfig(ProviderKind.Qwen)!!.defaultBaseURL
        assertFalse(decoded, decoded.contains("example.com"))
        assertEquals(ProviderKind.Qwen.defaultBaseUrl, ProviderSetupCatalogResolver.current().defaultBaseUrl(ProviderKind.Qwen))
    }

    // ── Detail page (the detail page region picker also lists templates with placeholders, and selecting one shows a Workspace ID slot; for the form see SetupFieldsDetailTest) ──

    @Test
    fun `SETUP-FIELDS-detail page region options include template options`() {
        applyMetadata(config())
        assertEquals(listOf("sg", "sg-ws"), ProviderSetupCopy.regionOptions(ProviderKind.Qwen).map { it.id })
        assertEquals(listOf("sg", "sg-ws"), ProviderSetupCopy.detailRegionOptions(ProviderKind.Qwen).map { it.id })
    }

    // ── helpers ──

    private fun decodeCase(caseId: String) {
        val case = case("decodeCases", caseId)
        applyMetadata(patchedConfig(case))
        val ids = ProviderSetupCatalogResolver.current().regionOptions(ProviderKind.Qwen).map { it.id }
        case["expectRegionIds"]?.jsonArray?.let { expected ->
            assertEquals(caseId, expected.map { it.jsonPrimitive.content }, ids)
        }
        case.string("dropped")?.let { dropped -> assertFalse(caseId, dropped in ids) }
    }

    private fun formCase(caseId: String) = runTest(dispatcher) {
        val case = case("formCases", caseId)
        applyMetadata(patchedConfig(case))
        val baseSlot = slot<String?>()
        val sourceSlot = slot<String?>()
        val valuesSlot = slot<Map<String, String>?>()
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.Qwen,
                apiKey = "sk-fixture",
                baseUrl = captureNullable(baseSlot),
                isAdditionalInstance = false,
                endpointSource = captureNullable(sourceSlot),
                setupValues = captureNullable(valuesSlot),
            )
        } returns Provider(id = "sf", kind = ProviderKind.Qwen)

        val viewModel = ProviderSetupViewModel(
            context = context,
            providerRepository = providerRepository,
            appPreferencesRepository = appPreferencesRepository,
            globalSnackbarManager = globalSnackbarManager,
            catalogProvider = ProviderSetupCatalogResolver::current,
        )
        viewModel.selectKind(ProviderKind.Qwen)
        viewModel.selectRegion(viewModel.regionOptions.first { it.id == case.string("regionId") })
        case.string("value")?.let { viewModel.updateSetupField("workspaceId", it) }
        viewModel.apiKey = "sk-fixture"

        assertEquals(caseId, case.getValue("expectFields").jsonArray.map { it.jsonPrimitive.content }, viewModel.setupFieldIds)
        val expectSubmit = case.getValue("expectSubmit").jsonPrimitive.content.toBoolean()
        assertEquals(caseId, expectSubmit, viewModel.canSubmit)
        if (!expectSubmit) return@runTest

        viewModel.submitApiKey()
        advanceUntilIdle()
        assertTrue(caseId, baseSlot.isCaptured)
        val persisted = prepareProviderForUpsert(
            Provider(
                id = "sf",
                kind = ProviderKind.Qwen,
                baseUrlText = baseSlot.captured,
                endpointSource = if (sourceSlot.isCaptured) sourceSlot.captured else null,
                setupValues = if (valuesSlot.isCaptured) valuesSlot.captured else null,
            ),
        )
        val expect = case["expect"]?.jsonObject ?: return@runTest
        assertEquals(caseId, expect.string("endpointSource"), persisted.endpointSource)
        assertEquals(caseId, expect.string("baseURLText"), persisted.baseUrlText)
        expect["setupValues"]?.jsonObject?.let { values ->
            assertEquals(caseId, values.mapValues { it.value.jsonPrimitive.content }, persisted.setupValues)
        }
    }

    private fun resolveCase(caseId: String) {
        val case = case("resolveCases", caseId)
        val stored = case.getValue("stored").jsonObject
        val provider = Provider(
            id = "sf-$caseId",
            kind = ProviderKind.Qwen,
            baseUrlText = stored.string("baseURLText"),
            endpointSource = stored.string("endpointSource"),
            setupValues = (stored["setupValues"] as? JsonObject)?.mapValues { it.value.jsonPrimitive.content },
        )
        applyMetadata(regionPatched(config(), case.getValue("metadataPatch").jsonObject))
        assertEquals(caseId, case.string("expectBaseURL"), EndpointResolver.resolveBaseUrl(provider))
    }

    private fun case(group: String, caseId: String): JsonObject =
        fixture.getValue(group).jsonArray.map { it.jsonObject }.first { it.string("caseId") == caseId }

    private fun config(): JsonObject = fixture.getValue("config").jsonObject

    /** Fixture configPatch: top-level keys are replaced as a whole, null = not delivered. */
    private fun patchedConfig(case: JsonObject): JsonObject {
        val patch = case["configPatch"]?.jsonObject ?: return config()
        val merged = config().toMutableMap()
        patch.forEach { (key, value) -> if (value is JsonNull) merged.remove(key) else merged[key] = value }
        return JsonObject(merged)
    }

    /** Fixture metadataPatch: `regionOptions.<id>.baseURL`. */
    private fun regionPatched(config: JsonObject, patch: JsonObject): JsonObject {
        val regions = config.getValue("regionOptions").jsonArray.map { it.jsonObject }.toMutableList()
        patch.forEach { (path, value) ->
            val parts = path.split('.')
            require(parts.size == 3 && parts[0] == "regionOptions" && parts[2] == "baseURL") { "unsupported patch $path" }
            val index = regions.indexOfFirst { it.string("id") == parts[1] }
            regions[index] = JsonObject(regions[index] + ("baseURL" to value))
        }
        return JsonObject(config + ("regionOptions" to JsonArray(regions)))
    }

    private fun applyMetadata(config: JsonObject) {
        val entry = JsonObject(config + ("displayName" to JsonPrimitive("Qwen")))
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[$entry]}""")
        // Production decoding really got this provider (otherwise the assertions below would test the built-in fallback table).
        assertTrue(MetadataClient.publicProviderConfig(ProviderKind.Qwen) != null)
    }

    private fun JsonObject.string(key: String): String? =
        get(key)?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

    private fun readFixture(relativePath: String): JsonObject {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }
}
