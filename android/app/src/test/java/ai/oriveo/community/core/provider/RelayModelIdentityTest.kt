package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.resolveSendModelSelection
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.resolveActiveModel
import ai.oriveo.community.core.model.resolveLastUsedModelRef
import ai.oriveo.community.feature.providers.detail.buildProviderCatalogGroups
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Relays judge identity by the literal ID: gpt-4o and gpt-4o-2024-08-06 are two different models.
 * All assertions use outputs of production paths (decoding, catalog projection, catalog refresh, selection resolution, runtime identity).
 */
class RelayModelIdentityTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private val base = AIModel(id = "gpt-4o", name = "GPT-4o", canonicalModelId = "gpt-4o")
    private val dated = AIModel(id = "gpt-4o-2024-08-06", name = "GPT-4o", canonicalModelId = "gpt-4o")
    private val dated2 = AIModel(id = "gpt-4o-2024-11-20", name = "GPT-4o", canonicalModelId = "gpt-4o")
    private val claude = AIModel(id = "claude-sonnet-4-5", name = "Claude Sonnet 4.5", canonicalModelId = "claude-sonnet-4-5")

    private fun relay(models: List<AIModel>, catalog: List<AIModel> = models) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalog,
    )

    @Test
    fun `RL2-IDENT-01 relay decode keeps dated rows in catalog and enabled list`() {
        val stored = relay(models = listOf(base, dated), catalog = listOf(dated, base, dated2))
        val decoded = with(ProviderMapper) { stored.toEntity().toDomain("sk-test") }

        assertEquals(listOf("gpt-4o-2024-08-06", "gpt-4o", "gpt-4o-2024-11-20"), decoded.catalogModels.map { it.id })
        assertEquals(listOf("gpt-4o", "gpt-4o-2024-08-06"), decoded.models.map { it.id })
        // The enabled list is likewise deduplicated by literal key: ones differing only in case are the same, and the first one wins.
        val caseTwin = with(ProviderMapper) {
            relay(models = listOf(base, base.copy(id = "GPT-4o"), dated)).toEntity().toDomain("sk-test")
        }
        assertEquals(listOf("gpt-4o", "gpt-4o-2024-08-06"), caseTwin.models.map { it.id })

        // Model library projection: both not-enabled snapshots are present (they are not merged onto the enabled base).
        val library = buildProviderCatalogGroups(
            provider = relay(models = listOf(base), catalog = listOf(dated, base, dated2)),
            searchQuery = "",
            relayFamily = { null },
        ).flatMap { group -> group.models.map { it.id } }
        assertEquals(setOf("gpt-4o-2024-08-06", "gpt-4o-2024-11-20"), library.toSet())
    }

    @Test
    fun `RL2-IDENT-02 selecting the dated relay model stores and sends the dated id`() {
        val provider = relay(models = listOf(base, dated))

        val send = resolveSendModelSelection(provider, "gpt-4o-2024-08-06")
        assertEquals("gpt-4o-2024-08-06", send.runtimeModelId)
        assertEquals("gpt-4o-2024-08-06", send.storedModelId)

        val persisted = ProviderSelectionSnapshot.persistedSelection(provider, "gpt-4o-2024-08-06")
        assertEquals("gpt-4o-2024-08-06", persisted?.storedModelId)
        assertEquals("gpt-4o-2024-08-06", ProviderSelectionSnapshot.runtimeModelId(provider, "gpt-4o-2024-08-06"))

        val lastUsed = resolveLastUsedModelRef(listOf(provider), LastUsedModelRef("relay-1", "gpt-4o-2024-08-06"))
        assertEquals("gpt-4o-2024-08-06", lastUsed?.modelID)
        val active = resolveActiveModel(listOf(provider), LastUsedModelRef("relay-1", "gpt-4o"))
        assertEquals("gpt-4o", active?.model?.id)
        assertEquals("gpt-4o", resolveLastUsedModelRef(listOf(provider), LastUsedModelRef("relay-1", "gpt-4o"))?.modelID)
    }

    @Test
    fun `RL2-IDENT-03 disabling one relay snapshot leaves the other enableable and enabled`() {
        // After disabling dated only base remains: dated returns to the model library and can be enabled again on its own.
        val afterDisable = relay(models = listOf(base), catalog = listOf(base, dated))
        val resolved = ProviderCatalogResolver.resolve(afterDisable)
        assertEquals(setOf("gpt-4o"), resolved.enabledModels.map { it.model.id }.toSet())
        assertTrue(resolved.catalog.single { it.model.id == "gpt-4o-2024-08-06" }.isEnabled.not())

        val reEnabled = ModelSelectionUtils.enableModel(afterDisable, dated)
        assertEquals(listOf("gpt-4o", "gpt-4o-2024-08-06"), reEnabled.models.map { it.id })

        // Disabling base: dated stays in the enabled list and still resolves literally.
        val onlyDated = relay(models = listOf(dated), catalog = listOf(base, dated))
        assertEquals("gpt-4o-2024-08-06", ProviderSelectionSnapshot.selectedModel(onlyDated, "gpt-4o-2024-08-06")?.id)
        val library = buildProviderCatalogGroups(onlyDated, searchQuery = "", relayFamily = { null })
            .flatMap { group -> group.models.map { it.id } }
        assertEquals(listOf("gpt-4o"), library)
    }

    @Test
    fun `RL2-IDENT-04 catalog refresh keeps enabled dated snapshot even when only base is listed`() {
        val existing = relay(models = listOf(base, dated), catalog = listOf(base, dated))

        val both = ModelSelectionUtils.replaceRelayCatalog(existing.catalogModels, listOf(base, dated), ProviderKind.Relay)
        val keptBoth = ModelSelectionUtils.retainRelayEnabledModels(existing.models, both, ProviderKind.Relay)
        assertEquals(listOf("gpt-4o", "gpt-4o-2024-08-06"), keptBoth.map { it.id })

        val onlyBase = ModelSelectionUtils.replaceRelayCatalog(existing.catalogModels, listOf(base), ProviderKind.Relay)
        val keptOnlyDated = ModelSelectionUtils.retainRelayEnabledModels(listOf(dated), onlyBase, ProviderKind.Relay)
        assertEquals(listOf("gpt-4o-2024-08-06"), keptOnlyDated.map { it.id })

        // After the catalog confirms, dated is judged "gone from the catalog" and base is not.
        val refreshed = relay(models = keptOnlyDated, catalog = onlyBase)
        val index = ModelSelectionUtils.catalogMembershipIndex(refreshed.catalogModels, ProviderKind.Relay)
        assertTrue(
            ai.oriveo.community.feature.providers.detail.RelayCatalogBoardModel
                .isMissingFromConfirmedCatalog(refreshed, dated, index),
        )
    }

    @Test
    fun `RL2-IDENT-05 legacy canonical stored value resolves only when unique`() {
        val unique = relay(models = listOf(dated, claude))
        assertEquals("gpt-4o-2024-08-06", ProviderSelectionSnapshot.selectedModel(unique, "gpt-4o")?.id)
        assertEquals("gpt-4o-2024-08-06", resolveActiveModel(listOf(unique), LastUsedModelRef("relay-1", "gpt-4o"))?.model?.id)
        assertNull(RelayModelFallback.removedConnectionName(unique, "gpt-4o"))
        assertEquals("GPT-4o", ModelDisplayLookup(listOf(unique)).modelDisplayName("relay-1", "gpt-4o", fallback = null))

        val ambiguous = relay(models = listOf(dated, dated2))
        assertNull(ProviderSelectionSnapshot.selectedModel(ambiguous, "gpt-4o"))
        assertNotNull("judged removed when both snapshots equal the old canonical", RelayModelFallback.removedConnectionName(ambiguous, "gpt-4o"))
        assertTrue(RelayModelFallback.isSelectionRemoved(listOf(ambiguous), "relay-1", "gpt-4o"))
        assertNull(ModelDisplayLookup(listOf(ambiguous)).selectedModel(ambiguous, "gpt-4o"))

        // Resolution only looks in the enabled list: when the catalog has base and only dated is enabled, the old stored value gpt-4o resolves to dated.
        val catalogHasBase = relay(models = listOf(dated, claude), catalog = listOf(base, dated, claude))
        assertEquals("gpt-4o-2024-08-06", ProviderSelectionSnapshot.selectedModel(catalogHasBase, "gpt-4o")?.id)
        assertEquals("gpt-4o-2024-08-06", resolveActiveModel(listOf(catalogHasBase), LastUsedModelRef("relay-1", "gpt-4o"))?.model?.id)
        assertEquals("gpt-4o-2024-08-06", ModelDisplayLookup(listOf(catalogHasBase)).selectedModel(catalogHasBase, "gpt-4o")?.id)
        assertNull(RelayModelFallback.removedConnectionName(catalogHasBase, "gpt-4o"))

        // A stored dated value does not fall back to base.
        val onlyBase = relay(models = listOf(base))
        assertNotNull(RelayModelFallback.removedConnectionName(onlyBase, "gpt-4o-2024-08-06"))
    }

    @Test
    fun `RL2-IDENT-06 relay capability identity keys by the literal id`() {
        val client = runtimeMetadata()
        val provider = relay(models = listOf(base, dated))
        val datedModel = dated.copy(relayTransport = RelayTransport.OpenAIResponses)

        val identity = ModelControlRuntimeIdentityResolver.resolve(provider, datedModel, client)
            ?: throw AssertionError("relay identity must resolve")
        assertEquals("gpt-4o-2024-08-06", identity.canonicalModelId)
        assertEquals("gpt-4o", identity.legacyModelId)

        val baseIdentity = ModelControlRuntimeIdentityResolver.resolve(
            provider, base.copy(relayTransport = RelayTransport.OpenAIResponses), client,
        ) ?: throw AssertionError("relay identity must resolve")
        assertEquals("gpt-4o", baseIdentity.canonicalModelId)
        assertNull(baseIdentity.legacyModelId)

        // A miss on the literal key falls back to the old canonical key; once the literal key is written it takes precedence.
        var payload: String? = null
        val store = ai.oriveo.community.core.model.CapabilityPreferenceStore(read = { payload }, write = { payload = it })
        val transport = identity.storageIdentity
        val legacyValues = ai.oriveo.community.core.model.CapabilityPreferenceValues(reasoningIntent = "high")
        store.setConnectionModel(legacyValues, provider.id, "gpt-4o", transport)
        fun read() = store.scopeValues(
            provider.id, identity.canonicalModelId, null, null, transport, legacyModelID = identity.legacyModelId,
        ).connectionModel
        assertEquals(legacyValues, read())
        assertNull(store.scopeValues(provider.id, identity.canonicalModelId, null, null, transport).connectionModel)
        val literalValues = ai.oriveo.community.core.model.CapabilityPreferenceValues(reasoningIntent = "low")
        store.setConnectionModel(literalValues, provider.id, identity.canonicalModelId, transport)
        assertEquals(literalValues, read())

        // Custom fields / additional request body are keyed by the same identity and read back the same way.
        var fragments: String? = null
        var bodies: String? = null
        val fragmentStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore(
            { fragments }, { fragments = it }, readAdditionalBody = { bodies }, writeAdditionalBody = { bodies = it },
        )
        val legacyJson = """{"temperature":0.2}"""
        fragmentStore.setConfiguration(
            ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.Configuration(true, legacyJson),
            provider.id, "gpt-4o", null, transport,
        )
        fragmentStore.setAdditionalBody(
            ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody(legacyJson, true),
            provider.id, "gpt-4o", null,
        )
        assertEquals(
            legacyJson,
            fragmentStore.effectiveConfiguration(
                provider.id, identity.canonicalModelId, "conversation-1", transport, legacyModelID = identity.legacyModelId,
            ).rawJSON,
        )
        assertEquals("", fragmentStore.effectiveConfiguration(provider.id, identity.canonicalModelId, "conversation-1", transport).rawJSON)
        assertEquals(
            legacyJson,
            fragmentStore.outboundAdditionalBody(provider.id, identity.canonicalModelId, "conversation-1", identity.legacyModelId),
        )
        assertNull(fragmentStore.outboundAdditionalBody(provider.id, identity.canonicalModelId, "conversation-1"))
        val literalJson = """{"temperature":0.9}"""
        fragmentStore.setConfiguration(
            ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.Configuration(true, literalJson),
            provider.id, identity.canonicalModelId, null, transport,
        )
        assertEquals(
            literalJson,
            fragmentStore.effectiveConfiguration(
                provider.id, identity.canonicalModelId, "conversation-1", transport, legacyModelID = identity.legacyModelId,
            ).rawJSON,
        )
    }

    @Test
    fun `RL2-IDENT-08 official openAI still folds dated snapshots onto the base model`() {
        val kind = ProviderKind.OpenAI
        assertEquals("gpt-4o", ModelSelectionUtils.matchingModel(listOf(base), "gpt-4o-2024-08-06", kind)?.id)
        assertTrue(ModelSelectionUtils.modelsShareSameRemoteModel(base, dated, kind))
        assertEquals("gpt-4o", ModelSelectionUtils.preferredStoredModelIdentifier(dated, kind))
        assertEquals(listOf("gpt-4o"), ModelSelectionUtils.deduplicate(listOf(dated, base), kind).map { it.id })

        val official = Provider(id = "openai-1", kind = kind, models = listOf(base), catalogModels = listOf(dated, base))
        val decoded = with(ProviderMapper) { official.toEntity().toDomain("sk-test") }
        assertEquals(listOf("gpt-4o"), decoded.catalogModels.map { it.id })
    }

    private fun runtimeMetadata(): MetadataClient {
        val client = MetadataClient()
        val registry = workspaceFile(
            "shared/capabilityrecipe/capability_runtime.v1.json",
        ).readText().trim().removeSuffix("}") +
            ",\"revision\":\"runtime-r7\",\"generatedAt\":\"2026-08-14T00:00:00Z\"}"
        client.loadNetworkPayloadForTesting(
            """{"version":1,"capabilityRuntime":$registry,"providers":{}}""",
            "etag-relay-literal-identity",
        )
        return client
    }

    private fun workspaceFile(relativePath: String): File = generateSequence(
        File(System.getProperty("user.dir") ?: ".").absoluteFile,
    ) { it.parentFile }
        .map { File(it, relativePath) }
        .firstOrNull { it.isFile }
        ?: error("workspace file missing: $relativePath")
}
