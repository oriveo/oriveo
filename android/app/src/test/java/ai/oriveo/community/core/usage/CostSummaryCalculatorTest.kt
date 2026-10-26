package ai.oriveo.community.core.usage

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import org.junit.Assert.assertEquals
import org.junit.Test

class CostSummaryCalculatorTest {

    @Test
    fun `augmentDisplayNames replaces kind-only fallback with customName`() {
        val raw = MonthlyCostSummary(
            totalCost = 3.5,
            providers = listOf(
                MonthlyCostProviderEntry(
                    providerKind = ProviderKind.Relay,
                    providerID = "relay-a",
                    displayName = "Relay",
                    cost = 3.5,
                ),
            ),
            hiddenProviderCount = 0,
            source = CostSummarySource.LocalDevice,
        )
        val augmented = CostSummaryCalculator.augmentDisplayNames(
            raw,
            providers = listOf(makeProvider("relay-a", ProviderKind.Relay, customName = "My Relay")),
        )
        assertEquals("My Relay", augmented.providers.first().displayName)
    }

    @Test
    fun `augmentDisplayNames also resolves relay logo kind`() {
        val raw = MonthlyCostSummary(
            totalCost = 3.5,
            providers = listOf(
                MonthlyCostProviderEntry(
                    providerKind = ProviderKind.Relay,
                    providerID = "relay-a",
                    displayName = "Relay",
                    cost = 3.5,
                ),
            ),
            hiddenProviderCount = 0,
            source = CostSummarySource.LocalDevice,
        )
        val augmented = CostSummaryCalculator.augmentDisplayNames(
            raw,
            providers = listOf(
                makeProvider(
                    "relay-a",
                    ProviderKind.Relay,
                    customName = "My Relay",
                    relayKind = RelayKind.AnthropicCompatible,
                ),
            ),
        )

        // Relay connections no longer draw a protocol logo from relayKind (the old Anthropic assertion was stale).
        assertEquals(ProviderKind.Relay, augmented.providers.first().logoProviderKind)
    }


    private fun makeProvider(
        id: String,
        kind: ProviderKind,
        customName: String? = null,
        baseUrlText: String? = null,
        relayKind: RelayKind? = null,
        models: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = id,
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        customName = customName,
        baseUrlText = baseUrlText,
        relayKind = relayKind,
    )
}
