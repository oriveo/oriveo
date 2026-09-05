package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import kotlinx.coroutines.CancellationException

/** Resolve a chat provider without turning an expected catalog failure into an uncaught coroutine crash. */
internal suspend fun resolveChatProvider(
    providerRepository: ProviderRepository,
    providerId: String?,
    onMissing: () -> Unit = {},
    onFailure: (Throwable) -> Unit,
): Provider? {
    val id = providerId ?: return null
    return try {
        providerRepository.getById(id).also { provider ->
            if (provider == null) onMissing()
        }
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (error: Exception) {
        onFailure(error)
        null
    }
}
