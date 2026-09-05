package ai.oriveo.community.core.reachability

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import androidx.annotation.VisibleForTesting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean


class ServiceReachabilityMonitor(
    context: Context,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {

    sealed class State {
        object Online : State()
        object NoNetwork : State()
        object ServicesUnreachable : State()
    }

    
    enum class FailureScope {
        CloudAuth,
        RemoteData,
        BackendApi,
    }

    private val appContext: Context = context.applicationContext
    private val connectivityManager: ConnectivityManager? =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    /** Reachability state for banner UI. */
    private val _state = MutableStateFlow<State>(State.Online)
    val state: StateFlow<State> = _state.asStateFlow()

    
    private val _bannerState = MutableStateFlow<State>(State.Online)
    val bannerState: StateFlow<State> = _bannerState.asStateFlow()

    private val hasStarted = AtomicBoolean(false)

    @Volatile
    private var currentStateInstance: Long = 0

    @Volatile
    private var dismissedStateInstance: Long? = null

    @Volatile
    private var pathSatisfied: Boolean = true

    private val lastRemoteFailureAtByScope = mutableMapOf<FailureScope, Long>()
    private val remoteFailureExpiryJobs = mutableMapOf<FailureScope, Job>()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    
    private val availableNetworks = mutableSetOf<Network>()

    
    private val unreachableWindowMs: Long = 60_000L

    fun start() {
        if (!hasStarted.compareAndSet(false, true)) return
        val cm = connectivityManager ?: return

        
        
        
        
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetworkAvailable(network)
            override fun onLost(network: Network) = onNetworkLost(network)
        }

        runCatching { cm.registerDefaultNetworkCallback(callback) }
            .onSuccess { networkCallback = callback }

        
        
        applyPathSatisfied(cm.activeNetwork != null)
    }

    
    @VisibleForTesting
    internal fun onNetworkAvailable(network: Network) {
        val satisfied = synchronized(availableNetworks) {
            availableNetworks.add(network)
            availableNetworks.isNotEmpty()
        }
        applyPathSatisfied(satisfied)
    }

    
    @VisibleForTesting
    internal fun onNetworkLost(network: Network) {
        val satisfied = synchronized(availableNetworks) {
            availableNetworks.remove(network)
            availableNetworks.isNotEmpty()
        }
        applyPathSatisfied(satisfied)
    }

    
    fun reportRemoteFailure(scope: FailureScope) {
        if (!pathSatisfied) {
            recompute()
            return
        }
        val failureAt = nowMs()
        synchronized(this) {
            lastRemoteFailureAtByScope[scope] = failureAt
            scheduleRemoteFailureExpiry(scope, failureAt)
        }
        recompute()
    }

    
    fun reportRemoteSuccess(scope: FailureScope) {
        synchronized(this) {
            if (lastRemoteFailureAtByScope[scope] == null) return
            clearRemoteFailure(scope)
        }
        recompute()
    }

    
    @Synchronized
    fun dismissCurrentBanner() {
        dismissedStateInstance = currentStateInstance
        _bannerState.value = State.Online
    }

    @VisibleForTesting
    internal fun applyPathSatisfied(satisfied: Boolean) {
        pathSatisfied = satisfied
        if (!satisfied) {
            clearAllRemoteFailures()
        }
        recompute()
    }

    @Synchronized
    private fun recompute() {
        val current = _state.value
        val next: State = when {
            !pathSatisfied -> State.NoNetwork
            hasActiveRemoteFailure() -> State.ServicesUnreachable
            else -> State.Online
        }
        if (next == current) return
        _state.value = next
        currentStateInstance += 1
        _bannerState.value = nextBannerState(next)
    }

    private fun scheduleRemoteFailureExpiry(scopeKey: FailureScope, failureAt: Long) {
        remoteFailureExpiryJobs[scopeKey]?.cancel()
        remoteFailureExpiryJobs[scopeKey] = scope.launch {
            kotlinx.coroutines.delay(unreachableWindowMs)
            synchronized(this@ServiceReachabilityMonitor) {
                remoteFailureExpiryJobs.remove(scopeKey)
                if (lastRemoteFailureAtByScope[scopeKey] == failureAt) {
                    lastRemoteFailureAtByScope.remove(scopeKey)
                    recompute()
                }
            }
        }
    }

    private fun clearRemoteFailure(scopeKey: FailureScope) {
        lastRemoteFailureAtByScope.remove(scopeKey)
        remoteFailureExpiryJobs.remove(scopeKey)?.cancel()
    }

    private fun clearAllRemoteFailures() {
        FailureScope.entries.forEach { clearRemoteFailure(it) }
    }

    private fun hasActiveRemoteFailure(): Boolean {
        val now = nowMs()
        return lastRemoteFailureAtByScope.values.any { now - it < unreachableWindowMs }
    }

    @VisibleForTesting
    internal fun nowMs(): Long = System.currentTimeMillis()

    private fun nextBannerState(state: State): State {
        if (state != State.NoNetwork) return State.Online
        return if (dismissedStateInstance == currentStateInstance) State.Online else state
    }
}
