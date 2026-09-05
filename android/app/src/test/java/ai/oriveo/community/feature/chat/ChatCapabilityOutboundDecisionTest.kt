package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ReasoningMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatCapabilityOutboundDecisionTest {
    private val controls = ChatModelCapabilityResolver.ModelControls(
        webAvailable = true,
        webForceAvailable = true,
        reasoningIntents = listOf("off", "low", "balanced", "deep", "max"),
        reasoningState = "auto_available",
    )

    @Test
    fun `active selections mirror the effective outbound request`() {
        val decision = ChatCapabilityOutboundDecision.resolve(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            controls,
        )

        assertTrue(decision.webSearchEnabled)
        assertEquals(ReasoningMode.Deep, decision.reasoningMode)
        assertEquals("deep", decision.reasoningIntent)
        assertTrue(decision.hasActiveCapabilitySelection)
    }

    @Test
    fun `dormant owners and unavailable intents do not highlight the chip`() {
        val dormant = ChatCapabilityOutboundDecision.resolve(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            controls,
            dormantOwners = setOf("web", "reasoning"),
        )
        val unavailableIntent = ChatCapabilityOutboundDecision.resolve(
            CapabilityPreferenceValues(CapabilityWebPreference.Off, "low"),
            controls.copy(reasoningIntents = listOf("deep")),
        )

        assertFalse(dormant.hasActiveCapabilitySelection)
        assertEquals(ReasoningMode.Automatic, dormant.reasoningMode)
        assertFalse(unavailableIntent.hasReasoningSelection)
    }
}
