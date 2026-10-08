package ai.oriveo.community.core.data.repository.streaming

import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.OpenAISubscriptionFailureReason
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.ProviderSubscriptionLane
import ai.oriveo.community.core.provider.SseParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A subscription request refused by the upstream has to reach the user as a sentence they can act
 * on, not as the upstream's own wording.
 */
class SubscriptionFailureHandlingTest {

    // What xAI answers when the client version header is below its minimum.
    private val xaiBody =
        """{"error":{"message":"Your Grok CLI version (1.0.4) is outdated. Please update to version 1.0.13 or later via `grok update` or the installation documentation."}}"""

    private fun grok426(): ProviderServiceError =
        SseParser.mapHttpError(426, xaiBody, emptyList(), ProviderSubscriptionLane.Grok)

    @Test
    fun `the failed message stores copy the app user can act on, not the cli upgrade hint`() {
        val error = grok426()
        // Premise: the production mapping classifies this as a rejected client version and still
        // carries the upstream text in the technical detail.
        assertTrue(error.isSubscriptionClientVersionRejection())
        assertTrue(error.technicalDetail.contains("grok update"))

        val stored = failedMessageDetail(error)

        assertFalse(stored.contains("grok update"))
        assertEquals(GrokSubscriptionFailureReason.ClientVersionRejected.userMessage, stored)
        // The failure card uses this lookup to choose between localized copy and the generic body.
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(stored))
        assertTrue(isSubscriptionFailureDetail(stored))
    }

    @Test
    fun `every subscription failure reason of both providers stores localizable copy`() {
        val errors = GrokSubscriptionFailureReason.entries.map { ProviderServiceError.GrokSubscription(it, "raw") } +
            OpenAISubscriptionFailureReason.entries.map { ProviderServiceError.OpenAISubscription(it, "raw") }

        for (error in errors) {
            val stored = failedMessageDetail(error)
            assertTrue("$error", ErrorMapper.hasLocalizedProviderMessage(stored))
            assertTrue("$error", isSubscriptionFailureDetail(stored))
        }
    }

    @Test
    fun `other provider errors keep their technical detail`() {
        val upstream = ProviderServiceError.Upstream(500, "boom")

        assertEquals(upstream.technicalDetail, failedMessageDetail(upstream))
        assertFalse(isSubscriptionFailureDetail(failedMessageDetail(upstream)))
    }

    @Test
    fun `codex 426 counts as a client version rejection too`() {
        val codex = SseParser.mapHttpError(426, """{"error":{"message":"upgrade"}}""", emptyList(), ProviderSubscriptionLane.OpenAI)

        assertTrue(codex.isSubscriptionClientVersionRejection())
        assertFalse(
            SseParser.mapHttpError(429, "{}", emptyList(), ProviderSubscriptionLane.Grok)
                .isSubscriptionClientVersionRejection(),
        )
    }
}
