package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.feature.providers.relay.relayCodexIdentityChecked
import ai.oriveo.community.feature.providers.relay.relayCodexIdentityEditable
import ai.oriveo.community.feature.providers.relay.relayCodexIdentityForSave

import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayDetailConfigTest {

    @Test
    fun `codex identity can be disabled for codex style relay`() {
        val requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIResponses,
            codexCompatIdentity = false,
        )

        assertTrue(relayCodexIdentityEditable(RelayKind.CodexStyle))
        assertFalse(relayCodexIdentityChecked(RelayKind.CodexStyle, requested))
        assertEquals(false, relayCodexIdentityForSave(RelayKind.CodexStyle, requested))
    }

    @Test
    fun `codex style relay defaults to codex identity on when unset`() {
        val requested = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses)

        assertTrue(relayCodexIdentityEditable(RelayKind.CodexStyle))
        assertTrue(relayCodexIdentityChecked(RelayKind.CodexStyle, requested))
        assertEquals(true, relayCodexIdentityForSave(RelayKind.CodexStyle, requested))
    }

    @Test
    fun `non codex relay clears codex identity on save`() {
        val requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            codexCompatIdentity = true,
        )

        assertFalse(relayCodexIdentityEditable(RelayKind.OpenAICompatible))
        assertFalse(relayCodexIdentityChecked(RelayKind.OpenAICompatible, requested))
        assertNull(relayCodexIdentityForSave(RelayKind.OpenAICompatible, requested))
    }
}
