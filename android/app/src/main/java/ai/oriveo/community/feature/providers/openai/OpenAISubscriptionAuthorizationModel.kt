package ai.oriveo.community.feature.providers.openai

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.provider.openai.OpenAIDeviceAuthorization
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAuthConfig
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionError
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionException
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionOAuthClient
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.feature.providers.SubscriptionAuthorizationSnapshotStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json


class OpenAISubscriptionAuthorizationModel(
    private val client: OpenAISubscriptionOAuthClient,
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val sleep: suspend (Long) -> Unit = { millis -> delay(millis) },
    
    private val snapshotStore: SubscriptionAuthorizationSnapshotStore =
        SubscriptionAuthorizationSnapshotStore.None,
) {
    sealed class Phase {
        data object Idle : Phase()

        
        data object Requesting : Phase()

        
        data class AwaitingAuthorization(val authorization: OpenAIDeviceAuthorization) : Phase()

        data class Succeeded(val tokens: OpenAISubscriptionTokens) : Phase()

        data class Failed(val error: OpenAISubscriptionError) : Phase()
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

    val deviceAuthorization: OpenAIDeviceAuthorization?
        get() = (phase as? Phase.AwaitingAuthorization)?.authorization

    fun markVerificationPageOpened() {
        didOpenVerificationPage = true
    }

    
    fun startIfIdle(config: OpenAISubscriptionAuthConfig) {
        if (pollJob?.isActive == true) return
        
        if (phase is Phase.Succeeded || phase is Phase.Failed) return
        
        
        if (resumeFromSnapshot(config)) return
        start(config)
    }

    
    fun start(config: OpenAISubscriptionAuthConfig) {
        pollJob?.cancel()
        didOpenVerificationPage = false
        phase = Phase.Requesting

        pollJob = scope.launch {
            val authorization = try {
                client.requestDeviceAuthorization(config)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: OpenAISubscriptionException) {
                phase = Phase.Failed(e.error)
                return@launch
            } catch (e: Exception) {
                phase = Phase.Failed(OpenAISubscriptionError.Transport(e.message.orEmpty()))
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
        config: OpenAISubscriptionAuthConfig,
        authorization: OpenAIDeviceAuthorization,
        
        deadline: Long,
    ) {
        var intervalSeconds = maxOf(1, authorization.interval)

        while (currentCoroutineIsActive()) {
            if (nowMillis() >= deadline) {
                phase = Phase.Failed(OpenAISubscriptionError.CodeExpired)
                return
            }
            sleep(intervalSeconds * 1000L)

            try {
                
                
                val tokens = client.pollToken(config, authorization.deviceAuthId, authorization.userCode)
                phase = Phase.Succeeded(tokens)
                return
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: OpenAISubscriptionException) {
                when (e.error) {
                    is OpenAISubscriptionError.AuthorizationPending -> continue
                    is OpenAISubscriptionError.SlowDown -> {
                        intervalSeconds += 5
                        continue
                    }
                    
                    
                    
                    
                    is OpenAISubscriptionError.Transport -> continue
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
        config: OpenAISubscriptionAuthConfig,
        authorization: OpenAIDeviceAuthorization,
    ): Long = nowMillis() + minOf(authorization.expiresIn, config.pollTimeoutSeconds) * 1000L

    
    private fun resumeFromSnapshot(config: OpenAISubscriptionAuthConfig): Boolean {
        val raw = snapshotStore.read()?.takeIf { it.isNotBlank() } ?: return false
        val snapshot = runCatching { snapshotJson.decodeFromString<Snapshot>(raw) }.getOrNull()
        if (snapshot == null || nowMillis() >= snapshot.deadlineMillis) {
            snapshotStore.write(null)
            return false
        }
        val authorization = OpenAIDeviceAuthorization(
            deviceAuthId = snapshot.deviceAuthId,
            userCode = snapshot.userCode,
            verificationUrl = snapshot.verificationUrl,
            interval = snapshot.interval,
            expiresIn = snapshot.expiresIn,
        )
        phaseState = Phase.AwaitingAuthorization(authorization)
        
        
        didOpenVerificationPage = true
        pollJob = scope.launch { poll(config, authorization, snapshot.deadlineMillis) }
        return true
    }

    private fun encodeSnapshot(authorization: OpenAIDeviceAuthorization, deadline: Long): String =
        snapshotJson.encodeToString(
            Snapshot.serializer(),
            Snapshot(
                deviceAuthId = authorization.deviceAuthId,
                userCode = authorization.userCode,
                verificationUrl = authorization.verificationUrl,
                interval = authorization.interval,
                expiresIn = authorization.expiresIn,
                deadlineMillis = deadline,
            ),
        )

    
    @Serializable
    private data class Snapshot(
        val deviceAuthId: String,
        val userCode: String,
        val verificationUrl: String,
        val interval: Int,
        val expiresIn: Int,
        val deadlineMillis: Long,
    )

    private suspend fun currentCoroutineIsActive(): Boolean =
        kotlinx.coroutines.currentCoroutineContext()[Job]?.isActive ?: scope.isActive
}
