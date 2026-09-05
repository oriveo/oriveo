package ai.oriveo.community.core.provider

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

data class LocalEngineDiscoveryResult(val endpoint: String, val source: String)

/** LAN scan the user starts and cancels explicitly. Discovered addresses stay in this process and are never sent anywhere. */
class LocalEngineDiscoverySession(context: Context) {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val listeners = CopyOnWriteArrayList<NsdManager.DiscoveryListener>()
    private var portJob: Job? = null
    @Volatile var isActive: Boolean = false
        private set

    fun start(
        scope: CoroutineScope,
        knownHosts: List<String>,
        onResult: (LocalEngineDiscoveryResult) -> Unit,
        onComplete: () -> Unit,
    ) {
        cancel()
        isActive = true
        listOf("_http._tcp.", "_ollama._tcp.", "_llamacpp._tcp.", "_lmstudio._tcp.", "_open-webui._tcp.").forEach { type ->
            val listener = object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) = stopSelf()
                override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) = stopSelf()
                override fun onDiscoveryStarted(serviceType: String?) = Unit
                override fun onDiscoveryStopped(serviceType: String?) = Unit
                override fun onServiceLost(serviceInfo: NsdServiceInfo?) = Unit
                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) = Unit
                        @Suppress("DEPRECATION")
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            val host = info.host?.hostAddress ?: return
                            onResult(LocalEngineDiscoveryResult("http://$host:${info.port}", "mdns"))
                        }
                    })
                }
                private fun stopSelf() { runCatching { nsd.stopServiceDiscovery(this) } }
            }
            listeners += listener
            runCatching { nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener) }
        }
        portJob = scope.launch {
            val startedAt = SystemClock.elapsedRealtime()
            knownHosts.flatMap { host -> KNOWN_PORTS.map { host to it } }.forEach { (host, port) ->
                if (probe(host, port)) onResult(LocalEngineDiscoveryResult("http://$host:$port", "known_port"))
            }
            // mDNS discovery is asynchronous and often has no explicit host to probe. The old
            // implementation completed immediately for the default loopback field while leaving
            // NSD listeners alive, so the button flashed and returned to "Search" even though the
            // scan was still running. Keep one bounded, observable discovery window instead.
            val remaining = (DISCOVERY_WINDOW_MILLIS - (SystemClock.elapsedRealtime() - startedAt)).coerceAtLeast(0L)
            delay(remaining)
            if (isActive) onComplete()
        }
    }

    fun cancel() {
        listeners.forEach { runCatching { nsd.stopServiceDiscovery(it) } }
        listeners.clear()
        portJob?.cancel()
        portJob = null
        isActive = false
    }

    private suspend fun probe(host: String, port: Int): Boolean = withContext(Dispatchers.IO) {
        runCatching { Socket().use { it.connect(InetSocketAddress(host, port), 800) } }.isSuccess
    }

    companion object {
        const val uploadsResults = false
        const val DISCOVERY_WINDOW_MILLIS = 6_000L
        private val KNOWN_PORTS = listOf(8080, 11434, 1234, 8000, 3000)
    }
}
