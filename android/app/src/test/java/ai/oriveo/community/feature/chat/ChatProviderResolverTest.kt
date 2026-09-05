package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.ProviderServiceError
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatProviderResolverTest {
    private val providerRepository = mockk<ProviderRepository>()

    @Test
    fun `upstream failure is returned to the UI boundary instead of escaping`() = runTest {
        val failure = ProviderServiceError.Upstream(502, "bad gateway")
        coEvery { providerRepository.getById("oriveo-ai") } throws failure
        var handled: Throwable? = null

        val provider = resolveChatProvider(
            providerRepository = providerRepository,
            providerId = "oriveo-ai",
            onFailure = { handled = it },
        )

        assertNull(provider)
        assertSame(failure, handled)
    }

    @Test
    fun `missing provider uses the existing selection error path`() = runTest {
        coEvery { providerRepository.getById("missing") } returns null
        var missing = false
        var failed = false

        val provider = resolveChatProvider(
            providerRepository = providerRepository,
            providerId = "missing",
            onMissing = { missing = true },
            onFailure = { failed = true },
        )

        assertNull(provider)
        assertTrue(missing)
        assertFalse(failed)
    }

    @Test
    fun `cancellation is never converted into a provider failure`() = runTest {
        val cancellation = CancellationException("left chat")
        coEvery { providerRepository.getById("oriveo-ai") } throws cancellation
        var handled = false

        val thrown = try {
            resolveChatProvider(
                providerRepository = providerRepository,
                providerId = "oriveo-ai",
                onFailure = { handled = true },
            )
            null
        } catch (error: CancellationException) {
            error
        }

        assertSame(cancellation, thrown)
        assertFalse(handled)
    }

    @Test
    fun `provider error exposes technical detail through exception message`() {
        val error = ProviderServiceError.Upstream(502, "bad gateway")

        assertEquals("Upstream HTTP 502: bad gateway", error.message)
    }
}
