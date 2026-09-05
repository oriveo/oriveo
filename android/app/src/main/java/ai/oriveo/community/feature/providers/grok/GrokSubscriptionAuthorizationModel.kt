package ai.oriveo.community.feature.providers.grok

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.provider.grok.GrokDeviceAuthorization
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthConfig
import ai.oriveo.community.core.provider.grok.GrokSubscriptionError
import ai.oriveo.community.core.provider.grok.GrokSubscriptionException
import ai.oriveo.community.core.provider.grok.GrokSubscriptionOAuthClient
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json


class GrokSubscriptionAuthorizationModel(
    private val client: GrokSubscriptionOAuthClient,
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { millis -> delay(millis) },
    
    private val snapshotStore: SubscriptionAuthorizationSnapshotStore =
        SubscriptionAuthorizationSnapshotStore.None,
) {
    sealed class Phase {
        data object Idle : Phase()

        
        data object Requesting : Phase()

        
        data class AwaitingAuthorization(val authorization: GrokDeviceAuthorization) : Phase()

        data class Succeeded(val tokens: GrokSubscriptionTokens) : Phase()

        data class Failed(val error: GrokSubscriptionError) : Phase()
    }

    private var phaseState: Phase by mutableStateOf(Phase.Idle)

    
    var phase: Phase
        get() = phaseState
        private set(value) {
            phaseState = value
            if (value !is Phase.AwaitingAuthorization && value !is Phase.Requesting) {
                snapshotStore.write(null)
            }
        }

    
    var didOpenVerificationPage: Boolean by mutableStateOf(false)
        private set

    private var pollJob: Job? = null

    private val snapshotJson = Json { ignoreUnknownKeys = true }

    val deviceAuthorization: GrokDeviceAuthorization?
        get() = (phase as? Phase.AwaitingAuthorization)?.authorization

    fun markVerificationPageOpened() {
        didOpenVerificationPage = true
    }
    
    fun startIfIdle(config: GrokSubscriptionAuthConfig) {
        if (pollJob?.isActive == true) return
        
        if (phase is Phase.Succeeded || phase is Phase.Failed) return
        
        
        if (resumeFromSnapshot(config)) return
        start(config)
    }


    
    fun start(config: GrokSubscriptionAuthConfig) {
        pollJob?.cancel()
        didOpenVerificationPage = false
        phase = Phase.Requesting

        pollJob = scope.launch {
            val authorization = try {
                client.requestDeviceAuthorization(config)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: GrokSubscriptionException) {
                phase = Phase.Failed(e.error)
                return@launch
            } catch (e: Exception) {
                phase = Phase.Failed(GrokSubscriptionError.Transport(e.message.orEmpty()))
                return@launch
            }
            phase = Phase.AwaitingAuthorization(authorization)
            val deadline = deadlineFor(config, authorization)
            snapshotStore.write(encodeSnapshot(authorization, deadline))
            poll(config, authorization, deadline)
        }
    }

    
    @androidx.annotation.VisibleForTesting
    internal suspend fun awaitCompletionForTest() {
        pollJob?.join()
    }

    
    fun cancel() {
        pollJob?.cancel()
        pollJob = null
        phase = Phase.Idle
        didOpenVerificationPage = false
    }

    private suspend fun poll(
        config: GrokSubscriptionAuthConfig,
        authorization: GrokDeviceAuthorization,
        
        deadline: Long,
    ) {
        var intervalSeconds = maxOf(1, authorization.interval ?: config.pollIntervalSeconds)

        while (currentCoroutineIsActive()) {
            if (nowMillis() >= deadline) {
                phase = Phase.Failed(GrokSubscriptionError.CodeExpired)
                return
            }
            sleep(intervalSeconds * 1000L)

            try {
                val tokens = client.pollToken(config, authorization.deviceCode)
                phase = Phase.Succeeded(tokens)
                return
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: GrokSubscriptionException) {
                when (e.error) {
                    is GrokSubscriptionError.AuthorizationPending -> continue
                    is GrokSubscriptionError.SlowDown -> {
                        intervalSeconds += 5
                        continue
                    }
                    
                    
                    
                    
                    is GrokSubscriptionError.Transport -> continue
                    else -> {
                        phase = Phase.Failed(e.error)
                        return
                    }
                }
            } catch (e: Exception) {
                
                continue
            }
        }
    }

    
    private fun deadlineFor(
        config: GrokSubscriptionAuthConfig,
        authorization: GrokDeviceAuthorization,
    ): Long = nowMillis() + minOf(authorization.expiresIn, config.pollTimeoutSeconds) * 1000L

    
    private fun resumeFromSnapshot(config: GrokSubscriptionAuthConfig): Boolean {
        val raw = snapshotStore.read()?.takeIf { it.isNotBlank() } ?: return false
        val snapshot = runCatching { snapshotJson.decodeFromString<Snapshot>(raw) }.getOrNull()
        if (snapshot == null || nowMillis() >= snapshot.deadlineMillis) {
            snapshotStore.write(null)
            return false
        }
        val authorization = GrokDeviceAuthorization(
            deviceCode = snapshot.deviceCode,
            userCode = snapshot.userCode,
            verificationUrl = snapshot.verificationUrl,
            expiresIn = snapshot.expiresIn,
            interval = snapshot.interval,
        )
        phaseState = Phase.AwaitingAuthorization(authorization)
        
        
        didOpenVerificationPage = true
        pollJob = scope.launch { poll(config, authorization, snapshot.deadlineMillis) }
        return true
    }

    private fun encodeSnapshot(authorization: GrokDeviceAuthorization, deadline: Long): String =
        snapshotJson.encodeToString(
            Snapshot.serializer(),
            Snapshot(
                deviceCode = authorization.deviceCode,
                userCode = authorization.userCode,
                verificationUrl = authorization.verificationUrl,
                expiresIn = authorization.expiresIn,
                interval = authorization.interval,
                deadlineMillis = deadline,
            ),
        )

    
    @Serializable
    private data class Snapshot(
        val deviceCode: String,
        val userCode: String,
        val verificationUrl: String,
        val expiresIn: Int,
        val interval: Int?,
        val deadlineMillis: Long,
    )

    private suspend fun currentCoroutineIsActive(): Boolean =
        kotlinx.coroutines.currentCoroutineContext()[Job]?.isActive ?: scope.isActive
}
