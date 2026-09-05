package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class ProviderEffectiveStatusKindTest {
    
    
    @Test
    fun `local engine with empty key is not derived as NeedsKey`() {
        val localEngine = Provider(
            id = "123e4567-e89b-12d3-a456-426614174001",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(
                engineProfile = "lmstudio",
                authMode = RelayAuthMode.None,
            ),
        )
        assertNotEquals(ProviderEffectiveStatusKind.NeedsKey, localEngine.effectiveStatusKind)
        assertEquals(ProviderEffectiveStatusKind.Connected, localEngine.effectiveStatusKind)
    }

    
    @Test
    fun `cloud relay with empty key still derives NeedsKey`() {
        val cloudRelay = Provider(
            id = "123e4567-e89b-12d3-a456-426614174002",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(),
        )
        assertEquals(ProviderEffectiveStatusKind.NeedsKey, cloudRelay.effectiveStatusKind)
    }

    @Test
    fun `auth none relay with no engine profile is not derived as NeedsKey`() {
        val unauthenticatedRelay = Provider(
            id = "123e4567-e89b-12d3-a456-426614174003",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )

        assertEquals(ProviderEffectiveStatusKind.Connected, unauthenticatedRelay.effectiveStatusKind)
    }
}
