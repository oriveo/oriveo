package ai.oriveo.community.core.data.mapper

import ai.oriveo.community.core.data.mapper.ProviderMapper.toDomain
import ai.oriveo.community.core.data.mapper.ProviderMapper.toEntity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderIssueReason
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderMapperIssueReasonTest {

    private fun roundTrip(status: ProviderConnectionState): ProviderConnectionState =
        Provider(id = "provider-openai", kind = ProviderKind.OpenAI, status = status).toEntity().toDomain().status

    @Test
    fun `typed issue reason survives persistence`() {
        assertEquals(
            ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.Subscription),
            roundTrip(ProviderConnectionState.Issue.missingCredential(ProviderAuthMode.Subscription)),
        )
        assertEquals(
            ProviderConnectionState.Issue("Invalid API Key"),
            roundTrip(ProviderConnectionState.Issue("Invalid API Key")),
        )
    }

    @Test
    fun `legacy rows without reason recover missing-credential reason on read`() {
        // A row stored before the reason field existed has no reason: it decodes to the default Error, and the read boundary restores it from the message the writer used then.
        val legacyKey = roundTrip(ProviderConnectionState.Issue("API Key required"))
        val legacySignIn = roundTrip(ProviderConnectionState.Issue("Sign in required"))

        assertEquals(ProviderIssueReason.MissingCredential, (legacyKey as ProviderConnectionState.Issue).reason)
        assertEquals(ProviderIssueReason.SignInRequired, (legacySignIn as ProviderConnectionState.Issue).reason)
        assertEquals("API Key required", legacyKey.message)
    }
}
