package ai.oriveo.community.core.model

import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavior matrix for the read ladder (the fallback order across conversation, connection+model
 * and connection scopes) and for forward-porting typed preferences across runtime revisions.
 */
class CapabilityPreferenceReadLadderTest {
    private val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
    private val conversationID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    private val skillID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    private val model = "gpt-test"

    private fun identity(transport: String = "openai_responses", revision: String = "runtime-r7"): String =
        ModelControlRuntimeIdentity(providerID, model, transport, revision).storageIdentity

    private fun store(
        payload: AtomicReference<String?> = AtomicReference(null),
        drafts: AtomicReference<String?> = AtomicReference(null),
    ) = CapabilityPreferenceStore(
        read = { payload.get() },
        write = { payload.set(it) },
        readDrafts = { drafts.get() },
        writeDrafts = { drafts.set(it) },
    )

    // ── Display layer keeps the three states apart, with no final collapse ──────────

    /**
     * The outbound `resolved` value collapses "never set / chose automatic / chose off" into a
     * single "inject nothing" result. If the display layer echoed that result as-is, it would
     * render "never set" as "off" being selected -- making a choice for the user that they never
     * made, and doing so every time they open the panel on a model for the first time.
     */
    @Test
    fun `display selection keeps never-set, explicit automatic and explicit off apart`() {
        assertNull(
            "never set: the display layer must be null (renders as automatic selected)",
            CapabilityScopeValues().displaySelection().reasoningIntent,
        )
        assertNull(
            "explicit automatic is stored as null, same as never set, both render as automatic",
            CapabilityScopeValues(
                conversation = CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            ).displaySelection().reasoningIntent,
        )
        assertEquals(
            "an explicit off choice must read back unchanged",
            "off",
            CapabilityScopeValues(
                conversation = CapabilityPreferenceValues(CapabilityWebPreference.Off, "off"),
            ).displaySelection().reasoningIntent,
        )
        // Same for web: only Off when no layer has ever stored a value.
        assertEquals(
            CapabilityWebPreference.Off,
            CapabilityScopeValues().displaySelection().web,
        )
        assertEquals(
            CapabilityWebPreference.Force,
            CapabilityScopeValues(
                connectionModel = CapabilityPreferenceValues(CapabilityWebPreference.Force, null),
            ).displaySelection().web,
        )
    }

    /** reasoning and web fall back independently -- changing only web in a conversation must not also override the connection-level thinking tier. */
    @Test
    fun `each field walks the ladder independently`() {
        val selection = CapabilityScopeValues(
            conversation = CapabilityPreferenceValues(CapabilityWebPreference.Automatic, null),
            connectionModel = CapabilityPreferenceValues(CapabilityWebPreference.Off, "deep"),
        ).displaySelection()
        assertEquals(CapabilityWebPreference.Automatic, selection.web)
        assertEquals("deep", selection.reasoningIntent)
    }

    // ── Read path and send path share the same source ──────────────────────

    /**
     * After "set as default for this model" writes into connection_model, the UI must read it
     * back. Previously the UI only checked the conversation scope, so after setting a default
     * the panel still showed "automatic" on reopen -- the value only took effect on send.
     */
    @Test
    fun `the ui read falls back to the model default scope exactly like the send path`() {
        val store = store()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, identity(),
        )

        val display = store.displayedForUi(
            providerID, ProviderKind.OpenAI, model, conversationID, null, identity(),
        )
        assertEquals(CapabilityWebPreference.Automatic, display.web)
        assertEquals("deep", display.reasoningIntent)
        // The outbound side reads the same records, just with a different final collapse.
        assertEquals(
            "deep",
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, model, conversationID, null, identity())
                .reasoningIntent,
        )

        // An explicit conversation-scope choice wins (same source as the send path).
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Off, "off"),
            providerID, model, conversationID, identity(),
        )
        assertEquals(
            CapabilityWebPreference.Off,
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, identity()).web,
        )
        assertEquals(
            "off",
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, identity())
                .reasoningIntent,
        )
    }

    /**
     * A draft conversation must also see "the default for this model": a draft is just another
     * carrier for the conversation scope, and the connection*model / connection layers beneath
     * it still participate. Previously the draft branch only read the draft layer, so "set as
     * default for this model" neither read back in the next new conversation nor matched the
     * outbound path.
     */
    @Test
    fun `a draft conversation inherits the model default and its own record still wins`() {
        val store = store()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, identity(),
        )
        val draft = store.displayedForUi(
            providerID, ProviderKind.OpenAI, model, "draft-session", null, identity(),
            isExistingConversation = false,
        )
        assertEquals(CapabilityWebPreference.Automatic, draft.web)
        assertEquals("deep", draft.reasoningIntent)

        store.setDraftConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Off, "off"),
            providerID, model, "draft-session", identity(),
        )
        assertEquals(
            "an explicit choice made in the draft should win",
            "off",
            store.displayedForUi(
                providerID, ProviderKind.OpenAI, model, "draft-session", null, identity(),
                isExistingConversation = false,
            ).reasoningIntent,
        )
    }

    /** Storage side: a missing transport fails closed identically on both the read and write entries. */
    @Test
    fun `a missing transport fails closed on both read entries`() {
        val store = store()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, identity(),
        )
        assertEquals(
            CapabilityPreferenceValues(),
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, ""),
        )
        assertEquals(
            CapabilityPreferenceValues(),
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, model, conversationID, null, ""),
        )
    }

    // ── Forward-port matrix ─────────────────────────────────────────────────

    /** Each scope forward-ports independently through a versioned write, and the old record stays in place. */
    @Test
    fun `typed preferences forward port across runtime revisions and keep the old record`() {
        val store = store()
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        // Each scope stores a **different** value: if all three used the same value they would
        // all pass regardless of which one actually forward-ported.
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, conversationID, old,
        )
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "low"), providerID, model, old,
        )
        store.setConnection(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "balanced"), providerID, model, old,
        )
        store.confirmSkillAgent(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "max"),
            providerID, model, skillID, old,
        )

        val display = store.displayedForUi(
            providerID, ProviderKind.OpenAI, model, conversationID, skillID, new,
        )
        assertEquals("the conversation scope never followed the revision", "deep", display.reasoningIntent)
        assertEquals(CapabilityWebPreference.Automatic, display.web)

        // The forward-port is **actually persisted**, not computed on the fly at read time --
        // otherwise the outbound side wouldn't see it.
        val records = store.exportPayload().records.filter { it.transportIdentity == new }
        assertEquals(
            mapOf(
                "conversation_connection_model" to "deep",
                "connection_model" to "low",
                "connection" to "balanced",
                "skill_agent" to "max",
            ),
            records.associate { it.scope to it.reasoningIntent },
        )
        // Writes are versioned, with revision incrementing above any prior record or tombstone.
        assertTrue("the forward-port must go through the versioned entry", records.all { it.revision >= 1 && it.mutationId.isNotBlank() })
        // The old record stays in place, so a rollback to an older revision still picks up the user's setting.
        assertEquals(
            "deep",
            store.exportPayload().records
                .firstOrNull { it.transportIdentity == old && it.scope == "conversation_connection_model" }
                ?.reasoningIntent,
        )
        // The outbound side and the UI read the very same record.
        assertEquals(
            "deep",
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, model, conversationID, skillID, new)
                .reasoningIntent,
        )
    }

    /** Scopes never substitute for each other -- if only the conversation scope has an old value, the connection scope shouldn't sprout a record out of nowhere. */
    @Test
    fun `scopes forward port independently and never substitute for each other`() {
        val store = store()
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, conversationID, old,
        )

        store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)

        assertEquals(
            listOf("conversation_connection_model"),
            store.exportPayload().records.filter { it.transportIdentity == new }.map { it.scope },
        )
    }

    /**
     * A transport change isn't just "a new revision" -- it's an actual change of request
     * contract: field names, available tiers, and schema are all different. Carrying the old
     * value over would be guessing on the user's behalf, so it resets instead.
     */
    @Test
    fun `forward port is limited to the same transport`() {
        val store = store()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, identity("openai_responses", "runtime-r7"),
        )
        val otherProtocol = identity("openai_chat", "runtime-r8")

        assertNull(
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, otherProtocol)
                .reasoningIntent,
        )
        assertTrue(
            "the value was carried across a transport change, which is guessing a new contract for the user",
            store.exportPayload().records.none { it.transportIdentity == otherProtocol },
        )
    }

    /**
     * When the user has deleted this scope under the **current** revision, the tombstone wins.
     * Ignoring it would resurrect a deletion from an older record, which the sync envelope
     * explicitly forbids.
     */
    @Test
    fun `forward port respects tombstones and never resurrects a deleted scope`() {
        val store = store()
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, conversationID, old,
        )
        // The user cleared this scope under the new revision (writes a tombstone, no record).
        store.setConversation(null, providerID, model, conversationID, new)

        assertNull(
            "a deleted scope was resurrected by an old revision's value",
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
                .reasoningIntent,
        )
        assertTrue(
            store.exportPayload().records.none {
                it.transportIdentity == new && it.scope == "conversation_connection_model"
            },
        )
    }

    /** No forward-port when the target identity already has a record -- the user's choice under the new revision must not be overwritten by an old one. */
    @Test
    fun `an existing record on the current identity is never overwritten`() {
        val store = store()
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"), providerID, model, old,
        )
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Off, null), providerID, model, new,
        )

        assertNull(
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
                .reasoningIntent,
        )
    }

    /**
     * The candidate is "the user's last expressed choice." `runtimeRevision` is an opaque token
     * from the server (hashes, dates, and sequence numbers have all appeared), so comparing it
     * lexicographically would be guessing at its encoding -- this test deliberately makes
     * **the later write sort lower**, so a lexicographic-comparison implementation fails at once.
     */
    @Test
    fun `the candidate is the last expression, not the lexicographically larger revision`() {
        val store = store()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"),
            providerID, model, identity(revision = "runtime-r6"),
        )
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "low"),
            providerID, model, identity(revision = "runtime-r5"),
        )

        assertEquals(
            "runtime-r5 was written later, so it is the value the user last confirmed",
            "low",
            store.displayedForUi(
                providerID, ProviderKind.OpenAI, model, conversationID, null, identity(revision = "runtime-r9"),
            ).reasoningIntent,
        )
    }

    /** Idempotent -- a repeated read must not produce a second record or keep bumping revision. */
    @Test
    fun `repeated reads neither duplicate the record nor bump its revision`() {
        val store = store()
        val new = identity(revision = "runtime-r8")
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"),
            providerID, model, identity(revision = "runtime-r7"),
        )

        store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
        val first = store.exportPayload().records
        repeat(3) {
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
        }
        val repeated = store.exportPayload().records

        assertEquals("a repeated read forward-ported the record again", first.size, repeated.size)
        assertEquals(
            "a repeated read kept bumping revision",
            first.map { it.recordId to it.revision }.sortedBy { it.first },
            repeated.map { it.recordId to it.revision }.sortedBy { it.first },
        )
    }

    /**
     * The forward-port is written on the read path, and reads are called concurrently from
     * multiple places (the panel, the composer, the send task). Uses a real thread pool with
     * 16 threads -- `UnconfinedTestDispatcher` would mask the race entirely.
     */
    @Test
    fun `concurrent reads forward port exactly one record`() {
        val payload = AtomicReference<String?>(null)
        val store = store(payload)
        val old = identity(revision = "runtime-r7")
        val new = identity(revision = "runtime-r8")
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"), providerID, model, old,
        )

        val pool = Executors.newFixedThreadPool(16)
        val start = CountDownLatch(1)
        val done = CountDownLatch(16)
        repeat(16) {
            pool.execute {
                start.await()
                runCatching {
                    store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, new)
                }
                done.countDown()
            }
        }
        start.countDown()
        assertTrue("concurrent reads did not converge within 10 seconds", done.await(10, TimeUnit.SECONDS))
        pool.shutdown()

        val migrated = store.exportPayload().records.filter {
            it.transportIdentity == new && it.scope == "connection_model"
        }
        assertEquals("concurrent reads forward-ported more than one record", 1, migrated.size)
        assertEquals("max", migrated.single().reasoningIntent)
        assertEquals("force", migrated.single().web)
    }

    /** Write/read loop for promotion: the default written by `setConnectionModel` must read back through the very same ladder. */
    @Test
    fun `promoting to the model default is readable by every entry that shows it`() {
        val store = store()
        val transport = identity()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "deep"), providerID, model, transport,
        )

        // 1. This current conversation
        assertEquals(
            CapabilityWebPreference.Force,
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, transport).web,
        )
        // 2. Another conversation (this is what "new conversations for this model default to
        // these settings" actually means)
        assertEquals(
            "deep",
            store.displayedForUi(
                providerID, ProviderKind.OpenAI, model, "0b4e28ba-2fa1-11d2-883f-0016d3cca427", null, transport,
            ).reasoningIntent,
        )
        // 3. Outbound
        assertEquals(
            "deep",
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, model, conversationID, null, transport)
                .reasoningIntent,
        )
        // Another model is unaffected: storage is strictly isolated per connection x model x transport.
        assertNotEquals(
            "deep",
            store.displayedForUi(providerID, ProviderKind.OpenAI, "other-model", conversationID, null, transport)
                .reasoningIntent,
        )
    }

    /**
     * Promotion writes through the same versioned entry -- reconfirming must outrank its own
     * tombstone, otherwise export/merge keeps picking the deletion, and the user's default
     * disappears again after switching devices.
     */
    @Test
    fun `promoting again outranks its own tombstone`() {
        val store = store()
        val transport = identity()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"), providerID, model, transport,
        )
        store.setConnectionModel(null, providerID, model, transport)
        assertNull(
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, transport)
                .reasoningIntent,
        )

        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"), providerID, model, transport,
        )

        val record = store.exportPayload().records.single { it.scope == "connection_model" }
        assertEquals("max", record.reasoningIntent)
        assertTrue("reconfirming must increment above the tombstone", record.revision >= 3)
        assertTrue(
            "the tombstone with the same id must be cleared",
            store.exportPayload().tombstones.none { it.recordID == record.recordId },
        )
    }

    // ── Skill confirmation reads through the same forward-port chain ────────────

    /**
     * A revision bump must not make an already-confirmed skill look "unconfirmed."
     *
     * The old failure mode: the server moves `runtimeRevision` from r1 to r2, and when the
     * skill editor asks `hasSkillAgentConfirmation` the record is still pinned to r1, so it
     * shows "unconfirmed"; the user then opens a conversation (which runs the forward-port
     * through `scopeValues` and brings the record up to r2), and back on the editor it flips to
     * "confirmed." The same fact flips between two screens, and the only conclusion a user can
     * draw is "my confirmation got cleared, I need to click it again."
     *
     * A revision forward-port does not count as a fingerprint change: confirmation is bound to
     * connection x model x transport, and only an actual transport change counts as a new target.
     */
    @Test
    fun `a skill confirmation survives a recipe revision bump without opening a conversation`() {
        val store = store()
        val r1 = identity(revision = "runtime-r1")
        val r2 = identity(revision = "runtime-r2")
        store.confirmSkillAgent(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, skillID, r1,
        )

        assertTrue("the same revision obviously still counts as confirmed", store.hasSkillAgentConfirmation(providerID, model, skillID, r1))
        assertTrue(
            "must still count as confirmed after a revision bump -- not wait for a conversation to catch it up",
            store.hasSkillAgentConfirmation(providerID, model, skillID, r2),
        )
        assertEquals(
            "the value carries across the revision unchanged",
            "deep",
            store.exportPayload().records.single { it.scope == "skill_agent" && it.transportIdentity == r2 }
                .reasoningIntent,
        )
    }

    /** An actual transport change means a different request contract, so confirmation does not carry over (the test is still `isSameTransportLineage`). */
    @Test
    fun `a skill confirmation never crosses a transport change`() {
        val store = store()
        store.confirmSkillAgent(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, skillID, identity(transport = "openai_responses", revision = "runtime-r1"),
        )
        assertTrue(
            "must require reconfirmation after a transport change",
            !store.hasSkillAgentConfirmation(
                providerID, model, skillID, identity(transport = "anthropic_messages", revision = "runtime-r2"),
            ),
        )
    }

    /** A withdrawal is final: it must not be resurrected by a forward-port even after a revision bump. */
    @Test
    fun `withdrawing a skill confirmation is not undone by the forward port`() {
        val store = store()
        val r1 = identity(revision = "runtime-r1")
        store.confirmSkillAgent(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, model, skillID, r1,
        )
        store.invalidateSkillAgent(skillID)
        assertTrue(!store.hasSkillAgentConfirmation(providerID, model, skillID, r1))
        assertTrue(
            "must not be resurrected by a revision bump after being withdrawn",
            !store.hasSkillAgentConfirmation(providerID, model, skillID, identity(revision = "runtime-r2")),
        )
    }

    // ── A mutex that turns off web writes only the web field ─────────────────

    /**
     * When a mutex turns web off, only the web field may be written.
     *
     * The old approach took the whole `resolvedForRequest` result, applied `copy(web = Off)`,
     * and wrote it back into the conversation scope -- which also froze the inherited thinking
     * tier into that layer. If the user later changed the thinking tier in the connection
     * default, this conversation could no longer follow it, even though all they did was
     * trigger a single retrieval.
     */
    @Test
    fun `the library mutex writes web only and leaves an inherited thinking tier inheritable`() {
        val store = store()
        val transport = identity()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"), providerID, model, transport,
        )

        // The production approach: no record at this layer -> write only web, leaving
        // reasoningIntent null so it keeps reading up the ladder.
        val existing = store.scopeValues(providerID, model, conversationID, null, transport).conversation
        assertNull("precondition: the conversation layer starts with no record", existing)
        store.setConversation(
            existing?.copy(web = CapabilityWebPreference.Off)
                ?: CapabilityPreferenceValues(CapabilityWebPreference.Off, null),
            providerID, model, conversationID, transport,
        )

        assertEquals(
            "the conversation layer must not be left with a frozen thinking tier",
            null,
            store.scopeValues(providerID, model, conversationID, null, transport).conversation?.reasoningIntent,
        )
        val displayed = store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, transport)
        assertEquals(CapabilityWebPreference.Off, displayed.web)
        assertEquals("the thinking tier is still inherited from the connection x model layer", "deep", displayed.reasoningIntent)

        // The connection default changes tier, and this conversation must follow -- freezing it would break that.
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "max"), providerID, model, transport,
        )
        assertEquals(
            "max",
            store.displayedForUi(providerID, ProviderKind.OpenAI, model, conversationID, null, transport)
                .reasoningIntent,
        )
    }

    /** Merges instead when this layer already has an explicit record: whatever the user chose in this conversation must be preserved as-is. */
    @Test
    fun `the library mutex merges into an explicit conversation record instead of replacing it`() {
        val store = store()
        val transport = identity()
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "low"),
            providerID, model, conversationID, transport,
        )
        val existing = store.scopeValues(providerID, model, conversationID, null, transport).conversation
        store.setConversation(
            existing?.copy(web = CapabilityWebPreference.Off)
                ?: CapabilityPreferenceValues(CapabilityWebPreference.Off, null),
            providerID, model, conversationID, transport,
        )
        val after = store.scopeValues(providerID, model, conversationID, null, transport).conversation
        assertEquals(CapabilityWebPreference.Off, after?.web)
        assertEquals("an explicitly chosen thinking tier in the conversation must not be erased", "low", after?.reasoningIntent)
    }
}
