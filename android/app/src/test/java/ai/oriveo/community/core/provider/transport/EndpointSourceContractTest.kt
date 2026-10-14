package ai.oriveo.community.core.provider.transport

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.util.DeterministicProviderId
import ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver
import ai.oriveo.community.feature.providers.setup.ProviderSetupCopy
import ai.oriveo.community.core.provider.BalanceQueryable
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.core.provider.ProviderBalanceRepository
import ai.oriveo.community.core.provider.ProviderKeyValidator
import java.time.Instant
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

/**
 * Same-named cases on all three platforms: `shared/test-fixtures/provider-catalog/endpoint-source.v1.json`.
 *
 * One `ENDPOINT-SOURCE-<caseId>` per fixture caseId. Metadata goes through production decoding ([MetadataTestFixtures.applyRaw]),
 * classification goes through [prepareProviderForUpsert] before persisting, and the live computation through the production [EndpointResolver.resolveBaseUrl].
 */
class EndpointSourceContractTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readFixture("shared/test-fixtures/provider-catalog/endpoint-source.v1.json") }

    @Before
    fun setUp() = MetadataTestFixtures.clear()

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    // ── classifyCases ──

    @Test fun `ENDPOINT-SOURCE-empty_is_default`() = classifyCase("empty_is_default")
    @Test fun `ENDPOINT-SOURCE-blank_is_default`() = classifyCase("blank_is_default")
    @Test fun `ENDPOINT-SOURCE-equal_to_default_is_default`() = classifyCase("equal_to_default_is_default")
    @Test fun `ENDPOINT-SOURCE-region_match_exact`() = classifyCase("region_match_exact")
    @Test fun `ENDPOINT-SOURCE-region_match_trailing_slash`() = classifyCase("region_match_trailing_slash")
    @Test fun `ENDPOINT-SOURCE-region_match_legacy_compat_suffix`() = classifyCase("region_match_legacy_compat_suffix")
    @Test fun `ENDPOINT-SOURCE-region_match_case_insensitive_host`() = classifyCase("region_match_case_insensitive_host")
    @Test fun `ENDPOINT-SOURCE-region_beats_default_when_equal`() = classifyCase("region_beats_default_when_equal")
    @Test fun `ENDPOINT-SOURCE-other_host_is_custom`() = classifyCase("other_host_is_custom")
    @Test fun `ENDPOINT-SOURCE-empty_with_regions_is_default`() = classifyCase("empty_with_regions_is_default")

    // ── resolveCases ──

    @Test fun `ENDPOINT-SOURCE-region_follows_metadata_change`() = resolveCase("region_follows_metadata_change")
    @Test fun `ENDPOINT-SOURCE-default_follows_metadata_change`() = resolveCase("default_follows_metadata_change")
    @Test fun `ENDPOINT-SOURCE-custom_keeps_literal`() = resolveCase("custom_keeps_literal")
    @Test fun `ENDPOINT-SOURCE-region_removed_falls_back_to_literal`() = resolveCase("region_removed_falls_back_to_literal")
    @Test fun `ENDPOINT-SOURCE-untrusted_metadata_falls_back_to_literal`() = resolveCase("untrusted_metadata_falls_back_to_literal")
    @Test fun `ENDPOINT-SOURCE-no_metadata_uses_literal`() = resolveCase("no_metadata_uses_literal")
    @Test fun `ENDPOINT-SOURCE-missing_source_is_classified_then_follows`() = resolveCase("missing_source_is_classified_then_follows")

    // ── writeCases ──

    @Test
    fun `ENDPOINT-SOURCE-setup_region_choice_writes_region`() {
        // The setup page's write goes through the ViewModel and has its own case in ProviderSetupViewModelTest; here we assert the repository's classification result before persisting.
        val case = case("writeCases", "setup_region_choice_writes_region")
        applyMetadata(configOf(case))
        val regionId = case.string("regionId")!!
        val regionBase = config(case).getValue("regionOptions").jsonArray
            .map { it.jsonObject }.first { it.string("id") == regionId }.string("baseURL")
        val persisted = prepareProviderForUpsert(provider(case, baseUrlText = regionBase, endpointSource = null))
        assertWrite(case, persisted)
    }

    @Test
    fun `ENDPOINT-SOURCE-setup_without_regions_writes_default`() {
        val case = case("writeCases", "setup_without_regions_writes_default")
        applyMetadata(configOf(case))
        val persisted = prepareProviderForUpsert(
            provider(case, baseUrlText = config(case).string("defaultBaseURL"), endpointSource = null),
        )
        assertWrite(case, persisted)
    }

    @Test
    fun `ENDPOINT-SOURCE-edit_base_reclassifies`() {
        val case = case("writeCases", "edit_base_reclassifies")
        applyMetadata(configOf(case))
        val before = provider(case, case.obj("before"))
        // Same path as ProviderRepository.updateBaseUrl: changing the address clears the source -> recomputed before persisting.
        val persisted = prepareProviderForUpsert(OfficialEndpointSource.withBaseUrlText(before, case.string("baseURLText")))
        assertWrite(case, persisted)
    }

    // ── Send path ──

    @Test
    fun `ENDPOINT-SOURCE-send path region source hits the metadata address after it changes`() {
        val case = case("resolveCases", "region_follows_metadata_change")
        val stored = provider(case, case.obj("stored"))
        applyMetadata(patched(config(case), case.obj("metadataPatch")))
        val urls = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                synchronized(urls) { urls += request.url.toString() }
                respond(
                    content = ByteReadChannel("data: [DONE]\n\n"),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        val model = AIModel(id = "qwen-plus", name = "qwen-plus")
        try {
            runCatching {
                runBlocking {
                    withTimeout(15_000) {
                        // The same argument as the ChatRepository send branch: the address is taken by source, not the literal baseUrlText.
                        QwenService(client, json, TransportRegistry(json)).sendMessageStream(
                            apiKey = "sk-es",
                            modelID = model.id,
                            messages = listOf(
                                ChatMessage(
                                    id = "es-msg",
                                    role = ChatRole.User,
                                    text = "Hello",
                                    providerKind = ProviderKind.Qwen,
                                    providerName = "Qwen",
                                    modelID = model.id,
                                    modelName = model.id,
                                    state = ChatMessageState.Delivered,
                                ),
                            ),
                            baseUrl = OfficialEndpointSource.effectiveBaseUrlText(stored),
                            supportsImageGen = false,
                            reasoningMode = ReasoningMode.Automatic,
                            webSearchEnabled = false,
                            requestOptions = ChatRequestOptions(activeModel = model),
                        ).collect { }
                    }
                }
            }
        } finally {
            client.close()
        }
        val url = synchronized(urls) { urls.firstOrNull() } ?: error("no request issued")
        assertTrue(url, url.startsWith(case.string("expectBaseURL")!! + "/"))
    }

    // ── Balance / Key validation path (official providers: every real request takes its address by source) ──

    @Test
    fun `ENDPOINT-SOURCE-key validation region source hits the metadata address after it changes`() {
        val case = case("resolveCases", "region_follows_metadata_change")
        val stored = provider(case, case.obj("stored"))
        applyMetadata(patched(config(case), case.obj("metadataPatch")))
        val urls = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                synchronized(urls) { urls += request.url.toString() }
                respond(content = ByteReadChannel("{}"), status = HttpStatusCode.OK)
            },
        )
        try {
            runBlocking { ProviderKeyValidator.validate(stored, "sk-es", client) }
        } finally {
            client.close()
        }
        val url = synchronized(urls) { urls.firstOrNull() } ?: error("no request issued")
        assertTrue(url, url.startsWith(case.string("expectBaseURL")!! + "/"))
    }

    @Test
    fun `ENDPOINT-SOURCE-balance default source hits the metadata address after it changes`() {
        val case = case("resolveCases", "default_follows_metadata_change")
        val stored = provider(case, case.obj("stored")).copy(apiKey = "sk-es")
        applyMetadata(patched(config(case), case.obj("metadataPatch")))
        val seen = mutableListOf<String?>()
        val service = object : BalanceQueryable {
            override suspend fun fetchBalance(apiKey: String, baseURL: String?): ProviderBalance {
                seen += baseURL
                return ProviderBalance(currency = "CNY", total = 1.0, fetchedAt = Instant.now())
            }
        }
        val repository = ProviderBalanceRepository(mapOf(stored.kind to service))
        runBlocking { repository.fetchBalance(stored, forceRefresh = true) }
        assertEquals(listOf<String?>(case.string("expectBaseURL")), seen)
    }

    // ── reconcileCases ──

    @Test fun `ENDPOINT-SOURCE-qwen_us_region_moves_to_sg`() = reconcileCase("qwen_us_region_moves_to_sg")
    @Test fun `ENDPOINT-SOURCE-qwen_us_literal_unclassified_moves_to_sg`() = reconcileCase("qwen_us_literal_unclassified_moves_to_sg")
    @Test fun `ENDPOINT-SOURCE-qwen_us_custom_literal_moves_to_sg`() = reconcileCase("qwen_us_custom_literal_moves_to_sg")
    @Test fun `ENDPOINT-SOURCE-qwen_us_without_metadata_moves_to_builtin_sg`() = reconcileCase("qwen_us_without_metadata_moves_to_builtin_sg")
    @Test fun `ENDPOINT-SOURCE-zhipu_cn_literal_default_pins_cn`() = reconcileCase("zhipu_cn_literal_default_pins_cn")
    @Test fun `ENDPOINT-SOURCE-zhipu_cn_literal_unclassified_pins_cn`() = reconcileCase("zhipu_cn_literal_unclassified_pins_cn")
    @Test fun `ENDPOINT-SOURCE-zhipu_empty_literal_follows_new_default`() = reconcileCase("zhipu_empty_literal_follows_new_default")
    @Test fun `ENDPOINT-SOURCE-zhipu_before_regions_stays_default`() = reconcileCase("zhipu_before_regions_stays_default")
    @Test fun `ENDPOINT-SOURCE-together_default_moves_to_ai`() = reconcileCase("together_default_moves_to_ai")
    @Test fun `ENDPOINT-SOURCE-together_unclassified_moves_to_ai`() = reconcileCase("together_unclassified_moves_to_ai")
    @Test fun `ENDPOINT-SOURCE-together_ai_untrusted_keeps_literal`() = reconcileCase("together_ai_untrusted_keeps_literal")
    @Test fun `ENDPOINT-SOURCE-together_custom_keeps_literal`() = reconcileCase("together_custom_keeps_literal")

    // ── identityCases ──

    @Test fun `ENDPOINT-SOURCE-identity_region_source_beats_moved_literal`() = identityCase("identity_region_source_beats_moved_literal")
    @Test fun `ENDPOINT-SOURCE-identity_unclassified_uses_literal`() = identityCase("identity_unclassified_uses_literal")
    @Test fun `ENDPOINT-SOURCE-identity_retired_us_literal_keeps_us`() = identityCase("identity_retired_us_literal_keeps_us")
    @Test fun `ENDPOINT-SOURCE-identity_zhipu_cn_ignores_metadata_regions`() = identityCase("identity_zhipu_cn_ignores_metadata_regions")
    @Test fun `ENDPOINT-SOURCE-identity_zhipu_intl_ignores_metadata_regions`() = identityCase("identity_zhipu_intl_ignores_metadata_regions")

    @Test
    fun `ENDPOINT-SOURCE-identity table equals fixture identityRegions`() {
        val expected = fixture.getValue("identityRegions").jsonObject.mapValues { (_, rows) ->
            rows.jsonArray.map { it.jsonObject }.map { DeterministicProviderId.IdentityRegion(it.string("id")!!, it.string("baseURL")!!) }
        }
        val actual = DeterministicProviderId.identityRegions.mapKeys { (kind, _) -> kind.rawValue }
        assertEquals(expected, actual)
    }

    // ── echoCases ──

    @Test fun `ENDPOINT-SOURCE-echo_region_source_after_metadata_moves_address`() = echoCase("echo_region_source_after_metadata_moves_address")
    @Test fun `ENDPOINT-SOURCE-echo_unclassified_uses_literal`() = echoCase("echo_unclassified_uses_literal")
    @Test fun `ENDPOINT-SOURCE-echo_source_region_not_in_catalog_uses_literal`() = echoCase("echo_source_region_not_in_catalog_uses_literal")
    @Test fun `ENDPOINT-SOURCE-echo_zhipu_cn_after_e3`() = echoCase("echo_zhipu_cn_after_e3")

    // ── regionPickerCases ──

    @Test fun `ENDPOINT-SOURCE-picker_zhipu_after_e3`() = pickerCase("picker_zhipu_after_e3")
    @Test fun `ENDPOINT-SOURCE-picker_zhipu_before_e3`() = pickerCase("picker_zhipu_before_e3")
    @Test fun `ENDPOINT-SOURCE-picker_together`() = pickerCase("picker_together")
    @Test fun `ENDPOINT-SOURCE-picker_qwen`() = pickerCase("picker_qwen")

    // ── builtInCases ──

    @Test fun `ENDPOINT-SOURCE-builtin_qwen_selectable_regions_drop_us`() = builtInCase("builtin_qwen_selectable_regions_drop_us")
    @Test fun `ENDPOINT-SOURCE-builtin_qwen_default_is_intl`() = builtInCase("builtin_qwen_default_is_intl")
    @Test fun `ENDPOINT-SOURCE-builtin_zhipu_has_no_regions`() = builtInCase("builtin_zhipu_has_no_regions")

    @Test
    fun `ENDPOINT-SOURCE-builtin_defaults_match_fixture`() {
        val case = case("builtInCases", "builtin_defaults_match_fixture")
        assertEquals("true", case.string("expectEqualsBuiltInDefaults"))
        val defaults = fixture.getValue("builtInDefaults").jsonObject
        case.getValue("kinds").jsonArray.map { it.jsonPrimitive.content }.forEach { name ->
            val kind = kindNamed(fixture.getValue("configs").jsonObject.getValue(name).jsonObject.string("kind")!!)
            // The third classification step compares against this built-in table (OfficialEndpointSource.classificationCatalog)
            assertEquals(name, defaults.string(name), OfficialEndpointSource.normalize(kind.defaultBaseUrl))
            assertEquals(
                name,
                defaults.string(name),
                OfficialEndpointSource.normalize(OfficialEndpointSource.classificationCatalog(kind).builtInDefaultBaseUrl),
            )
        }
    }

    // ── Send path (sendPath: true): the stored record is the pre-migration original, proving the migration ran in memory at request time ──

    @Test
    fun `ENDPOINT-SOURCE-SEND-qwen_us_region_moves_to_sg`() = sendCase("qwen_us_region_moves_to_sg") { client ->
        QwenService(client, json, TransportRegistry(json))
    }

    @Test
    fun `ENDPOINT-SOURCE-SEND-zhipu_cn_literal_default_pins_cn`() = sendCase("zhipu_cn_literal_default_pins_cn") { client ->
        ZhipuService(client, json, TransportRegistry(json))
    }

    @Test
    fun `ENDPOINT-SOURCE-SEND-together_default_moves_to_ai`() = sendCase("together_default_moves_to_ai") { client ->
        TogetherService(client, json)
    }

    // ── Endpoint source helpers ──

    private fun reconcileCase(caseId: String) {
        val case = case("reconcileCases", caseId)
        val stored = provider(case, case.obj("stored"))
        applyCaseMetadata(case)
        // What the startup backfill writes back is this result (ProviderRepository.backfillEndpointSource only persists to the DAO).
        val persisted = OfficialEndpointSource.startupBackfill(stored) ?: stored
        val expect = case.obj("expect")
        assertEquals(caseId, expect.string("endpointSource"), persisted.endpointSource)
        assertEquals(caseId, expect.string("baseURLText"), persisted.baseUrlText)
        // At request time the un-backfilled original record was used: the migration is likewise computed in memory first.
        assertEquals(caseId, case.string("expectRequestBaseURL"), EndpointResolver.resolveBaseUrl(stored))
        assertEquals(caseId, case.string("expectRequestBaseURL"), EndpointResolver.resolveBaseUrl(persisted))
    }

    private fun identityCase(caseId: String) {
        val case = case("identityCases", caseId)
        val stored = provider(case, case.obj("stored"))
        applyCaseMetadata(case)
        assertEquals(
            caseId,
            case.string("expectRegionId"),
            DeterministicProviderId.identityRegionId(stored.kind, stored.baseUrlText, stored.endpointSource),
        )
    }

    private fun echoCase(caseId: String) {
        val case = case("echoCases", caseId)
        val stored = provider(case, case.obj("stored"))
        applyCaseMetadata(case)
        assertEquals(
            caseId,
            case.string("expectRegionId"),
            ProviderSetupCopy.resolveRegionOption(stored.kind, stored.baseUrlText, stored.endpointSource)?.id,
        )
    }

    private fun pickerCase(caseId: String) {
        val case = case("regionPickerCases", caseId)
        applyCaseMetadata(case)
        val expected = case.string("expectShown") == "true"
        val catalog = ProviderSetupCatalogResolver.current()
        assertEquals(caseId, expected, catalog.usesConfigurableBaseUrl(kindOf(case)))
        assertEquals(caseId, expected, catalog.regionOptions(kindOf(case)).isNotEmpty())
    }

    private fun builtInCase(caseId: String) {
        val case = case("builtInCases", caseId)
        MetadataTestFixtures.clear()
        val kind = kindNamed(case.string("kind")!!)
        case["expectRegionIds"]?.let { ids ->
            assertEquals(caseId, ids.jsonArray.map { it.jsonPrimitive.content }, kind.regionOptions.map { it.id })
            assertEquals(caseId, ids.jsonArray.map { it.jsonPrimitive.content }, ProviderSetupCatalogResolver.current().regionOptions(kind).map { it.id })
        }
        case.string("expectDefaultMatchKey")?.let { key ->
            assertEquals(caseId, key, OfficialEndpointSource.normalize(kind.defaultBaseUrl))
        }
    }

    private fun sendCase(caseId: String, makeService: (HttpClient) -> ai.oriveo.community.core.provider.ProviderService) {
        val case = case("reconcileCases", caseId)
        assertEquals(caseId, "true", case.string("sendPath"))
        val stored = provider(case, case.obj("stored"))
        applyCaseMetadata(case)
        val urls = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                synchronized(urls) { urls += request.url.toString() }
                respond(
                    content = ByteReadChannel("data: [DONE]\n\n"),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        val model = AIModel(id = "es-model", name = "es-model")
        try {
            runCatching {
                runBlocking {
                    withTimeout(15_000) {
                        // The same argument as the ChatRepository send branch: the endpoint source resolver, not the literal baseUrlText.
                        makeService(client).sendMessageStream(
                            apiKey = "sk-es",
                            modelID = model.id,
                            messages = listOf(
                                ChatMessage(
                                    id = "es-msg",
                                    role = ChatRole.User,
                                    text = "Hello",
                                    providerKind = stored.kind,
                                    providerName = stored.kind.displayName,
                                    modelID = model.id,
                                    modelName = model.id,
                                    state = ChatMessageState.Delivered,
                                ),
                            ),
                            baseUrl = OfficialEndpointSource.effectiveBaseUrlText(stored),
                            supportsImageGen = false,
                            reasoningMode = ReasoningMode.Automatic,
                            webSearchEnabled = false,
                            requestOptions = ChatRequestOptions(activeModel = model),
                        ).collect { }
                    }
                }
            }
        } finally {
            client.close()
        }
        val url = synchronized(urls) { urls.firstOrNull() } ?: error("no request issued")
        val expectedHost = java.net.URI(case.string("expectRequestBaseURL")!!).host
        assertEquals(caseId, expectedHost, java.net.URI(url).host)
        assertTrue(url, url.startsWith(case.string("expectRequestBaseURL")!! + "/"))
    }

    /** metadataPatch: an object (keys with / without dots), `"absent"` (no metadata) or the name of a metadataPresets entry. */
    private fun applyCaseMetadata(case: JsonObject) {
        val patch = case["metadataPatch"]
        if (patch is JsonPrimitive) {
            val name = patch.content
            if (name == "absent") {
                MetadataTestFixtures.clear()
                return
            }
            applyMetadata(patched(config(case), fixture.getValue("metadataPresets").jsonObject.getValue(name).jsonObject))
            return
        }
        applyMetadata(patched(config(case), patch as JsonObject))
    }

    // ── helpers ──

    private fun classifyCase(caseId: String) {
        val case = case("classifyCases", caseId)
        applyMetadata(configOf(case))
        val persisted = prepareProviderForUpsert(provider(case, baseUrlText = case.string("baseURLText"), endpointSource = null))
        assertEquals(caseId, case.string("expect"), persisted.endpointSource)
    }

    private fun resolveCase(caseId: String) {
        val case = case("resolveCases", caseId)
        var stored = provider(case, case.obj("stored"))
        if (case["classifyWithBaseMetadataFirst"]?.jsonPrimitive?.contentOrNull == "true") {
            // An unclassified record is first classified by the metadata of the time and written back (the read-path write-back and pre-persist classification are the same function).
            applyMetadata(configOf(case))
            stored = OfficialEndpointSource.withClassifiedSource(stored)
        }
        val patch = case["metadataPatch"]
        if (patch is JsonPrimitive && patch.contentOrNull == "absent") {
            MetadataTestFixtures.clear()
        } else {
            applyMetadata(patched(config(case), patch as JsonObject))
        }
        case.string("expectEndpointSource")?.let { assertEquals(caseId, it, stored.endpointSource) }
        assertEquals(caseId, case.string("expectBaseURL"), EndpointResolver.resolveBaseUrl(stored))
    }

    private fun assertWrite(case: JsonObject, persisted: Provider) {
        val expect = case.obj("expect")
        assertEquals(case.string("caseId"), expect.string("endpointSource"), persisted.endpointSource)
        assertEquals(case.string("caseId"), expect.string("baseURLText"), persisted.baseUrlText)
    }

    private fun case(group: String, caseId: String): JsonObject =
        fixture.getValue(group).jsonArray.map { it.jsonObject }.first { it.string("caseId") == caseId }

    private fun config(case: JsonObject): JsonObject =
        fixture.getValue("configs").jsonObject.getValue(case.string("config")!!).jsonObject

    private fun configOf(case: JsonObject): JsonObject = config(case)

    private fun kindOf(case: JsonObject): ProviderKind = kindNamed(config(case).string("kind")!!)

    /** Fixture kind name to this platform's enum: `togetherAI` is Together's cross-platform rawValue. */
    private fun kindNamed(name: String): ProviderKind = when (name) {
        "qwen" -> ProviderKind.Qwen
        "deepseek" -> ProviderKind.DeepSeek
        "togetherAI" -> ProviderKind.Together
        "zhipu" -> ProviderKind.Zhipu
        else -> error("unknown config kind $name")
    }

    private fun provider(case: JsonObject, baseUrlText: String?, endpointSource: String?): Provider =
        Provider(id = "es-${case.string("caseId")}", kind = kindOf(case), baseUrlText = baseUrlText, endpointSource = endpointSource)

    private fun provider(case: JsonObject, stored: JsonObject): Provider =
        provider(case, stored.string("baseURLText"), stored.string("endpointSource"))

    /**
     * Fixture metadataPatch: `regionOptions.<id>` (null = delete), `regionOptions.<id>.baseURL`;
     * a `defaultBaseURL` / `trustedHosts` / `regionOptions` without dots is replaced as a whole value.
     */
    private fun patched(config: JsonObject, patch: JsonObject): JsonObject {
        var defaultBase = config.string("defaultBaseURL")
        var trustedHosts = config["trustedHosts"]
        var regions = config["regionOptions"]?.jsonArray?.map { it.jsonObject }?.toMutableList()
        patch.forEach { (path, value) ->
            val parts = path.split('.')
            when {
                parts == listOf("defaultBaseURL") -> defaultBase = value.jsonPrimitive.content
                parts == listOf("trustedHosts") -> trustedHosts = value
                parts == listOf("regionOptions") -> regions = value.jsonArray.map { it.jsonObject }.toMutableList()
                parts.size == 2 && parts[0] == "regionOptions" && value is JsonNull ->
                    regions?.removeAll { it.string("id") == parts[1] }
                parts.size == 3 && parts[0] == "regionOptions" && parts[2] == "baseURL" -> {
                    val index = regions!!.indexOfFirst { it.string("id") == parts[1] }
                    regions[index] = JsonObject(regions[index] + ("baseURL" to value))
                }
                else -> error("unsupported patch $path")
            }
        }
        return JsonObject(
            config + ("defaultBaseURL" to JsonPrimitive(defaultBase)) +
                (trustedHosts?.let { mapOf("trustedHosts" to it) } ?: emptyMap()) +
                (regions?.let { mapOf("regionOptions" to JsonArray(it)) } ?: emptyMap()),
        )
    }

    private fun applyMetadata(config: JsonObject) {
        val entry = buildJsonObject {
            config.forEach { (key, value) -> put(key, value) }
            put("displayName", config.string("kind"))
        }
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[$entry]}""")
    }

    private fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject

    private fun JsonObject.string(key: String): String? =
        (get(key) as? JsonElement)?.takeUnless { it is JsonNull }?.jsonPrimitive?.contentOrNull

    private fun readFixture(relativePath: String): JsonObject {
        val moduleDir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        val repoRoot = moduleDir.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }
}
