package ai.oriveo.community.feature.providers.detail

import java.util.concurrent.ConcurrentHashMap

/**
 * One-shot notice slot for the detail page: after the two-step add is saved from the providers entry,
 * it writes an Added n models notice; after manual setup Save anyway (unverified) it writes a Connection not verified yet notice + a localized reason;
 * the detail page clears it once taken; valid in-process only, never persisted.
 */
object ProviderDetailNotice {
    private val addedModels = ConcurrentHashMap<String, Int>()
    private val unverified = ConcurrentHashMap<String, String>()

    fun postAddedModels(providerId: String, count: Int) {
        addedModels[providerId] = count
    }

    fun take(providerId: String): Int? = addedModels.remove(providerId)

    fun postUnverified(providerId: String, reason: String) {
        unverified[providerId] = reason
    }

    fun takeUnverified(providerId: String): String? = unverified.remove(providerId)
}
