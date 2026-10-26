package ai.oriveo.community.core.voice

import android.Manifest
import android.app.Activity
import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Where a pending request goes after the requester is released on a configuration change: adopted after recreation, or ended as not granted if the host is truly destroyed. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidMicrophonePermissionTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun `carried request completes when host finishes without reattach`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val host = Robolectric.buildActivity(Activity::class.java).setup()
        val permission = AndroidMicrophonePermission(app)
        val handle = permission.attach { }

        val result = async { permission.request() }
        handle.releaseForConfigChange()
        assertFalse(result.isCompleted)

        // The host is truly destroyed before the recreated requester attaches: the pending request ends as not granted.
        host.pause().stop().destroy()
        assertTrue(result.isCompleted)
        assertFalse(result.await())
    }

    @Test
    fun `config change then reattach still adopts carried`() = runTest(UnconfinedTestDispatcher()) {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val host = Robolectric.buildActivity(Activity::class.java).setup()
        val permission = AndroidMicrophonePermission(app)
        val handle = permission.attach { }

        val result = async { permission.request() }
        handle.releaseForConfigChange()
        // Configuration-change recreation: isChangingConfigurations is true when the old instance is destroyed, so the pending request is left for the recreated requester.
        host.recreate()
        assertFalse(result.isCompleted)

        val next = permission.attach { }
        assertFalse(result.isCompleted)
        next.onResult(true)
        assertTrue(result.await())
    }
}
