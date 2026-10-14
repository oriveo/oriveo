package ai.oriveo.community.feature.chat.recovery

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Chat "switch key": the condition is derived only from the persisted `relayDeniedKeyID` and alternate,
 * options come from production [RelayKeyBinding.modelState], selecting goes through [RelayKeyBinding.rebind], and nothing is resent automatically.
 */
class RelaySwitchKeyTest {

    private fun provider(models: List<AIModel>) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://api.myrelay.dev",
        apiKey = "sk-main-000000000000aaaa",
        relayKind = RelayKind.OpenAICompatible,
        relayKeys = listOf(
            RelayKey(id = "k1", name = "Main"),
            RelayKey(id = "k2", name = null, apiKey = "sk-backup-00000000beef"),
            RelayKey(id = "k3", name = "Spare", apiKey = "sk-spare-000000000cafe"),
        ),
        models = models,
        catalogModels = listOf(
            AIModel(id = "gpt-5", name = "GPT-5", relayListedByKeyIDs = listOf("k1", "k2")),
            AIModel(id = "solo", name = "solo", relayListedByKeyIDs = listOf("k1")),
        ),
    )

    private fun failed(modelID: String, state: ChatMessageState = ChatMessageState.Failed, role: ChatRole = ChatRole.Assistant) = ChatMessage(
        id = "m1",
        role = role,
        text = "",
        providerID = "relay-1",
        providerKind = ProviderKind.Relay,
        providerName = "myrelay",
        modelID = modelID,
        modelName = modelID,
        state = state,
    )

    @Test
    fun `CHAT-SWITCHKEY-01 switch key replaces edit when the bound key is denied and alternates list the model`() {
        val denied = AIModel(id = "gpt-5", name = "GPT-5", relayKeyID = "k1", relayDeniedKeyID = "k1")
        val p = provider(listOf(denied))
        val options = RelaySwitchKey.options(p, failed("gpt-5"))
        // alternate = the other keys that list this model (production modelState), name or mask + mask.
        assertEquals(RelayKeyBinding.modelState(p, "gpt-5").alternateKeyIDs, options.map { it.keyId })
        assertEquals(listOf(RelaySwitchKeyOption("k2", "sk-b…beef", "sk-b…beef")), options)

        // Failure card has three slots: Switch key replaces the edit slot, Retry stays the primary button, switch model is kept.
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = true,
            offersSwitchKey = options.isNotEmpty(),
        )
        assertEquals(MessageRecoveryActionKind.Retry, layout.primary)
        assertEquals(MessageRecoveryActionKind.SwitchKey, layout.secondary)
        assertEquals(MessageRecoveryActionKind.SwitchModel, layout.tertiary)
        assertEquals(R.string.relay_chat_switch_key, MessageRecoveryActionKind.SwitchKey.titleRes())
        var switched = false
        var retried = false
        performRecoveryAction(
            MessageRecoveryActionKind.SwitchKey,
            onRetry = { retried = true },
            onEdit = {},
            onRegenerate = {},
            onSwitchModel = {},
            onContinue = {},
            onSwitchKey = { switched = true },
        )
        assertTrue(switched)
        assertEquals(false, retried)

        // Selecting -> rebind: clears the no-access marker and the button disappears; no automatic resend (the user resends via the existing Retry).
        val rebound = requireNotNull(RelayKeyBinding.rebind(p, "gpt-5", options.single().keyId))
        assertEquals("k2", rebound.models.single().relayKeyID)
        assertNull(rebound.models.single().relayDeniedKeyID)
        assertTrue(RelaySwitchKey.options(rebound, failed("gpt-5")).isEmpty())

        // No button: no alternate, not denied, model no longer enabled, not a failed / non-assistant message, or no connection.
        val soloDenied = AIModel(id = "solo", name = "solo", relayKeyID = "k1", relayDeniedKeyID = "k1")
        assertTrue(RelaySwitchKey.options(provider(listOf(soloDenied)), failed("solo")).isEmpty())
        assertTrue(RelaySwitchKey.options(provider(listOf(denied.copy(relayDeniedKeyID = null))), failed("gpt-5")).isEmpty())
        assertTrue(RelaySwitchKey.options(provider(listOf(soloDenied)), failed("gpt-5")).isEmpty())
        assertTrue(RelaySwitchKey.options(p, failed("gpt-5", state = ChatMessageState.Delivered)).isEmpty())
        assertTrue(RelaySwitchKey.options(p, failed("gpt-5", role = ChatRole.User)).isEmpty())
        assertTrue(RelaySwitchKey.options(null, failed("gpt-5")).isEmpty())
        // Layout unchanged when absent: the edit slot stays as before.
        assertEquals(
            MessageRecoveryActionKind.EditMessage,
            resolveMessageRecoveryCardActionLayout(state = ChatMessageState.Failed, shouldOfferModelSwitch = false).secondary,
        )
    }
}
