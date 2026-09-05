package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.LocatedModelControlRejection
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalCustomRetryRecoveryTest {
    @Test
    fun `only a production-located custom pre-token upstream 400 offers explicit omit-custom retry`() {
        val located = LocatedModelControlRejection(
            source = "custom",
            owner = "generation",
            locatedPointers = listOf("/temperature"),
        )
        assertTrue(
            canOfferExplicitModelControlResend(
                located = located,
                receivedUpstreamEvent = false,
                error = ProviderServiceError.Upstream(
                    400,
                    "intentionally not inspected",
                    rejectedParameter = "temperature",
                ),
            ),
        )
    }

    @Test
    fun `auth rate limit server network and stream failures never offer omit-custom retry`() {
        val located = LocatedModelControlRejection(
            source = "custom",
            owner = "generation",
            locatedPointers = listOf("/temperature"),
        )
        listOf<Throwable>(
            ProviderServiceError.Upstream(401, ""),
            ProviderServiceError.Upstream(403, ""),
            ProviderServiceError.Upstream(429, ""),
            ProviderServiceError.Upstream(500, ""),
            ProviderServiceError.Network(""),
        ).forEach { error ->
            assertFalse(
                canOfferExplicitModelControlResend(
                    located = located,
                    receivedUpstreamEvent = false,
                    error = error,
                ),
            )
        }
        assertFalse(
            canOfferExplicitModelControlResend(
                located = located,
                receivedUpstreamEvent = true,
                error = ProviderServiceError.Upstream(400, "", rejectedParameter = "temperature"),
            ),
        )
        assertFalse(
            canOfferExplicitModelControlResend(
                located = located.copy(locatedPointers = emptyList()),
                receivedUpstreamEvent = false,
                error = ProviderServiceError.Upstream(400, "", rejectedParameter = "temperature"),
            ),
        )
    }
}
