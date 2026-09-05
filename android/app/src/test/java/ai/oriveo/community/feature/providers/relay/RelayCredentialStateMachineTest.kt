package ai.oriveo.community.feature.providers.relay

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.security.SecureKeyStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The three credential states (S0 not required / S1 missing / S2 stored) and their single
 * derived predicate `requiresCredential`, locked down here.
 *
 * Key discipline: every input in this class comes from an object produced by production code --
 * protocol defaults come from [RelayKindDefaults.makeRequested], previews come from
 * [SecureKeyStore.maskApiKey]; tests never hand-roll a `RelayRequestedConfig` to prove a
 * production predicate holds.
 */
class RelayCredentialStateMachineTest {

    @Test
    fun `every built-in relay protocol default requires a credential`() {
        // Defaults produced by the production factory: Bearer / x-api-key / x-goog-api-key are all auth modes that require a credential
        RelayKind.entries.forEach { kind ->
            val produced = RelayKindDefaults.makeRequested(kind)
            assertTrue(
                "$kind default authMode=${produced.authMode} should be judged to require a credential",
                produced.requiresCredential,
            )
        }
    }

    @Test
    fun `only an explicit none auth mode waives the credential`() {
        val custom = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )
        assertEquals(RelayAuthMode.None, custom.authMode)
        assertFalse(custom.requiresCredential)

        // auto just means "not yet determined"; fail-safe still requires a credential
        val auto = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = RelayAuthMode.Auto),
        )
        assertTrue(auto.requiresCredential)

        // A missing relayRequested (official providers / legacy dirty data) is treated the same as auto
        val missing: RelayRequestedConfig? = null
        assertTrue(missing.requiresCredential)
    }

    @Test
    fun `api key row renders S0 neutral instead of the orange required warning`() {
        val localEngine = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )
        // The preview comes from the production masking function: an empty key must produce an empty string, not a run of mask dots drawn for a key that doesn't exist
        val preview = SecureKeyStore.maskApiKey("")
        assertEquals("", preview)

        assertEquals(
            RelayApiKeyRowState.NotRequired,
            RelayApiKeyRowState.of(localEngine.requiresCredential, preview),
        )
    }

    @Test
    fun `api key row keeps the warning only when a credential is required and absent`() {
        val bearer = RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible)

        assertEquals(
            RelayApiKeyRowState.Missing,
            RelayApiKeyRowState.of(bearer.requiresCredential, SecureKeyStore.maskApiKey("")),
        )
        assertEquals(
            RelayApiKeyRowState.Present,
            RelayApiKeyRowState.of(bearer.requiresCredential, SecureKeyStore.maskApiKey("sk-abcdefghijklmnop")),
        )
        // Legacy dirty data: auth=none but a key is still stored -- still render S2, otherwise the user has no way to remove it
        val noAuth = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )
        assertEquals(
            RelayApiKeyRowState.Present,
            RelayApiKeyRowState.of(noAuth.requiresCredential, SecureKeyStore.maskApiKey("sk-abcdefghijklmnop")),
        )
    }

    @Test
    fun `mask keeps at most four leading and trailing characters and never invents dots`() {
        assertEquals("", SecureKeyStore.maskApiKey(""))
        assertEquals("", SecureKeyStore.maskApiKey("   "))
        // <=12 chars are masked entirely -- for a short key, revealing 4 leading and trailing characters would print most of the key on screen (same rule across all three platforms: 8 mask dots)
        assertEquals("••••••••", SecureKeyStore.maskApiKey("sk-123456789"))
        assertEquals("sk-1••••wxyz", SecureKeyStore.maskApiKey("sk-1234567890wxyz"))
    }
}
