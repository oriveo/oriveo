package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.chat.resolveMessageDisplayMetadata
import ai.oriveo.community.feature.home.resolveConversationModelName
import java.util.concurrent.Executors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Resolving the model display name of every conversation row on Home and in folders, and of every chat
 * message, must not cost more as a relay catalog grows.
 *
 * With a public relay catalog of 22,014 models, every providers emission made [ModelDisplayLookup]
 * rebuild `(models + catalogModels).distinctBy` for every row and scan the whole catalog with
 * matchingModel, 1.7 to 2.4ms per row; each row also scanned the enabled models one by one (after
 * "add all" that is the whole catalog too).
 *
 * The data follows the production path: the catalog comes out of [prepareProviderForUpsert]
 * (enrichment and resolve before a write), and a conversation's modelID comes from
 * [ProviderSelectionSnapshot.persistedSelection] (the value stored after picking a model). The
 * equivalence reference is the per-row scan as it was, built on the production functions.
 */
class ModelDisplayLookupScaleTest {

    @Before
    fun setUp() {
        // Give relay enrichment a real official catalog to hit: a hit carries canonicalModelId and the official
        // display name, the conversation stores the canonical id, the exact pass misses and the fuzzy pass answers.
        // That shape exists in production.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf(
                    "gpt-4o" to "gpt-4o",
                    "gpt-4o-2024-08-06" to "gpt-4o",
                    "gpt-4o-mini" to "gpt-4o-mini",
                    "gpt-4.1" to "gpt-4.1",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o", displayName = "GPT-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o-mini", canonicalModelId = "gpt-4o-mini", displayName = "GPT-4o mini"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1", canonicalModelId = "gpt-4.1", displayName = "GPT-4.1"),
                ),
            ),
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-sonnet-4-5",
                resolveMap = mapOf(
                    "claude-sonnet-4-5" to "claude-sonnet-4-5",
                    "claude-sonnet-4-5-20250929" to "claude-sonnet-4-5",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "claude-sonnet-4-5",
                        canonicalModelId = "claude-sonnet-4-5",
                        displayName = "Claude Sonnet 4.5",
                    ),
                ),
            ),
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    // ---- Scale ----

    /**
     * One providers emission = a new [ModelDisplayLookup] (as HomeScreen's `remember(providers)` does) plus one
     * resolution for each of some Home rows (visible rows plus prefetch). Two warmups, then the median of five runs.
     *
     * Scanning the whole catalog per row made an emission cost grow with rows x catalog size. With one index per
     * provider per emission and a lookup per row, 10x the rows barely changes the emission cost and 10x the catalog
     * leaves the per-row cost unchanged. It measures the calling thread's CPU time (ThreadMXBean; wall clock
     * stretches when the machine is loaded), and the assertions only pin the growth factors.
     */
    @Test
    fun `home rows resolve model names without rescanning a 22k relay catalog per row`() {
        fun emissionMs(provider: Provider, rows: List<Conversation>) = medianMillis(warmups = 2, runs = 5) {
            val lookup = ModelDisplayLookup(listOf(provider))
            rows.forEach { resolveConversationModelName(it, provider, lookup) }
        }

        /** Per-row marginal cost: resolve the rows once more after the same emission has built its indexes. */
        fun rowsAfterIndexMs(provider: Provider, rows: List<Conversation>) = medianMillis(warmups = 2, runs = 5) {
            val lookup = ModelDisplayLookup(listOf(provider))
            rows.forEach { resolveConversationModelName(it, provider, lookup) }
            val start = threadCpuNanos()
            rows.forEach { resolveConversationModelName(it, provider, lookup) }
            recordNanos(threadCpuNanos() - start)
        }

        // The usual case (1,500 enabled) and "add all" (enabled = the whole catalog; a row with no display name
        // falls back to searching the enabled list, which must not be a per-row scan either)
        listOf(false, true).forEach { enableAll ->
            val label = if (enableAll) "allEnabled" else "enabled=$ENABLED"
            val small = relayProvider(catalogSize = 2_200, enableAll = enableAll)
            val large = relayProvider(catalogSize = 22_000, enableAll = enableAll)
            val largeRows = conversations(large, count = ROWS)
            val fewRowsEmission = emissionMs(large, largeRows.take(ROWS / 10))
            val largeEmission = emissionMs(large, largeRows)
            val smallRowsOnly = rowsAfterIndexMs(small, conversations(small, count = ROWS))
            val largeRowsOnly = rowsAfterIndexMs(large, largeRows)
            println(
                "ModelDisplayLookupScaleTest $label catalog=22000 emission rows ${ROWS / 10}=${"%.1f".format(fewRowsEmission)}ms " +
                    "rows $ROWS=${"%.1f".format(largeEmission)}ms; perRow catalog 2200=${"%.1f".format(smallRowsOnly * 1_000 / ROWS)}µs " +
                    "22000=${"%.1f".format(largeRowsOnly * 1_000 / ROWS)}µs",
            )

            // Preconditions: the rows include exact hits, fuzzy-pass hits (canonical ids after enrichment) and
            // fallbacks, and the first batch (the denominator of the 10x rows) already has the latter two, so both
            // sides build the same indexes and only the row count differs.
            val lookup = ModelDisplayLookup(listOf(large))
            val names = largeRows.map { resolveConversationModelName(it, large, lookup) }
            assertTrue("precondition: an official display name after enrichment", "GPT-4o" in names)
            assertTrue("precondition: a retired model falling back to its raw id", largeRows.any { it.modelID.startsWith("retired-") && it.modelID in names })
            val fewRows = largeRows.take(ROWS / 10)
            assertTrue("precondition: the first batch already has fuzzy-pass and fallback rows", fewRows.any { it.modelID == "gpt-4o" } && fewRows.any { it.modelID.startsWith("retired-") })

            assertTrue(
                "$label one emission over a 22k catalog: 10x rows took ${"%.1f".format(fewRowsEmission)}ms -> ${"%.1f".format(largeEmission)}ms, still scanning the catalog per row",
                largeEmission / fewRowsEmission < 2.0,
            )
            assertTrue(
                "$label per-row cost grows with the catalog: 2.2k ${"%.3f".format(smallRowsOnly)}ms -> 22k ${"%.3f".format(largeRowsOnly)}ms",
                largeRowsOnly / smallRowsOnly < 2.5,
            )
        }
    }

    /**
     * Home, folders and chat only read the lookup the view model built in the background ([modelDisplayLookups]):
     * after a fresh emission, the composition thread's CPU for the first rows includes no index build. Before, composition
     * did `remember(providers) { ModelDisplayLookup(providers) }` and the first row built the 22k catalog index on the
     * main thread (fuzzy layer included: these rows have canonical ids and retired models).
     */
    @Test
    fun `rows on the composition thread do not build the 22k catalog index`() = runBlocking {
        val composition = Executors.newSingleThreadExecutor { Thread(it, "fake-main") }.asCoroutineDispatcher()
        try {
            val medians = listOf(false, true).map { enableAll ->
                val provider = relayProvider(catalogSize = 22_000, enableAll = enableAll)
                val rows = conversations(provider, count = ROWS)
                val samples = (1..7).map {
                    // Every round is a fresh emission, built in the background as in production
                    val lookup = flowOf(listOf(provider)).modelDisplayLookups(Dispatchers.Default).first()
                    withContext(composition) {
                        val start = threadCpuNanos()
                        rows.forEach { resolveConversationModelName(it, provider, lookup) }
                        (threadCpuNanos() - start) / 1_000_000.0
                    }
                }.drop(2).sorted()
                val median = samples[samples.size / 2]
                val label = if (enableAll) "allEnabled" else "enabled=$ENABLED"
                println("ModelDisplayLookupScaleTest $label catalog=22000 composition-thread CPU for first $ROWS rows of a fresh emission=${"%.2f".format(median)}ms samples=$samples")
                label to median
            }
            medians.forEach { (label, median) ->
                assertTrue(
                    "$label: the first $ROWS rows after a fresh emission took ${"%.2f".format(median)}ms CPU on the composition thread; the index is still built there",
                    median < 5.0,
                )
            }
        } finally {
            composition.close()
        }
    }

    @Test
    fun `a pending lookup never shows a fallback name`() {
        val provider = relayProvider(catalogSize = 200)
        val row = conversations(provider, count = 1).single()
        assertFalse(ModelDisplayLookup.Pending.isReady)
        assertEquals("", resolveConversationModelName(row, provider, ModelDisplayLookup.Pending))
        assertEquals("a deleted provider still shows the stored id", row.modelID, resolveConversationModelName(row, null, ModelDisplayLookup.Pending))
        assertTrue(runBlocking { flowOf(listOf(provider)).modelDisplayLookups().first().isReady })
    }

    // ---- Equivalence: index lookups == the per-row scan they replace ----

    @Test
    fun `lookup answers match the per-row linear scan on production-shaped relay rows`() {
        val provider = relayProvider(catalogSize = 3_000)
        val lookup = ModelDisplayLookup(listOf(provider))
        val rows = conversations(provider, count = 400)
        rows.forEach { conversation ->
            assertEquals(
                "row ${conversation.modelID}",
                referenceConversationModelName(conversation, provider),
                resolveConversationModelName(conversation, provider, lookup),
            )
        }
    }

    @Test
    fun `lookup answers match the per-row linear scan on crafted edge cases`() {
        val relay = Provider(
            id = "relay-edge",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(
                model("Dup-Id", name = "enabled first", canonicalModelId = null, isDefault = true),
                // A duplicate id in the enabled list: only the first one becomes a local candidate, so the second one's canonical id never matches locally
                model("Dup-Id", name = "enabled dup", canonicalModelId = "only-on-dup"),
                model(" padded-model ", name = "padded"),
                model("manual-legacy-x", name = "legacy manual"),
                model("enabled-only", name = "Enabled Only"),
            ),
            catalogModels = listOf(
                model("dup-id", name = "catalog case twin"),
                model("GPT-4o", name = "upper"),
                model("gpt-4o", name = "lower"),
                model("gpt-4o-2024-08-06", name = "snapshot"),
                model("claude-3-5-sonnet-20241022", name = "dated"),
                model("vendor/alias", name = "aliased", canonicalModelId = " Canonical-Target "),
                model("Straße", name = "sharp s"),
                model("ſtrange", name = "long s"),
                model("Kelvin", name = "kelvin"),
                model("blank-name", name = ""),
                model("Dup-Id", name = "catalog exact dup"),
            ),
            customName = "Edge Relay",
        )
        val official = Provider(
            id = "official-edge",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                model("gpt-4o", name = "Local 4o", canonicalModelId = "gpt-4o", isDefault = true),
                model("my-finetune", name = "Fine-tune"),
            ),
            catalogModels = listOf(
                model("gpt-4.1", name = "Local 4.1"),
                model("GPT-4O-2024-08-06", name = "Local snapshot"),
            ),
        )
        val officialNoCatalog = official.copy(id = "official-no-catalog", catalogModels = emptyList())
        val providers = listOf(relay, official, officialNoCatalog)
        val queries = listOf(
            "Dup-Id", "dup-id", "DUP-ID", "only-on-dup", "padded-model", " padded-model ", "legacy-x", "manual-legacy-x",
            "enabled-only", "gpt-4o", "GPT-4O", "gpt-4o-2024-08-06", "gpt-4o-20240806", "claude-3-5-sonnet",
            "CLAUDE-3-5-SONNET-20241022", "canonical-target", "Canonical-Target-2025-01-01", "strasse", "STRASSE",
            "Strange", "STRANGE", "kelvin", "KELVIN", "blank-name", "gpt-4.1", "my-finetune", "missing",
            "missing-20250101", "", "   ", "manual-", null,
        )
        val lookup = ModelDisplayLookup(providers)
        // Query the same lookup repeatedly and across providers: the per-provider indexes must never mix
        repeat(2) {
            providers.forEach { provider ->
                queries.forEach { query ->
                    assertEquals(
                        "modelDisplayName(${provider.id}, $query)",
                        referenceModelDisplayName(provider, query, fallback = "fallback"),
                        lookup.modelDisplayName(provider.id, query, fallback = "fallback"),
                    )
                    assertEquals(
                        "canonicalModelId(${provider.id}, $query)",
                        referenceCanonicalModelId(provider, query),
                        lookup.canonicalModelId(provider.id, query),
                    )
                    assertEquals(
                        "selectedModel(${provider.id}, $query)",
                        ProviderSelectionSnapshot.selectedModel(provider, query),
                        lookup.selectedModel(provider, query),
                    )
                    // A caller holding another emission (a different object) must not be answered from this instance's index
                    val otherEmission = provider.copy(models = provider.models.drop(1))
                    assertEquals(
                        "selectedModel(other emission of ${provider.id}, $query)",
                        ProviderSelectionSnapshot.selectedModel(otherEmission, query),
                        lookup.selectedModel(otherEmission, query),
                    )
                    if (query != null) {
                        val conversation = conversation(provider, query)
                        assertEquals(
                            "resolveConversationModelName(${provider.id}, $query)",
                            referenceConversationModelName(conversation, provider),
                            resolveConversationModelName(conversation, provider, lookup),
                        )
                    }
                    val message = ChatMessage(
                        id = "m",
                        role = ChatRole.Assistant,
                        text = "hi",
                        providerID = provider.id,
                        providerKind = provider.kind,
                        providerName = "stored provider",
                        modelID = query,
                        modelName = "stored model",
                        state = ChatMessageState.Delivered,
                    )
                    assertEquals(
                        "resolveMessageDisplayMetadata(${provider.id}, $query)",
                        referenceModelDisplayName(provider, query, fallback = "stored model"),
                        resolveMessageDisplayMetadata(message, lookup).modelName,
                    )
                }
            }
        }
        assertEquals("fallback", lookup.modelDisplayName("unknown-provider", "gpt-4o", fallback = "fallback"))
        assertEquals(null, lookup.canonicalModelId("unknown-provider", "gpt-4o"))
    }

    @Test
    fun `lookup answers match the per-row linear scan on random catalogs`() {
        val random = java.util.Random(0x5EED)
        val stems = listOf("alpha", "Beta", "GAMMA", "gpt-4o", "claude-sonnet-4-5", "delta-2025-01-01", "eps")
        fun randomId(): String {
            var id = stems[random.nextInt(stems.size)] + "-${random.nextInt(12)}"
            if (random.nextInt(3) == 0) id = id.uppercase()
            if (random.nextInt(5) == 0) id += "-20250101"
            if (random.nextInt(9) == 0) id = "manual-$id"
            if (random.nextInt(7) == 0) id = " $id "
            if (random.nextInt(4) == 0) id = stems[random.nextInt(stems.size)]
            return id
        }
        fun randomModel(): AIModel = model(
            id = randomId(),
            name = if (random.nextInt(3) == 0) randomId() else "name-${random.nextInt(50)}",
            canonicalModelId = when (random.nextInt(4)) {
                0 -> randomId()
                1 -> "  ${randomId().lowercase()} "
                else -> null
            },
        )
        repeat(40) { round ->
            val kind = listOf(ProviderKind.Relay, ProviderKind.OpenAI, ProviderKind.OpenRouter)[round % 3]
            val catalog = (0 until 40 + random.nextInt(80)).map { randomModel() }
            val provider = Provider(
                id = "random-$round",
                kind = kind,
                status = ProviderConnectionState.Connected,
                models = (0 until 3 + random.nextInt(30)).map {
                    if (random.nextBoolean()) catalog[random.nextInt(catalog.size)] else randomModel()
                },
                catalogModels = if (random.nextInt(5) == 0) emptyList() else catalog,
            )
            val lookup = ModelDisplayLookup(listOf(provider))
            val queries = (0 until 60).map { if (random.nextBoolean()) randomId() else catalog[random.nextInt(catalog.size)].id }
            queries.forEach { query ->
                assertEquals(
                    "round=$round kind=$kind query=$query",
                    referenceModelDisplayName(provider, query, fallback = "fallback"),
                    lookup.modelDisplayName(provider.id, query, fallback = "fallback"),
                )
                assertEquals(
                    "round=$round kind=$kind canonical query=$query",
                    referenceCanonicalModelId(provider, query),
                    lookup.canonicalModelId(provider.id, query),
                )
                assertEquals(
                    "round=$round kind=$kind selectedModel query=$query",
                    ProviderSelectionSnapshot.selectedModel(provider, query),
                    lookup.selectedModel(provider, query),
                )
                val conversation = conversation(provider, query)
                assertEquals(
                    "round=$round kind=$kind row query=$query",
                    referenceConversationModelName(conversation, provider),
                    resolveConversationModelName(conversation, provider, lookup),
                )
            }
        }
    }

    /**
     * The fuzzy-pass index strips a date suffix from every model and skips the regex when the last character cannot
     * end a match. Random and edge-case strings are checked one by one against the unconditional regex: Unicode
     * digits, full-width digits, supplementary-plane digits, every line terminator, surrounding whitespace, and both
     * date shapes.
     */
    @Test
    fun `date suffix fast path agrees with the unconditional regex`() {
        val regex = Regex("""(?:-\d{8}|-\d{4}-\d{2}-\d{2})$""")
        val alphabet = listOf(
            "-", "-", "0", "1", "2", "9", "a", "Z", " ", "\t", "\n", "\r", "\r\n", "\u000B", "\u000C", "\u0085",
            " ", " ", "٣", "５", "𝟎", "\uD835", "\uDFCE", "Ⅷ", "²",
        )
        val random = java.util.Random(0xDA7E)
        val inputs = mutableListOf(
            "", " ", "gpt-4o", "gpt-4o-20240806", "gpt-4o-2024-08-06", " gpt-4o-2024-08-06 ", "gpt-4o-20240806\n",
            "gpt-4o-20240806\r\n", "gpt-4o-20240806\u0085", "gpt-4o-20240806 ", "x-2024080", "x-202408061",
            "x-٣٣٣٣٣٣٣٣", "x-２０２４０８０６", "-20240806", "x-2024-08-06-20240806",
        )
        repeat(20_000) {
            val builder = StringBuilder()
            if (random.nextInt(3) == 0) builder.append("model-")
            repeat(random.nextInt(14)) { builder.append(alphabet[random.nextInt(alphabet.size)]) }
            if (random.nextInt(4) == 0) builder.append(if (random.nextBoolean()) "-20250101" else "-2025-01-01")
            if (random.nextInt(5) == 0) builder.append(alphabet[random.nextInt(alphabet.size)])
            inputs += builder.toString()
        }
        inputs.forEach { input ->
            assertEquals(
                "input=${input.map { "\\u%04X".format(it.code) }.joinToString("")}",
                input.trim().replace(regex, ""),
                ModelSelectionUtils.stripSnapshotDateSuffix(input),
            )
        }
    }

    // ---- Reference: the per-row scan as it was, verbatim, built on production functions ----

    private fun referenceLocalModel(provider: Provider, targetId: String): AIModel? {
        val localCandidates = if (provider.catalogModels.isNotEmpty()) {
            (provider.models + provider.catalogModels).distinctBy { it.id }
        } else {
            provider.models
        }
        return ModelSelectionUtils.matchingModel(localCandidates, targetId)
    }

    private fun referenceModelDisplayName(
        provider: Provider,
        modelId: String?,
        fallback: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): String? {
        val targetId = modelId?.trim().orEmpty()
        if (targetId.isEmpty()) return fallback
        if (provider.kind == ProviderKind.Relay) {
            referenceLocalModel(provider, targetId)?.name?.let { return it }
        } else {
            val metadataResolved = metadata.resolveCatalogModel(targetId, provider.kind)
            metadataResolved?.displayName?.takeIf { it.isNotBlank() }?.let { return it }
            metadataResolved?.canonicalModelId?.let { canonicalId ->
                referenceLocalModel(provider, canonicalId)?.name?.let { return it }
                metadata.resolveCatalogModel(canonicalId, provider.kind)
                    ?.displayName
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            referenceLocalModel(provider, targetId)?.name?.let { return it }
        }
        return fallback
    }

    private fun referenceCanonicalModelId(
        provider: Provider,
        modelId: String?,
        metadata: MetadataClient = MetadataClient.instance,
    ): String? {
        val targetId = modelId?.trim().orEmpty()
        if (targetId.isEmpty()) return null
        referenceLocalModel(provider, targetId)?.canonicalModelId?.takeIf { it.isNotBlank() }?.let { return it }
        referenceLocalModel(provider, targetId)?.id?.let { return it }
        if (provider.kind != ProviderKind.Relay) {
            metadata.resolveCatalogModel(targetId, provider.kind)?.canonicalModelId?.let { return it }
        }
        return null
    }

    private fun referenceConversationModelName(conversation: Conversation, provider: Provider): String {
        val fallback = ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID)?.name
            ?: conversation.modelID
        return referenceModelDisplayName(provider, conversation.modelID, fallback) ?: fallback
    }

    // ---- Fixtures ----

    /**
     * The shape of a large public relay catalog (`org/model-variant`), mixed with a few ids that hit the official
     * catalog (official ids with a snapshot date: after enrichment the canonical id is the undated one, which has no
     * entry of its own in the catalog).
     */
    private fun relayProvider(catalogSize: Int, enableAll: Boolean = false): Provider {
        val officialShaped = listOf("gpt-4o-2024-08-06", "claude-sonnet-4-5-20250929", "gpt-4o-mini", "gpt-4.1")
        val catalog = (0 until catalogSize).map { index ->
            val id = if (index < officialShaped.size) {
                officialShaped[index]
            } else {
                "org-${index % 3_000}/Gemma-4-31B-it-variant-$index"
            }
            AIModel(id = id, name = id, capabilities = listOf(ModelCapability.Text), contextLength = 32_768)
        }
        val stride = (catalogSize / ENABLED).coerceAtLeast(1)
        // enableAll: the shape "add all" syncs down, where the enabled models are the whole catalog
        val enabled = (if (enableAll) catalog else catalog.filterIndexed { index, _ -> index < officialShaped.size || index % stride == 0 }
            .take(ENABLED))
            .mapIndexed { index, model -> model.copy(isDefault = index == 0) }
        return prepareProviderForUpsert(
            Provider(
                id = "5f0c7c52-5a8e-4a0e-9d7e-3b1f0a9c2e11",
                kind = ProviderKind.Relay,
                status = ProviderConnectionState.Connected,
                models = enabled,
                catalogModels = catalog,
                baseUrlText = "https://api.featherless.ai/v1",
                customName = "Featherless",
                relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            ),
        )
    }

    /** A conversation's stored modelID comes from the production [ProviderSelectionSnapshot.persistedSelection]; one row in 20 points at a retired model. */
    private fun conversations(provider: Provider, count: Int): List<Conversation> = (0 until count).map { index ->
        val requested = when {
            index % 20 == 3 -> "retired-$index"
            index < 4 -> provider.models[index].id
            else -> provider.models[(index * 37) % provider.models.size].id
        }
        val stored = ProviderSelectionSnapshot.persistedSelection(provider, requested)?.storedModelId ?: requested
        conversation(provider, stored, id = "conversation-$index")
    }

    private fun conversation(provider: Provider, modelID: String, id: String = "conversation") = Conversation(
        id = id,
        title = "Row",
        providerID = provider.id,
        providerKind = provider.kind,
        modelID = modelID,
    )

    private fun model(
        id: String,
        name: String = id,
        canonicalModelId: String? = null,
        isDefault: Boolean = false,
    ) = AIModel(
        id = id,
        name = name,
        capabilities = listOf(ModelCapability.Text),
        canonicalModelId = canonicalModelId,
        isDefault = isDefault,
    )

    private var recordedNanos: Long? = null

    private fun recordNanos(nanos: Long) {
        recordedNanos = nanos
    }

    private val threadMx = java.lang.management.ManagementFactory.getThreadMXBean()

    private fun threadCpuNanos(): Long = threadMx.currentThreadCpuTime

    /** Calling thread CPU time; if the block called [recordNanos], that span is used, otherwise the whole block. */
    private fun medianMillis(warmups: Int, runs: Int, block: () -> Unit): Double {
        repeat(warmups) { block() }
        val samples = (1..runs).map {
            recordedNanos = null
            val start = threadCpuNanos()
            block()
            val elapsed = recordedNanos ?: (threadCpuNanos() - start)
            elapsed / 1_000_000.0
        }.sorted()
        return samples[samples.size / 2]
    }

    private companion object {
        const val ROWS = 40
        const val ENABLED = 1_500
    }
}
