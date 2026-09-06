package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelaySecurityModePolicyTest {
    @Test
    fun `scheme rewrite exposes only the newly added scheme for UI highlighting`() {
        assertEquals(0..6, RelaySecurityModePolicy.addedSchemeHighlightRange("relay.lan:8080", "http://relay.lan:8080"))
        assertEquals(null, RelaySecurityModePolicy.addedSchemeHighlightRange("http://relay.lan:8080", "http://relay.lan:8080"))
    }

    @Test
    fun `production classifier suggests local http without mutating the default mode`() {
        val assessment = RelaySecurityModePolicy.assess(
            rawEndpoint = "192.168.1.20:1234/v1",
            resolvedIPs = listOf("192.168.1.20"),
        )

        assertTrue(assessment.localHttp.enabled)
        assertEquals("private_lan", assessment.localHttp.reason)
        assertEquals("http://192.168.1.20:1234/v1", assessment.localHttp.normalizedEndpoint)
        assertEquals(RelayConnectionSecurityMode.LocalHttp, assessment.suggestedMode)

        // A suggestion never carries a chosen mode with it: the mode is only written when
        // the user affirmatively taps it in the UI.
        assertEquals(
            "https://192.168.1.20:1234/v1",
            RelaySecurityModePolicy.normalizedEndpoint(
                rawEndpoint = "192.168.1.20:1234/v1",
                mode = RelayConnectionSecurityMode.RemoteHttps,
                assessment = assessment,
            ),
        )
    }

    @Test
    fun `tailscale is only available as private vpn`() {
        val assessment = RelaySecurityModePolicy.assess(
            rawEndpoint = "http://100.64.10.20:8080/v1",
            resolvedIPs = listOf("100.64.10.20"),
        )

        assertFalse(assessment.localHttp.enabled)
        assertEquals("public_address", assessment.localHttp.reason)
        assertTrue(assessment.privateVpn.enabled)
        assertEquals("private_vpn", assessment.privateVpn.reason)
        assertEquals(RelayConnectionSecurityMode.PrivateVpn, assessment.suggestedMode)
    }

    @Test
    fun `public and mixed resolution keep cleartext choices disabled`() {
        val publicAssessment = RelaySecurityModePolicy.assess(
            rawEndpoint = "http://relay.example/v1",
            resolvedIPs = listOf("203.0.113.8"),
        )
        val mixedAssessment = RelaySecurityModePolicy.assess(
            rawEndpoint = "http://relay.example/v1",
            resolvedIPs = listOf("192.168.1.20", "203.0.113.8"),
        )

        assertFalse(publicAssessment.localHttp.enabled)
        assertFalse(publicAssessment.privateVpn.enabled)
        assertEquals("public_address", publicAssessment.localHttp.reason)
        assertNull(publicAssessment.suggestedMode)
        assertFalse(mixedAssessment.localHttp.enabled)
        assertFalse(mixedAssessment.privateVpn.enabled)
        assertEquals("mixed_resolution", mixedAssessment.localHttp.reason)
        assertNull(mixedAssessment.suggestedMode)
    }

    @Test
    fun `explicit https never produces a weaker suggestion`() {
        val assessment = RelaySecurityModePolicy.assess(
            rawEndpoint = "https://192.168.1.20:1234/v1",
            resolvedIPs = listOf("192.168.1.20"),
        )

        assertFalse(assessment.localHttp.enabled)
        assertFalse(assessment.privateVpn.enabled)
        assertEquals("encrypted_endpoint", assessment.localHttp.reason)
        assertNull(assessment.suggestedMode)
    }
}
