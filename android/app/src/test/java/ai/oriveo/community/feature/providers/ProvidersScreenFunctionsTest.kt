package ai.oriveo.community.feature.providers

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ProviderBalance
import ai.oriveo.community.ui.component.ProviderListTrailingAmount
import ai.oriveo.community.ui.component.formatProviderBalanceAmount
import ai.oriveo.community.ui.component.providerListTrailingAmount
import ai.oriveo.community.ui.component.shouldShowProviderListErrorCopy
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class ProvidersScreenFunctionsTest {

    @Test
    fun `balance capable BYOK uses balance and other BYOK uses labeled consumption`() {
        val siliconFlowBalance = ProviderBalance(
            currency = "CNY",
            total = 88.88,
            fetchedAt = java.time.Instant.now(),
        )
        assertEquals(
            ProviderListTrailingAmount(R.string.provider_list_balance_label, "¥88.88", false),
            providerListTrailingAmount(
                ProviderKind.SiliconFlow,
                "$42.00",
                isMonthlyCostZero = false,
                providerBalance = siliconFlowBalance,
            ),
        )
        assertEquals(
            ProviderListTrailingAmount(R.string.provider_list_balance_label, "--", false),
            providerListTrailingAmount(
                ProviderKind.DeepSeek,
                "$42.00",
                isMonthlyCostZero = false,
                providerBalance = null,
            ),
        )
        assertEquals(
            ProviderListTrailingAmount(R.string.provider_list_usage_label, "$2.50", false),
            providerListTrailingAmount(
                ProviderKind.OpenAI,
                "$2.50",
                isMonthlyCostZero = false,
                providerBalance = null,
            ),
        )
        assertEquals("¥88.88", formatProviderBalanceAmount(siliconFlowBalance))
    }

    /**
     * Per-provider cost is always visible: this is money the user pays directly to the upstream
     * provider, computed locally from each message's estimatedCost. Showing the per-message
     * estimated cost is a deliberate product commitment.
     */
    @Test
    fun `per provider cost is always shown`() {
        assertEquals(
            ProviderListTrailingAmount(R.string.provider_list_usage_label, "$31.20", false),
            providerListTrailingAmount(
                ProviderKind.OpenAI,
                "$31.20",
                isMonthlyCostZero = false,
                providerBalance = null,
            ),
        )
        assertEquals(
            ProviderListTrailingAmount(R.string.provider_list_usage_label, "$0", true),
            providerListTrailingAmount(
                ProviderKind.Anthropic,
                "$0",
                isMonthlyCostZero = true,
                providerBalance = null,
            ),
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `provider list count uses precomputed value without implicit resolve`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "o4-mini"),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val count = providerListAvailableModelCount(
            provider = provider,
            precomputedCount = 3,
        )

        assertEquals(3, count)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    @Test
    fun `providers cluster summary uses precomputed values without implicit resolve`() {
        val providers = listOf(
            Provider(
                id = "provider-1",
                kind = ProviderKind.OpenAI,
                status = ProviderConnectionState.Connected,
                models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
            ),
            Provider(
                id = "provider-2",
                kind = ProviderKind.Relay,
                status = ProviderConnectionState.Connected,
                models = listOf(AIModel(id = "custom-1", name = "Custom-1", isDefault = true)),
                catalogModels = listOf(
                    AIModel(id = "custom-1", name = "Custom-1", isAvailable = true),
                    AIModel(id = "custom-2", name = "Custom-2", isAvailable = true),
                ),
            ),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val total = providersClusterAvailableModelCount(
            providers = providers,
            precomputedCounts = mapOf(
                "provider-1" to 3,
                "provider-2" to 2,
            ),
        )

        assertEquals(5, total)
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    /**
     * The hero card must not read `provider.availableModelCount` directly: when
     * `cachedAvailableModelCount` is null it falls back to `allModels`, and that path runs
     * `ProviderCatalogResolver.resolve` right there during composition, on the main thread.
     * This number should instead be computed by `ProvidersViewModel.availableModelCounts`
     * (flowOn(Default)) and passed in.
     */
    @Test
    fun `hero card takes the available model count instead of resolving it in composition`() {
        val hero = File("src/main/java/ai/oriveo/community/feature/providers/ProviderHeroCard.kt")
            .readText()
            .lineSequence()
            .filterNot {
                val trimmed = it.trimStart()
                trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
            }
            .joinToString("\n")

        assertEquals(
            "the hero card must take the available model count as a parameter",
            true,
            hero.contains("    availableModelCount: Int,"),
        )
        assertEquals(
            "must not read provider.availableModelCount directly (it resolves the catalog during composition)",
            false,
            hero.contains("provider.availableModelCount"),
        )
    }

    @Test
    fun `provider list rows do not show separate error copy for issue providers`() {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Issue("invalid_key"),
            lastError = "API key invalid",
        )

        assertEquals(false, shouldShowProviderListErrorCopy(provider))
    }

}
