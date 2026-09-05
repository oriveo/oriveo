package ai.oriveo.community.core.data

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderPersistenceRecoveryTest {

    private inline fun <T> mapper(block: EntityMapper.() -> T): T =
        with(EntityMapper) { block() }

    @Test
    fun `persisted syncing provider recovers as connected`() = mapper {
        val provider = Provider(
            id = "p1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Syncing,
            apiKey = "secret-key",
        )

        val restored = provider.toEntity().toDomain(apiKey = "secret-key")

        assertEquals(ProviderConnectionState.Connected, restored.status)
    }
}
