package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The candidate-filtering logic ModelControlsSheet uses to suggest "models that support this
 * capability" as a primary action for the unavailable/unknown/custom_only states. A pure
 * function decoupled from the `MetadataClient` singleton, tested by injecting a lookup that
 * covers four scenarios: candidates present, no candidates, managed connections excluded, and
 * exact transport matches.
 * Mirrors iOS's `CapabilityControlActionCandidatesTests`.
 */
class CapabilityControlActionCandidatesTest {

    private data class Candidate(val id: String)

    @Test
    fun `only exact-transport auto_available models are kept`() {
        val models = listOf(Candidate("a"), Candidate("b"), Candidate("c"), Candidate("d"))
        val lookups = mapOf(
            // auto_available + exact transport match -> kept
            "a" to CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "auto_available", recipeTransport = "openai_chat", modelTransport = "openai_chat",
            ),
            // auto_available but recipe transport differs from this model's route -> dropped
            "b" to CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "auto_available", recipeTransport = "openai_chat", modelTransport = "anthropic_messages",
            ),
            // not auto_available at all -> dropped
            "c" to CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "unknown", recipeTransport = null, modelTransport = "openai_chat",
            ),
            // auto_available but missing recipe/model transport (unresolved runtime) -> dropped
            "d" to CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "auto_available", recipeTransport = null, modelTransport = null,
            ),
        )

        val result = CapabilityControlActionCandidates.supportingModels(
            capability = "web", models = models,
        ) { lookups.getValue(it.id) }

        assertEquals(listOf(Candidate("a")), result)
    }

    @Test
    fun `no supporting model yields an empty list, never a fabricated candidate`() {
        val models = listOf(Candidate("a"), Candidate("b"))

        val result = CapabilityControlActionCandidates.supportingModels(
            capability = "reasoning", models = models,
        ) {
            CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "unknown", recipeTransport = null, modelTransport = "openai_chat",
            )
        }

        assertTrue(result.isEmpty())
    }

    /**
     * Candidates come only from enabled models, matching iOS's `supportedModelCandidates`.
     * Models in the catalog that aren't enabled yet must never appear here even if the
     * capability is available -- tapping "switch" on one of those would do nothing, which is
     * just another dead end.
     */
    @Test
    fun `candidates come from the enabled models, never the whole catalog`() {
        val source = File(
            "src/main/java/ai/oriveo/community/feature/chat/ChatModelCapabilityResolver.kt",
        ).readText()
        val candidates = source
            .substringAfter("fun supportedModelCandidates(")
            .substringBefore("private fun relayRuntimeAttachmentSupport")
        assertTrue("the candidate pool must be enabled models", candidates.contains("models = provider.models,"))
        assertFalse("the candidate pool must not fall back to allModels, which includes disabled entries", candidates.contains("provider.allModels"))
    }

    @Test
    fun `openai_chat's sole transport alias still resolves as an exact match`() {
        // canonicalCapabilityTransport (MetadataClient.kt) normalizes "openai_chat" to
        // "openai_chat_completions" -- its only alias mapping, and the production candidate
        // filter reuses this same normalization.
        val models = listOf(Candidate("a"))

        val result = CapabilityControlActionCandidates.supportingModels(
            capability = "web", models = models,
        ) {
            CapabilityControlActionCandidates.ModelCapabilityLookup(
                state = "auto_available", recipeTransport = "openai_chat", modelTransport = "openai_chat_completions",
            )
        }

        assertEquals(listOf(Candidate("a")), result)
    }
}
