package ai.oriveo.community.core.reachability

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.TestScope
import org.junit.Assert.assertSame
import org.junit.Test

class ServiceReachabilityMonitorTest {

    @Test
    fun `remote failures do not show a global banner`() {
        val monitor = serviceReachabilityMonitor()

        monitor.reportRemoteFailure(ServiceReachabilityMonitor.FailureScope.RemoteData)

        assertSame(ServiceReachabilityMonitor.State.ServicesUnreachable, monitor.state.value)
        assertSame(ServiceReachabilityMonitor.State.Online, monitor.bannerState.value)
    }

    @Test
    fun `system offline still shows a global banner`() {
        val monitor = serviceReachabilityMonitor()

        monitor.applyPathSatisfied(false)

        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.state.value)
        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.bannerState.value)
    }

    @Test
    fun `losing the only network shows the NoNetwork banner`() {
        
        val monitor = serviceReachabilityMonitor()
        val wifi = mockk<Network>(relaxed = true)

        monitor.onNetworkAvailable(wifi)
        assertSame(ServiceReachabilityMonitor.State.Online, monitor.state.value)

        monitor.onNetworkLost(wifi)

        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.state.value)
        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.bannerState.value)
    }

    @Test
    fun `switching networks stays online without flicker`() {
        
        val monitor = serviceReachabilityMonitor()
        val wifi = mockk<Network>(relaxed = true)
        val cellular = mockk<Network>(relaxed = true)

        monitor.onNetworkAvailable(wifi)
        monitor.onNetworkAvailable(cellular)
        monitor.onNetworkLost(wifi)

        assertSame(ServiceReachabilityMonitor.State.Online, monitor.state.value)
        assertSame(ServiceReachabilityMonitor.State.Online, monitor.bannerState.value)
    }

    @Test
    fun `reconnecting after offline restores online`() {
        val monitor = serviceReachabilityMonitor()
        val wifi = mockk<Network>(relaxed = true)

        monitor.onNetworkAvailable(wifi)
        monitor.onNetworkLost(wifi)
        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.state.value)

        val cellular = mockk<Network>(relaxed = true)
        monitor.onNetworkAvailable(cellular)

        assertSame(ServiceReachabilityMonitor.State.Online, monitor.state.value)
        assertSame(ServiceReachabilityMonitor.State.Online, monitor.bannerState.value)
    }

    @Test
    fun `dismiss then disconnect again re-shows banner`() {
        val monitor = serviceReachabilityMonitor()
        val wifi = mockk<Network>(relaxed = true)

        
        monitor.onNetworkAvailable(wifi)
        monitor.onNetworkLost(wifi)
        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.bannerState.value)
        monitor.dismissCurrentBanner()
        assertSame(ServiceReachabilityMonitor.State.Online, monitor.bannerState.value)

        
        monitor.onNetworkAvailable(wifi)
        monitor.onNetworkLost(wifi)

        assertSame(ServiceReachabilityMonitor.State.NoNetwork, monitor.bannerState.value)
    }

    private fun serviceReachabilityMonitor(): ServiceReachabilityMonitor {
        val appContext = mockk<Context>(relaxed = true)
        val context = mockk<Context>(relaxed = true)
        every { context.applicationContext } returns appContext
        every { appContext.getSystemService(Context.CONNECTIVITY_SERVICE) } returns mockk<ConnectivityManager>(relaxed = true)
        return ServiceReachabilityMonitor(context, TestScope())
    }
}
