package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.providers.relay.RelayEditSavePolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Codex identity save rule: after the type layer was removed, saving keeps the value in the store as is,
 * no longer setting nil / true depending on whether relayKind is codex_style, and no longer varying with the transport.
 */
class RelayDetailConfigTest {

    private fun relay(identity: Boolean?, transport: RelayTransport, kind: RelayKind) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.example/v1",
        relayKind = kind,
        relayRequested = RelayRequestedConfig(transport = transport, codexCompatIdentity = identity),
    )

    @Test
    fun `codex identity is kept verbatim whatever the protocol or legacy kind`() {
        listOf(null, true, false).forEach { identity ->
            RelayKind.entries.forEach { kind ->
                RelayTransport.entries.forEach { target ->
                    val persisted = relay(identity, RelayTransport.OpenAIResponses, kind)
                    val saved = RelayEditSavePolicy.savedRequested(
                        persisted = persisted,
                        candidate = persisted.relayRequested!!.copy(transport = target, codexCompatIdentity = !(identity ?: false)),
                        candidateBaseUrl = persisted.baseUrlText,
                    )
                    assertEquals("$identity / $kind → $target", identity, saved.codexCompatIdentity)
                }
            }
        }
    }

    @Test
    fun `relay kind on save is derived from the default protocol`() {
        assertEquals(RelayKind.Custom, RelayEditSavePolicy.savedRelayKind(RelayRequestedConfig(transport = RelayTransport.Auto)))
        assertEquals(RelayKind.CodexStyle, RelayEditSavePolicy.savedRelayKind(RelayRequestedConfig(transport = RelayTransport.OpenAIResponses)))
        assertEquals(RelayKind.OpenAICompatible, RelayEditSavePolicy.savedRelayKind(RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions)))
        assertEquals(RelayKind.AnthropicCompatible, RelayEditSavePolicy.savedRelayKind(RelayRequestedConfig(transport = RelayTransport.AnthropicMessages)))
        assertEquals(RelayKind.GeminiCompatible, RelayEditSavePolicy.savedRelayKind(RelayRequestedConfig(transport = RelayTransport.GeminiGenerateContent)))
    }
}
