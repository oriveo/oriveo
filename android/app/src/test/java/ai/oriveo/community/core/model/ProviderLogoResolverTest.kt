package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderLogoResolverTest {
    @Test
    fun `relay logo resolves from provider name base url and model hints`() {
        val provider = Provider(
            id = "relay-kimi",
            kind = ProviderKind.Relay,
            customName = "Kimi Gateway",
            baseUrlText = "https://api.moonshot.cn/v1",
            models = listOf(
                AIModel(
                    id = "kimi-k2-0905-preview",
                    name = "Kimi K2",
                    groupKey = "moonshot",
                    groupName = "Kimi",
                ),
            ),
        )

        assertEquals(ProviderKind.Moonshot, resolveProviderLogoKind(provider))
    }

    @Test
    fun `relay logo falls back to relay kind when hints are unknown`() {
        val provider = Provider(
            id = "relay-anthropic",
            kind = ProviderKind.Relay,
            customName = "Work Relay",
            relayKind = RelayKind.AnthropicCompatible,
        )

        assertEquals(ProviderKind.Anthropic, resolveProviderLogoKind(provider))
    }
}
