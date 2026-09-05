package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import java.util.UUID

/**
 * Typed request intent for web search and reasoning. This is deliberately independent from the frozen
 * generation-parameter payload: it contains only typed web/reasoning intent, never raw JSON.
 */
@Serializable
enum class CapabilityWebPreference { Off, Automatic, Force, Custom }

@Serializable
data class CapabilityPreferenceValues(
    val web: CapabilityWebPreference = CapabilityWebPreference.Off,
    /** null means inherit/provider default; `off` is an explicit request to omit reasoning. */
    val reasoningIntent: String? = null,
)

@Serializable
data class CapabilityPreferenceRecord(
    val scope: String,
    val providerID: String,
    @SerialName("canonicalModelId") val modelID: String? = null,
    val conversationID: String? = null,
    val skillID: String? = null,
    /** Includes the sanitized Relay endpoint identity; no model-id heuristic is permitted. */
    val transportIdentity: String,
    val values: CapabilityPreferenceValues,
    val revision: Int,
    val mutationID: String,
)

@Serializable
data class CapabilityPreferenceTombstone(
    @SerialName("recordId") val recordID: String,
    val revision: Int,
    @SerialName("mutationId") val mutationID: String,
)

/** Schema-v2 cloud record. Custom/raw fragments are intentionally absent. */
@Serializable
data class CapabilityPreferenceSyncRecord(
    val recordId: String,
    val scope: String,
    val providerId: String,
    val canonicalModelId: String,
    val conversationId: String? = null,
    val skillId: String? = null,
    val transportIdentity: String,
    val web: String,
    val reasoningIntent: String? = null,
    val revision: Int,
    val mutationId: String,
)

/** Independent cloud envelope for this schema. */
@Serializable
data class CapabilityPreferenceSyncPayload(
    val schemaVersion: Int = 2,
    val records: List<CapabilityPreferenceSyncRecord> = emptyList(),
    val tombstones: List<CapabilityPreferenceTombstone> = emptyList(),
)

@Serializable
private data class LocalCapabilityPreferencePayload(
    val records: List<CapabilityPreferenceRecord> = emptyList(),
    val tombstones: List<CapabilityPreferenceTombstone> = emptyList(),
)

/**
 * The layers of records this device actually persists. The read path and
 * the send path share this exact same query -- neither is allowed to keep
 * its own copy.
 *
 * A single scope record carries both web and reasoningIntent at once, but
 * each falls through the ladder independently: a record that only changed
 * the reasoning tier in a conversation must not also override the
 * connection-level web preference.
 */
data class CapabilityScopeValues(
    val conversation: CapabilityPreferenceValues? = null,
    val skill: CapabilityPreferenceValues? = null,
    val connectionModel: CapabilityPreferenceValues? = null,
    val connection: CapabilityPreferenceValues? = null,
) {
    /** The one and only ordering of the ladder: conversation -> skill -> connection x model -> connection. */
    fun ordered(): List<CapabilityPreferenceValues> =
        listOfNotNull(conversation, skill, connectionModel, connection)

    /**
     * The projection the UI reads: the same ladder, but without the terminal
     * collapse.
     *
     * The outbound `resolved` value feeds the request compiler, where
     * "never set", "chose automatic", and "chose off" are all equivalent to
     * "omit this field" and collapse to off. If the UI reused that result
     * directly, "never set" would render as "off" being selected --
     * effectively making a choice on the user's behalf that they never made,
     * visible the first time they open the panel after switching to any new
     * model. This only answers "which layer actually stored a value first".
     */
    fun displaySelection(): CapabilityPreferenceValues {
        val ordered = ordered()
        return CapabilityPreferenceValues(
            web = ordered.firstOrNull()?.web ?: CapabilityWebPreference.Off,
            reasoningIntent = ordered.firstNotNullOfOrNull { it.reasoningIntent },
        )
    }
}

/**
 * A stored capability preference is only trusted when the transport it was recorded against is
 * known. Without that, the same preference could be replayed against a different protocol, where
 * it means something else entirely, so the read fails closed.
 */
private fun capabilityPreferenceReadIsPermitted(
    providerKind: ProviderKind,
    transportIdentity: String?,
): Boolean = !transportIdentity.isNullOrBlank()

/**
 * The single source of truth shared by composer chip highlighting, the
 * model control panel's restore state, and what actually goes out on the
 * wire.
 *
 * - `transportIdentity` being empty fails closed: without a final
 *   transport, no preference is trusted at all.
 * - `skillID` must be the real `conversation.skillId`. The outbound request
 *   always carries it, but the UI once hardcoded null, which made the
 *   skill_agent scope's web/reasoning preference completely invisible in
 *   the UI -- the panel showed "off" while the request still went out with
 *   it on.
 * - A draft conversation (no real conversation id yet) reads its
 *   conversation-layer value from the draft records, which never enter
 *   sync; the connection x model and connection layers beneath it still
 *   participate, otherwise "set as this model's default" wouldn't be
 *   readable back in a brand-new conversation.
 */
fun CapabilityPreferenceStore.resolvedForRequest(
    providerID: String,
    providerKind: ProviderKind,
    modelID: String,
    conversationID: String,
    skillID: String?,
    transportIdentity: String?,
    isExistingConversation: Boolean = true,
): CapabilityPreferenceValues {
    if (!capabilityPreferenceReadIsPermitted(providerKind, transportIdentity)) return CapabilityPreferenceValues()
    return resolved(
        providerID, modelID, conversationID, skillID, requireNotNull(transportIdentity),
        isDraftConversation = !isExistingConversation,
    )
}

/**
 * The UI's read entry point: the exact same ladder and the exact same
 * records as [resolvedForRequest], differing only in the terminal collapse
 * (see [CapabilityScopeValues.displaySelection]).
 *
 * The panel and the chip restore state are only ever allowed to ask this
 * one function. Querying the conversation layer on its own would mean that
 * once "set as this model's default" writes to connection_model, no UI
 * surface could read it back.
 */
fun CapabilityPreferenceStore.displayedForUi(
    providerID: String,
    providerKind: ProviderKind,
    modelID: String,
    conversationID: String,
    skillID: String?,
    transportIdentity: String?,
    isExistingConversation: Boolean = true,
): CapabilityPreferenceValues {
    if (!capabilityPreferenceReadIsPermitted(providerKind, transportIdentity)) return CapabilityPreferenceValues()
    return displaySelection(
        providerID, modelID, conversationID, skillID, requireNotNull(transportIdentity),
        isDraftConversation = !isExistingConversation,
    )
}

class CapabilityPreferenceStore internal constructor(
    private val read: () -> String?,
    private val write: (String) -> Unit,
    private val readDrafts: () -> String? = { null },
    private val writeDrafts: (String?) -> Unit = {},
    private val json: Json = Json { ignoreUnknownKeys = true; coerceInputValues = true },
) {
    /**
     * The layers of records this device actually persists. The read path
     * ([displaySelection]) and the send path ([resolved]) share this exact
     * same query.
     *
     * The lazy forward-port lives here: every read path passes through it,
     * so "the server shipped a new recipe version and the user's preference
     * silently reset to nothing" only needs one fix, structurally.
     */
    fun scopeValues(
        providerID: String,
        modelID: String,
        conversationID: String?,
        skillID: String?,
        transportIdentity: String,
        isDraftConversation: Boolean = false,
    ): CapabilityScopeValues {
        require(transportIdentity.isNotBlank()) { "final transport identity is required" }
        forwardPortIfNeeded(
            providerID, modelID, conversationID, skillID, transportIdentity, isDraftConversation,
        )
        val records = records()
        val conversation = when {
            conversationID == null -> null
            // A draft conversation only has a local draft record (it never syncs to the cloud), but it's still the conversation layer.
            isDraftConversation -> draftRecords().lastOrNull {
                it.providerID.equals(providerID, true) && it.modelID == modelID &&
                    it.conversationID == conversationID && it.transportIdentity == transportIdentity
            }?.values
            else -> records.lastOrNull {
                it.scope == "conversation_connection_model" && it.providerID.equals(providerID, true) &&
                    it.modelID == modelID && it.conversationID == conversationID &&
                    it.transportIdentity == transportIdentity
            }?.values
        }
        val skill = if (skillID == null) null else records.lastOrNull {
            it.scope == "skill_agent" && it.providerID.equals(providerID, true) && it.modelID == modelID &&
                it.skillID == skillID && it.transportIdentity == transportIdentity
        }?.values
        val model = records.lastOrNull {
            it.scope == "connection_model" && it.providerID.equals(providerID, true) && it.modelID == modelID &&
                it.transportIdentity == transportIdentity
        }?.values
        val connection = records.lastOrNull {
            it.scope == "connection" && it.providerID.equals(providerID, true) && it.modelID == modelID &&
                it.transportIdentity == transportIdentity
        }?.values
        return CapabilityScopeValues(conversation, skill, model, connection)
    }

    /** UI read: the same ladder, the same records, just without the terminal collapse. */
    fun displaySelection(
        providerID: String,
        modelID: String,
        conversationID: String?,
        skillID: String?,
        transportIdentity: String,
        isDraftConversation: Boolean = false,
    ): CapabilityPreferenceValues = scopeValues(
        providerID, modelID, conversationID, skillID, transportIdentity, isDraftConversation,
    ).displaySelection()

    fun resolved(
        providerID: String,
        modelID: String,
        conversationID: String?,
        skillID: String?,
        transportIdentity: String,
        singleSend: CapabilityPreferenceValues? = null,
        isDraftConversation: Boolean = false,
    ): CapabilityPreferenceValues {
        val scopes = scopeValues(
            providerID, modelID, conversationID, skillID, transportIdentity, isDraftConversation,
        )
        val conversation = scopes.conversation
        val skill = scopes.skill
        val model = scopes.connectionModel
        val connection = scopes.connection
        fun webOverride(values: CapabilityPreferenceValues?) = when (values?.web) {
            null -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.INHERIT)
            CapabilityWebPreference.Off -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.OMIT)
            else -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.VALUE, kotlinx.serialization.json.JsonPrimitive(values.web.name.lowercase()))
        }
        fun reasoningOverride(values: CapabilityPreferenceValues?) = when (val value = values?.reasoningIntent) {
            null -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.INHERIT)
            "off" -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.OMIT)
            else -> RequestPreferenceResolver.Override(RequestPreferenceResolver.OverrideState.VALUE, kotlinx.serialization.json.JsonPrimitive(value))
        }
        val scoped = listOf(
            "single_send" to singleSend, "conversation_connection_model" to conversation, "skill_agent" to skill,
            "connection_model" to model, "connection" to connection,
            "provider_recipe" to null, "provider_default" to null,
        )
        val web = RequestPreferenceResolver.resolveLayers(scoped.map { RequestPreferenceResolver.ScopeLayer(it.first, webOverride(it.second)) })
        val reasoning = RequestPreferenceResolver.resolveLayers(scoped.map { RequestPreferenceResolver.ScopeLayer(it.first, reasoningOverride(it.second)) })
        val webValue = (web.value as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            ?.let { raw -> CapabilityWebPreference.entries.firstOrNull { it.name.equals(raw, true) } }
            ?: CapabilityWebPreference.Off
        // `off` is the user explicitly asking to turn reasoning off (the request goes out
        // carrying the provider's own disable mechanism); the all-inherit fallback also lands
        // on TerminalState.OMIT, but it means "no explicit preference at all". The two must
        // never collapse into the same value -- doing so would make the composer's "provider
        // default" option permanently unselectable, and the model control chip would stay lit
        // on every existing conversation. Only `reason` tells them apart.
        val reasoningValue = (reasoning.value as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
            ?: "off".takeIf {
                reasoning.state == RequestPreferenceResolver.TerminalState.OMIT &&
                    reasoning.reason != "no_explicit_or_recipe_value"
            }
        return CapabilityPreferenceValues(webValue, reasoningValue)
    }

    // ── Lazy forward-port across recipe versions ─────────────────────────────

    /**
     * Whether two identities are different recipe versions of the same
     * transport lineage.
     *
     * `storageIdentity` encodes both `finalTransport` and `runtimeRevision`;
     * every time the server ships a new recipe, the revision changes, and
     * every record keyed by identity instantly goes dormant -- a
     * web/reasoning preference the user set last week suddenly renders as
     * never set. This only recognizes one relationship: the transport is
     * identical and only the revision changed.
     *
     * A real protocol change (`openai_chat` -> `openai_responses` and
     * similar) is never migrated: that's a genuinely different request
     * contract with new field names, tier options, and schema, so carrying
     * the old value forward would just be guessing on the user's behalf. It
     * resets instead.
     */
    private fun isSameTransportLineage(current: String, candidate: String): Boolean {
        if (current == candidate) return false
        val currentIdentity = ModelControlRuntimeIdentity.decodeStorageIdentity(current) ?: return false
        val candidateIdentity = ModelControlRuntimeIdentity.decodeStorageIdentity(candidate) ?: return false
        return currentIdentity.first == candidateIdentity.first &&
            currentIdentity.second != candidateIdentity.second
    }

    /** Each scope forward-ports independently. Scopes never substitute for each other: an old conversation-layer value can only backfill the conversation layer. */
    private fun forwardPortIfNeeded(
        providerID: String,
        modelID: String,
        conversationID: String?,
        skillID: String?,
        transportIdentity: String,
        isDraftConversation: Boolean,
    ) {
        if (modelID.isBlank()) return
        if (ModelControlRuntimeIdentity.decodeStorageIdentity(transportIdentity) == null) return
        if (conversationID != null && isDraftConversation) {
            forwardPortDraftScope(providerID, modelID, conversationID, transportIdentity)
        }
        // Most reads land in the "this device has no old-version records at all" bucket (fresh
        // install, just configured, recipe hasn't changed). Ruling that out up front saves every
        // scope from re-decoding the payload on its own.
        if (records().none { isSameTransportLineage(transportIdentity, it.transportIdentity) }) return
        if (conversationID != null && !isDraftConversation) {
            forwardPortScope(
                "conversation_connection_model", providerID, modelID, conversationID, null, transportIdentity,
            )
        }
        if (skillID != null) {
            forwardPortScope("skill_agent", providerID, modelID, null, skillID, transportIdentity)
        }
        forwardPortScope("connection_model", providerID, modelID, null, null, transportIdentity)
        forwardPortScope("connection", providerID, modelID, null, null, transportIdentity)
    }

    /**
     * Forward-ports a single scope.
     *
     * The write must go through the existing versioned entry point
     * [replace]: it increments by `max(record revision, tombstone
     * revision) + 1` and clears any tombstone with the same id -- exactly
     * the "a deletion can't be resurrected by an old record" protection the
     * sync envelope v2 relies on. Writing the key directly would bypass
     * that whole protection. The old record is left in place:
     * forward-porting is idempotent (it never fires again once the target
     * has a record), and keeping the old value around lets things pick
     * back up unchanged if the server ever rolls back to the old recipe
     * version; the record-count cap eventually cleans it up.
     */
    private fun forwardPortScope(
        scope: String,
        providerID: String,
        modelID: String,
        conversationID: String?,
        skillID: String?,
        transportIdentity: String,
    ) = synchronized(this) {
        val local = localPayload()
        val matches = { record: CapabilityPreferenceRecord ->
            record.scope == scope && record.providerID.equals(providerID, true) && record.modelID == modelID &&
                record.conversationID == conversationID && record.skillID == skillID
        }
        if (local.records.any { matches(it) && it.transportIdentity == transportIdentity }) return@synchronized
        // "The last thing the user expressed" is taken by write order: the record list is
        // delete-then-append by `replace`, so position is write order. `runtimeRevision` is an
        // opaque server token (hashes, dates, and sequence numbers have all shown up), so
        // comparing it as a string would be guessing its encoding; since every candidate here is
        // already a stale version, whichever was written last wins.
        val candidate = local.records.lastOrNull {
            matches(it) && isSameTransportLineage(transportIdentity, it.transportIdentity)
        } ?: return@synchronized
        // The user deleted this scope under the current version: the tombstone rules, and forward-porting must not resurrect it.
        val targetID = recordID(
            CapabilityPreferenceRecord(
                scope, providerID, modelID, conversationID, skillID, transportIdentity,
                CapabilityPreferenceValues(), 0, "",
            ),
        )
        if ((local.tombstones.firstOrNull { it.recordID == targetID }?.revision ?: 0) != 0) return@synchronized
        // Narrowed tiers (a new recipe dropping a tier) aren't handled here: `ModelControlWebLayout.clamp`,
        // the reasoning tier's stale-intent fallback, and the outbound compile gate each handle their own
        // case; forward-porting only carries the user's expressed choice across the version line.
        replace(scope, candidate.values, providerID, modelID, conversationID, skillID, transportIdentity)
    }

    /**
     * The draft layer must cross the version line too: a user who just
     * picked a web search preference in a draft would otherwise see it
     * reset the moment metadata refreshes, without having changed anything
     * themselves. Drafts have no sync envelope and therefore no concept of
     * a tombstone; the write still goes through the draft layer's own
     * existing entry point.
     */
    private fun forwardPortDraftScope(
        providerID: String,
        modelID: String,
        draftSessionID: String,
        transportIdentity: String,
    ) = synchronized(this) {
        val drafts = draftRecords()
        val matches = { record: CapabilityPreferenceRecord ->
            record.providerID.equals(providerID, true) && record.modelID == modelID &&
                record.conversationID == draftSessionID
        }
        if (drafts.any { matches(it) && it.transportIdentity == transportIdentity }) return@synchronized
        val candidate = drafts.lastOrNull {
            matches(it) && isSameTransportLineage(transportIdentity, it.transportIdentity)
        } ?: return@synchronized
        setDraftConversation(candidate.values, providerID, modelID, draftSessionID, transportIdentity)
    }

    fun setConversation(
        values: CapabilityPreferenceValues?, providerID: String, modelID: String, conversationID: String,
        transportIdentity: String,
    ) = replace("conversation_connection_model", values, providerID, modelID, conversationID, null, transportIdentity)

    /** A composer draft has a UUID but is not a conversation scope and must never enter sync. */
    fun setDraftConversation(
        values: CapabilityPreferenceValues?, providerID: String, modelID: String, draftSessionID: String,
        transportIdentity: String,
    ) = synchronized(this) {
        val current = draftRecords().toMutableList()
        current.removeAll {
            it.providerID.equals(providerID, true) && it.modelID == modelID && it.conversationID == draftSessionID &&
                it.transportIdentity == transportIdentity
        }
        values?.let { current += CapabilityPreferenceRecord("conversation_connection_model", providerID, modelID, draftSessionID, null, transportIdentity, it, 0, "local_draft") }
        writeDrafts(json.encodeToString(current.takeLast(50)))
    }

    fun draftConversation(
        providerID: String, modelID: String, draftSessionID: String, transportIdentity: String,
    ): CapabilityPreferenceValues? = synchronized(this) {
        draftRecords().lastOrNull {
            it.providerID.equals(providerID, true) && it.modelID == modelID && it.conversationID == draftSessionID &&
                it.transportIdentity == transportIdentity
        }?.values
    }

    fun migrateDraftConversation(
        providerID: String, modelID: String, draftSessionID: String, conversationID: String, transportIdentity: String,
    ) = synchronized(this) {
        val source = draftConversation(providerID, modelID, draftSessionID, transportIdentity) ?: return@synchronized
        setConversation(source, providerID, modelID, conversationID, transportIdentity)
        setDraftConversation(null, providerID, modelID, draftSessionID, transportIdentity)
    }

    fun setConnectionModel(values: CapabilityPreferenceValues?, providerID: String, modelID: String, transportIdentity: String) =
        replace("connection_model", values, providerID, modelID, null, null, transportIdentity)

    fun setConnection(
        values: CapabilityPreferenceValues?,
        providerID: String,
        modelID: String,
        transportIdentity: String,
    ) = replace("connection", values, providerID, modelID, null, null, transportIdentity)

    fun confirmSkillAgent(values: CapabilityPreferenceValues?, providerID: String, modelID: String, skillID: String, transportIdentity: String) =
        replace("skill_agent", values, providerID, modelID, null, skillID, transportIdentity)

    /**
     * A Skill confirmation is tied to an exact provider instance, model, and final transport
     * fingerprint.  When that target changes (or the user withdraws the confirmation), every
     * prior Skill record must become a tombstone instead of silently surviving as a dormant
     * preference.  Keeping this operation scoped to the skill id also covers a deleted provider:
     * callers do not need to reconstruct the old fingerprint just to revoke consent.
     */
    fun invalidateSkillAgent(skillID: String) = synchronized(this) {
        val local = localPayload()
        val removed = local.records.filter { it.scope == "skill_agent" && it.skillID.equals(skillID, ignoreCase = true) }
        if (removed.isEmpty()) return@synchronized
        val tombstones = local.tombstones.toMutableList()
        removed.forEach { record ->
            val recordID = recordID(record)
            tombstones.removeAll { it.recordID == recordID }
            tombstones += CapabilityPreferenceTombstone(recordID, record.revision + 1, UUID.randomUUID().toString())
        }
        write(LocalCapabilityPreferencePayload(local.records - removed.toSet(), tombstones.takeLast(300)))
    }

    /**
     * True only for an explicit confirmation on this exact request target,
     * never an inherited value.
     *
     * This read also goes through the forward-port chain: a recipe version
     * change is only the same protocol picking up a new `runtimeRevision`,
     * not the confirmed request target actually changing -- a revision
     * forward-port does not count as a fingerprint change (only a real
     * protocol change does, still judged by `isSameTransportLineage`).
     * Without this, a Skill's edit page would show "not confirmed" right
     * after a recipe version bump, and then flip back to "confirmed" the
     * moment the user opens a conversation (which runs the forward-port
     * through `scopeValues`) and comes back -- the same fact flipping
     * between two screens, leaving the user with only one conclusion: "the
     * confirmation got lost, I need to tap it again." A withdrawal still
     * has the final say: `invalidateSkillAgent` tombstones every old
     * record, and [forwardPortScope] never resurrects anything once it
     * sees a tombstone.
     */
    fun hasSkillAgentConfirmation(
        providerID: String,
        modelID: String,
        skillID: String,
        transportIdentity: String,
    ): Boolean {
        if (modelID.isNotBlank() && ModelControlRuntimeIdentity.decodeStorageIdentity(transportIdentity) != null) {
            forwardPortScope("skill_agent", providerID, modelID, null, skillID, transportIdentity)
        }
        return hasStoredSkillAgentConfirmation(providerID, modelID, skillID, transportIdentity)
    }

    private fun hasStoredSkillAgentConfirmation(
        providerID: String,
        modelID: String,
        skillID: String,
        transportIdentity: String,
    ): Boolean = synchronized(this) {
        records().any {
            it.scope == "skill_agent" && it.providerID.equals(providerID, true) && it.modelID == modelID &&
                it.skillID.equals(skillID, ignoreCase = true) && it.transportIdentity == transportIdentity
        }
    }

    private fun replace(
        scope: String, values: CapabilityPreferenceValues?, providerID: String, modelID: String?, conversationID: String?,
        skillID: String?, transportIdentity: String,
    ) = synchronized(this) {
        val current = records().toMutableList()
        val matches = current.filter { it.scope == scope && it.providerID.equals(providerID, true) && it.modelID == modelID &&
            it.conversationID == conversationID && it.skillID == skillID && it.transportIdentity == transportIdentity }
        current.removeAll(matches.toSet())
        val idPrototype = CapabilityPreferenceRecord(scope, providerID, modelID, conversationID, skillID, transportIdentity, values ?: CapabilityPreferenceValues(), 0, "")
        val id = recordID(idPrototype)
        val local = localPayload()
        val revision = maxOf(matches.maxOfOrNull { it.revision } ?: 0, local.tombstones.firstOrNull { it.recordID == id }?.revision ?: 0) + 1
        val mutation = UUID.randomUUID().toString()
        val nextTombstones = local.tombstones.filterNot { it.recordID == id }.toMutableList()
        if (values != null) current += CapabilityPreferenceRecord(scope, providerID, modelID, conversationID, skillID, transportIdentity, values, revision, mutation)
        else nextTombstones += CapabilityPreferenceTombstone(id, revision, mutation)
        write(LocalCapabilityPreferencePayload(current.takeLast(200), nextTombstones.takeLast(300)))
    }

    fun removeScopes(providerID: String? = null, modelID: String? = null, conversationID: String? = null) = synchronized(this) {
        val local = localPayload()
        val removed = local.records.filter { (providerID == null || it.providerID.equals(providerID, true)) &&
            (modelID == null || it.modelID == modelID) && (conversationID == null || it.conversationID == conversationID) }
        val tombstones = local.tombstones.toMutableList()
        removed.forEach { record -> tombstones.removeAll { it.recordID == recordID(record) }; tombstones += CapabilityPreferenceTombstone(recordID(record), record.revision + 1, UUID.randomUUID().toString()) }
        write(LocalCapabilityPreferencePayload(local.records - removed.toSet(), tombstones.takeLast(300)))
        // Drafts are local-only and never sync, so they have no tombstone ledger. They still
        // belong to the deleted connection lifecycle and must not reactivate if the same local
        // draft session survives navigation or the connection id is restored later.
        val drafts = draftRecords()
        val retainedDrafts = drafts.filterNot {
            (providerID == null || it.providerID.equals(providerID, true)) &&
                (modelID == null || it.modelID == modelID) &&
                (conversationID == null || it.conversationID == conversationID)
        }
        if (retainedDrafts.size != drafts.size) {
            writeDrafts(json.encodeToString(retainedDrafts).takeIf { retainedDrafts.isNotEmpty() })
        }
    }

    /**
     * Resets local scope boundaries: records, tombstones, and local drafts
     * are cleared together.
     *
     * Tombstones are deliberately not recreated here: a tombstone means
     * "this boundary explicitly deleted this setting", and letting it carry
     * across the reset would misapply an old boundary's deletion history to
     * a fresh one.
     *
     * Records and tombstones must be cleared in the same step: clearing
     * only the records would let the next boundary's first write inherit
     * the outgoing boundary's revision baseline, inflating version numbers
     * and corrupting cross-device last-write-wins comparisons.
     */
    fun clearForAccountBoundary() = synchronized(this) {
        write(LocalCapabilityPreferencePayload())
        writeDrafts(null)
    }

    fun migrateConversation(providerID: String, modelID: String, fromConversationID: String, toConversationID: String, transportIdentity: String) = synchronized(this) {
        if (fromConversationID == toConversationID) return@synchronized
        val source = records().lastOrNull { it.scope == "conversation_connection_model" && it.providerID.equals(providerID, true) && it.modelID == modelID && it.conversationID == fromConversationID && it.transportIdentity == transportIdentity } ?: return@synchronized
        replace("conversation_connection_model", source.values, providerID, modelID, toConversationID, null, transportIdentity)
        removeScopes(providerID = providerID, modelID = modelID, conversationID = fromConversationID)
    }

    fun exportPayload(): CapabilityPreferenceSyncPayload = localPayload().let { local ->
        CapabilityPreferenceSyncPayload(
            records = local.records.mapNotNull { record ->
                if (record.modelID.isNullOrBlank() || ModelControlRuntimeIdentity.decodeStorageIdentity(record.transportIdentity) == null) {
                    return@mapNotNull null
                }
                toSyncRecord(record).takeIf { it.web in setOf("off", "automatic", "force") && it.reasoningIntent in setOf(null, "off", "low", "balanced", "deep", "max") }
            }.sortedBy { it.recordId }.take(200),
            tombstones = local.tombstones.filter(::validSyncTombstone).sortedBy { it.recordID }.takeLast(300),
        )
    }

    fun merge(payload: CapabilityPreferenceSyncPayload): CapabilityPreferenceSyncPayload = synchronized(this) {
        require(payload.schemaVersion == 2) { "Unsupported capability preference schema" }
        val localBeforeMerge = localPayload()
        // Schema-v1/raw transport identities are deliberately dormant, not deleted. Keep their
        // local bytes across a v2 sync so only explicit reconfirmation can create a current record.
        val dormantRecords = localBeforeMerge.records.filter { record ->
            record.modelID.isNullOrBlank() || ModelControlRuntimeIdentity.decodeStorageIdentity(record.transportIdentity) == null
        }
        val dormantTombstones = localBeforeMerge.tombstones.filterNot(::validSyncTombstone)
        val candidates = linkedMapOf<String, Pair<CapabilityPreferenceSyncRecord?, CapabilityPreferenceTombstone?>>()
        fun putRecord(record: CapabilityPreferenceSyncRecord) {
            if (!validSyncRecord(record)) return
            val current = candidates[record.recordId]
            val currentRevision = current?.first?.revision ?: current?.second?.revision ?: 0
            val currentMutation = current?.first?.mutationId ?: current?.second?.mutationID.orEmpty()
            if (record.revision > currentRevision || (record.revision == currentRevision && record.mutationId > currentMutation)) {
                candidates[record.recordId] = record to null
            }
        }
        fun putTombstone(tombstone: CapabilityPreferenceTombstone) {
            if (!validSyncTombstone(tombstone)) return
            val current = candidates[tombstone.recordID]
            val currentRevision = current?.first?.revision ?: current?.second?.revision ?: 0
            val currentMutation = current?.first?.mutationId ?: current?.second?.mutationID.orEmpty()
            if (tombstone.revision > currentRevision || (tombstone.revision == currentRevision && tombstone.mutationID > currentMutation)) candidates[tombstone.recordID] = null to tombstone
        }
        listOf(exportPayload(), payload).forEach { source -> source.records.forEach(::putRecord); source.tombstones.forEach(::putTombstone) }
        val merged = CapabilityPreferenceSyncPayload(records = candidates.values.mapNotNull { it.first }.sortedBy { it.recordId }.take(200), tombstones = candidates.values.mapNotNull { it.second }.sortedBy { it.recordID }.takeLast(300))
        write(
            LocalCapabilityPreferencePayload(
                records = (dormantRecords + merged.records.map(::fromSyncRecord)).takeLast(200),
                tombstones = (dormantTombstones + merged.tombstones).takeLast(300),
            ),
        )
        merged
    }

    private fun localPayload(): LocalCapabilityPreferencePayload = read()?.let { raw ->
        runCatching { json.decodeFromString<LocalCapabilityPreferencePayload>(raw) }.getOrElse {
            runCatching { LocalCapabilityPreferencePayload(records = json.decodeFromString<List<CapabilityPreferenceRecord>>(raw)) }.getOrDefault(LocalCapabilityPreferencePayload())
        }
    } ?: LocalCapabilityPreferencePayload()
    private fun records(): List<CapabilityPreferenceRecord> = localPayload().records
    private fun draftRecords(): List<CapabilityPreferenceRecord> = readDrafts()?.let { raw ->
        runCatching { json.decodeFromString<List<CapabilityPreferenceRecord>>(raw) }.getOrDefault(emptyList())
    } ?: emptyList()
    private fun write(payload: LocalCapabilityPreferencePayload) = write(json.encodeToString(payload))

    private fun toSyncRecord(record: CapabilityPreferenceRecord): CapabilityPreferenceSyncRecord = CapabilityPreferenceSyncRecord(
        recordId = recordID(record), scope = record.scope, providerId = record.providerID.lowercase(),
        canonicalModelId = requireNotNull(record.modelID), conversationId = record.conversationID?.lowercase(), skillId = record.skillID?.lowercase(),
        transportIdentity = record.transportIdentity, web = record.values.web.name.lowercase(), reasoningIntent = record.values.reasoningIntent,
        revision = record.revision, mutationId = record.mutationID,
    )

    private fun fromSyncRecord(record: CapabilityPreferenceSyncRecord): CapabilityPreferenceRecord = CapabilityPreferenceRecord(
        scope = record.scope, providerID = record.providerId, modelID = record.canonicalModelId, conversationID = record.conversationId,
        skillID = record.skillId, transportIdentity = record.transportIdentity,
        values = CapabilityPreferenceValues(CapabilityWebPreference.entries.first { it.name.equals(record.web, true) }, record.reasoningIntent),
        revision = record.revision, mutationID = record.mutationId,
    )

    private fun validSyncRecord(record: CapabilityPreferenceSyncRecord): Boolean {
        if (
            record.revision < 1 || record.mutationId.isBlank() || record.canonicalModelId.isBlank() ||
            ModelControlRuntimeIdentity.decodeStorageIdentity(record.transportIdentity) == null ||
            record.web !in setOf("off", "automatic", "force") ||
            record.reasoningIntent !in setOf(null, "off", "low", "balanced", "deep", "max")
        ) return false
        fun canonicalUuid(value: String?): Boolean = value != null && runCatching { UUID.fromString(value) }.isSuccess && value == value.lowercase()
        if (!canonicalUuid(record.providerId)) return false
        val expected = when (record.scope) {
            "connection" -> "scope:connection:${record.providerId.lowercase()}:${record.canonicalModelId}:${record.transportIdentity}"
            "connection_model" -> "scope:model:${record.providerId.lowercase()}:${record.canonicalModelId}:${record.transportIdentity}"
            "conversation_connection_model" -> "scope:conversation:${record.providerId.lowercase()}:${record.canonicalModelId}:${record.transportIdentity}:${record.conversationId?.lowercase()}"
            "skill_agent" -> "scope:skill:${record.providerId.lowercase()}:${record.canonicalModelId}:${record.transportIdentity}:${record.skillId?.lowercase()}"
            else -> return false
        }
        return record.recordId == expected && record.providerId.isNotBlank() && when (record.scope) {
            "connection" -> record.conversationId == null && record.skillId == null
            "connection_model" -> record.conversationId == null && record.skillId == null
            "conversation_connection_model" -> canonicalUuid(record.conversationId) && record.skillId == null
            else -> canonicalUuid(record.skillId) && record.conversationId == null
        }
    }

    /**
     * Tombstones lack the record's separate scope fields, so their record id must itself be a
     * canonical scope key before it can participate in LWW. Model and transport segments may
     * contain ':' (for example `llama3:latest` and an endpoint fingerprint); only the fixed
     * prefix and trailing UUID portions are structural.
     */
    private fun validSyncTombstone(tombstone: CapabilityPreferenceTombstone): Boolean {
        if (tombstone.revision < 1 || tombstone.mutationID.isBlank()) return false
        fun canonicalUuid(value: String): Boolean = runCatching { UUID.fromString(value) }.isSuccess && value == value.lowercase()
        fun withProvider(prefix: String): Pair<String, String>? {
            if (!tombstone.recordID.startsWith(prefix)) return null
            val tail = tombstone.recordID.removePrefix(prefix)
            val separator = tail.indexOf(':')
            if (separator <= 0 || separator == tail.lastIndex) return null
            val providerId = tail.substring(0, separator)
            return providerId to tail.substring(separator + 1)
        }
        return when {
            tombstone.recordID.startsWith("scope:connection:") -> {
                val parsed = withProvider("scope:connection:") ?: return false
                canonicalUuid(parsed.first) && validModelAndRuntimeIdentity(parsed.second)
            }
            tombstone.recordID.startsWith("scope:model:") -> {
                val parsed = withProvider("scope:model:") ?: return false
                canonicalUuid(parsed.first) && validModelAndRuntimeIdentity(parsed.second)
            }
            tombstone.recordID.startsWith("scope:conversation:") -> validScopedTombstone(tombstone.recordID, "scope:conversation:") { canonicalUuid(it) }
            tombstone.recordID.startsWith("scope:skill:") -> validScopedTombstone(tombstone.recordID, "scope:skill:") { canonicalUuid(it) }
            else -> false
        }
    }

    private fun validScopedTombstone(recordID: String, prefix: String, canonicalUuid: (String) -> Boolean): Boolean {
        val tail = recordID.removePrefix(prefix)
        val providerEnd = tail.indexOf(':')
        if (providerEnd <= 0 || providerEnd == tail.lastIndex) return false
        val providerId = tail.substring(0, providerEnd)
        val remainder = tail.substring(providerEnd + 1)
        val lastSeparator = remainder.lastIndexOf(':')
        if (lastSeparator <= 0 || lastSeparator == remainder.lastIndex) return false
        val modelAndTransport = remainder.substring(0, lastSeparator)
        val scopedUuid = remainder.substring(lastSeparator + 1)
        return canonicalUuid(providerId) && canonicalUuid(scopedUuid) &&
            validModelAndRuntimeIdentity(modelAndTransport)
    }

    private fun validModelAndRuntimeIdentity(value: String): Boolean {
        val marker = value.lastIndexOf(":r1.")
        if (marker <= 0 || marker >= value.lastIndex) return false
        return ModelControlRuntimeIdentity.decodeStorageIdentity(value.substring(marker + 1)) != null
    }


    companion object {
        private const val PREFS = "capability_preference_settings"
        private const val KEY = "v1"
        fun from(context: Context): CapabilityPreferenceStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val drafts = context.applicationContext.getSharedPreferences("capability_preference_drafts", Context.MODE_PRIVATE)
            return CapabilityPreferenceStore(
                { prefs.getString(KEY, null) }, { prefs.edit().putString(KEY, it).apply() },
                { drafts.getString(KEY, null) }, { payload -> drafts.edit().putString(KEY, payload).apply() },
            )
        }
        fun recordID(record: CapabilityPreferenceRecord): String = when (record.scope) {
            "connection" -> "scope:connection:${record.providerID.lowercase()}:${record.modelID}:${record.transportIdentity}"
            "connection_model" -> "scope:model:${record.providerID.lowercase()}:${record.modelID}:${record.transportIdentity}"
            "conversation_connection_model" -> "scope:conversation:${record.providerID.lowercase()}:${record.modelID}:${record.transportIdentity}:${record.conversationID?.lowercase()}"
            "skill_agent" -> "scope:skill:${record.providerID.lowercase()}:${record.modelID}:${record.transportIdentity}:${record.skillID?.lowercase()}"
            else -> error("unknown capability preference scope ${record.scope}")
        }
    }
}
