package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.displayedForUi
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityWebPreferenceLiveness
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A dormant value must never be written back to storage as if it were the
 * user's own choice.
 *
 * The shape of this bug: the composer's restore path first ran the stored
 * value through `CapabilityWebPreferenceLiveness`, folding a web preference
 * that "can't reach the wire right now" down to `Off` before handing it to
 * the panel; but the value the panel receives doubles as both the displayed
 * value and the write-back source for `persist()` / `promoteToModelDefault()`.
 * So the moment a user opened the panel and casually changed a reasoning
 * tier, a web preference they never turned off got silently rewritten to
 * "off" -- and switching back to a model that supports web search wouldn't
 * bring it back, because the stored `Automatic` had already been overwritten.
 *
 * The fix separates two responsibilities:
 * - storage / display / write-back always use the raw, unfiltered value;
 * - liveness only feeds chip highlighting, library mutual exclusion, and
 *   outbound compilation.
 */
class ModelControlWriteBackPollutionTest {
    private val providerID = "conn-1"
    private val modelID = "model-1"
    private val conversationID = "conversation-1"
    private val transportIdentity = ModelControlRuntimeIdentity(
        connectionId = providerID,
        canonicalModelId = modelID,
        finalTransport = "openai_chat",
        runtimeRevision = "sha256:r1",
    ).storageIdentity

    private fun store(): CapabilityPreferenceStore {
        var payload = ""
        var drafts: String? = null
        return CapabilityPreferenceStore(
            read = { payload.ifEmpty { null } },
            write = { payload = it },
            readDrafts = { drafts },
            writeDrafts = { drafts = it },
        )
    }

    private fun CapabilityPreferenceStore.displayed(): CapabilityPreferenceValues = displayedForUi(
        providerID = providerID,
        providerKind = ProviderKind.OpenAI,
        modelID = modelID,
        conversationID = conversationID,
        skillID = null,
        transportIdentity = transportIdentity,
        isExistingConversation = true,
    )

    /** The value the panel displays is the raw stored value -- liveness never touches the read projection. */
    @Test
    fun `the panel reads the stored preference even when it cannot reach the wire right now`() {
        val store = store()
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            providerID, modelID, conversationID, transportIdentity,
        )

        // After a recipe change / delisting / transport switch, this preference can't reach the wire right now.
        assertFalse(
            "precondition: this tier really is dormant, otherwise this test isn't testing anything",
            CapabilityWebPreferenceLiveness.reachesTheWire(
                CapabilityControlPresentation.Pending, customIsActive = false,
            ),
        )
        assertEquals(
            "dormant does not rewrite the read projection: the panel must display whatever the user actually set",
            CapabilityWebPreference.Automatic,
            store.displayed().web,
        )
    }

    /**
     * Changing only the reasoning tier: the web preference must stay exactly
     * as stored.
     *
     * This replicates the panel's full `persist()` write-back chain: `clamp`
     * then `setConversation`. What goes in is whatever the restore path
     * produced, so whether the restore path gates it directly decides the
     * outcome of this assertion.
     */
    @Test
    fun `changing only the thinking tier never rewrites a dormant web preference`() {
        val store = store()
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            providerID, modelID, conversationID, transportIdentity,
        )
        val status = CapabilityControlPresentation.Pending

        // The web value the panel receives equals the raw stored value (the restore path does not gate it).
        val restoredWeb = store.displayed().web
        val clamped = ModelControlWebLayout.clamp(restoredWeb, status, availableIntents = emptyList())
        store.setConversation(
            CapabilityPreferenceValues(clamped, "deep"),
            providerID, modelID, conversationID, transportIdentity,
        )

        val after = store.displayed()
        assertEquals("the reasoning tier must be written", "deep", after.reasoningIntent)
        assertEquals(
            "the user never turned web search off, so storage must not become Off",
            CapabilityWebPreference.Automatic,
            after.web,
        )
    }

    /** Control case: once the restore path gates the value before handing it to the panel, this same chain corrupts the preference. */
    @Test
    fun `gating the restore value before write back is what corrupts the preference`() {
        val store = store()
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            providerID, modelID, conversationID, transportIdentity,
        )
        val status = CapabilityControlPresentation.Pending

        // This is the superseded approach: `selectedControlWeb = if (live) stored.web else Off`.
        val live = CapabilityWebPreferenceLiveness.reachesTheWire(status, customIsActive = false)
        val gated = if (live) store.displayed().web else CapabilityWebPreference.Off
        store.setConversation(
            CapabilityPreferenceValues(ModelControlWebLayout.clamp(gated, status, emptyList()), "deep"),
            providerID, modelID, conversationID, transportIdentity,
        )

        assertEquals(CapabilityWebPreference.Off, store.displayed().web)
        assertNotEquals(
            "the old approach and the new approach must give different results -- if they match, this control case has gone stale",
            store.displayed().web,
            CapabilityWebPreference.Automatic,
        )
    }

    /**
     * Structural guard: the library mutual-exclusion write-back must not
     * `copy` the entire resolved packet back wholesale.
     *
     * The behavior matrix lives in `CapabilityPreferenceReadLadderTest`
     * (write only web / merge when a record exists); this test only catches
     * someone reverting to a whole-packet write -- a mistake a pure behavior
     * assertion can't catch, because what breaks is another layer's
     * inheritance relationship.
     */
    @Test
    fun `the library mutex never persists the whole resolved packet`() {
        val viewModel = java.io.File(
            "src/main/java/ai/oriveo/community/feature/chat/ChatViewModel.kt",
        ).readText()
        val block = viewModel
            .substringAfter("private fun disableWebSearchPreference()")
            .substringBefore("\n    /** ")
        assertFalse(
            "must not copy the whole resolved packet back to the conversation layer",
            block.contains("val next = current.copy(web = CapabilityWebPreference.Off)"),
        )
        assertTrue("must read this layer's own record first", block.contains("capabilityPreferenceStore.scopeValues("))
        assertTrue(
            "with no record, only the web field should be written",
            block.contains("CapabilityPreferenceValues(web = CapabilityWebPreference.Off, reasoningIntent = null)"),
        )
    }

    /** "Set as this model's default" uses the same value, and must equally never bake a dormant value into the connection-times-model layer. */
    @Test
    fun `promoting to the model default carries the stored preference, not the dormant projection`() {
        val store = store()
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            providerID, modelID, conversationID, transportIdentity,
        )
        val panelValue = store.displayed()
        store.setConnectionModel(panelValue, providerID, modelID, transportIdentity)

        val connectionModel = store.scopeValues(
            providerID = providerID,
            modelID = modelID,
            conversationID = null,
            skillID = null,
            transportIdentity = transportIdentity,
        ).connectionModel
        assertEquals(CapabilityWebPreference.Automatic, connectionModel?.web)
    }
}
