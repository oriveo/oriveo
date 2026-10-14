package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.R
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.mockk.every
import kotlinx.coroutines.flow.MutableStateFlow
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.LocalEngineConnector
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.mockk
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Structure snapshot of the Relay / local "model library" subpage (BOARD-CATALOG-01 to 08).
 *
 * Sections, filters, row states and the five capability tri-states all come from the production [RelayCatalogBoardModel.build]; the capability tri-states go through
 * [RelayCatalogCapabilityFacts], which calls the existing chat-page / evidence-layer predicates. The model objects of -07 are produced by the production
 * [LocalEngineConnector] running against the Ollama recording in the shared fixture `engine-declarations.v1.json`.
 */
class RelayCatalogBoardStructureTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val metadata = MetadataClient()
    private val nowSeconds = 1_760_000_000L

    @Before
    fun setUp() {
    }

    private fun relay(
        transport: RelayTransport = RelayTransport.OpenAIChatCompletions,
        models: List<AIModel>,
        catalog: List<AIModel> = models,
        id: String = "relay-catalog",
    ) = Provider(
        id = id,
        kind = ProviderKind.Relay,
        customName = "myrelay.dev",
        baseUrlText = "https://api.myrelay.dev",
        apiKey = "sk-live-0000000000007f2a",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = transport,
            resolvedAPIBaseURL = "https://api.myrelay.dev/v1",
        ),
        models = models,
        catalogModels = catalog,
    )

    private fun local(models: List<AIModel>, catalog: List<AIModel> = models) = Provider(
        id = "local-engine",
        kind = ProviderKind.Relay,
        customName = "Mac mini",
        baseUrlText = "http://127.0.0.1:11434",
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            engineProfile = "ollama",
            resolvedAPIBaseURL = "http://127.0.0.1:11434/v1",
        ),
        models = models,
        catalogModels = catalog,
    )

    private fun identity(provider: Provider) = CapabilityEvidenceIdentity(
        partitionId = "partition",
        connectionInstanceId = provider.id,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
    )

    private fun cache() = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { nowSeconds })

    private fun facts(provider: Provider, negativeCache: RelayNegativeCache = cache()) = RelayCatalogCapabilityFacts(
        metadata = metadata,
        negativeCache = negativeCache,
        identityFor = { identity(provider) },
    )

    private fun groups(vararg models: AIModel) = listOf(ProviderCatalogGroup(id = "g", title = "Group", models = models.toList()))

    private fun build(
        provider: Provider,
        catalogGroups: List<ProviderCatalogGroup>,
        filter: RelayCatalogFilter = RelayCatalogFilter.All,
        confirmedIndex: Set<String>? = null,
        negativeCache: RelayNegativeCache = cache(),
    ) = RelayCatalogBoardModel.build(
        provider = provider,
        enabledModels = provider.models,
        catalogGroups = catalogGroups,
        filter = filter,
        nowSeconds = nowSeconds,
        confirmedCatalogIndex = confirmedIndex,
        facts = facts(provider, negativeCache),
    )

    private fun RelayCatalogBoard.enabledRow(id: String) = enabled.rows.single { it.model.id == id }
    private fun RelayCatalogBoard.libraryRow(id: String) = library.groups.flatMap { it.rows }.single { it.model.id == id }

    private val all = RelayCatalogCapabilityState.entries.toSet()

    // ── BOARD-CATALOG-01: section header count + three legend items + footnote + rows without a source badge ──

    @Test
    fun `BOARD-CATALOG-01 section counts legend footnote and no source badge on rows`() {
        val enabled = listOf(AIModel(id = "gpt-5", name = "gpt-5", isDefault = true), AIModel(id = "o3", name = "o3"))
        val provider = relay(models = enabled, catalog = enabled + listOf(AIModel(id = "a", name = "a"), AIModel(id = "b", name = "b"), AIModel(id = "c", name = "c")))
        val board = build(provider, groups(AIModel(id = "a", name = "a"), AIModel(id = "b", name = "b"), AIModel(id = "c", name = "c")))

        assertEquals(R.string.relay_catalog_section_enabled, board.enabled.titleRes)
        assertEquals(2, board.enabled.count)
        assertEquals(R.string.relay_catalog_section_library, board.library.titleRes)
        assertEquals(3, board.library.count)
        // Search narrows the catalog group to one row; the count is still the catalog de-duplicated by id minus the enabled total.
        val searched = build(provider, groups(AIModel(id = "a", name = "a")))
        assertEquals(3, searched.library.count)
        assertEquals(1, searched.library.groups.flatMap { it.rows }.size)
        val duplicated = relay(models = enabled, catalog = provider.catalogModels + AIModel(id = "a", name = "a"))
        assertEquals(3, build(duplicated, emptyList()).library.count)
        assertEquals(
            listOf(
                RelayCatalogCapabilityState.Supported to R.string.relay_catalog_legend_supported,
                RelayCatalogCapabilityState.Unknown to R.string.relay_catalog_legend_unknown,
                RelayCatalogCapabilityState.Unsupported to R.string.relay_catalog_legend_unsupported,
            ),
            board.legend,
        )
        assertEquals(R.string.relay_catalog_sources_footnote, board.footnoteRes)
        // The source badge lives only under "Advanced": the row model has no source field at all.
        val rowFields = RelayCatalogRow::class.java.declaredFields.map { it.name.lowercase() }
        assertFalse(rowFields.toString(), rowFields.any { "source" in it })
    }

    // ── BOARD-CATALOG-02: filter chips ──

    @Test
    fun `BOARD-CATALOG-02 filter chips follow the fixed order and filter both sections`() {
        val enabled = listOf(
            AIModel(id = "claude", name = "claude", relayTransport = RelayTransport.AnthropicMessages, relayTransportSource = RelayTransportSource.Observed),
            AIModel(id = "gpt-5", name = "gpt-5"),
        )
        val catalog = listOf(
            AIModel(id = "gemini", name = "gemini", relayTransport = RelayTransport.GeminiGenerateContent),
            AIModel(id = "o3", name = "o3"),
        )
        val provider = relay(models = enabled, catalog = enabled + catalog)
        val board = build(provider, groups(*catalog.toTypedArray()))
        assertEquals(
            listOf(
                RelayCatalogFilter.All,
                RelayCatalogFilter.Protocol(RelayBoardProtocol.Chat),
                RelayCatalogFilter.Protocol(RelayBoardProtocol.Messages),
                RelayCatalogFilter.Protocol(RelayBoardProtocol.Gemini),
            ),
            board.filters,
        )
        assertEquals(R.string.provider_category_all, RelayCatalogFilter.All.labelRes)

        val chatOnly = build(provider, groups(*catalog.toTypedArray()), filter = RelayCatalogFilter.Protocol(RelayBoardProtocol.Chat))
        assertEquals(listOf("gpt-5"), chatOnly.enabled.rows.map { it.model.id })
        assertEquals(listOf("o3"), chatOnly.library.groups.flatMap { it.rows }.map { it.model.id })
        // The section header count is the total: filters only filter rows and never change the count.
        assertEquals(2, chatOnly.enabled.count)
        assertEquals(2, chatOnly.library.count)

        // Rebuilding the board on search / filter only reuses the five capabilities already computed and does not re-run the predicates.
        val computed = mutableListOf<String>()
        val counting = RelayCatalogCapabilitySource { p, m, now -> computed += m.id; facts(p).states(p, m, now) }
        val memo = RelayCatalogCapabilityMemo(counting)
        fun rebuild(groups: List<ProviderCatalogGroup>, f: RelayCatalogFilter) = RelayCatalogBoardModel.build(
            provider = provider,
            enabledModels = provider.models,
            catalogGroups = groups,
            filter = f,
            nowSeconds = nowSeconds,
            confirmedCatalogIndex = null,
            facts = memo,
        )
        val full = rebuild(groups(*catalog.toTypedArray()), RelayCatalogFilter.All)
        rebuild(groups(catalog[1]), RelayCatalogFilter.All)
        val filtered = rebuild(groups(*catalog.toTypedArray()), RelayCatalogFilter.Protocol(RelayBoardProtocol.Gemini))
        assertEquals(listOf("claude", "gpt-5", "gemini", "o3"), computed)
        assertEquals(full.libraryRow("gemini").caps, filtered.libraryRow("gemini").caps)

        // Fewer than two distinct transports: the whole chip row is hidden.
        val single = relay(models = listOf(AIModel(id = "a", name = "a")), catalog = listOf(AIModel(id = "a", name = "a"), AIModel(id = "b", name = "b")))
        assertTrue(build(single, groups(AIModel(id = "b", name = "b"))).filters.isEmpty())

        // Local connection: no chips.
        val localProvider = local(models = enabled)
        assertTrue(build(localProvider, groups(*catalog.toTypedArray())).filters.isEmpty())
    }

    // ── BOARD-CATALOG-03: transport chips = effectiveTransport ──

    @Test
    fun `BOARD-CATALOG-03 protocol chip is the effective transport and never a candidate`() {
        val enabled = listOf(
            AIModel(id = "claude", name = "claude", relayTransport = RelayTransport.AnthropicMessages, relayTransportSource = RelayTransportSource.User),
            AIModel(id = "follow", name = "follow"),
        )
        val catalogModel = AIModel(id = "candidate-only", name = "candidate-only")
        val provider = relay(transport = RelayTransport.OpenAIResponses, models = enabled, catalog = enabled + catalogModel)
        // A catalog row carrying a candidate hint (supported_endpoint_types from /models) still does not draw a candidate transport.
        RelayCatalogEndpointTypes.record("https://api.myrelay.dev/v1", mapOf("candidate-only" to listOf("anthropic")))
        val board = build(provider, groups(catalogModel))
        assertEquals(RelayBoardProtocol.Messages, board.enabledRow("claude").protocol)
        assertEquals(RelayBoardProtocol.Responses, board.enabledRow("follow").protocol)
        assertEquals(RelayBoardProtocol.Responses, board.libraryRow("candidate-only").protocol)

        // auto -> Chat.
        val auto = relay(transport = RelayTransport.Auto, models = listOf(AIModel(id = "x", name = "x")))
        assertEquals(RelayBoardProtocol.Chat, build(auto, emptyList()).enabledRow("x").protocol)

        // Local: no transport chip.
        val localProvider = local(models = listOf(AIModel(id = "qwen", name = "qwen")))
        assertNull(build(localProvider, emptyList()).enabledRow("qwen").protocol)
    }

    // ── BOARD-CATALOG-04: five enabled-row states + catalog-missing takes priority + manually added rows are not marked ──

    @Test
    fun `BOARD-CATALOG-04 enabled row status follows the transport source with missing first`() {
        val enabled = listOf(
            AIModel(id = "observed", name = "observed", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Observed),
            AIModel(id = "reachable", name = "reachable", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Reachable),
            AIModel(id = "user", name = "user", relayTransport = RelayTransport.AnthropicMessages, relayTransportSource = RelayTransportSource.User),
            AIModel(id = "none", name = "none"),
            AIModel(id = "auto", name = "auto", relayTransport = RelayTransport.Auto, relayTransportSource = RelayTransportSource.Observed),
            AIModel(id = "gone", name = "gone", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Observed),
            AIModel(id = "typed", name = "typed", isManual = true),
        )
        val catalog = enabled.filter { it.id != "gone" && it.id != "typed" }
        // Connection transport auto: states stay as before (a user-chosen connection transport is covered by the next test).
        val provider = relay(transport = RelayTransport.Auto, models = enabled, catalog = catalog)
        val index = ModelSelectionUtils.catalogMembershipIndex(catalog, ProviderKind.Relay)
        val board = build(provider, emptyList(), confirmedIndex = index)

        assertEquals(RelayCatalogRowStatus.Verified, board.enabledRow("observed").status)
        assertEquals(RelayCatalogRowStatus.Reachable, board.enabledRow("reachable").status)
        assertEquals(RelayCatalogRowStatus.SetByYou, board.enabledRow("user").status)
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, board.enabledRow("none").status)
        // auto counts as no model-level transport: even with a source field it is not considered verified.
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, board.enabledRow("auto").status)
        assertEquals(RelayCatalogRowStatus.MissingFromCatalog, board.enabledRow("gone").status)
        // A manually added model is never marked catalog-missing.
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, board.enabledRow("typed").status)

        assertEquals(R.string.relay_catalog_status_verified, RelayCatalogRowStatus.Verified.textRes)
        assertEquals(R.string.relay_catalog_status_reachable, RelayCatalogRowStatus.Reachable.textRes)
        assertEquals(R.string.relay_catalog_status_set_by_you, RelayCatalogRowStatus.SetByYou.textRes)
        assertEquals(R.string.model_options_vision_unknown, RelayCatalogRowStatus.UnknownUntilSent.textRes)
        assertEquals(R.string.relay_model_missing_from_catalog, RelayCatalogRowStatus.MissingFromCatalog.textRes)

        // Catalog not confirmed (index = null): do not claim missing.
        assertEquals(RelayCatalogRowStatus.Verified, build(provider, emptyList(), confirmedIndex = null).enabledRow("gone").status)
    }

    // ── User-chosen connection transport: a model row without its own transport sits in the same tier as a hand-picked model transport ──

    @Test
    fun `model rows under an explicit connection transport are user-set`() {
        val following = AIModel(id = "following", name = "following")
        val autoPinned = AIModel(id = "auto", name = "auto", relayTransport = RelayTransport.Auto, relayTransportSource = RelayTransportSource.Observed)
        val observed = AIModel(id = "observed", name = "observed", relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.Observed)
        val known = AIModel(id = "files", name = "files", nativeFileMimes = listOf("application/pdf"))
        val blank = AIModel(id = "blank", name = "blank", capabilities = listOf(ModelCapability.Text))
        val enabled = listOf(following, autoPinned, observed)

        val explicit = relay(transport = RelayTransport.AnthropicMessages, models = enabled, catalog = enabled + known + blank)
        val board = build(explicit, groups(known, blank))
        assertEquals(RelayCatalogRowStatus.SetByYou, board.enabledRow("following").status)
        assertEquals(RelayCatalogRowStatus.SetByYou, board.enabledRow("auto").status)
        // The model's own transport is still displayed according to its source.
        assertEquals(RelayCatalogRowStatus.Verified, board.enabledRow("observed").status)
        // Model library: enabling does not verify either, so "verify after enabling / unknown before send" is no longer written.
        assertEquals(RelayCatalogRowStatus.SetByYou, board.libraryRow("files").status)
        assertEquals(RelayCatalogRowStatus.SetByYou, board.libraryRow("blank").status)
        // Reuse the copy resources of the existing tier.
        assertEquals(R.string.relay_catalog_status_set_by_you, board.enabledRow("following").status?.textRes)

        // Put the same batch of models on an auto connection: the states are unchanged.
        val auto = relay(transport = RelayTransport.Auto, models = enabled, catalog = enabled + known + blank)
        val autoBoard = build(auto, groups(known, blank))
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, autoBoard.enabledRow("following").status)
        assertEquals(RelayCatalogRowStatus.VerifyOnEnable, autoBoard.libraryRow("files").status)
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, autoBoard.libraryRow("blank").status)
    }

    // ── BOARD-CATALOG-05: two catalog-row states + no state for local ──

    @Test
    fun `BOARD-CATALOG-05 library row status and local rows without status`() {
        val known = AIModel(id = "files", name = "files", nativeFileMimes = listOf("application/pdf"))
        val blank = AIModel(id = "blank", name = "blank", capabilities = listOf(ModelCapability.Text))
        val provider = relay(transport = RelayTransport.Auto, models = emptyList(), catalog = listOf(known, blank))
        val board = build(provider, groups(known, blank))
        assertEquals(RelayCatalogRowStatus.VerifyOnEnable, board.libraryRow("files").status)
        assertEquals(R.string.relay_catalog_status_verify_on_enable, RelayCatalogRowStatus.VerifyOnEnable.textRes)
        assertTrue(board.libraryRow("blank").caps.all { it == RelayCatalogCapabilityState.Unknown })
        assertEquals(RelayCatalogRowStatus.UnknownUntilSent, board.libraryRow("blank").status)

        // Local: only catalog-missing has a state label.
        val enabled = listOf(AIModel(id = "qwen", name = "qwen"), AIModel(id = "gone", name = "gone"))
        val localProvider = local(models = enabled, catalog = listOf(AIModel(id = "qwen", name = "qwen"), blank))
        val localBoard = build(localProvider, groups(blank), confirmedIndex = ModelSelectionUtils.catalogMembershipIndex(localProvider.catalogModels, localProvider.kind))
        assertNull(localBoard.enabledRow("qwen").status)
        assertEquals(RelayCatalogRowStatus.MissingFromCatalog, localBoard.enabledRow("gone").status)
        assertNull(localBoard.libraryRow("blank").status)
    }

    // ── BOARD-CATALOG-06: Relay five-capability tri-state ──

    @Test
    fun `BOARD-CATALOG-06 relay five capability states come from the production predicates`() {
        val override = AIModel(
            id = "override",
            name = "override",
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            relayCapabilityOverrides = RelayCapabilityOverrides(image = true),
        )
        val rejectedImage = AIModel(id = "rejected-image", name = "rejected-image", capabilities = listOf(ModelCapability.Text, ModelCapability.Image))
        val plain = AIModel(id = "plain", name = "plain", capabilities = listOf(ModelCapability.Text))
        val rejectedTool = AIModel(id = "rejected-tool", name = "rejected-tool", capabilities = listOf(ModelCapability.Text), toolCall = true)
        val files = AIModel(id = "files", name = "files", nativeFileMimes = listOf("application/pdf"))
        val rejectedFile = AIModel(id = "rejected-file", name = "rejected-file", nativeFileMimes = listOf("application/pdf"))
        val fileOn = AIModel(id = "file-on", name = "file-on", relayCapabilityOverrides = RelayCapabilityOverrides(file = true))
        val fileOff = AIModel(
            id = "file-off",
            name = "file-off",
            nativeFileMimes = listOf("application/pdf"),
            relayCapabilityOverrides = RelayCapabilityOverrides(file = false),
        )
        val enabled = listOf(override, rejectedImage, plain, rejectedTool, files, rejectedFile, fileOn, fileOff)
        val provider = relay(models = enabled)
        val negativeCache = cache()
        fun reject(model: AIModel, kind: RelayNegativeCache.Kind) =
            negativeCache.record(RelayNegativeCache.keyFor(provider, model)!!, kind, nowSeconds - 60)
        reject(override, RelayNegativeCache.Kind.Image)
        reject(rejectedImage, RelayNegativeCache.Kind.Image)
        reject(rejectedTool, RelayNegativeCache.Kind.ToolCall)
        reject(rejectedFile, RelayNegativeCache.Kind.File)
        reject(fileOn, RelayNegativeCache.Kind.File)
        val board = build(provider, emptyList(), negativeCache = negativeCache)

        fun caps(id: String) = board.enabledRow(id).caps
        val image = RelayCatalogCapability.Image.ordinal
        val file = RelayCatalogCapability.File.ordinal
        val tool = RelayCatalogCapability.Tool.ordinal
        assertEquals(
            listOf(RelayCatalogCapability.Image, RelayCatalogCapability.File, RelayCatalogCapability.Thinking, RelayCatalogCapability.Tool, RelayCatalogCapability.Web),
            RelayCatalogCapability.entries,
        )
        assertTrue(board.enabled.rows.all { it.caps.size == 5 })
        // Vision: override true beats the negative cache; negative cache -> unsupported; no evidence -> unknown.
        assertEquals(RelayCatalogCapabilityState.Supported, caps("override")[image])
        assertEquals(RelayCatalogCapabilityState.Unsupported, caps("rejected-image")[image])
        assertEquals(RelayCatalogCapabilityState.Unknown, caps("plain")[image])
        // Tools: negative cache -> unsupported (beats toolCall = true on the model); no evidence -> unknown.
        assertEquals(RelayCatalogCapabilityState.Unsupported, caps("rejected-tool")[tool])
        assertEquals(RelayCatalogCapabilityState.Unknown, caps("plain")[tool])
        // Files: allowlist -> supported; negative cache -> unsupported; neither -> unknown.
        assertEquals(RelayCatalogCapabilityState.Supported, caps("files")[file])
        assertEquals(RelayCatalogCapabilityState.Unsupported, caps("rejected-file")[file])
        assertEquals(RelayCatalogCapabilityState.Unknown, caps("plain")[file])
        // The file override is checked first: On beats the file negative cache -> supported; Off -> unsupported even with a non-empty allowlist.
        assertEquals(RelayCatalogCapabilityState.Supported, caps("file-on")[file])
        assertEquals(RelayCatalogCapabilityState.Unsupported, caps("file-off")[file])
        // After the negative cache expires (7 days) the allowlist decides again.
        val later = RelayCatalogBoardModel.build(
            provider = provider,
            enabledModels = provider.models,
            catalogGroups = emptyList(),
            filter = RelayCatalogFilter.All,
            nowSeconds = nowSeconds + RelayNegativeCache.TTL_SECONDS,
            confirmedCatalogIndex = null,
            facts = facts(provider, negativeCache),
        )
        assertEquals(RelayCatalogCapabilityState.Supported, later.enabledRow("rejected-file").caps[file])
        // Every cell is one of the three states.
        assertTrue(board.enabled.rows.flatMap { it.caps }.all { it in all })
    }

    // ── BOARD-CATALOG-07: shared engine fixture through the production connector ──

    private fun fixture(relativePath: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return Json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }

    private data class Recorded(val status: Int, val contentType: String, val body: String)

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun recordKey(method: String, path: String, model: String?) = "$method $path ${model.orEmpty()}"

    private fun ollamaRoutes(): Map<String, Recorded> {
        val recordings = fixture("shared/test-fixtures/local-engine/engine-declarations.v1.json")
        val records = recordings.getValue("engines").jsonObject.getValue("ollama").jsonObject.getValue("records").jsonArray.map { it.jsonObject }
        return records.associate { record ->
            val request = record.getValue("request").jsonObject
            val model = (request["body"] as? JsonObject)?.string("model")
            val response = record.getValue("response").jsonObject
            val body = response["body"]
            recordKey(request.getValue("method").jsonPrimitive.content, request.getValue("path").jsonPrimitive.content, model) to Recorded(
                status = response.getValue("status").jsonPrimitive.content.toInt(),
                contentType = response.string("contentType") ?: "application/json",
                body = if (body == null || body is JsonNull) "404 page not found" else body.toString(),
            )
        }
    }

    private fun showModel(request: HttpRequestData): String? {
        if (request.method != HttpMethod.Post) return null
        val text = (request.body as? TextContent)?.text ?: return null
        return runCatching { json.parseToJsonElement(text).jsonObject.string("model") }.getOrNull()
    }

    @Test
    fun `BOARD-CATALOG-07 engine declarations from the shared fixture drive image tools and thinking`() = runTest {
        val routes = ollamaRoutes()
        val client = HttpClient(
            MockEngine { request ->
                val hit = routes[recordKey(request.method.value, request.url.encodedPath, showModel(request))]
                    ?: Recorded(404, "text/plain", "404 page not found")
                respond(hit.body, HttpStatusCode.fromValue(hit.status), headersOf(HttpHeaders.ContentType, hit.contentType))
            },
        )
        val relayService = mockk<RelayService>()
        coEvery { relayService.pingRelay(any(), any(), any(), any(), any()) } returns Unit
        val connection = LocalEngineConnector(client, json, relayService).connect(
            engine = LocalEngineKind.Ollama,
            rawEndpoint = "http://127.0.0.1:11434",
            securityMode = RelayConnectionSecurityMode.LocalHttp,
        )
        fun model(id: String) = AIModel(
            id = id,
            name = id,
            capabilities = listOf(ModelCapability.Text),
            engineDeclaration = connection.engineDeclarations.getValue(id),
        )
        val models = connection.modelIds.filter { it in connection.engineDeclarations }.map(::model)
        assertTrue(models.isNotEmpty())
        val provider = local(models = models.take(1), catalog = models)
        val board = build(provider, groups(*models.drop(1).toTypedArray()))
        val rows = board.enabled.rows + board.library.groups.flatMap { it.rows }
        assertEquals(models.size, rows.size)
        fun expected(flag: Boolean?) = when (flag) {
            true -> RelayCatalogCapabilityState.Supported
            false -> RelayCatalogCapabilityState.Unsupported
            null -> RelayCatalogCapabilityState.Unknown
        }
        // Expectations come from the Ollama declaration cases in the shared fixture engine-expectations.v1.json (same source as iOS / Web), not from the object under test's own declarations.
        val cases = fixture("shared/test-fixtures/local-engine/engine-expectations.v1.json")
            .getValue("declarations").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
            .filter { it.string("engine") == "ollama" && it.string("instance") == null && it.getValue("inChatCatalog").jsonPrimitive.content.toBoolean() }
        assertTrue(cases.size >= 2)
        val byId = rows.associateBy { it.model.id }
        cases.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val row = byId[case.getValue("modelId").jsonPrimitive.content] ?: error("$caseId: row missing")
            val expect = case.getValue("expect").jsonObject
            fun flag(key: String) = (expect[key] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()
            assertEquals("$caseId image", expected(flag("image")), row.caps[RelayCatalogCapability.Image.ordinal])
            assertEquals("$caseId tool", expected(flag("toolCall")), row.caps[RelayCatalogCapability.Tool.ordinal])
            assertEquals("$caseId thinking", expected(flag("thinking")), row.caps[RelayCatalogCapability.Thinking.ordinal])
        }
        assertTrue("fixture must carry a vision model", cases.any { (it.getValue("expect").jsonObject["image"] as? JsonPrimitive)?.contentOrNull == "true" })
        assertTrue(board.filters.isEmpty())
        assertTrue(rows.all { it.protocol == null })
    }

    // ── BOARD-CATALOG-08: trailing ──

    @Test
    fun `BOARD-CATALOG-08 trailing chevron plus unavailable and default mark`() {
        val enabled = listOf(AIModel(id = "gpt-5", name = "gpt-5", isDefault = true), AIModel(id = "o3", name = "o3"))
        val add = AIModel(id = "add", name = "add")
        val gone = AIModel(id = "gone", name = "gone", isAvailable = false)
        val provider = relay(models = enabled, catalog = enabled + listOf(add, gone))
        val board = build(provider, groups(add, gone))
        // Enabled rows now end with [new chat, more] and no longer have a chevron (supersedes BOARD-CATALOG-14).
        assertEquals(listOf(RelayCatalogTrailing.NewChat, RelayCatalogTrailing.More), board.enabledRow("gpt-5").trailing)
        assertEquals(listOf(RelayCatalogTrailing.NewChat, RelayCatalogTrailing.More), board.enabledRow("o3").trailing)
        assertEquals(listOf(RelayCatalogTrailing.Add), board.libraryRow("add").trailing)
        assertEquals(listOf(RelayCatalogTrailing.Unavailable), board.libraryRow("gone").trailing)
        // Relays have no default model, so the model library no longer shows a "default" mark; the legacy isDefault does not affect row order.
        assertEquals(listOf("gpt-5", "o3"), board.enabled.rows.map { it.model.id })
    }

    // ── Relay grouping, key chips and probe states ──

    private fun multiKey(
        models: List<AIModel>,
        catalog: List<AIModel> = models,
        keys: List<RelayKey> = listOf(
            RelayKey(id = "k1", name = "Main"),
            RelayKey(id = "k2", name = "Backup", apiKey = "sk-backup-00000000beef"),
        ),
    ) = relay(models = models, catalog = catalog).copy(relayKeys = keys)

    private fun buildWith(
        provider: Provider,
        catalogGroups: List<ProviderCatalogGroup>,
        catalogState: ProviderDetailViewModel.RelayCatalogUiState = ProviderDetailViewModel.RelayCatalogUiState.Available,
        probeStates: Map<String, ProviderRepository.RelayModelProbeState> = emptyMap(),
        confirmedIndex: Set<String>? = null,
        canAddManual: Boolean = true,
    ) = RelayCatalogBoardModel.build(
        provider = provider,
        enabledModels = provider.models,
        catalogGroups = catalogGroups,
        filter = RelayCatalogFilter.All,
        nowSeconds = nowSeconds,
        confirmedCatalogIndex = confirmedIndex,
        facts = facts(provider),
        catalogState = catalogState,
        probeStates = probeStates,
        canAddManual = canAddManual,
    )

    @Test
    fun `BOARD-CATALOG-09 relay library groups by family through the shared projection, Other last, official unchanged`() {
        // An old groupKey stamped at fetch time (such as the domain) is no longer used for relay grouping.
        fun stamped(id: String, sortRank: Int? = null) = AIModel(id = id, name = id, groupKey = "example.com", groupName = "example.com", sortRank = sortRank)
        val catalog = listOf(
            stamped("claude-sonnet-4-5"),
            stamped("my-custom-model"),
            stamped("gpt-5", sortRank = 1),
            stamped("claude-opus-4", sortRank = 999),
            stamped("gemini-2.5-pro"),
        )
        val provider = relay(models = listOf(stamped("gpt-5")), catalog = catalog)
        val groups = buildProviderCatalogGroups(provider, searchQuery = "", relayFamily = { RelayFamilyHeuristics.infer(it)?.name?.lowercase() })
        assertEquals(listOf("anthropic", "google", "other"), groups.map { it.id })
        assertEquals(listOf("Anthropic", "Google"), groups.dropLast(1).map { it.title })
        // Order within a group follows the catalog (no re-sort by sortRank); the enabled gpt-5 is not in the catalog area.
        assertEquals(listOf("claude-sonnet-4-5", "claude-opus-4"), groups.first().models.map { it.id })
        assertEquals(R.string.relay_catalog_group_other, groups.last().titleRes)
        assertNull(groups.first().titleRes)
        // The family function prefers the Server family.
        val server = buildProviderCatalogGroups(provider, searchQuery = "", relayFamily = { if (it == "my-custom-model") "zhipu" else null })
        assertEquals(listOf("other", "zhipu").sorted(), server.map { it.id }.sorted())
        assertEquals("other", server.last().id)
        assertEquals("Zhipu", server.single { it.id == "zhipu" }.title)

        // Add step 2 uses the same projection as the model library (family default = cached Server family -> heuristics; the Server family table is not loaded in tests).
        val rows = catalog.map { it.copy(groupKey = null, groupName = null) }
        val setup = ai.oriveo.community.feature.providers.relay.relaySetupCatalogGroups(rows, "https://api.myrelay.dev", "")
        val library = buildProviderCatalogGroups(relay(models = emptyList(), catalog = rows), searchQuery = "")
        assertEquals(library.map { Triple(it.id, it.title, it.titleRes) }, setup.map { Triple(it.id, it.title, it.titleRes) })
        assertEquals(listOf("anthropic", "openai", "google", "other"), setup.map { it.id })

        // Groups on the board carry the same titleRes; groups are collapsed by default (not auto-expanded without a search).
        val board = build(provider, groups)
        assertEquals(R.string.relay_catalog_group_other, board.library.groups.last().titleRes)
        assertFalse(shouldAutoExpandCatalogGroups(""))

        // Official / aggregator provider groups are untouched: still grouped by metadata groupKey.
        val official = Provider(
            id = "or",
            kind = ProviderKind.OpenRouter,
            catalogModels = listOf(AIModel(id = "anthropic/claude", name = "c", groupKey = "anthropic", groupName = "Anthropic")),
        )
        val resolved = ai.oriveo.community.core.provider.ResolvedProviderCatalog(
            catalog = official.catalogModels.map { ai.oriveo.community.core.provider.ResolvedModel(model = it, isEnabled = false, isManual = false) },
            enabledModels = emptyList(),
            recommendedModels = emptyList(),
            defaultModel = null,
            availableModelCount = 1,
            hasManualModels = false,
        )
        assertEquals(listOf("anthropic" to "Anthropic"), buildProviderCatalogGroups(official, resolved, "").map { it.id to it.title })
    }

    @Test
    fun `BOARD-CATALOG-10 header, key chips and per-key status strip only with two or more keys`() {
        val enabled = listOf(
            AIModel(id = "gpt-5", name = "gpt-5", relayKeyID = "k2"),
            AIModel(id = "o3", name = "o3"),
        )
        val catalog = enabled.map { it.copy(relayKeyID = null, relayListedByKeyIDs = listOf("k1", "k2")) } +
            AIModel(id = "a", name = "a", relayListedByKeyIDs = listOf("k1"))
        val keys = listOf(
            RelayKey(id = "k1", name = "Main", status = RelayKeyStatus("ok")),
            RelayKey(id = "k2", name = null, apiKey = "sk-backup-00000000beef", status = RelayKeyStatus("invalid", 401, 1L)),
            RelayKey(id = "k3", name = "Spare", apiKey = "sk-spare-000000000cafe"),
        )
        val provider = multiKey(enabled, catalog, keys)
        val board = buildWith(provider, groups(catalog.last()))

        assertEquals(RelayCatalogHeader(host = "api.myrelay.dev", modelCount = 3, keyCount = 3), board.header)
        // The key chip on an enabled row = the name of the effective bound key, or the mask when it has no name.
        assertEquals("sk-b…beef", board.enabledRow("gpt-5").keyChip)
        assertEquals("Main", board.enabledRow("o3").keyChip)
        assertNull(board.libraryRow("a").keyChip)

        assertEquals(listOf("k1", "k2", "k3"), board.keyStrip.map { it.keyId })
        assertEquals(listOf("Main", "sk-b…beef", "Spare"), board.keyStrip.map { it.title })
        assertEquals(listOf(3, 2, null), board.keyStrip.map { it.catalogCount })
        assertEquals(RelayCatalogKeyStripState.Ok, board.keyStrip[0].state)
        assertEquals(RelayCatalogKeyStripState.Failed(401, R.string.relay_key_status_invalid), board.keyStrip[1].state)
        // A key that was never checked draws no check mark and no Retry.
        assertEquals(RelayCatalogKeyStripState.Unchecked, board.keyStrip[2].state)
        assertEquals(listOf(false, true, false), board.keyStrip.map { it.showsRetry })
        assertTrue(RelayCatalogPageSection.KeyStrip in board.sections)

        // Succeeded but empty: the status strip is still shown, the catalog area is not drawn.
        val empty = buildWith(multiKey(enabled, emptyList(), keys), emptyList(), ProviderDetailViewModel.RelayCatalogUiState.Empty)
        assertTrue(RelayCatalogPageSection.KeyStrip in empty.sections)
        assertFalse(RelayCatalogPageSection.Library in empty.sections)

        // Only one key: no chip, no status strip, and the page header carries no key count.
        val single = buildWith(relay(models = enabled, catalog = catalog), groups(catalog.last()))
        assertTrue(single.enabled.rows.all { it.keyChip == null })
        assertTrue(single.keyStrip.isEmpty())
        assertFalse(RelayCatalogPageSection.KeyStrip in single.sections)
        assertNull(single.header.keyCount)
    }

    @Test
    fun `BOARD-CATALOG-11 enabled row status priority denied over verifying over unreachable over existing`() {
        val failure = ProviderRepository.RelayModelProbeState.Failed(error = IllegalStateException("boom"), httpStatus = 404)
        val enabled = listOf(
            AIModel(id = "denied", name = "denied", relayKeyID = "k2", relayDeniedKeyID = "k2"),
            AIModel(id = "verifying", name = "verifying", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Observed),
            AIModel(id = "unreachable", name = "unreachable"),
            AIModel(id = "gone", name = "gone"),
            AIModel(id = "plain", name = "plain", relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Observed),
        )
        val catalog = enabled.filter { it.id != "gone" }
        val provider = multiKey(enabled, catalog)
        val board = buildWith(
            provider,
            emptyList(),
            probeStates = mapOf(
                "denied" to ProviderRepository.RelayModelProbeState.InFlight,
                "verifying" to ProviderRepository.RelayModelProbeState.InFlight,
                "unreachable" to failure,
                "gone" to failure,
            ),
            confirmedIndex = ModelSelectionUtils.catalogMembershipIndex(catalog, ProviderKind.Relay),
        )
        assertEquals(RelayCatalogRowStatus.DeniedOnCurrentKey, board.enabledRow("denied").status)
        assertEquals(RelayCatalogRowStatus.Verifying, board.enabledRow("verifying").status)
        assertEquals(RelayCatalogRowStatus.Unreachable, board.enabledRow("unreachable").status)
        assertEquals(failure, board.enabledRow("unreachable").unreachable)
        // Unreachable beats the original "catalog missing".
        assertEquals(RelayCatalogRowStatus.Unreachable, board.enabledRow("gone").status)
        assertEquals(RelayCatalogRowStatus.Verified, board.enabledRow("plain").status)
        assertNull(board.enabledRow("plain").unreachable)
        assertEquals(R.string.relay_catalog_status_denied, RelayCatalogRowStatus.DeniedOnCurrentKey.textRes)
        assertEquals(R.string.relay_catalog_status_verifying, RelayCatalogRowStatus.Verifying.textRes)
        assertEquals(R.string.relay_catalog_status_unreachable, RelayCatalogRowStatus.Unreachable.textRes)
    }

    @Test
    fun `BOARD-CATALOG-11 lazy probe failure is kept in session memory by the production repository and cleared on success and rebind`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.Unauthorized)
        harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "gpt-5")
        val failed = harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"]
        assertTrue(failed.toString(), failed is ProviderRepository.RelayModelProbeState.Failed)
        assertTrue(harness.pings > 0)
        // Feed the production state table to the board: the row reads "Unreachable · view reason".
        val provider = harness.current()
        val board = buildWith(provider, emptyList(), probeStates = harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID))
        assertEquals(RelayCatalogRowStatus.Unreachable, board.enabledRow("gpt-5").status)
        // Unreachable lives only in memory: no new field is written on the persisted object.
        assertNull(provider.models.single { it.id == "gpt-5" }.relayTransport)

        // Rebinding clears it (a re-probe after rebinding that still fails records it again; here upstream is recovered first).
        harness.pingStatus = HttpStatusCode.OK
        harness.repository.rebindRelayModelKey(ProbeHarness.PROVIDER_ID, "gpt-5", "k2")
        assertNull(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])

        // Fail once more; the lazy check that succeeded is cleared.
        harness.pingStatus = HttpStatusCode.Unauthorized
        harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "o3")
        assertTrue(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["o3"] is ProviderRepository.RelayModelProbeState.Failed)
        harness.pingStatus = HttpStatusCode.OK
        harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "o3")
        assertNull(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["o3"])
    }

    @Test
    fun `BOARD-CATALOG-11 cancelled lazy probe only clears verifying and never records unreachable`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.Unauthorized).apply { hold = kotlinx.coroutines.CompletableDeferred() }
        val job = launch { harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "gpt-5") }
        harness.entered.await()
        assertEquals(ProviderRepository.RelayModelProbeState.InFlight, harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])
        job.cancelAndJoin()
        // Cancel: clears "verifying" and does not record "unreachable".
        assertNull(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])
    }

    /** Makes each of [modelIDs] fail its lazy check once so "unreachable" is recorded; then restores upstream to [then] and returns the request-count baseline after reset. */
    private suspend fun ProbeHarness.failLazyProbes(vararg modelIDs: String, then: HttpStatusCode = HttpStatusCode.OK) {
        pingStatus = HttpStatusCode.Unauthorized
        modelIDs.forEach { repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, it) }
        modelIDs.forEach {
            assertTrue(it, repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)[it] is ProviderRepository.RelayModelProbeState.Failed)
        }
        pingStatus = then
        pingModels.clear()
    }

    private fun ProbeHarness.withKeyStatus(keyID: String, state: String) = store(
        current().let { p -> p.copy(relayKeys = p.relayKeys!!.map { if (it.id == keyID) it.copy(status = RelayKeyStatus(state)) else it }) },
    )

    @Test
    fun `RL2-PROBESTATE-01 multi key replacing K's value clears and re-probes only models bound to K`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK).apply { catalogIDs = listOf("gpt-5", "o3") }
        // gpt-5 is bound to k1, o3 is rebound to k2.
        harness.store(harness.current().let { p -> p.copy(models = p.models.map { if (it.id == "o3") it.copy(relayKeyID = "k2") else it }) })
        harness.failLazyProbes("gpt-5", "o3")

        harness.repository.replaceRelayKeySecret(ProbeHarness.PROVIDER_ID, "k1", "sk-main-rotated-000000002222")
        harness.awaitBackgroundProbes()

        val states = harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)
        assertNull("changing K's value clears M", states["gpt-5"])
        assertEquals("M has no transport, re-probed once", listOf("gpt-5"), harness.pingModels)
        assertTrue("N bound to J is untouched", states["o3"] is ProviderRepository.RelayModelProbeState.Failed)
    }

    @Test
    fun `RL2-PROBESTATE-02 multi key catalog success writing K ok keeps unreachable with zero probes`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK).apply { catalogIDs = listOf("gpt-5", "o3") }
        harness.withKeyStatus("k1", "invalid")
        harness.failLazyProbes("gpt-5")

        val refreshed = harness.repository.refreshRelayKeyCatalog(ProbeHarness.PROVIDER_ID, "k1")
        harness.awaitBackgroundProbes()

        // Regression: a relay may gate only some transport with 403 while the key can still fetch the catalog; "unreachable" must not be wiped.
        assertEquals("ok", refreshed!!.relayKeys!!.single { it.id == "k1" }.status?.state)
        assertTrue(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"] is ProviderRepository.RelayModelProbeState.Failed)
        assertEquals(0, harness.pingModels.size)
    }

    @Test
    fun `RL2-PROBESTATE-03 single key replacing the key clears all and re-probes only models without a protocol`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK, singleKey = true)
        harness.failLazyProbes("gpt-5", "o3")
        // o3 later gets a model-level transport (the failed state is still in memory).
        harness.store(
            harness.current().let { p ->
                p.copy(models = p.models.map { if (it.id == "o3") it.copy(relayTransport = RelayTransport.OpenAIChatCompletions, relayTransportSource = RelayTransportSource.Reachable) else it })
            },
        )
        suspend fun saveEdit(apiKey: String) = harness.repository.persistRelayEditUnverified(
            candidate = harness.current(),
            replacementApiKey = apiKey,
            failureRevision = ProviderRepository.RelayEditRevision(requireNotNull(harness.stored)),
            commitGuard = { true },
        )

        // A save with an unchanged value does not count as a value change.
        assertTrue(saveEdit(harness.apiKey).persisted)
        harness.awaitBackgroundProbes()
        assertEquals(2, harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID).size)

        // Edit the connection, change the key and save.
        assertTrue(saveEdit("sk-main-rotated-000000002222").persisted)
        harness.awaitBackgroundProbes()

        assertTrue(harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID).isEmpty())
        assertEquals("only models without a transport get a lazy check", listOf("gpt-5"), harness.pingModels)
    }

    @Test
    fun `RL2-PROBESTATE-04 send success with an already ok key clears only that model and sends no probe`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK)
        harness.withKeyStatus("k1", "ok")
        harness.failLazyProbes("gpt-5", "o3")

        // The two steps after ChatRepository delivered: first clear that model, then write key success (this key is already ok, nothing is written to storage).
        harness.repository.clearRelayModelProbeFailure(ProbeHarness.PROVIDER_ID, "gpt-5")
        harness.repository.recordRelayKeyAccessSuccess(ProbeHarness.PROVIDER_ID, "gpt-5", "k1", harness.current())
        harness.awaitBackgroundProbes()

        val states = harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)
        assertNull(states["gpt-5"])
        assertTrue("the other model on the same connection is untouched", states["o3"] is ProviderRepository.RelayModelProbeState.Failed)
        assertEquals(0, harness.pingModels.size)
    }

    @Test
    fun `RL2-PROBESTATE-05 send success turning K back to ok keeps the other model on K with zero probes`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK)
        harness.withKeyStatus("k1", "invalid")
        harness.failLazyProbes("gpt-5", "o3")

        harness.repository.clearRelayModelProbeFailure(ProbeHarness.PROVIDER_ID, "gpt-5")
        harness.repository.recordRelayKeyAccessSuccess(ProbeHarness.PROVIDER_ID, "gpt-5", "k1", harness.current())
        harness.awaitBackgroundProbes()

        assertEquals("ok", harness.current().relayKeys!!.single { it.id == "k1" }.status?.state)
        val states = harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)
        assertNull(states["gpt-5"])
        assertTrue("the other model on the same key is kept", states["o3"] is ProviderRepository.RelayModelProbeState.Failed)
        assertEquals(0, harness.pingModels.size)
    }

    @Test
    fun `RL2-PROBESTATE-07 a lazy probe result returning after K's value changed is discarded, not recorded unreachable`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.Unauthorized).apply {
            catalogIDs = listOf("gpt-5", "o3")
            hold = kotlinx.coroutines.CompletableDeferred()
        }
        val job = launch(kotlinx.coroutines.Dispatchers.IO) { harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "gpt-5") }
        harness.entered.await()

        // While a probe is in flight the value of K is changed, then the failure from the old value comes back.
        harness.repository.replaceRelayKeySecret(ProbeHarness.PROVIDER_ID, "k1", "sk-main-rotated-000000002222")
        harness.hold!!.complete(Unit)
        job.join()
        harness.awaitBackgroundProbes()

        assertNull("connection identity changed: the result is discarded and verifying is cleared", harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])
    }

    @Test
    fun `RL2-PROBESTATE-06 verifying is never cleared by key replacement or send success`() = runTest {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK).apply {
            catalogIDs = listOf("gpt-5", "o3")
            hold = kotlinx.coroutines.CompletableDeferred()
        }
        harness.withKeyStatus("k1", "invalid")
        val job = launch(kotlinx.coroutines.Dispatchers.IO) { harness.repository.probeEnabledRelayModel(ProbeHarness.PROVIDER_ID, "gpt-5") }
        harness.entered.await()
        val verifying = ProviderRepository.RelayModelProbeState.InFlight

        harness.repository.replaceRelayKeySecret(ProbeHarness.PROVIDER_ID, "k1", "sk-main-rotated-000000002222")
        harness.awaitBackgroundProbes()
        assertEquals(verifying, harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])
        harness.withKeyStatus("k1", "invalid")
        harness.repository.clearRelayModelProbeFailure(ProbeHarness.PROVIDER_ID, "gpt-5")
        harness.repository.recordRelayKeyAccessSuccess(ProbeHarness.PROVIDER_ID, "gpt-5", "k1", harness.current())
        harness.awaitBackgroundProbes()
        assertEquals(verifying, harness.repository.relayModelProbeStates(ProbeHarness.PROVIDER_ID)["gpt-5"])
        assertEquals("neither T1 nor T2 sent a lazy check", 1, harness.pings)

        harness.hold!!.complete(Unit)
        job.join()
    }

    @Test
    fun `BOARD-CATALOG-12 single key failure card above the old catalog and one manual add at the page end`() {
        val enabled = listOf(AIModel(id = "gpt-5", name = "gpt-5"))
        val old = AIModel(id = "o3", name = "o3")
        val provider = relay(models = enabled, catalog = enabled + old)
        val failed = buildWith(provider, groups(old), ProviderDetailViewModel.RelayCatalogUiState.Failed)
        assertEquals(
            listOf(
                RelayCatalogPageSection.Header,
                RelayCatalogPageSection.Enabled,
                RelayCatalogPageSection.FailureCard,
                RelayCatalogPageSection.Library,
                RelayCatalogPageSection.EnableHint,
                RelayCatalogPageSection.ManualAdd,
                RelayCatalogPageSection.Legend,
            ),
            failed.sections,
        )
        // The old catalog is still shown below the failure card.
        assertEquals(listOf("o3"), failed.library.groups.flatMap { it.rows }.map { it.model.id })

        // Success: no failure card, and manual add still appears only once at the page bottom.
        val ok = buildWith(provider, groups(old))
        assertFalse(RelayCatalogPageSection.FailureCard in ok.sections)
        assertEquals(1, ok.sections.count { it == RelayCatalogPageSection.ManualAdd })
        assertEquals(RelayCatalogPageSection.ManualAdd, ok.sections[ok.sections.lastIndex - 1])

        // Succeeded but empty: the catalog area is not drawn; the enabled section and the manual add at the page bottom are as usual.
        val empty = buildWith(relay(models = enabled, catalog = emptyList()), emptyList(), ProviderDetailViewModel.RelayCatalogUiState.Empty)
        assertEquals(
            listOf(RelayCatalogPageSection.Header, RelayCatalogPageSection.Enabled, RelayCatalogPageSection.ManualAdd, RelayCatalogPageSection.Legend),
            empty.sections,
        )

        // Two or more keys: failures go through the per-key status strip and no whole failure card appears.
        val multi = buildWith(multiKey(enabled, enabled + old), groups(old), ProviderDetailViewModel.RelayCatalogUiState.Failed)
        assertFalse(RelayCatalogPageSection.FailureCard in multi.sections)
        assertTrue(RelayCatalogPageSection.KeyStrip in multi.sections)

        // A connection that cannot add manually shows no manual add.
        assertFalse(RelayCatalogPageSection.ManualAdd in buildWith(provider, groups(old), canAddManual = false).sections)
    }

    @Test
    fun `BOARD-CATALOG-13 catalog row opens read-only advanced, plus enables, hint only for relay`() {
        val enabled = listOf(AIModel(id = "gpt-5", name = "gpt-5"))
        val catalogModel = AIModel(id = "o3", name = "o3")
        val provider = relay(models = enabled, catalog = enabled + catalogModel)
        val board = buildWith(provider, groups(catalogModel))
        val row = board.libraryRow("o3")
        assertEquals(listOf(RelayCatalogTrailing.Add), row.trailing)
        val layer = RelayCatalogBoardModel.libraryRowLayer(row)
        assertEquals(RelayDetailLayer.Advanced("o3", readOnly = true), layer)
        assertEquals(RelayDetailLayer.Advanced("gpt-5", readOnly = false), RelayCatalogBoardModel.enabledRowLayer(board.enabledRow("gpt-5")))
        // Read-only advanced is entered from the model library; going back once returns to the model library.
        val stack = RelayDetailNavStack().push(RelayDetailLayer.Library()).push(layer)
        assertEquals(RelayDetailLayer.Library(), stack.pop().top)

        // The three hint states are covered by BOARD-CATALOG-16; this connection has Chat selected, so only the second half of the sentence appears.
        assertEquals(R.string.relay_catalog_enable_hint_explicit, board.enableHintRes)
        assertTrue(RelayCatalogPageSection.EnableHint in board.sections)
        // Enabling on local sends no probe: no hint sentence.
        val localBoard = buildWith(local(models = enabled, catalog = enabled + catalogModel), groups(catalogModel))
        assertNull(localBoard.enableHintRes)
        assertFalse(RelayCatalogPageSection.EnableHint in localBoard.sections)
    }

    // ── Alignment with the iOS board (BOARD-CATALOG-14 to 19) ──

    @Test
    fun `BOARD-CATALOG-14 enabled rows open editable advanced with new chat and more, catalog rows open read-only advanced`() {
        val ready = AIModel(id = "gpt-5", name = "gpt-5")
        val gone = AIModel(id = "o3", name = "o3", isAvailable = false)
        val add = AIModel(id = "add", name = "add")
        val unavailable = AIModel(id = "unavailable", name = "unavailable", isAvailable = false)
        val provider = relay(models = listOf(ready, gone), catalog = listOf(ready, gone, add, unavailable))
        val board = build(provider, groups(add, unavailable))
        for (id in listOf("gpt-5", "o3")) {
            val row = board.enabledRow(id)
            assertEquals("enabled rows (including unavailable) open editable advanced on tap", RelayCatalogTapTarget.Advanced, row.tapTarget)
            assertEquals(listOf(RelayCatalogTrailing.NewChat, RelayCatalogTrailing.More), row.trailing)
        }
        assertEquals(RelayCatalogTapTarget.ReadOnlyAdvanced, board.libraryRow("add").tapTarget)
        assertEquals(listOf(RelayCatalogTrailing.Add), board.libraryRow("add").trailing)
        assertEquals(RelayCatalogTapTarget.ReadOnlyAdvanced, board.libraryRow("unavailable").tapTarget)
        assertEquals(listOf(RelayCatalogTrailing.Unavailable), board.libraryRow("unavailable").trailing)
        // Same set for local.
        val localBoard = build(local(models = listOf(ready), catalog = listOf(ready, add)), groups(add))
        assertEquals(RelayCatalogTapTarget.Advanced, localBoard.enabledRow("gpt-5").tapTarget)
        assertEquals(RelayCatalogTapTarget.ReadOnlyAdvanced, localBoard.libraryRow("add").tapTarget)
        // Hierarchy and row tap target use the same rule.
        assertEquals(RelayDetailLayer.Advanced("o3", readOnly = false), RelayCatalogBoardModel.enabledRowLayer(board.enabledRow("o3")))
        assertEquals(RelayDetailLayer.Advanced("add", readOnly = true), RelayCatalogBoardModel.libraryRowLayer(board.libraryRow("add")))
        // Enabled rows no longer have a chevron / advanced button.
        val rows = mainSource("feature/providers/detail/ProviderDetailEnabledModels.kt")
        assertFalse("RelayCatalogChevron(" in rows)
        assertFalse("provider_detail_enabled_model_advanced_button" in mainSource("feature/providers/detail/RelayCatalogBoardView.kt"))
    }

    @Test
    fun `BOARD-CATALOG-14b views dispatch row taps only by tapTarget, rows without board context keep the old behavior`() {
        assertEquals(
            RelayCatalogRowTap.OpenAdvanced(RelayDetailLayer.Advanced("m", readOnly = false)),
            RelayCatalogBoardModel.rowTap("m", RelayCatalogTapTarget.Advanced, enabledRow = true),
        )
        assertEquals(
            RelayCatalogRowTap.OpenAdvanced(RelayDetailLayer.Advanced("m", readOnly = true)),
            RelayCatalogBoardModel.rowTap("m", RelayCatalogTapTarget.ReadOnlyAdvanced, enabledRow = false),
        )
        // No board context (add model from home, official): tap on a catalog row = enable, tap on an enabled row = open chat.
        assertEquals(RelayCatalogRowTap.Enable, RelayCatalogBoardModel.rowTap("m", null, enabledRow = false))
        assertEquals(RelayCatalogRowTap.StartChat, RelayCatalogBoardModel.rowTap("m", null, enabledRow = true))
        // The view dispatches on tapTarget only.
        val rows = mainSource("feature/providers/detail/ProviderDetailEnabledModels.kt")
        assertTrue("RelayCatalogBoardModel.rowTap(model.id, boardRow.tapTarget, enabledRow = true)" in rows)
        val library = mainSource("feature/providers/detail/RelayCatalogBoardView.kt")
        assertTrue("RelayCatalogBoardModel.rowTap(row.model.id, row.tapTarget, enabledRow = false)" in library)
    }

    @Test
    fun `BOARD-CATALOG-15 more menu only has Remove, disabled with a reason when one model is left`() = runBlocking {
        val one = AIModel(id = "gpt-5", name = "gpt-5")
        val two = AIModel(id = "o3", name = "o3")
        val add = AIModel(id = "add", name = "add")
        val single = build(relay(models = listOf(one), catalog = listOf(one, add)), groups(add))
        val lone = single.enabledRow("gpt-5")
        assertEquals("1 left: the menu stays", listOf(RelayCatalogTrailing.NewChat, RelayCatalogTrailing.More), lone.trailing)
        assertEquals(
            listOf(RelayCatalogMenuItem(RelayEnabledRowMenuItem.Remove, enabled = false, disabledReasonRes = R.string.relay_catalog_remove_last_reason)),
            lone.menu,
        )
        assertEquals("This connection needs at least one model.", englishString("relay_catalog_remove_last_reason"))
        val pair = build(relay(models = listOf(one, two), catalog = listOf(one, two, add)), groups(add))
        for (id in listOf("gpt-5", "o3")) {
            assertEquals(listOf(RelayCatalogMenuItem(RelayEnabledRowMenuItem.Remove, enabled = true, disabledReasonRes = null)), pair.enabledRow(id).menu)
        }
        assertEquals("catalog rows have no menu", emptyList<RelayCatalogMenuItem>(), pair.libraryRow("add").menu)
        // Same for local.
        val local = build(local(models = listOf(one), catalog = listOf(one)), emptyList())
        assertFalse(local.enabledRow("gpt-5").menu.single().enabled)
        // "Set as default" no longer exists.
        assertFalse(RelayEnabledRowMenuItem.SetDefault in (pair.enabled.rows + single.enabled.rows).flatMap { row -> row.menu.map { it.action } })

        // Same production removal rule: refused when only 1 is left, nothing written to storage.
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK)
        harness.store(harness.current().copy(models = listOf(AIModel(id = "gpt-5", name = "gpt-5", relayKeyID = "k1"))))
        val upsertsBefore = harness.upserts
        harness.withViewModel { viewModel ->
            viewModel.toggleModelEnabled(AIModel(id = "gpt-5", name = "gpt-5"))
            kotlinx.coroutines.delay(400)
        }
        assertEquals(upsertsBefore, harness.upserts)
        assertEquals(listOf("gpt-5"), harness.current().models.map { it.id })
    }

    @Test
    fun `BOARD-CATALOG-16 enable hint follows the connection protocol in three states`() {
        val enabled = listOf(AIModel(id = "gpt-5", name = "gpt-5"))
        val catalogModel = AIModel(id = "o3", name = "o3")
        val auto = buildWith(relay(transport = RelayTransport.Auto, models = enabled, catalog = enabled + catalogModel), groups(catalogModel))
        assertEquals(R.string.relay_catalog_enable_hint, auto.enableHintRes)
        assertEquals(
            "Enabling sends 1 tiny request to confirm the model works. Tap a model in the catalog to view Advanced first. No request is sent.",
            englishString("relay_catalog_enable_hint"),
        )
        for (transport in listOf(
            RelayTransport.OpenAIChatCompletions,
            RelayTransport.OpenAIResponses,
            RelayTransport.AnthropicMessages,
            RelayTransport.GeminiGenerateContent,
        )) {
            val explicit = buildWith(relay(transport = transport, models = enabled, catalog = enabled + catalogModel), groups(catalogModel))
            assertEquals(transport.name, R.string.relay_catalog_enable_hint_explicit, explicit.enableHintRes)
            assertTrue(RelayCatalogPageSection.EnableHint in explicit.sections)
        }
        assertEquals("Tap a model in the catalog to view Advanced first. No request is sent.", englishString("relay_catalog_enable_hint_explicit"))
        val localBoard = buildWith(local(models = enabled, catalog = enabled + catalogModel), groups(catalogModel))
        assertNull(localBoard.enableHintRes)
        assertFalse(RelayCatalogPageSection.EnableHint in localBoard.sections)
    }

    @Test
    fun `BOARD-CATALOG-17 row readout names every capability with its state in icon order`() {
        val enabled = AIModel(id = "gpt-5", name = "gpt-5", capabilities = listOf(ModelCapability.Image))
        val catalogModel = AIModel(id = "o3", name = "o3")
        val provider = relay(models = listOf(enabled), catalog = listOf(enabled, catalogModel))
        val board = build(provider, groups(catalogModel))
        val titles = listOf(
            R.string.capability_image,
            R.string.capability_file,
            R.string.local_setup_tile_thinking,
            R.string.relay_model_advanced_tool_calls,
            R.string.model_control_web_search,
        )
        fun stateRes(state: RelayCatalogCapabilityState) = when (state) {
            RelayCatalogCapabilityState.Supported -> R.string.relay_capability_test_supported
            RelayCatalogCapabilityState.Unknown -> R.string.relay_model_advanced_unknown
            RelayCatalogCapabilityState.Unsupported -> R.string.relay_capability_test_unsupported
        }
        for (row in listOf(board.enabledRow("gpt-5"), board.libraryRow("o3"))) {
            assertEquals(
                titles.zip(row.caps).map { (title, state) -> RelayCatalogReadoutPart(title, stateRes(state)) },
                row.readout,
            )
        }
        val english = mapOf(
            R.string.capability_image to "Vision",
            R.string.capability_file to "Files",
            R.string.local_setup_tile_thinking to "Thinking",
            R.string.relay_model_advanced_tool_calls to "Tool calls",
            R.string.model_control_web_search to "Web Search",
            R.string.relay_capability_test_supported to "Supported",
            R.string.relay_model_advanced_unknown to "Unknown",
            R.string.relay_capability_test_unsupported to "Not supported",
        )
        val parts = listOf(
            RelayCatalogReadoutPart(R.string.capability_image, R.string.relay_capability_test_supported),
            RelayCatalogReadoutPart(R.string.capability_file, R.string.relay_model_advanced_unknown),
            RelayCatalogReadoutPart(R.string.local_setup_tile_thinking, R.string.relay_capability_test_unsupported),
        )
        assertEquals(
            "gpt-5, Vision Supported, Files Unknown, Thinking Not supported",
            RelayCatalogBoardModel.rowReadoutText("gpt-5", parts) { english.getValue(it) },
        )
        // The five icons are hidden from screen readers; the reader value hangs on the row-level merged node (the tappable node of the row body).
        val view = mainSource("feature/providers/detail/RelayCatalogBoardView.kt")
        assertTrue("Modifier.clearAndSetSemantics {}" in view)
        assertTrue("modifier.semantics { contentDescription = readout }" in view)
        assertTrue("RelayCatalogBoardModel.rowReadoutText(row.model.name, row.readout)" in view)
    }

    @Test
    fun `BOARD-CATALOG-18 group Add All lists only enable-able models in row order, key denial only counts on the landing key`() {
        val keys = listOf(RelayKey(id = "k1", name = "Main"), RelayKey(id = "k2", name = "Backup", apiKey = "sk-backup-00000000beef"))
        val enabled = AIModel(id = "alpha-on", name = "alpha-on", relayKeyID = "k1")
        val both = AIModel(id = "alpha-both", name = "alpha-both", relayListedByKeyIDs = listOf("k1", "k2"))
        val deniedOnLanding = AIModel(id = "alpha-denied", name = "alpha-denied", relayListedByKeyIDs = listOf("k2"), relayDeniedKeyID = "k2")
        val deniedElsewhere = AIModel(id = "alpha-elsewhere", name = "alpha-elsewhere", relayListedByKeyIDs = listOf("k2"), relayDeniedKeyID = "k1")
        val unavailable = AIModel(id = "alpha-gone", name = "alpha-gone", isAvailable = false, relayListedByKeyIDs = listOf("k1"))
        val catalog = listOf(enabled.copy(relayKeyID = null, relayListedByKeyIDs = listOf("k1")), deniedElsewhere, both, deniedOnLanding, unavailable)
        val provider = relay(models = listOf(enabled), catalog = catalog).copy(relayKeys = keys)
        val board = buildWith(
            provider,
            listOf(
                ProviderCatalogGroup(id = "g1", title = "G1", models = listOf(deniedElsewhere, both, deniedOnLanding, unavailable)),
                ProviderCatalogGroup(id = "g2", title = "G2", models = listOf(unavailable)),
            ),
        )
        val g1 = board.library.groups.single { it.id == "g1" }
        assertEquals(listOf("alpha-elsewhere", "alpha-both"), g1.enableAllModelIDs)
        assertEquals("nothing to enable shows no enable-all", emptyList<String>(), board.library.groups.single { it.id == "g2" }.enableAllModelIDs)
        // Single key: the no-access decision looks only at that one key (the primary key).
        val single = buildWith(
            relay(models = emptyList(), catalog = listOf(both.copy(relayListedByKeyIDs = null, relayDeniedKeyID = RelayKeyBinding.IMPLICIT_KEY_ID), AIModel(id = "beta", name = "beta"))),
            groups(both, AIModel(id = "beta", name = "beta")),
        )
        assertEquals(listOf("beta"), single.library.groups.single().enableAllModelIDs)
        // Relay model library only: the catalog on the home add-model page does not pass enable-all.
        assertFalse("relayAddAll" in mainSource("feature/modelpicker/InlineModelCatalog.kt"))
        assertTrue("relayAddAll = board?.library?.groups" in mainSource("feature/providers/detail/ProviderDetailScreen.kt"))
    }

    @Test
    fun `BOARD-CATALOG-19 Add All appends the group in one write with zero probes, single enable still probes`() = runBlocking {
        val harness = ProbeHarness(pingStatus = HttpStatusCode.OK)
        val base = harness.current()
        val extra = listOf(
            AIModel(id = "claude-x", name = "claude-x", relayListedByKeyIDs = listOf("k2")),
            AIModel(id = "gemini-x", name = "gemini-x", relayListedByKeyIDs = listOf("k1", "k2")),
            AIModel(id = "grok-x", name = "grok-x", relayListedByKeyIDs = listOf("k1")),
        )
        harness.store(base.copy(catalogModels = base.catalogModels + extra))
        val upsertsBefore = harness.upserts
        val added = harness.withViewModel { viewModel ->
            val count = viewModel.enableRelayCatalogModels(listOf("claude-x", "gemini-x", "gpt-5"))
            kotlinx.coroutines.withTimeout(5_000) { while (harness.upserts == upsertsBefore) kotlinx.coroutines.delay(10) }
            // Leave a window for afterPersist: a probe would be sent out here.
            kotlinx.coroutines.delay(400)
            count
        }
        assertEquals("already enabled ones are not added again", 2, added)
        assertEquals("the connection is written back only once", upsertsBefore + 1, harness.upserts)
        assertEquals("zero probes", 0, harness.pings)
        assertTrue("no lazy-check state", harness.spyRepository.relayModelProbeStates(ProbeHarness.PROVIDER_ID).isEmpty())
        val written = harness.current()
        assertEquals(listOf("gpt-5", "o3", "claude-x", "gemini-x"), written.models.map { it.id })
        assertTrue("no transport written", written.models.all { it.relayTransport == null && it.relayTransportSource == null })
        // Key ownership is the same as a single enable: it lands on the key that lists it.
        assertEquals("k2", written.models.single { it.id == "claude-x" }.relayKeyID)
        assertEquals(
            ai.oriveo.community.core.provider.relay.RelayKeyBinding.withBinding(base.copy(catalogModels = base.catalogModels + extra), extra[1]).relayKeyID,
            written.models.single { it.id == "gemini-x" }.relayKeyID,
        )
        // toast: plural string, no hint for 0.
        io.mockk.verify(exactly = 1) {
            harness.snackbar.show(
                match {
                    val message = it.message
                    message is ai.oriveo.community.core.app.UiText.PluralResource &&
                        message.resId == R.plurals.relay_catalog_added_models && message.count == 2
                },
            )
        }
        val none = harness.withViewModel { viewModel -> viewModel.enableRelayCatalogModels(listOf("gpt-5")) }
        assertEquals(0, none)
        io.mockk.verify(exactly = 1) { harness.snackbar.show(match { it.message is ai.oriveo.community.core.app.UiText.PluralResource }) }

        // Contrast: a single enable does probe.
        harness.withViewModel { viewModel ->
            viewModel.toggleModelEnabled(written.catalogModels.single { it.id == "grok-x" })
            kotlinx.coroutines.withTimeout(5_000) { while (harness.pings == 0) kotlinx.coroutines.delay(10) }
        }
        assertTrue(harness.pings > 0)
    }

    // ── BOARD-CATALOG-20: key(id) filter predicate / chip appearance and fallback ──

    @Test
    fun `BOARD-CATALOG-20 key filter keeps rows listed by the key, chip only while active, falls back to All`() {
        val catalog = listOf(
            AIModel(id = "a", name = "a", relayListedByKeyIDs = listOf("k1")),
            AIModel(id = "b", name = "b", relayListedByKeyIDs = listOf("k2")),
            AIModel(id = "c", name = "c", relayListedByKeyIDs = listOf("k1", "k2")),
            // By default the lister = the primary key.
            AIModel(id = "d", name = "d"),
        )
        val enabled = listOf(catalog[2].copy(isDefault = true), catalog[0])
        val keys = listOf(
            RelayKey(id = "k1", name = "Main"),
            RelayKey(id = "k2", name = "Backup", apiKey = "sk-backup-00000000beef"),
            RelayKey(id = "k3", name = "Empty", apiKey = "sk-empty-00000000cafe"),
        )
        val provider = multiKey(models = enabled, catalog = catalog, keys = keys)
        val library = groups(catalog[1], catalog[3])

        val byBackup = build(provider, library, filter = RelayCatalogFilter.Key("k2"))
        assertEquals(RelayCatalogFilter.Key("k2"), byBackup.selected)
        // A single transport normally hides the whole row; when the key filter is active it appears, after "All".
        assertEquals(listOf(RelayCatalogFilter.All, RelayCatalogFilter.Key("k2")), byBackup.filters)
        assertTrue(RelayCatalogPageSection.Filters in byBackup.sections)
        // Chip display name = the same function as the key row title.
        assertEquals(RelayKeysBoardModel.build(provider).rows.single { it.id == "k2" }.title, byBackup.keyFilterTitle)
        assertEquals("Backup", byBackup.keyFilterTitle)
        assertEquals(listOf("c"), byBackup.enabled.rows.map { it.model.id })
        assertEquals(listOf("b"), byBackup.library.groups.flatMap { it.rows }.map { it.model.id })
        // The count is still the total.
        assertEquals(2, byBackup.enabled.count)
        // The predicate shares its source with the production lister: every remaining row is listed by k2, and every filtered-out row is not.
        (byBackup.enabled.rows + byBackup.library.groups.flatMap { it.rows }).forEach {
            assertTrue(it.model.id, "k2" in RelayKeyBinding.listingKeyIDs(provider, it.model.id))
        }

        val byMain = build(provider, library, filter = RelayCatalogFilter.Key("k1"))
        assertEquals(listOf("c", "a"), byMain.enabled.rows.map { it.model.id })
        assertEquals(listOf("d"), byMain.library.groups.flatMap { it.rows }.map { it.model.id })
        assertEquals("Main", byMain.keyFilterTitle)

        // Filter inactive: the chip does not appear.
        val plain = build(provider, library)
        assertTrue(plain.filters.isEmpty())
        assertNull(plain.keyFilterTitle)

        // The key no longer exists / the catalog is 0 -> fall back to "All", no chip.
        listOf("gone", "k3").forEach { id ->
            val fallback = build(provider, library, filter = RelayCatalogFilter.Key(id))
            assertEquals(id, RelayCatalogFilter.All, fallback.selected)
            assertTrue(id, fallback.filters.isEmpty())
            assertNull(id, fallback.keyFilterTitle)
            assertEquals(id, listOf("b", "d"), fallback.library.groups.flatMap { it.rows }.map { it.model.id })
        }

        // Multiple transports: the key chip still sits after "All" and before the transports; tapping a transport chip leaves the key filter and the key chip disappears.
        val mixedCatalog = catalog + AIModel(id = "g", name = "g", relayTransport = RelayTransport.GeminiGenerateContent, relayListedByKeyIDs = listOf("k2"))
        val mixed = multiKey(models = enabled, catalog = mixedCatalog, keys = keys)
        val mixedLibrary = groups(catalog[1], catalog[3], mixedCatalog.last())
        val mixedByKey = build(mixed, mixedLibrary, filter = RelayCatalogFilter.Key("k2"))
        assertEquals(
            listOf(
                RelayCatalogFilter.All,
                RelayCatalogFilter.Key("k2"),
                RelayCatalogFilter.Protocol(RelayBoardProtocol.Chat),
                RelayCatalogFilter.Protocol(RelayBoardProtocol.Gemini),
            ),
            mixedByKey.filters,
        )
        assertEquals(listOf("b", "g"), mixedByKey.library.groups.flatMap { it.rows }.map { it.model.id })
        val left = build(mixed, mixedLibrary, filter = RelayCatalogFilter.Protocol(RelayBoardProtocol.Gemini))
        assertFalse(left.filters.any { it is RelayCatalogFilter.Key })
        assertNull(left.keyFilterTitle)

        // A single (implicit) key can also be filtered by key.
        val single = relay(models = listOf(AIModel(id = "x", name = "x", isDefault = true)), catalog = listOf(AIModel(id = "x", name = "x"), AIModel(id = "y", name = "y")))
        val implicitID = RelayKeyBinding.keyIDs(single).single()
        val singleBoard = build(single, groups(AIModel(id = "y", name = "y")), filter = RelayCatalogFilter.Key(implicitID))
        assertEquals(RelayCatalogFilter.Key(implicitID), singleBoard.selected)
        assertEquals(RelayKeysBoardModel.build(single).rows.single().title, singleBoard.keyFilterTitle)
        assertEquals(listOf("y"), singleBoard.library.groups.flatMap { it.rows }.map { it.model.id })
    }

    // ── BOARD-CATALOG-21: enter with key(id), the first frame already has that filter ──

    @Test
    fun `BOARD-CATALOG-21 opening the library with a key filter selects it on the first frame`() {
        val catalog = listOf(
            AIModel(id = "a", name = "a", relayListedByKeyIDs = listOf("k1")),
            AIModel(id = "b", name = "b", relayListedByKeyIDs = listOf("k2")),
        )
        val provider = multiKey(models = listOf(catalog[0].copy(isDefault = true)), catalog = catalog)
        val stack = RelayDetailNavStack().push(RelayDetailLayer.Keys).push(RelayDetailLayer.Library(keyFilter = "k2"))
        // The filter layer is restored as is after rotation / process recreation.
        assertEquals(stack, RelayDetailNavStack.decode(RelayDetailNavStack.encode(stack)))
        assertTrue(stack.showsLibrary)

        val first = build(provider, groups(catalog[1]), filter = RelayCatalogBoardModel.initialFilter(stack))
        assertEquals(RelayCatalogFilter.Key("k2"), first.selected)
        assertEquals(listOf(RelayCatalogFilter.All, RelayCatalogFilter.Key("k2")), first.filters)
        assertEquals("Backup", first.keyFilterTitle)
        // With the advanced page on top it still follows that layer's filter; going back returns to the key page.
        assertEquals(RelayCatalogFilter.Key("k2"), RelayCatalogBoardModel.initialFilter(stack.push(RelayDetailLayer.Advanced("b", readOnly = true))))
        assertEquals(RelayDetailLayer.Keys, stack.pop().top)
        // Entering without a filter = "All".
        assertEquals(RelayCatalogFilter.All, RelayCatalogBoardModel.initialFilter(RelayDetailNavStack().push(RelayDetailLayer.Library())))
    }

    private fun mainSource(relative: String): String {
        val direct = java.io.File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct.readText()
        return java.io.File("app/src/main/java/ai/oriveo/community/$relative").readText()
    }

    private fun englishString(name: String): String? {
        val direct = java.io.File("src/main/res/values/strings.xml")
        val file = if (direct.exists()) direct else java.io.File("app/src/main/res/values/strings.xml")
        val doc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = doc.getElementsByTagName("string")
        for (i in 0 until nodes.length) {
            val element = nodes.item(i) as org.w3c.dom.Element
            if (element.getAttribute("name") == name) return element.textContent.replace("\\'", "'")
        }
        return null
    }

    /** Production ProviderRepository + production RelayService with an upstream MockEngine: GET returns an empty catalog, POST (1-token probe) returns [pingStatus]. */
    private class ProbeHarness(
        var pingStatus: HttpStatusCode,
        /** true = implicit single key (relayKeys empty), models are not bound to a key. */
        singleKey: Boolean = false,
    ) {
        var pings = 0
        /** Model id of each 1-token request (in send order). */
        val pingModels = mutableListOf<String>()
        /** GET returns these models for the catalog; empty = empty catalog. */
        var catalogIDs: List<String> = emptyList()
        /** Returns 401 when the catalog is fetched with these key values. */
        val catalogFailSecrets = mutableSetOf<String>()
        /** Scope of the lazy-check background coroutines: cases join its children to wait for background re-probes to finish. */
        val probeScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

        suspend fun awaitBackgroundProbes() {
            probeScope.coroutineContext[kotlinx.coroutines.Job]!!.children.toList().forEach { it.join() }
        }
        /** Number of connection persists (dao.upsert). */
        var upserts = 0
        /** When non-null, 1-token requests hang here so they can be cancelled while in flight. */
        var hold: kotlinx.coroutines.CompletableDeferred<Unit>? = null
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        var apiKey = "sk-main-0000000000001111"
        val secrets = mutableMapOf("k2" to "sk-backup-00000000beef")
        var stored: ProviderEntity? = with(ProviderMapper) {
            Provider(
                id = PROVIDER_ID,
                kind = ProviderKind.Relay,
                status = ProviderConnectionState.Connected,
                baseUrlText = "https://relay.example.com/v1",
                relayKind = RelayKind.OpenAICompatible,
                relayRequested = RelayRequestedConfig(
                    // Only auto connection transport has a lazy check; a user-chosen connection transport is not probed.
                    transport = RelayTransport.Auto,
                    resolvedAPIBaseURL = "https://relay.example.com/v1",
                ),
                relayKeys = if (singleKey) null else listOf(RelayKey(id = "k1", name = "Main"), RelayKey(id = "k2", name = "Backup", apiKey = "sk-backup-00000000beef")),
                models = listOf(
                    AIModel(id = "gpt-5", name = "gpt-5", relayKeyID = "k1".takeUnless { singleKey }),
                    AIModel(id = "o3", name = "o3", relayKeyID = "k1".takeUnless { singleKey }),
                ),
                catalogModels = listOf(
                    AIModel(id = "gpt-5", name = "gpt-5", relayListedByKeyIDs = listOf("k1", "k2")),
                    AIModel(id = "o3", name = "o3", relayListedByKeyIDs = listOf("k1", "k2")),
                ),
            ).toEntity(ACCOUNT)
        }

        private val json = Json { ignoreUnknownKeys = true }
        private val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get) {
                val auth = request.headers.entries().flatMap { it.value }
                if (catalogFailSecrets.any { secret -> auth.any { it.contains(secret) } }) {
                    respond("{\"error\":\"Invalid API key\"}", HttpStatusCode.Unauthorized, headersOf(HttpHeaders.ContentType, "application/json"))
                } else {
                    val data = catalogIDs.joinToString(",") { "{\"id\":\"$it\",\"object\":\"model\"}" }
                    respond("{\"data\":[$data]}", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
                }
            } else {
                pings += 1
                (request.body as? TextContent)?.text
                    ?.let { runCatching { json.parseToJsonElement(it).jsonObject["model"]?.jsonPrimitive?.content }.getOrNull() }
                    ?.let { pingModels += it }
                entered.complete(Unit)
                hold?.await()
                respond(
                    if (pingStatus == HttpStatusCode.OK) "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}]}" else "{\"error\":\"Invalid API key\"}",
                    pingStatus,
                    headersOf(HttpHeaders.ContentType, "application/json"),
                )
            }
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers {
                upserts += 1
                stored = firstArg()
            }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
            ProviderRepository(
                dao = dao,
                conversationDao = mockk(relaxed = true),
                secureKeyStore = keys,
                openRouterService = mockk(relaxed = true),
                openAIService = mockk(relaxed = true),
                deepSeekService = mockk(relaxed = true),
                grokService = mockk(relaxed = true),
                anthropicService = mockk(relaxed = true),
                geminiService = mockk(relaxed = true),
                groqService = mockk(relaxed = true),
                togetherService = mockk(relaxed = true),
                fireworksService = mockk(relaxed = true),
                miniMaxService = mockk(relaxed = true),
                zhipuService = mockk(relaxed = true),
                qwenService = mockk(relaxed = true),
                moonshotService = mockk(relaxed = true),
                mistralService = mockk(relaxed = true),
                siliconFlowService = mockk(relaxed = true),
                relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
                metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayModelFamily = { null },
                relayProbeScope = probeScope,
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }

        fun store(provider: Provider) {
            stored = with(ProviderMapper) { provider.toEntity(ACCOUNT) }
        }

        val snackbar: ai.oriveo.community.core.app.GlobalSnackbarManager = mockk(relaxed = true)

        /** Production ViewModel wrapping the production repository (only observeById is wired to the persisted value). */
        val spyRepository: ProviderRepository by lazy {
            io.mockk.spyk(repository).also { spy ->
                every { spy.observeById(PROVIDER_ID) } answers { MutableStateFlow(current()) }
            }
        }

        suspend fun <T> withViewModel(block: suspend (ProviderDetailViewModel) -> T): T {
            kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.Dispatchers.Unconfined)
            val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined)
            var created: ProviderDetailViewModel? = null
            try {
                val viewModel = ProviderDetailViewModel(
                    savedStateHandle = androidx.lifecycle.SavedStateHandle(mapOf("providerID" to PROVIDER_ID)),
                    providerRepository = spyRepository,
                    appPreferencesRepository = mockk(relaxed = true),
                    metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
                    applicationScope = scope,
                    globalSnackbarManager = snackbar,
                )
                created = viewModel
                scope.launch { viewModel.provider.collect {} }
                kotlinx.coroutines.withTimeout(5_000) { while (viewModel.provider.value == null) kotlinx.coroutines.delay(10) }
                return block(viewModel)
            } finally {
                // Stop the in-flight coroutines in the ViewModel first (persist / lazy check return from IO to Main), then remove Main so nothing leaks into the next case.
                created?.viewModelScope?.coroutineContext?.get(kotlinx.coroutines.Job)?.cancel()
                scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
                kotlinx.coroutines.delay(300)
                kotlinx.coroutines.Dispatchers.resetMain()
            }
        }

        companion object {
            const val ACCOUNT = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
            const val PROVIDER_ID = "44444444-4444-4444-8444-444444444444"
        }
    }
}
