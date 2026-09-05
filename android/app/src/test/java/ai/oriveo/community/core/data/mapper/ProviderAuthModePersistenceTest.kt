package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper.toDomain
import ai.oriveo.community.core.data.mapper.ProviderMapper.toEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Persistence compatibility and catalog-source branching after Provider gained an `authMode` field. */
class ProviderAuthModePersistenceTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun subscriptionProvider(
        models: List<AIModel> = listOf(AIModel(id = "grok-4.6", name = "grok-4.6", isDefault = true)),
    ) = Provider(
        id = "11111111-1111-1111-1111-111111111111",
        kind = ProviderKind.Grok,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = models,
        apiKey = "access-token",
        apiKeyPreview = "",
        baseUrlText = "https://api.x.ai/v1",
        authMode = ProviderAuthMode.Subscription,
    )

    @Test
    fun `authMode persists as a bare string and round trips exactly`() {
        val entity = subscriptionProvider().toEntity(accountId = "acc")
        assertEquals("subscription", entity.authMode)
        assertEquals(ProviderAuthMode.Subscription, entity.toDomain("access-token").authMode)
    }

    /**
     * Rows from before this column existed don't have it, so the migration's
     * default is `apiKey`. Getting this wrong looks like every existing Grok
     * connection suddenly going out over the subscription transport instead
     * -- a wall of 404s.
     */
    @Test
    fun `legacy rows default to apiKey so existing providers see no behavior change`() {
        val legacy = ProviderEntity(
            id = "22222222-2222-2222-2222-222222222222",
            kind = ProviderKind.Grok.name,
            status = """{"type":"connected"}""",
            lastCheckedAt = null,
            apiKeyPreview = "xai-••••abcd",
            lastError = null,
            baseUrlText = "https://api.x.ai/v1",
            customName = null,
            modelsJson = "[]",
            catalogModelsJson = "[]",
            updatedAt = 0,
            // authMode uses its default, matching an old row that already went through migration
        )
        assertEquals(ProviderAuthMode.ApiKey, legacy.toDomain("xai-key").authMode)
    }

    /** An unrecognized value falls back to apiKey, so an unknown string never makes the whole provider fail to parse. */
    @Test
    fun `an unknown authMode value falls back to apiKey`() {
        assertEquals(ProviderAuthMode.ApiKey, ProviderAuthMode.fromRawValue("oauth_v2"))
        assertEquals(ProviderAuthMode.ApiKey, ProviderAuthMode.fromRawValue(null))
    }

    /**
     * For a subscription instance, the catalog's source of truth is the
     * subscription transport itself.
     *
     * Without this branch, the model picker would show subscription users
     * the entire official model page, none of which actually exist on that
     * transport: picking any of them fails immediately with a confusing
     * error.
     */
    @Test
    fun `a subscription instance's catalog comes only from local catalogModels, never official metadata`() {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Grok,
                defaultModelId = "grok-4.3",
                resolveMap = mapOf("grok-4.3" to "grok-4.3", "grok-code-fast-1" to "grok-code-fast-1"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec("grok-4.3", displayName = "Grok 4.3"),
                    MetadataTestFixtures.ModelSpec("grok-code-fast-1", displayName = "Grok Code Fast"),
                ),
            )
        )

        val resolved = ProviderCatalogResolver.resolve(subscriptionProvider())
        assertEquals(listOf("grok-4.6"), resolved.catalog.map { it.model.id })
        assertTrue(resolved.catalog.none { it.model.id == "grok-4.3" })

        // The same provider kind in key mode still treats metadata as authoritative -- the subscription branch doesn't touch it.
        val keyModeProvider = subscriptionProvider(models = emptyList()).copy(
            authMode = ProviderAuthMode.ApiKey,
            catalogModels = emptyList(),
        )
        val keyResolved = ProviderCatalogResolver.resolve(keyModeProvider)
        assertEquals(
            listOf("grok-4.3", "grok-code-fast-1"),
            keyResolved.catalog.map { it.model.id }.sorted(),
        )
    }
}
