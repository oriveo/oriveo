package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * A non-secret invalidation signal for capability consumers.
 *
 * Metadata publication changes and the earliest observed candidate expiry both advance the same
 * revision. Credential/connection mutation owners may call [invalidate] after their durable
 * mutation succeeds; this bridge deliberately neither reads nor carries credential material.
 */
internal object CapabilityEvidenceObservationBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = Any()
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision.asStateFlow()

    private var nearestExpiryAt: Long? = null
    private var expiryJob: Job? = null

    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            MetadataClient.refreshEvents.collect {
                synchronized(lock) {
                    nearestExpiryAt = null
                    expiryJob?.cancel()
                    expiryJob = null
                }
                invalidate()
            }
        }
    }

    /** Registers a projection's TTL; at most one process-wide timer is kept. */
    fun observe(projection: CapabilityEvidenceProductionAdapter.Projection) {
        observeExpiry(projection.nextExpiryAt)
    }

    /** Safe to call from any credential/connection mutation path after a real state change. */
    fun invalidate() {
        synchronized(lock) {
            _revision.value = _revision.value + 1
        }
    }

    internal fun observeExpiry(expiryAt: Long?, now: Long = System.currentTimeMillis()) {
        expiryAt ?: return
        synchronized(lock) {
            val current = nearestExpiryAt
            if (current != null && current <= expiryAt) return
            nearestExpiryAt = expiryAt
            expiryJob?.cancel()
            expiryJob = scope.launch {
                delay((expiryAt - now).coerceAtLeast(0L))
                val fires = expireAt(expiryAt)
                if (fires) invalidate()
            }
        }
    }

    /** Deterministic clock seam for the core test; production only reaches this from the timer. */
    internal fun expireDueForTesting(now: Long): Boolean {
        val expiry = synchronized(lock) { nearestExpiryAt } ?: return false
        if (expiry > now) return false
        val fires = expireAt(expiry)
        if (fires) invalidate()
        return fires
    }

    internal fun resetForTesting() {
        synchronized(lock) {
            nearestExpiryAt = null
            expiryJob?.cancel()
            expiryJob = null
            _revision.value = 0L
        }
    }

    private fun expireAt(expiryAt: Long): Boolean = synchronized(lock) {
        if (nearestExpiryAt != expiryAt) false else {
            nearestExpiryAt = null
            expiryJob?.cancel()
            expiryJob = null
            true
        }
    }

    /** Typed Compose/cache key; no epoch, endpoint, or credential value is exposed. */
    fun uiIdentityScopeKey(
        provider: Provider,
        model: AIModel,
        partitionId: String,
        revision: Long = _revision.value,
    ): UiIdentityScopeKey = UiIdentityScopeKey(
        providerId = provider.id,
        providerKind = provider.kind.rawValue,
        modelId = model.canonicalModelId ?: model.id,
        partitionId = partitionId,
        observationRevision = revision,
    )
}

internal data class UiIdentityScopeKey(
    val providerId: String,
    val providerKind: String,
    val modelId: String,
    val partitionId: String,
    val observationRevision: Long,
)
