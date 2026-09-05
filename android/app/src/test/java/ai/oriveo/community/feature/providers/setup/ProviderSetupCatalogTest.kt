package ai.oriveo.community.feature.providers.setup

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderSetupCatalogTest {
    @Test
    fun `null provider configs use local fallback catalog`() {
        val catalog = ProviderSetupCatalog.fromProviderConfigs(null)

        assertEquals(ProviderKind.OpenAI, catalog.directProviders.first())
        assertTrue(catalog.aggregatorProviders.contains(ProviderKind.OpenRouter))
        assertEquals("api.openai.com/v1", catalog.defaultBaseUrl(ProviderKind.OpenAI))
        assertEquals(listOf("cn", "intl"), catalog.regionOptions(ProviderKind.SiliconFlow).map { it.id })
        assertEquals(
            "https://api.siliconflow.com/v1",
            catalog.regionOptions(ProviderKind.SiliconFlow).last().baseURL,
        )
    }

    @Test
    fun `remote provider configs drive order labels and region options`() {
        val catalog = ProviderSetupCatalog.fromProviderConfigs(
            listOf(
                MetadataClient.PublicProviderConfig(
                    kind = "qwen",
                    displayName = "Qwen Remote",
                    shortName = "Qwen",
                    selectionLabel = "Alibaba Cloud",
                    defaultBaseURL = "https://dashscope.example/v1",
                    apiKeyPlaceholder = "sk-qwen",
                    category = "direct",
                    regionOptions = listOf(
                        MetadataClient.ProviderRegionOption(
                            id = "hk",
                            label = "Hong Kong",
                            baseURL = "https://hk.example/v1",
                        ),
                    ),
                    sortOrder = 20,
                ),
                MetadataClient.PublicProviderConfig(
                    kind = "miniMax",
                    displayName = "MiniMax Remote",
                    shortName = "MiniMax",
                    selectionLabel = null,
                    defaultBaseURL = "https://minimax.example/v1",
                    apiKeyPlaceholder = "sk-api",
                    category = "direct",
                    regionOptions = emptyList(),
                    sortOrder = 10,
                ),
                MetadataClient.PublicProviderConfig(
                    kind = "unknownNative",
                    displayName = "Unknown",
                    shortName = null,
                    selectionLabel = null,
                    defaultBaseURL = "https://unknown.example/v1",
                    apiKeyPlaceholder = "sk",
                    category = "direct",
                    regionOptions = emptyList(),
                    sortOrder = 1,
                ),
            ),
        )

        assertEquals(listOf(ProviderKind.MiniMax, ProviderKind.Qwen), catalog.directProviders)
        assertEquals(emptyList<ProviderKind>(), catalog.aggregatorProviders)
        assertEquals("Alibaba Cloud", catalog.displayName(ProviderKind.Qwen))
        assertEquals("sk-qwen", catalog.apiKeyPlaceholder(ProviderKind.Qwen))
        assertEquals("https://dashscope.example/v1", catalog.defaultBaseUrl(ProviderKind.Qwen))
        assertEquals(
            listOf(ai.oriveo.community.core.model.RegionOption("hk", "Hong Kong", "https://hk.example/v1")),
            catalog.regionOptions(ProviderKind.Qwen),
        )
    }

    @Test
    fun `explicit empty provider configs hide official setup entries`() {
        val catalog = ProviderSetupCatalog.fromProviderConfigs(emptyList())

        assertEquals(emptyList<ProviderKind>(), catalog.directProviders)
        assertEquals(emptyList<ProviderKind>(), catalog.aggregatorProviders)
    }
}
