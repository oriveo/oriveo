package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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

    @Test
    fun `last balance stays available for display past the TTL until credentials change`() = runTest {
        var now = Instant.parse("2026-07-22T00:00:00Z")
        val service = FakeBalanceService()
        val repository = ProviderBalanceRepository(
            services = mapOf(ProviderKind.DeepSeek to service),
            now = { now },
        )
        val provider = Provider(
            id = "deepseek-1",
            kind = ProviderKind.DeepSeek,
            apiKey = "sk-a",
            baseUrlText = "https://api.deepseek.com",
        )

        repository.fetchBalance(provider)
        now = now.plus(Duration.ofHours(1))

        assertEquals(1.0, repository.cachedBalance(provider.copy(apiKey = " sk-a "))?.total)
        assertNull(repository.cachedBalance(provider.copy(apiKey = "sk-b")))
        assertNull(repository.cachedBalance(provider.copy(baseUrlText = null)))
        assertNull(repository.cachedBalance(provider.copy(id = "deepseek-2")))
    }

    @Test
    fun `display refresh keeps the last balance on network errors and drops it once the key is rejected`() = runTest {
        var now = Instant.parse("2026-07-22T00:00:00Z")
        val service = FakeBalanceService()
        val repository = ProviderBalanceRepository(
            services = mapOf(ProviderKind.DeepSeek to service),
            now = { now },
        )
        val provider = Provider(id = "deepseek-1", kind = ProviderKind.DeepSeek, apiKey = "sk-test")

        assertEquals(1.0, repository.fetchBalanceForDisplay(provider)?.total)

        // Expired and offline: keep showing the last balance, and keep it cached
        now = now.plus(Duration.ofMinutes(10))
        service.error = ProviderServiceError.Network("offline")
        assertEquals(1.0, repository.fetchBalanceForDisplay(provider)?.total)
        assertNotNull(repository.cachedBalance(provider))

        // Key rejected: stop showing the old balance and drop it from the cache
        service.error = ProviderServiceError.InvalidAPIKey("401")
        assertNull(repository.fetchBalanceForDisplay(provider))
        assertNull(repository.cachedBalance(provider))
        assertEquals(3, service.calls)
    }

    private class FakeBalanceService : BalanceQueryable {
        var calls = 0
        var error: Exception? = null

        override suspend fun fetchBalance(apiKey: String, baseURL: String?): ProviderBalance {
            calls += 1
            error?.let { throw it }
            return ProviderBalance(
                currency = if (baseURL?.contains(".cn") == true) "CNY" else "USD",
                total = calls.toDouble(),
                fetchedAt = Instant.parse("2026-07-22T00:00:00Z"),
            )
        }
    }
}
