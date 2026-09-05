package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Unit tests for ProviderCatalogResolver.
 *
 * MetadataClient is a global object that depends on an Android Context, so in these tests an
 * official provider falls back to its local catalogModels whenever metadata is unavailable.
 * The relay tests do not depend on metadata at all.
 */
class ProviderCatalogResolverTest {

    @Before
    fun setUp() {
        clearMetadataTable()
    }

    @After
    fun tearDown() {
        clearMetadataTable()
    }

    private fun model(
        id: String,
        name: String = id,
        isDefault: Boolean = false,
        isAvailable: Boolean = true,
        isRecommended: Boolean = false,
        canonicalModelId: String? = null,
        sortRank: Int? = null,
        capabilities: List<ModelCapability> = listOf(ModelCapability.Text),
    ) = AIModel(
        id = id,
        name = name,
        isDefault = isDefault,
        isAvailable = isAvailable,
        isRecommended = isRecommended,
        canonicalModelId = canonicalModelId,
        sortRank = sortRank,
        capabilities = capabilities,
    )

    private fun relayProvider(
        models: List<AIModel> = emptyList(),
        catalogModels: List<AIModel> = emptyList(),
    ) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
    )

    private fun officialProvider(
        kind: ProviderKind = ProviderKind.OpenAI,
        models: List<AIModel> = emptyList(),
        catalogModels: List<AIModel> = emptyList(),
    ) = Provider(
        id = "official-1",
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
    )

    // 1. A relay uses its local catalogModels.

    @Test
    fun `Relay uses local catalogModels`() {
        val catalog = listOf(
            model("model-a"),
            model("model-b"),
        )
        val provider = relayProvider(
            models = listOf(model("model-a", isDefault = true)),
            catalogModels = catalog,
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(2, resolved.catalog.size)
        assertEquals(listOf("model-a", "model-b"), resolved.catalog.map { it.model.id })
    }

    // 2. The enabled state of a relay model is matched correctly.

    @Test
    fun `Relay enabled models correctly identified`() {
        val provider = relayProvider(
            models = listOf(model("model-a", isDefault = true)),
            catalogModels = listOf(model("model-a"), model("model-b"), model("model-c")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(1, resolved.enabledModels.size)
        assertEquals("model-a", resolved.enabledModels.first().model.id)
        assertTrue(resolved.enabledModels.first().isEnabled)
        assertFalse(resolved.enabledModels.first().isManual)
    }

    // 3. A manually added model is recognised even though it is not in the catalog.

    @Test
    fun `manual models not in catalog are identified`() {
        val provider = relayProvider(
            models = listOf(
                model("model-a", isDefault = true),
                model("custom-model"),
            ),
            catalogModels = listOf(model("model-a")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.hasManualModels)
        val manual = resolved.catalog.filter { it.isManual }
        assertEquals(1, manual.size)
        assertEquals("custom-model", manual.first().model.id)
        assertTrue(manual.first().isEnabled)
    }

    // 4. No model is enabled.

    @Test
    fun `zero enabled models returns empty enabledModels`() {
        val provider = relayProvider(
            models = emptyList(),
            catalogModels = listOf(model("model-a"), model("model-b")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.enabledModels.isEmpty())
        assertEquals(2, resolved.catalog.size)
    }

    // 5. Resolving the default model when the user already has one.

    @Test
    fun `default model resolves from user existing default`() {
        val provider = relayProvider(
            models = listOf(
                model("model-a"),
                model("model-b", isDefault = true),
            ),
            catalogModels = listOf(model("model-a"), model("model-b")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertNotNull(resolved.defaultModel)
        assertEquals("model-b", resolved.defaultModel?.model?.id)
    }

    // 6. Resolving the default model falls back to the first enabled model.

    @Test
    fun `default model falls back to first enabled`() {
        val provider = relayProvider(
            models = listOf(model("model-a"), model("model-b")),
            catalogModels = listOf(model("model-a"), model("model-b")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertNotNull(resolved.defaultModel)
        assertEquals("model-a", resolved.defaultModel?.model?.id)
    }

    // 7. Resolving the default model yields nothing when no model is enabled.

    @Test
    fun `default model null when no enabled and no catalog models`() {
        val provider = relayProvider(
            models = emptyList(),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertNull(resolved.defaultModel)
    }

    // 8. Recommended models: isRecommended and not yet enabled.

    @Test
    fun `recommended models are isRecommended and not enabled`() {
        val provider = relayProvider(
            models = listOf(model("model-a", isDefault = true)),
            catalogModels = listOf(
                model("model-a"),
                model("model-b", isRecommended = true, sortRank = 200),
                model("model-c", isRecommended = true, sortRank = 100),
                model("model-d", isRecommended = false),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(2, resolved.recommendedModels.size)
        // Descending by sortRank.
        assertEquals("model-b", resolved.recommendedModels[0].model.id)
        assertEquals("model-c", resolved.recommendedModels[1].model.id)
    }

    // 9. Recommended models: an already enabled model is not recommended again.

    @Test
    fun `enabled recommended models excluded from recommended list`() {
        val provider = relayProvider(
            models = listOf(model("model-a", isDefault = true, isRecommended = true)),
            catalogModels = listOf(
                model("model-a", isRecommended = true),
                model("model-b", isRecommended = true),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(1, resolved.recommendedModels.size)
        assertEquals("model-b", resolved.recommendedModels.first().model.id)
    }

    // ── 10. availableModelCount ──

    @Test
    fun `availableModelCount counts only available models`() {
        val provider = relayProvider(
            models = emptyList(),
            catalogModels = listOf(
                model("model-a", isAvailable = true),
                model("model-b", isAvailable = false),
                model("model-c", isAvailable = true),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(2, resolved.availableModelCount)
    }

    // 11. Falling back with an empty catalogModels.

    @Test
    fun `empty catalog with manual models only`() {
        val provider = relayProvider(
            models = listOf(model("manual-model", isDefault = true)),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertTrue(resolved.hasManualModels)
        assertEquals(1, resolved.catalog.size)
        assertTrue(resolved.catalog.first().isManual)
    }

    // 12. An official provider must not fall back to local catalogModels when metadata is
    // unavailable.

    @Test
    fun `official provider must not fall back to local catalogModels when metadata unavailable`() {
        // When metadata is unavailable an official provider is forbidden from using
        // provider.catalogModels. Models the user had enabled are still rendered through the
        // Manual-Retained fallback; everything else in catalogModels is treated as stale and dropped.
        val provider = officialProvider(
            models = listOf(model("gpt-4o", isDefault = true)),
            catalogModels = listOf(model("gpt-4o"), model("gpt-4o-mini")),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // Only gpt-4o, which the user had enabled, survives as manual-retained; gpt-4o-mini is dropped.
        assertEquals(1, resolved.catalog.size)
        assertTrue(resolved.hasManualModels)
        assertEquals("gpt-4o", resolved.catalog.first().model.id)
    }

    // 13. An official provider with empty metadata and empty catalogModels.

    @Test
    fun `official provider with empty metadata and empty catalog only has manual models`() {
        val provider = officialProvider(
            models = listOf(model("custom-model", isDefault = true)),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // Manual models only.
        assertTrue(resolved.hasManualModels)
        assertEquals(1, resolved.catalog.size)
        assertEquals("custom-model", resolved.catalog.first().model.id)
    }

    // 14. SiliconFlow vendor fallback.

    @Test
    fun `siliconflow models without groupKey get vendor fallback from model id`() {
        // Simulates the fallback path when metadata is unavailable: catalogModels carries
        // slash-formatted ids but no groupKey.
        val provider = officialProvider(
            kind = ProviderKind.SiliconFlow,
            models = listOf(model("zai-org/GLM-4-Flash")),
            catalogModels = listOf(
                model("zai-org/GLM-4-Flash"),
                model("deepseek-ai/DeepSeek-V3"),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // Even when metadata is unavailable and the resolver falls back to local data, an enabled
        // model still has to be recognised.
        assertEquals(1, resolved.enabledModels.size)
    }

    // 15. Matching by canonical id.

    @Test
    fun `canonical model id matching works for enabled check`() {
        val provider = relayProvider(
            models = listOf(model("gpt-4o-2024-08-06", isDefault = true)),
            catalogModels = listOf(
                model("gpt-4o-2024-08-06", canonicalModelId = "gpt-4o"),
                model("gpt-4o-mini"),
            ),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        assertEquals(1, resolved.enabledModels.size)
        assertEquals("gpt-4o-2024-08-06", resolved.enabledModels.first().model.id)
    }

    // 16. Safe degradation: an official provider must not expand its catalog once
    // contractVersion is two or more versions ahead of what this client understands.

    @Test
    fun `official provider returns empty catalog when contractVersion is degraded`() {
        // Injects metadata carrying contractVersion N+2 along with several canonical OpenAI models.
        injectMetadata(
            """
            {
              "version": 99,
              "contractVersion": ${MetadataClient.SUPPORTED_CONTRACT_VERSION + 2},
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-4o",
                  "models": {
                    "gpt-4o": {"canonicalModelId": "gpt-4o"},
                    "gpt-4o-mini": {"canonicalModelId": "gpt-4o-mini"}
                  }
                }
              }
            }
            """.trimIndent(),
        )
        assertTrue(
            "precondition: metadata must be degraded for this test",
            MetadataClient.isContractVersionDegraded,
        )

        val provider = officialProvider(
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // The official catalog is suppressed entirely, leaving only the user's enabled models
        // held by the manual-retained fallback.
        val nonManual = resolved.catalog.filter { !it.isManual }
        assertTrue(
            "degraded contractVersion must suppress official catalog expansion",
            nonManual.isEmpty(),
        )
        assertTrue(resolved.hasManualModels)
        assertEquals(1, resolved.catalog.size)
        assertEquals("gpt-4o", resolved.catalog.first().model.id)
        assertTrue(resolved.catalog.first().isManual)
    }

    // 17. Safe degradation: a relay is unaffected by the contractVersion downgrade.

    @Test
    fun `relay provider catalog is unaffected by contractVersion degraded`() {
        injectMetadata(
            """
            {
              "version": 99,
              "contractVersion": ${MetadataClient.SUPPORTED_CONTRACT_VERSION + 2},
              "providers": {}
            }
            """.trimIndent(),
        )
        assertTrue(MetadataClient.isContractVersionDegraded)

        val catalog = listOf(model("model-a"), model("model-b"))
        val provider = relayProvider(
            models = listOf(model("model-a", isDefault = true)),
            catalogModels = catalog,
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // A relay catalog keeps being built from the local catalogModels.
        assertEquals(2, resolved.catalog.size)
        assertEquals(listOf("model-a", "model-b"), resolved.catalog.map { it.model.id })
        assertEquals(1, resolved.enabledModels.size)
    }

    // 18. Safe degradation: the official catalog expands normally while contractVersion is
    // inside the supported window.

    @Test
    fun `official provider expands catalog when contractVersion is supported`() {
        injectMetadata(
            """
            {
              "version": 42,
              "contractVersion": ${MetadataClient.SUPPORTED_CONTRACT_VERSION},
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-4o",
                  "models": {
                    "gpt-4o": {"canonicalModelId": "gpt-4o"},
                    "gpt-4o-mini": {"canonicalModelId": "gpt-4o-mini"}
                  }
                }
              }
            }
            """.trimIndent(),
        )
        assertFalse(MetadataClient.isContractVersionDegraded)

        val provider = officialProvider(
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
            catalogModels = emptyList(),
        )

        val resolved = ProviderCatalogResolver.resolve(provider)

        // contractVersion is inside the window, so the catalog expands from metadata.
        val catalogIds = resolved.catalog.map { it.model.id }.toSet()
        assertTrue(
            "supported contractVersion must expand catalog via metadata; got $catalogIds",
            catalogIds.contains("gpt-4o") && catalogIds.contains("gpt-4o-mini"),
        )
    }

    // Reflection helper for injecting into MetadataClient, matching MetadataClientTest.

    private fun injectMetadata(rawJson: String) {
        val clientClass = MetadataClient::class.java

        val jsonField = clientClass.getDeclaredField("json")
        jsonField.isAccessible = true
        val internalJson = jsonField.get(MetadataClient.instance) as Json

        val responseClass = clientClass.declaredClasses.first { it.simpleName == "MetadataResponse" }
        val companionField = responseClass.getDeclaredField("Companion")
        companionField.isAccessible = true
        val companion = companionField.get(null)
        val serializerMethod = companion.javaClass.getDeclaredMethod("serializer")
        serializerMethod.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val serializer = serializerMethod.invoke(companion) as kotlinx.serialization.KSerializer<Any>

        val decoded = internalJson.decodeFromString(serializer, rawJson)

        val tableField = clientClass.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, decoded)
    }

    private fun clearMetadataTable() {
        val tableField = MetadataClient::class.java.getDeclaredField("table")
        tableField.isAccessible = true
        tableField.set(MetadataClient.instance, null)
    }
}
