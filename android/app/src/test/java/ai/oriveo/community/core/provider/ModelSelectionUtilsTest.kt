package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelSelectionUtilsTest {

    private fun model(
        id: String,
        caps: List<ModelCapability> = listOf(ModelCapability.Text),
        isAvailable: Boolean = true,
        isDefault: Boolean = false,
        canonicalModelId: String? = null,
    ) = AIModel(
        id = id, name = id, capabilities = caps,
        isAvailable = isAvailable, isDefault = isDefault,
        canonicalModelId = canonicalModelId,
    )

    // ── D15: Smart Default Scoring ──

    @Test
    fun `initialEnabledModels - selects isDefault model`() {
        val result = ModelSelectionUtils.initialEnabledModels(
            listOf(
                model("basic-model"),
                model("gpt-4o", isDefault = true),
                model("unknown-model"),
            )
        )

        assertEquals(1, result.size)
        assertEquals("gpt-4o", result.single().id)
        assertTrue(result.single().isDefault)
    }

    // ── D16: Model Matching & Dedup ──

    @Test
    fun `resolvedId - strips manual prefix`() {
        assertEquals("gpt-4o", ModelSelectionUtils.resolvedId("manual-gpt-4o"))
    }

    @Test
    fun `resolvedId - no prefix unchanged`() {
        assertEquals("gpt-4o", ModelSelectionUtils.resolvedId("gpt-4o"))
    }

    @Test
    fun `matchingModel - exact match`() {
        val models = listOf(model("gpt-4o"), model("gpt-3.5"))
        val result = ModelSelectionUtils.matchingModel(models, "gpt-4o")
        assertNotNull(result)
        assertEquals("gpt-4o", result!!.id)
    }

    @Test
    fun `matchingModel - manual prefix match`() {
        val models = listOf(model("gpt-4o"), model("gpt-3.5"))
        val result = ModelSelectionUtils.matchingModel(models, "manual-gpt-4o")
        assertNotNull(result)
        assertEquals("gpt-4o", result!!.id)
    }

    @Test
    fun `matchingModel - no match returns null`() {
        val models = listOf(model("gpt-4o"))
        val result = ModelSelectionUtils.matchingModel(models, "claude-3")
        assertNull(result)
    }

    @Test
    fun `matchingModel - canonical identifier resolves snapshot runtime model`() {
        val models = listOf(
            model(
                id = "gpt-5.4-2026-03-05",
                canonicalModelId = "gpt-5.4",
            ),
        )

        val result = ModelSelectionUtils.matchingModel(models, "gpt-5.4")
        assertNotNull(result)
        assertEquals("gpt-5.4-2026-03-05", result!!.id)
    }

    @Test
    fun `preferredStoredModelIdentifier - snapshot model stores canonical id`() {
        val models = listOf(
            model(
                id = "gpt-5.4-2026-03-05",
                canonicalModelId = "gpt-5.4",
            ),
        )

        val result = ModelSelectionUtils.preferredStoredModelIdentifier(models, "gpt-5.4-2026-03-05")
        assertEquals("gpt-5.4", result)
    }

    @Test
    fun `modelsShareSameRemoteModel - same resolved ID`() {
        assertTrue(
            ModelSelectionUtils.modelsShareSameRemoteModel(
                model("manual-gpt-4o"),
                model("gpt-4o"),
                ProviderKind.OpenAI,
            )
        )
    }

    @Test
    fun `modelsShareSameRemoteModel - different IDs different names`() {
        assertFalse(
            ModelSelectionUtils.modelsShareSameRemoteModel(
                model("gpt-4o"),
                model("claude-3"),
                ProviderKind.OpenAI,
            )
        )
    }

    @Test
    fun `modelsShareSameRemoteModel - canonical identifier dedupes snapshot model`() {
        assertTrue(
            ModelSelectionUtils.modelsShareSameRemoteModel(
                model("gpt-5.4-2026-03-05", canonicalModelId = "gpt-5.4"),
                model("gpt-5.4"),
                ProviderKind.OpenAI,
            )
        )
    }

    @Test
    fun `matchingModel - exact canonical id wins over snapshot alias`() {
        val models = listOf(
            model("gpt-5.4-nano-2026-03-01", canonicalModelId = "gpt-5.4-nano"),
            model("gpt-5.4-nano", canonicalModelId = "gpt-5.4-nano"),
        )

        val result = ModelSelectionUtils.matchingModel(models, "gpt-5.4-nano")
        assertEquals("gpt-5.4-nano", result?.id)
    }

    @Test
    fun `modelsShareSameRemoteModel - OpenRouter same name different ids stays false`() {
        assertFalse(
            ModelSelectionUtils.modelsShareSameRemoteModel(
                model("openai/gpt-5.4-nano", canonicalModelId = "openai/gpt-5.4-nano"),
                model("openai/gpt-5.4-mini", canonicalModelId = "openai/gpt-5.4-mini"),
                ProviderKind.OpenRouter,
            )
        )
    }

    @Test
    fun `mergeManualModels - preserves unique manual models`() {
        val existing = listOf(model("manual-custom-model"), model("gpt-4o"))
        val synced = listOf(model("gpt-4o"), model("gpt-3.5"))
        val result = ModelSelectionUtils.mergeManualModels(existing, synced, ProviderKind.OpenAI)
        assertEquals(3, result.size)
        assertEquals("manual-custom-model", result[0].id) // manual first
    }

    @Test
    fun `mergeManualModels - removes duplicate manual models`() {
        val existing = listOf(model("manual-gpt-4o"))
        val synced = listOf(model("gpt-4o"), model("gpt-3.5"))
        val result = ModelSelectionUtils.mergeManualModels(existing, synced, ProviderKind.OpenAI)
        // manual-gpt-4o is a duplicate of gpt-4o, should be excluded
        assertEquals(2, result.size)
    }

    @Test
    fun `mergeManualModels - empty existing returns synced`() {
        val synced = listOf(model("gpt-4o"))
        val result = ModelSelectionUtils.mergeManualModels(emptyList(), synced, ProviderKind.OpenAI)
        assertEquals(1, result.size)
    }

    @Test
    fun `makeEnabledModels - without existing only keeps one initial model`() {
        val result = ModelSelectionUtils.makeEnabledModels(
            existingEnabledModels = emptyList(),
            catalogModels = listOf(
                model("gpt-4o"),
                model("gpt-4.1"),
                model("gpt-4.1-mini"),
            ),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(1, result.size)
        assertTrue(result.single().isDefault)
    }

    @Test
    fun `makeEnabledModels - preserves existing enabled selection on resync`() {
        val result = ModelSelectionUtils.makeEnabledModels(
            existingEnabledModels = listOf(model("gpt-4.1", isDefault = true)),
            catalogModels = listOf(
                model("gpt-4o"),
                model("gpt-4.1"),
                model("gpt-4.1-mini"),
            ),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(listOf("gpt-4.1"), result.map { it.id })
        assertTrue(result.single().isDefault)
    }

    @Test
    fun `allEnabledModels - returns full catalog and preserves preferred default`() {
        val result = ModelSelectionUtils.allEnabledModels(
            catalogModels = listOf(
                model("gpt-4o"),
                model("gpt-4.1", isDefault = true),
                model("gpt-4.1-mini"),
            ),
            preferredDefaultId = "gpt-4o",
        )

        assertEquals(listOf("gpt-4o", "gpt-4.1", "gpt-4.1-mini"), result.map { it.id })
        assertEquals("gpt-4o", result.first { it.isDefault }.id)
    }

    @Test
    fun `filteredRecommendedModels - excludes already enabled models`() {
        val result = ModelSelectionUtils.filteredRecommendedModels(
            recommendations = listOf(model("gpt-4.1"), model("gpt-4o-mini")),
            enabledModels = listOf(model("gpt-4.1")),
            providerKind = ProviderKind.OpenAI,
        )

        assertEquals(listOf("gpt-4o-mini"), result.map { it.id })
    }

    /**
     * Grouping is by canonical key, not by id: two records that share an id but carry
     * different canonicalModelId values land in two separate keys and both survive. The
     * result is fed straight to a LazyColumn/LazyRow as `key = it.id`, and a duplicate key
     * there is a crash.
     */
    @Test
    fun `deduplicateByCanonical - never returns two models with the same id`() {
        val result = ModelSelectionUtils.deduplicateByCanonical(
            listOf(
                model("gpt-5.4", canonicalModelId = "gpt-5.4"),
                model("gpt-5.4", canonicalModelId = "openai/gpt-5.4"),
            ),
        )

        assertEquals(listOf("gpt-5.4"), result.map { it.id })
    }

    @Test
    fun `synchronizeDefaultSelection - syncs default flag into catalog`() {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(model("gpt-4.1", isDefault = true)),
            catalogModels = listOf(model("gpt-4.1"), model("gpt-4o-mini")),
        )

        val result = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = provider,
            preferredModelId = "gpt-4.1",
        )

        assertTrue(result.catalogModels.first { it.id == "gpt-4.1" }.isDefault)
        assertFalse(result.catalogModels.first { it.id == "gpt-4o-mini" }.isDefault)
    }
}
