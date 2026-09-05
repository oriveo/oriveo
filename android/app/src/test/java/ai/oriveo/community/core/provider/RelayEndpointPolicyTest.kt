package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.provider.relay.RELAY_SECURITY_MODE_HEADER
import ai.oriveo.community.core.provider.relay.relayLocalSecurityPlugin
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.get
import io.ktor.client.request.header
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayEndpointPolicyTest {

    @Test
    fun `normalizes secure public local and vpn endpoints`() {
        assertEquals(
            "https://relay.example.com/v1",
            RelayEndpointPolicy.normalize("relay.example.com/v1/"),
        )
        assertEquals(
            "https://192.168.2.50:11434/v1",
            RelayEndpointPolicy.normalize("https://192.168.2.50:11434/v1"),
        )
        assertEquals(
            "https://modelbox.local/v1",
            RelayEndpointPolicy.normalize("https://modelbox.local/v1"),
        )
        assertEquals(
            "https://relay.tailnet.example/v1",
            RelayEndpointPolicy.normalize("https://relay.tailnet.example/v1"),
        )
    }

    @Test
    fun `rejects cleartext unsupported and credential bearing endpoints`() {
        assertNull(RelayEndpointPolicy.normalize("http://192.168.2.50:11434/v1"))
        assertNull(RelayEndpointPolicy.normalize("ftp://relay.example.com/v1"))
        assertNull(RelayEndpointPolicy.normalize("https://alice:secret@relay.example.com/v1"))
        assertNull(RelayEndpointPolicy.normalize("https:///v1"))
    }

    @Test
    fun `runtime guard reports configuration error for persisted http endpoint`() {
        try {
            RelayEndpointPolicy.requireSecure("http://10.0.0.5:8080/v1")
            throw AssertionError("Expected InvalidConfiguration")
        } catch (error: ProviderServiceError.InvalidConfiguration) {
            assertEquals(RelayEndpointPolicy.HTTPS_REQUIRED_MESSAGE, error.detail)
        }
    }

    @Test
    fun `configured cleartext endpoint requires real private address evidence`() {
        val publicError = runCatching {
            RelayEndpointPolicy.requireConfigured(
                "http://8.8.8.8/v1",
                RelayConnectionSecurityMode.LocalHttp,
                RelayEndpointPolicy.Credentials(authMode = RelayAuthMode.None),
            )
        }.exceptionOrNull() as ProviderServiceError.InvalidConfiguration
        assertEquals("public_address", publicError.detail)

        // Do not tie the unit test to the host machine's DNS: some networks hijack the
        // reserved `.invalid` domain and hand back a public address, in which case the
        // production code correctly reports `public_address` and the test fails for a
        // reason that has nothing to do with the code under test.
        val unknown = RelayEndpointPolicy.classify(
            raw = "http://unresolved.invalid/v1",
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            resolvedIPs = emptyList(),
            credentials = RelayEndpointPolicy.Credentials(authMode = RelayAuthMode.None),
        )
        assertFalse(unknown.allowed)
        assertEquals("unknown_address", unknown.reason)
    }

    @Test
    fun `password uses the same sensitive name source as credential policy`() {
        val credentials = RelayEndpointPolicy.credentialsOf(
            RelayRequestedConfig(
                authMode = RelayAuthMode.None,
                headers = listOf(
                    RelayKeyValue("X-Password", "sensitive-value"),
                    RelayKeyValue("X-Trace", "safe-value"),
                ),
            ),
            hasKey = false,
        )

        assertTrue(RelayEndpointPolicy.isSensitiveName("X-Password"))
        assertEquals(listOf("X-Password"), credentials.sensitiveHeaders)
        assertFalse(RelayEndpointPolicy.isSensitiveName("X-Trace"))
    }

    @Test
    fun `production local transport rejects password header from the shared source`() = runTest {
        val client = HttpClient(MockEngine { respond("unexpected") }) {
            install(relayLocalSecurityPlugin())
        }
        try {
            val error = runCatching {
                client.get("http://127.0.0.1/v1/models") {
                    header(RELAY_SECURITY_MODE_HEADER, RelayConnectionSecurityMode.LocalHttp.value)
                    header("X-Password", "sensitive-value")
                }
            }.exceptionOrNull()
            assertTrue(
                generateSequence(error) { it.cause }
                    .any { it.message?.contains("local_http_sensitive_credential_blocked") == true },
            )
        } finally {
            client.close()
        }
    }
}
