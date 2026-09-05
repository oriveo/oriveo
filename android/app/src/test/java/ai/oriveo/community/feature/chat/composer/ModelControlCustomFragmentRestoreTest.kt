package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The "Custom" state shown on screen and the "Custom" fields that actually reach the wire must
 * come from the same computation.
 *
 * The shape of the bug this guards against: the composer's restore state only read the
 * generation namespace, while the outbound path (`ChatSendCoordinator`) read all three. If a
 * user had saved a fragment on web or reasoning, reopening the sheet would show that row as
 * unselected while the request still sent it -- the UI showed less than what was actually in
 * effect.
 */
class ModelControlCustomFragmentRestoreTest {
    private val provider = "provider-1"
    private val model = "model-1"
    private val conversation = "conversation-1"
    private val transport = "fingerprint-1"

    private fun store(): LocalCapabilityCustomFragmentStore {
        var payload: String? = null
        return LocalCapabilityCustomFragmentStore(read = { payload }, write = { payload = it })
    }

    private fun LocalCapabilityCustomFragmentStore.put(namespace: String, raw: String) = setFragment(
        rawJSON = raw,
        providerID = provider,
        modelID = model,
        conversationID = conversation,
        transportIdentity = transport,
        namespace = namespace,
    )

    private fun LocalCapabilityCustomFragmentStore.owners() =
        fragmentsByOwner(provider, model, conversation, transport)

    @Test
    fun `restore reads every namespace the outbound path sends`() {
        val store = store()
        store.put(LocalCapabilityCustomFragmentStore.WEB_NAMESPACE, """{"enable_search":true}""")
        store.put(LocalCapabilityCustomFragmentStore.REASONING_NAMESPACE, """{"reasoning":{"effort":"high"}}""")
        store.put(LocalCapabilityCustomFragmentStore.GENERATION_NAMESPACE, """{"max_output_tokens":64}""")

        assertEquals(
            mapOf(
                "web" to """{"enable_search":true}""",
                "reasoning" to """{"reasoning":{"effort":"high"}}""",
                "generation" to """{"max_output_tokens":64}""",
            ),
            store.owners(),
        )
    }

    /** Saved only on web: the restore path must recognize web, and must not report "no custom fields at all" just because generation is empty. */
    @Test
    fun `a web-only fragment is not invisible to the restore path`() {
        val store = store()
        store.put(LocalCapabilityCustomFragmentStore.WEB_NAMESPACE, """{"enable_search":true}""")
        assertEquals(setOf("web"), store.owners().keys)
        assertEquals("""{"enable_search":true}""", store.owners()["web"])
    }

    @Test
    fun `reasoning-only fragment is visible too`() {
        val store = store()
        store.put(LocalCapabilityCustomFragmentStore.REASONING_NAMESPACE, """{"reasoning":{"effort":"low"}}""")
        assertEquals(setOf("reasoning"), store.owners().keys)
    }

    @Test
    fun `nothing stored means nothing restored and nothing sent`() {
        assertEquals(emptyMap<String, String>(), store().owners())
    }

    /** Clearing one owner only affects itself: the other two owners' Custom state must not be wiped along with it. */
    @Test
    fun `clearing one owner leaves the others intact`() {
        val store = store()
        store.put(LocalCapabilityCustomFragmentStore.WEB_NAMESPACE, """{"enable_search":true}""")
        store.put(LocalCapabilityCustomFragmentStore.GENERATION_NAMESPACE, """{"max_output_tokens":64}""")
        store.setFragment(
            rawJSON = null,
            providerID = provider,
            modelID = model,
            conversationID = conversation,
            transportIdentity = transport,
            namespace = LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
        )
        assertEquals(setOf("generation"), store.owners().keys)
    }

    /** A different transport is not the same connection: both the restore path and the outbound path must fail closed together. */
    @Test
    fun `a different transport identity restores nothing`() {
        val store = store()
        store.put(LocalCapabilityCustomFragmentStore.WEB_NAMESPACE, """{"enable_search":true}""")
        assertEquals(
            emptyMap<String, String>(),
            store.fragmentsByOwner(provider, model, conversation, "fingerprint-2"),
        )
    }

    @Test
    fun `owner to namespace mapping has a single implementation`() {
        assertEquals(
            mapOf(
                "web" to LocalCapabilityCustomFragmentStore.WEB_NAMESPACE,
                "reasoning" to LocalCapabilityCustomFragmentStore.REASONING_NAMESPACE,
                "generation" to LocalCapabilityCustomFragmentStore.GENERATION_NAMESPACE,
            ),
            LocalCapabilityCustomFragmentStore.ownerNamespaces(),
        )
        assertEquals(
            LocalCapabilityCustomFragmentStore.ownerNamespaces().values.toSet(),
            LocalCapabilityCustomFragmentStore.supportedNamespaces(),
        )
        assertNull(LocalCapabilityCustomFragmentStore.namespaceForOwner("telemetry"))
    }

    /**
     * Structural lock: both the restore path and the outbound path must consume
     * [LocalCapabilityCustomFragmentStore.fragmentsByOwner]. A pure behavior assertion alone
     * can't catch someone reintroducing a single-namespace read inside the composer -- which is
     * exactly how the original bug was written.
     */
    @Test
    fun `both consumers go through the shared owner walk`() {
        val composer = File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
        val coordinator = File("src/main/java/ai/oriveo/community/feature/chat/ChatSendCoordinator.kt").readText()

        assertTrue("the composer's restore path must go through the shared owner walk", composer.contains("localCustomFragmentStore.fragmentsByOwner("))
        assertTrue("the outbound path must go through the same function", coordinator.contains("fragmentsByOwner("))
        assertFalse(
            "the outbound side must not build its own owner -> namespace table",
            coordinator.contains("REASONING_NAMESPACE") && coordinator.contains("WEB_NAMESPACE"),
        )
        // The restore path must never reintroduce a single-namespace read. The walk across all
        // three namespaces lives in `restoredCustomOwners()` (the forward-port is wired into that
        // same read), and the restore path calls it.
        val restoreBlock = composer
            .substringAfter("LaunchedEffect(\n        showModelControls,")
            .substringBefore("var composerGenerationOverrides")
        assertTrue("the restore path anchor is stale; this test isn't catching anything anymore", restoreBlock.contains("restoredCustomOwners()"))
        assertTrue(
            "the shared owner walk must actually go through fragmentsByOwner",
            composer.substringAfter("fun restoredCustomOwners()").substringBefore("}\n")
                .contains("localCustomFragmentStore.fragmentsByOwner("),
        )
        assertFalse(
            "the restore path must not read only a single namespace",
            restoreBlock.contains("localCustomFragmentStore.fragment("),
        )
        // The editor lives on the advanced settings page. Returning from that page bumps
        // `modelBehaviorRevision`, and the restore path must key off it -- otherwise an owner
        // that was just enabled or cleared on the edit page would still show its old state on
        // the card, again showing less on screen than what actually gets sent.
        assertTrue(
            "the restore path must key off modelBehaviorRevision",
            composer.substringBefore("if (!showModelControls) return@LaunchedEffect")
                .takeLast(400)
                .contains("modelBehaviorRevision,"),
        )
        assertFalse(
            "there must be no remaining developer master-switch symbol anywhere in the repo",
            composer.contains("isDeveloperModeEnabled(") || composer.contains("setDeveloperModeEnabled("),
        )
        // The panel itself no longer holds the editor, but "which owners are currently taken over
        // by a custom control" must still be passed in -- the card's "the preference selected
        // above won't be sent" note is rendered from exactly this value.
        assertTrue(composer.contains("customOwners = developerCustomOwners,"))
        val sheet = File(
            "src/main/java/ai/oriveo/community/feature/chat/composer/ModelControlsSheet.kt",
        ).readText()
        assertTrue(sheet.contains("fun isCustomActive(owner: String): Boolean = owner in customOwners"))
    }
}
