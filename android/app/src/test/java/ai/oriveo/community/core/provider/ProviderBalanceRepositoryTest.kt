package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import java.time.Instant
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderBalanceRepositoryTest {
    @Test
    fun `cache is shared for five minutes and invalidates when credentials change`() = runTest {
        val service = FakeBalanceService()
        val repository = ProviderBalanceRepository(
            services = mapOf(ProviderKind.Moonshot to service),
            now = { Instant.parse("2026-07-22T00:00:00Z") },
        )
        val provider = Provider(
            id = "moonshot-1",
            kind = ProviderKind.Moonshot,
            apiKey = "sk-test",
            baseUrlText = "https://api.moonshot.ai/v1",
        )

        repository.fetchBalance(provider)
        repository.fetchBalance(provider)
        assertEquals(1, service.calls)

        repository.fetchBalance(provider.copy(apiKey = "sk-replaced"))
        assertEquals(2, service.calls)

        val replacedKeyProvider = provider.copy(apiKey = "sk-replaced")
        repository.fetchBalance(replacedKeyProvider.copy(baseUrlText = "https://api.moonshot.cn/v1"))
        assertEquals(3, service.calls)

        repository.fetchBalance(replacedKeyProvider)
        assertEquals(4, service.calls)
    }

    private class FakeBalanceService : BalanceQueryable {
        var calls = 0

        override suspend fun fetchBalance(apiKey: String, baseURL: String?): ProviderBalance {
            calls += 1
            return ProviderBalance(
                currency = if (baseURL?.contains(".cn") == true) "CNY" else "USD",
                total = calls.toDouble(),
                fetchedAt = Instant.parse("2026-07-22T00:00:00Z"),
            )
        }
    }
}
