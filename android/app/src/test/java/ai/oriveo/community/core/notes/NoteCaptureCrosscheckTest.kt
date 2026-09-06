package ai.oriveo.community.core.notes

import ai.oriveo.community.core.model.NoteCaptureKind
import ai.oriveo.community.core.model.ProvenanceKind
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteCaptureCrosscheckTest {

    private fun build() = NoteCapture.fromCrosscheck(
        originalAnswer = "  Paris is the capital.  ",
        originConversationId = "CONV-1",
        originMessageId = "MSG-1",
        originModelID = "gpt-5",
        originModelName = "GPT-5",
        originProviderKind = ProviderKind.OpenAI,
        originProviderName = "OpenAI",
        originPrompt = "What is the capital of France?",
        crosscheckProviderKind = ProviderKind.Anthropic,
        crosscheckProviderName = "Anthropic",
        crosscheckModelID = "claude-opus",
        crosscheckModelName = "Claude Opus",
        crosscheckText = "  Correct. Paris.  ",
        originAtIso = "2026-06-01T10:00:00Z",
        nowIso = "2026-06-21T12:00:00Z",
    )

    @Test
    fun `body uses exact two-section template`() {
        val input = build()
        assertEquals(
            "## Original answer\n\nParis is the capital.\n\n## Cross-check (Claude Opus)\n\nCorrect. Paris.",
            input.body,
        )
        assertEquals("  Paris is the capital.  ", input.bodySnapshot)
        assertEquals(NoteCaptureKind.FullAnswer, input.captureKind)
        assertEquals("What is the capital of France?", input.sourcePrompt)
        assertEquals("MSG-1", input.sourceMessageId)
        assertEquals(ProviderKind.OpenAI, input.sourceProviderKind)
    }

    @Test
    fun `provenance has origin then crosscheck with expected fields`() {
        val p = build().provenance
        assertEquals(2, p.size)

        assertEquals(ProvenanceKind.Origin, p[0].kind)
        assertEquals("GPT-5", p[0].modelName)
        assertEquals(ProviderKind.OpenAI, p[0].providerKind)
        assertEquals("MSG-1", p[0].messageId)
        assertEquals("2026-06-01T10:00:00Z", p[0].at)

        assertEquals(ProvenanceKind.Crosscheck, p[1].kind)
        assertEquals("Claude Opus", p[1].modelName)
        assertEquals(ProviderKind.Anthropic, p[1].providerKind)
        assertEquals("MSG-1", p[1].messageId)
        assertEquals("2026-06-21T12:00:00Z", p[1].at)
    }

    @Test
    fun `model name appears in section header`() {
        assertTrue(build().body.contains("## Cross-check (Claude Opus)"))
    }
}
