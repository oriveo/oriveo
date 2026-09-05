package ai.oriveo.community.ui.component

import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderBadgeIconTest {
    @Test
    fun `provider badge uses safe area embedded in unified assets`() {
        assertEquals(1f, ProviderBadgeLogoMetrics.BrandContentScale, 0.0001f)
        assertEquals(0f, ProviderBadgeLogoMetrics.brandInset(28f), 0.0001f)
        assertEquals(0.92f, ProviderBadgeLogoMetrics.RelayFallbackContentScale, 0.0001f)
    }

    @Test
    fun `relay fallback mark is inset inside its badge canvas`() {
        assertEquals(
            0.04f,
            (1f - ProviderBadgeLogoMetrics.RelayFallbackContentScale) / 2f,
            0.0001f,
        )
    }

    @Test
    fun `providers expose explicit light and dark assets`() {
        assertEquals(R.drawable.ic_provider_grok, providerLogoRes(ProviderKind.Grok))
        assertEquals(R.drawable.ic_provider_grok_dark, providerLogoRes(ProviderKind.Grok, darkAppearance = true))
        assertEquals(R.drawable.ic_provider_kimi, providerLogoRes(ProviderKind.Moonshot))
        assertEquals(R.drawable.ic_provider_kimi_dark, providerLogoRes(ProviderKind.Moonshot, darkAppearance = true))
    }

    @Test
    fun `Mistral colored logo is shared across light and dark appearances`() {
        // A multi-colour mark reads correctly on both appearances, so no inverted _dark variant
        // exists for it (same situation as Together).
        assertEquals(R.drawable.ic_provider_mistral, providerLogoRes(ProviderKind.Mistral))
        assertEquals(R.drawable.ic_provider_mistral, providerLogoRes(ProviderKind.Mistral, darkAppearance = true))
    }
}
