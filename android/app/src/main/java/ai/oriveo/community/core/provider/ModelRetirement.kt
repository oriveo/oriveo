package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.ModelLifecycle
import ai.oriveo.community.core.data.remote.RetiredModel
import ai.oriveo.community.core.model.AIModel
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/**
 * Retirement status of the conversation model for official BYOK providers, same rules on all three platforms
 * (shared fixture `shared/test-fixtures/provider-catalog/model-retired.v1.json`; its `$comment` is authoritative).
 * Relay goes through [RelayModelFallback.removedConnectionName] and does not pass through here.
 *
 * Pure functions: never rewrite the conversation model id, never write storage, never branch on providerKind.
 */
object ModelRetirement {

    enum class Status(val wire: String) {
        Available("available"),
        Retired("retired"),
        Missing("missing"),
    }

    enum class NewChatHint(val wire: String) {
        /** The last-used / user-default model is no longer available and a new chat switched to another model (hinted once per device per provider+model). */
        LastUsedRetired("last_used_retired"),
    }

    data class CatalogModel(
        val id: String,
        val displayName: String?,
        val lifecycle: ModelLifecycle?,
    )

    /** Catalog view of one provider. Callers pass null when catalogLoadState is not Loaded (always available). */
    data class Catalog(
        val models: List<CatalogModel>,
        val retiredModels: List<RetiredModel>,
        val resolveMap: Map<String, String>,
        val defaultModelId: String?,
    )

    data class ConversationModelStatus(
        val status: Status,
        val successorId: String?,
        val displayName: String,
        /** Both retired and missing block sending and show banner.model_retired. */
        val sendBlocked: Boolean,
        /** The conversation model id is never rewritten before a user action, always equal to the input. */
        val modelIdAfter: String,
    )

    data class NewChatModel(
        val modelId: String?,
        val hint: NewChatHint?,
    )

    /**
     * Conversation model status, first match in order: catalog not loaded -> available; tombstone -> retired; deprecated and past shutdownAt -> retired;
     * in catalog -> available; in the user-enabled set (hand-entered id) -> available; resolveMap points into the catalog -> available; otherwise missing.
     * When [bundled] is true (built-in snapshot state) missing counts as available, while tombstones and expired deprecated models stay retired.
     */
    fun conversationStatus(
        catalog: Catalog?,
        userModels: List<String>,
        modelId: String,
        storedName: String?,
        now: Instant,
        bundled: Boolean = false,
    ): ConversationModelStatus {
        val (status, successorId) = resolveStatus(catalog, userModels, modelId, now, bundled)
        val displayName = storedName?.takeIf { it.isNotBlank() }
            ?: catalog?.models?.firstOrNull { it.id == modelId }?.displayName?.takeIf { it.isNotBlank() }
            ?: catalog?.retiredModels?.firstOrNull { it.id == modelId }?.displayName?.takeIf { it.isNotBlank() }
            ?: modelId
        return ConversationModelStatus(
            status = status,
            successorId = successorId,
            displayName = displayName,
            sendBlocked = status != Status.Available,
            modelIdAfter = modelId,
        )
    }

    /**
     * New chat (no conversation yet) model pick: preferred is available and enabled -> it; otherwise the enabled available model matched by the metadata default ([defaultMatch]);
     * otherwise the first available among the enabled. When preferred is non-empty but not adopted, carries [NewChatHint.LastUsedRetired].
     */
    fun newChatModel(
        catalog: Catalog?,
        userModels: List<String>,
        preferredModelId: String?,
        now: Instant,
        bundled: Boolean = false,
        canonicalIds: Map<String, String> = emptyMap(),
    ): NewChatModel {
        fun usable(id: String?): Boolean =
            id != null && isNewChatUsable(catalog, userModels, id, now, bundled, canonicalIds[id])

        val chosen = preferredModelId?.takeIf { usable(it) }
            ?: catalog?.let { defaultMatch(it, userModels, now, bundled, canonicalIds) }
            ?: userModels.firstOrNull { usable(it) }
        // Only hint when the preference was not adopted because it was retired / missing from the catalog; models available in the catalog that the user merely disabled get no hint.
        val hint = if (
            preferredModelId != null && chosen != preferredModelId &&
            !isNewChatUsable(catalog, userModels + preferredModelId, preferredModelId, now, bundled, canonicalIds[preferredModelId])
        ) NewChatHint.LastUsedRetired else null
        return NewChatModel(modelId = chosen, hint = hint)
    }

    /**
     * Catalog default tier: among enabled models with status available, match defaultModelId via [ModelSelectionUtils.matchingModel]
     * (same rule as iOS ModelResolver.matchingModel), returning the enabled id rather than the catalog id.
     * A matched model counts as in-catalog if it is in the catalog itself or the catalog default itself is available; only used for the default tier, it does not relax the last-used tier or the conversation status.
     * Relay does not pass through here (literal ids), so kind is null.
     */
    private fun defaultMatch(
        catalog: Catalog,
        userModels: List<String>,
        now: Instant,
        bundled: Boolean,
        canonicalIds: Map<String, String>,
    ): String? {
        val defaultId = catalog.defaultModelId?.takeIf { it.isNotBlank() } ?: return null
        val defaultAvailable = resolveStatus(catalog, userModels, defaultId, now, bundled).first == Status.Available
        // In the catalog itself: fine; otherwise the model is treated as in-catalog when the catalog default itself is available (in catalog and not retired).
        fun inCatalog(id: String): Boolean =
            isNewChatUsable(catalog, userModels, id, now, bundled, canonicalIds[id]) ||
                (defaultAvailable && isNewChatUsable(catalog, userModels, id, now, bundled, defaultId))
        val candidates = userModels
            .filter { resolveStatus(catalog, userModels, it, now, bundled).first == Status.Available }
            .map { AIModel(id = it, name = it, canonicalModelId = canonicalIds[it]) }
            .toMutableList()
        // Drop a match that is not in the catalog and match the next one (same as iOS ProviderSelectionSnapshot.firstAvailableMatch).
        while (true) {
            val matched = ModelSelectionUtils.matchingModel(candidates, defaultId, kind = null) ?: return null
            if (inCatalog(matched.id)) return matched.id
            candidates.remove(matched)
        }
    }

    /**
     * Usable in a new chat: enabled, status available, and in the catalog (models[] or resolveMap points into the catalog) --
     * enabled but not in the catalog (missing) is unusable; catalog not loaded / built-in snapshot state never counts as missing.
     * [canonicalId]: when a dated snapshot is enabled and the catalog records a canonical id, the canonical being available also counts as in-catalog.
     */
    fun isNewChatUsable(
        catalog: Catalog?,
        userModels: List<String>,
        modelId: String,
        now: Instant,
        bundled: Boolean = false,
        canonicalId: String? = null,
    ): Boolean {
        if (modelId !in userModels) return false
        if (resolveStatus(catalog, userModels, modelId, now, bundled).first != Status.Available) return false
        if (catalog == null || bundled) return true
        if (catalog.models.any { it.id == modelId } ||
            catalog.resolveMap[modelId]?.let { canonical -> catalog.models.any { it.id == canonical } } == true
        ) return true
        // When the own id is not in the catalog, the canonical must itself be available (in catalog, not tombstoned, deprecated not past shutdown).
        val canonical = canonicalId?.takeIf { it.isNotBlank() } ?: return false
        return resolveStatus(catalog, emptyList(), canonical, now, bundled = false).first == Status.Available
    }

    /** shutdownAt / retiredAt: accepts plain dates (UTC midnight) and RFC3339; returns null if unparseable. */
    fun parseInstant(raw: String?): Instant? {
        val text = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return try {
            OffsetDateTime.parse(text).toInstant()
        } catch (_: DateTimeParseException) {
            try {
                LocalDate.parse(text).atStartOfDay(ZoneOffset.UTC).toInstant()
            } catch (_: DateTimeParseException) {
                null
            }
        }
    }

    private fun resolveStatus(
        catalog: Catalog?,
        userModels: List<String>,
        modelId: String,
        now: Instant,
        bundled: Boolean,
    ): Pair<Status, String?> {
        if (catalog == null) return Status.Available to null
        catalog.retiredModels.firstOrNull { it.id == modelId }?.let { tombstone ->
            return Status.Retired to successor(catalog, tombstone.routedTo, now)
        }
        val model = catalog.models.firstOrNull { it.id == modelId }
        if (model != null) {
            if (isPastShutdown(model, now)) {
                return Status.Retired to successor(catalog, model.lifecycle?.routedTo, now)
            }
            return Status.Available to null
        }
        if (modelId in userModels) return Status.Available to null
        val canonical = catalog.resolveMap[modelId]
        if (canonical != null && catalog.models.any { it.id == canonical }) return Status.Available to null
        if (bundled) return Status.Available to null
        return Status.Missing to null
    }

    /** The successor must be an id in the catalog models[] that is itself available right now, otherwise null. */
    private fun successor(catalog: Catalog, routedTo: String?, now: Instant): String? {
        val id = routedTo?.takeIf { it.isNotBlank() } ?: return null
        val model = catalog.models.firstOrNull { it.id == id } ?: return null
        if (catalog.retiredModels.any { it.id == id }) return null
        if (isPastShutdown(model, now)) return null
        return id
    }

    private fun isPastShutdown(model: CatalogModel, now: Instant): Boolean {
        val lifecycle = model.lifecycle ?: return false
        if (lifecycle.state != "deprecated") return false
        val shutdownAt = parseInstant(lifecycle.shutdownAt) ?: return false
        return !shutdownAt.isAfter(now)
    }
}
