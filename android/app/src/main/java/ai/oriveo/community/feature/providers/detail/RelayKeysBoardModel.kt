package ai.oriveo.community.feature.providers.detail

import androidx.annotation.StringRes
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.requiresCredential
import ai.oriveo.community.core.provider.relay.RelayKeyBinding

/**
 * An item in the action panel shown when tapping a key; ordering uses move up / move down rather than dragging.
 * [ViewModels] = opens the model library filtered by key(id); listed first when that key's catalog is non-empty.
 */
enum class RelayKeyAction { ViewModels, Rename, Replace, MoveUp, MoveDown, Delete }

/** Marker before the status word: Active = dot, others = warning; fetching = spinner; never-checked and unrecognized states draw no marker (null). */
enum class RelayKeyStatusMark { Dot, Warning, Progress }

/** "Last: <code> <status word> · <time>"; when [checkedAt] is null the time slot shows "—". */
data class RelayKeyLastStatus(val httpStatus: Int, @StringRes val statusRes: Int, val checkedAt: Long?)

data class RelayKeysBoardRow(
    val id: String,
    /** Name; masked when there is no name. */
    val title: String,
    val maskedSecret: String,
    val isPrimary: Boolean,
    /** The "Primary" badge appears only on the first key when there are 2+ keys. */
    val showsPrimaryBadge: Boolean,
    /** Status word; null (not drawn) when never checked (or unrecognized status). */
    @StringRes val statusRes: Int?,
    val statusMark: RelayKeyStatusMark?,
    /** Number of catalog entries it lists; null when none (shows "Catalog: —"). */
    val catalogCount: Int?,
    val enabledCount: Int,
    val lastStatus: RelayKeyLastStatus?,
    val actions: List<RelayKeyAction>,
    /** Primary key when there are several: the panel offers no delete, but a hint to move another key to first place first. */
    val showsPrimaryNotDeletable: Boolean,
) {
    /** Mask prefix of the catalog row; an unnamed key's title is already the mask, so it is not repeated. */
    val catalogMask: String? get() = maskedSecret.takeIf { it.isNotEmpty() && it != title }

    /** Explanatory sentence at the bottom of the action panel; only the primary key of a multi-key setup has it. */
    @get:StringRes
    val panelNoteRes: Int? get() = if (showsPrimaryNotDeletable) R.string.relay_key_primary_not_deletable else null
}

/** One row in the key card: each key, then "Add key" last (when the connection needs credentials). */
sealed interface RelayKeysListItem {
    val id: String

    data class Key(val row: RelayKeysBoardRow) : RelayKeysListItem {
        override val id: String get() = row.id
    }

    data object AddKey : RelayKeysListItem {
        override val id: String get() = ADD_KEY_ID
    }

    companion object {
        /** Contains a colon, so it cannot collide with UUID-shaped key ids. */
        const val ADD_KEY_ID = "relay-keys:add"
    }
}

/** One entry of the "Actions for each key" explainer card: action + its consequence. */
data class RelayKeyActionNote(val action: RelayKeyAction, @StringRes val textRes: Int)

data class RelayKeysBoard(
    val host: String,
    val keyCount: Int,
    val showsPrimaryHint: Boolean,
    /** "Add key" is offered only when the connection needs credentials. */
    val showsAdd: Boolean,
    /** With fewer than two keys, replacing a key uses the existing single-key replace path (does not write the list); otherwise it goes through replaceSecret. */
    val replaceUsesSingleKeyPath: Boolean,
    val rows: List<RelayKeysBoardRow>,
    val listItems: List<RelayKeysListItem>,
    /** Action consequence note shown only with 2+ keys; empty for a single key. */
    val actionNotes: List<RelayKeyActionNote>,
    @StringRes val actionNotesTitleRes: Int = R.string.relay_keys_actions_title,
    /** Two footer sentences (this page has no save button): first that changes apply immediately, then where the status comes from. */
    val footnoteRes: List<Int> = listOf(R.string.relay_keys_apply_footnote, R.string.relay_keys_footnote),
)

enum class RelayKeyInputKind { Add, Replace, Rename }

enum class RelayKeyInputFieldId { Name, Secret }

/** One field of the input dialog; the placeholder is either a localized string [placeholderRes] or a literal [placeholderText] (mask). */
data class RelayKeyInputField(
    val id: RelayKeyInputFieldId,
    @StringRes val labelRes: Int,
    @StringRes val placeholderRes: Int? = null,
    val placeholderText: String? = null,
)

/** Content of the three input surfaces (container = bottom sheet). */
data class RelayKeyInputSheet(
    @StringRes val titleRes: Int,
    val fields: List<RelayKeyInputField>,
    @StringRes val noteRes: Int?,
) {
    /** Whether the full-width Save is tappable: with a key field (add / replace key), an empty key value disables it. */
    fun canSave(secret: String): Boolean = fields.none { it.id == RelayKeyInputFieldId.Secret } || secret.isNotBlank()
}

/** One write operation on the keys page; [fetchedKeyID] = the key whose catalog is re-fetched this time (only add / replace value). */
sealed interface RelayKeyOperation {
    val fetchedKeyID: String? get() = null

    data class Add(val keyID: String, val name: String?, val secret: String) : RelayKeyOperation {
        override val fetchedKeyID: String get() = keyID
    }

    data class ReplaceSecret(val keyID: String, val secret: String) : RelayKeyOperation {
        override val fetchedKeyID: String get() = keyID
    }

    data class Rename(val keyID: String, val name: String?) : RelayKeyOperation

    data class Move(val keyID: String, val toIndex: Int) : RelayKeyOperation

    data class Delete(val keyID: String) : RelayKeyOperation
}

/** The keys whose catalog is re-fetched and whose rows show fetching: add key = all existing + the new one; replace value = that one; otherwise none. */
fun RelayKeyOperation.fetchingKeyIDs(current: Provider?): Set<String> = when (this) {
    is RelayKeyOperation.Add -> current?.let { RelayKeyBinding.keyIDs(it) }.orEmpty().toSet() + keyID
    else -> setOfNotNull(fetchedKeyID)
}

/**
 * Outcome of one key operation: [accepted] = the key change was persisted (a fetch write-back dropped due to a concurrent change still counts as accepted);
 * [connection] = the connection in the store when the operation ended.
 */
data class RelayKeyOperationOutcome(
    val accepted: Boolean,
    val connection: Provider?,
    val fetchedKeyID: String?,
    /** This was an add-key operation: only a successful add yields the added notice. */
    val isAdd: Boolean = false,
)

/** Notice after a keys-page operation: one of three warnings (fixed sentence) or add success (with counts and a "View models" link); the notice function returns only one of them. */
sealed interface RelayKeysNotice {
    sealed class Warning(@StringRes val messageRes: Int) : RelayKeysNotice

    data object FetchFailed : Warning(R.string.relay_keys_notice_fetch_failed)
    data object Rejected : Warning(R.string.relay_keys_notice_rejected)
    data object FetchInterrupted : Warning(R.string.relay_keys_notice_fetch_interrupted)

    /** [listed] = number of catalog entries this key lists (N > 0); [new] = number of entries listed only by it and by no other key (M). */
    data class Added(val keyID: String, val listed: Int, val new: Int) : RelayKeysNotice
}

/**
 * In-flight state and notices of the keys page (pure values): in-flight operations on the same key are counted, and only the last completion clears "fetching" and reports the outcome;
 * notices are appended in completion order, deduplicated by sentence, and cleared as a whole at the next begin.
 */
data class RelayKeysPageState(
    val fetchingCounts: Map<String, Int> = emptyMap(),
    val notices: List<RelayKeysNotice> = emptyList(),
) {
    val fetchingKeyIDs: Set<String> get() = fetchingCounts.keys

    /** [fetching]: the keys shown as fetching this time (add key = all); the same set is passed to [finish] on completion. */
    fun begin(operation: RelayKeyOperation, fetching: Set<String> = setOfNotNull(operation.fetchedKeyID)): RelayKeysPageState =
        RelayKeysPageState(
            fetchingCounts = fetching.fold(fetchingCounts) { counts, id -> counts + (id to (counts[id] ?: 0) + 1) },
            notices = emptyList(),
        )

    fun finish(outcome: RelayKeyOperationOutcome, fetching: Set<String> = setOfNotNull(outcome.fetchedKeyID)): RelayKeysPageState {
        val counts = fetching.fold(fetchingCounts) { acc, key ->
            val left = ((acc[key] ?: 0) - 1).coerceAtLeast(0)
            if (left > 0) acc + (key to left) else acc - key
        }
        // The outcome only looks at the key this fetch is about (add key = the new one): if it has a later in-flight operation, nothing is reported.
        val id = outcome.fetchedKeyID
        val remaining = if (id == null) 0 else counts[id] ?: 0
        // Another later operation is in flight on the same key: this accepted one reports nothing; the outcome is left to the last one to finish, computed from the connection at that time.
        val notice = if (outcome.accepted && remaining > 0) null else RelayKeysBoardModel.notice(outcome)
        return RelayKeysPageState(
            fetchingCounts = counts,
            notices = if (notice == null || notice in notices) notices else notices + notice,
        )
    }
}

/** Production path of keys-page write operations: persists through the repository operations and returns the outcome to the page state. */
suspend fun applyRelayKeyOperation(
    repository: ProviderRepository,
    providerID: String,
    operation: RelayKeyOperation,
): RelayKeyOperationOutcome {
    val written = when (operation) {
        is RelayKeyOperation.Add -> repository.addRelayKey(providerID, operation.keyID, operation.name, operation.secret)
        is RelayKeyOperation.ReplaceSecret -> repository.replaceRelayKeySecret(providerID, operation.keyID, operation.secret)
        is RelayKeyOperation.Rename -> repository.renameRelayKey(providerID, operation.keyID, operation.name)
        is RelayKeyOperation.Move -> repository.moveRelayKey(providerID, operation.keyID, operation.toIndex)
        is RelayKeyOperation.Delete -> repository.deleteRelayKey(providerID, operation.keyID)
    }
    return RelayKeyOperationOutcome(
        accepted = written != null,
        connection = written,
        fetchedKeyID = operation.fetchedKeyID,
        isAdd = operation is RelayKeyOperation.Add,
    )
}

/** Delete confirmation: ids of enabled models using the key + name of the primary key they fall back to after deletion (masked when unnamed). */
data class RelayKeyDeleteConfirmation(
    val keyId: String,
    val modelIds: List<String>,
    val fallbackName: String,
    /** Models in use listed one by one in the confirmation: display name, or the id when unnamed; same order as [modelIds]. */
    val modelNames: List<String> = modelIds,
)

/**
 * Keys page board: data comes read-only from the [RelayKeyBinding] read model and the key list, and status comes only from
 * catalog fetches and real requests (`RelayKey.status`); no probes are sent here. The inline first 3 keys on the detail page also use rows from here.
 */
object RelayKeysBoardModel {
    const val INLINE_LIMIT = 3

    /** [fetchingKeyIDs]: keys currently fetching the catalog; rows show "Fetching" without the previous status code. */
    fun build(provider: Provider, fetchingKeyIDs: Set<String> = emptySet()): RelayKeysBoard {
        val keyRows = RelayKeyBinding.rows(provider)
        val statuses = RelayKeyBinding.keys(provider).associate { it.id to it.status }
        val multi = RelayKeyBinding.showsKeyUI(provider)
        val rows = keyRows.mapIndexed { index, row ->
            val status = statuses[row.id]
            val fetching = row.id in fetchingKeyIDs
            val statusRes = if (fetching) R.string.relay_catalog_loading else statusRes(row.status)
            RelayKeysBoardRow(
                id = row.id,
                title = row.name?.takeIf(String::isNotBlank) ?: row.maskedSecret,
                maskedSecret = row.maskedSecret,
                isPrimary = row.isPrimary,
                showsPrimaryBadge = row.isPrimary && multi,
                statusRes = statusRes,
                statusMark = when {
                    fetching -> RelayKeyStatusMark.Progress
                    // Never-checked and unrecognized states -> not drawn; ok -> dot; other known failures -> warning.
                    statusRes == null -> null
                    row.status == "ok" -> RelayKeyStatusMark.Dot
                    else -> RelayKeyStatusMark.Warning
                },
                catalogCount = row.catalogCount.takeIf { it > 0 },
                enabledCount = row.enabledCount,
                lastStatus = status?.takeIf { it.state != "ok" && !fetching }?.httpStatus?.let { code ->
                    statusRes?.let { RelayKeyLastStatus(code, it, status.checkedAt) }
                },
                actions = listOfNotNull(RelayKeyAction.ViewModels.takeIf { row.catalogCount > 0 }) + if (!multi) {
                    listOf(RelayKeyAction.Replace)
                } else {
                    listOfNotNull(
                        RelayKeyAction.Rename,
                        RelayKeyAction.Replace,
                        RelayKeyAction.MoveUp.takeIf { index > 0 },
                        RelayKeyAction.MoveDown.takeIf { index < keyRows.lastIndex },
                        RelayKeyAction.Delete.takeIf { !row.isPrimary },
                    )
                },
                showsPrimaryNotDeletable = multi && row.isPrimary,
            )
        }
        val showsAdd = provider.relayRequested.requiresCredential
        return RelayKeysBoard(
            host = host(provider.baseUrlText.orEmpty()),
            keyCount = rows.size,
            showsPrimaryHint = multi,
            showsAdd = showsAdd,
            replaceUsesSingleKeyPath = !multi,
            rows = rows,
            listItems = rows.map { RelayKeysListItem.Key(it) } + listOfNotNull(RelayKeysListItem.AddKey.takeIf { showsAdd }),
            actionNotes = if (!multi) {
                emptyList()
            } else {
                listOf(
                    RelayKeyActionNote(RelayKeyAction.Rename, R.string.relay_key_rename_hint),
                    RelayKeyActionNote(RelayKeyAction.Replace, R.string.relay_key_replace_hint),
                    RelayKeyActionNote(RelayKeyAction.Delete, R.string.relay_key_delete_hint),
                )
            },
        )
    }

    /** Three input dialogs: field placeholder differs from field title, field title differs from dialog title; rename placeholder = that key's mask. */
    fun inputSheet(kind: RelayKeyInputKind, row: RelayKeysBoardRow?): RelayKeyInputSheet {
        val secret = RelayKeyInputField(RelayKeyInputFieldId.Secret, R.string.api_key, placeholderRes = R.string.relay_api_key_placeholder)
        return when (kind) {
            RelayKeyInputKind.Add -> RelayKeyInputSheet(
                titleRes = R.string.relay_keys_add,
                fields = listOf(RelayKeyInputField(RelayKeyInputFieldId.Name, R.string.relay_setup_key_name), secret),
                noteRes = null,
            )
            RelayKeyInputKind.Replace -> RelayKeyInputSheet(R.string.relay_key_replace, listOf(secret), R.string.relay_key_replace_hint)
            RelayKeyInputKind.Rename -> RelayKeyInputSheet(
                titleRes = R.string.rename,
                fields = listOf(
                    RelayKeyInputField(RelayKeyInputFieldId.Name, R.string.relay_setup_key_name, placeholderText = row?.maskedSecret),
                ),
                noteRes = R.string.relay_key_rename_hint,
            )
        }
    }

    /** "View models" entry (shared by the panel item and the add-success notice link): opens the model library filtered by key(id). */
    fun libraryLayer(keyID: String): RelayDetailLayer.Library = RelayDetailLayer.Library(keyFilter = keyID)

    /**
     * Notice after an operation: not accepted -> rejected; fetched key's written-back status empty -> fetchInterrupted; any other non-ok -> fetchFailed;
     * ok and it was an add, with that key listing N > 0 -> added(N, M), otherwise none; the key no longer exists -> none. Reads only the written-back status, no extra probe.
     */
    fun notice(outcome: RelayKeyOperationOutcome): RelayKeysNotice? {
        if (!outcome.accepted) return RelayKeysNotice.Rejected
        val keyID = outcome.fetchedKeyID ?: return null
        val connection = outcome.connection ?: return null
        val key = RelayKeyBinding.keys(connection).firstOrNull { it.id == keyID } ?: return null
        val status = key.status ?: return RelayKeysNotice.FetchInterrupted
        if (status.state != "ok") return RelayKeysNotice.FetchFailed
        if (!outcome.isAdd) return null
        val listed = RelayKeyBinding.rows(connection).firstOrNull { it.id == keyID }?.catalogCount ?: 0
        if (listed <= 0) return null
        // M: entries listed only by this key (same criterion as the model library key filter and catalog count).
        val onlyThis = listOf(keyID)
        val new = connection.catalogModels.count { RelayKeyBinding.listingKeyIDs(connection, it.id) == onlyThis }
        return RelayKeysNotice.Added(keyID, listed, new)
    }

    /** Five status words; never-checked and unrecognized states have no status word. */
    @StringRes
    fun statusRes(state: String?): Int? = when (state) {
        "ok" -> R.string.relay_key_status_ok
        "invalid" -> R.string.relay_key_status_invalid
        "denied" -> R.string.relay_key_status_denied
        "limited" -> R.string.relay_key_status_limited
        "failed" -> R.string.relay_key_status_failed
        else -> null
    }

    /** Primary key, fewer than two keys, or a nonexistent id -> null (no confirmation shown). */
    fun deleteConfirmation(provider: Provider, keyId: String): RelayKeyDeleteConfirmation? {
        if (!RelayKeyBinding.showsKeyUI(provider)) return null
        val rows = build(provider).rows
        val target = rows.firstOrNull { it.id == keyId } ?: return null
        if (target.isPrimary) return null
        val primary = rows.first()
        val inUse = provider.models.filter { RelayKeyBinding.effectiveKeyID(provider, it.id) == keyId }
        return RelayKeyDeleteConfirmation(
            keyId = keyId,
            modelIds = inUse.map { it.id },
            modelNames = inUse.map { model -> model.name.takeIf(String::isNotBlank) ?: model.id },
            fallbackName = primary.title,
        )
    }

    /** Target position of move up / move down; the first key cannot move up, the last cannot move down, fewer than two keys -> null. */
    fun moveTarget(provider: Provider, keyId: String, action: RelayKeyAction): Int? {
        if (!RelayKeyBinding.showsKeyUI(provider)) return null
        val ids = RelayKeyBinding.keyIDs(provider)
        val index = ids.indexOf(keyId).takeIf { it >= 0 } ?: return null
        val target = when (action) {
            RelayKeyAction.MoveUp -> index - 1
            RelayKeyAction.MoveDown -> index + 1
            else -> return null
        }
        return target.takeIf { it in ids.indices }
    }

    private fun host(baseUrlText: String): String {
        val trimmed = baseUrlText.trim()
        val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        return runCatching { java.net.URI(candidate).host }.getOrNull()?.takeIf(String::isNotBlank) ?: trimmed
    }
}
