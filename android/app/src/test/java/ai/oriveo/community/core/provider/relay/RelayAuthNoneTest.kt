package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import io.ktor.client.request.HttpRequestBuilder
import org.junit.Assert.assertFalse
import org.junit.Test

class RelayAuthNoneTest {
    @Test
    fun `auth none injects no credential or custom header`() {
        val builder = HttpRequestBuilder()
        with(RelayHeaderBuilder) {
            builder.applyRelayHeaders(
                apiKey = "must-not-leak",
                requestOptions = ChatRequestOptions(
                    relayRequested = RelayRequestedConfig(
                        authMode = RelayAuthMode.None,
                        headers = listOf(
                            RelayKeyValue("Authorization", "Bearer must-not-leak"),
                            RelayKeyValue("X-Private-Key", "must-not-leak"),
                        ),
                        queryParams = listOf(RelayKeyValue("key", "must-not-leak")),
                    ),
                ),
                transport = RelayTransport.OpenAIChatCompletions,
            )
        }

        val names = builder.headers.names().map(String::lowercase).toSet()
        assertFalse("authorization" in names)
        assertFalse("x-api-key" in names)
        assertFalse("x-goog-api-key" in names)
        assertFalse("x-private-key" in names)
    }
}
