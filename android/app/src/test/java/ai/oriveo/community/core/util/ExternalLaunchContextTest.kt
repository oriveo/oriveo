package ai.oriveo.community.core.util

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.view.ContextThemeWrapper
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The notice page's "update in store" action calls [openExternalUrl] with the application context, and the
 * Custom Tabs intent carries no NEW_TASK flag, so a real device throws AndroidRuntimeException.
 * This test intercepts the Intent that is actually launched and checks its flags.
 */
@RunWith(RobolectricTestRunner::class)
class ExternalLaunchContextTest {

    private val url = "https://play.google.com/store/apps/details?id=ai.oriveo.community"

    @Test
    fun custom_tabs_from_application_context_adds_new_task() {
        val app = ApplicationProvider.getApplicationContext<Application>()

        assertTrue(openExternalUrl(app, url))

        val started = shadowOf(app).nextStartedActivity
        assertNotNull("an Activity should have been started", started)
        assertEquals(Intent.ACTION_VIEW, started.action)
        assertEquals(url, started.dataString)
        assertTrue(
            "launching from a non-Activity context must carry FLAG_ACTIVITY_NEW_TASK",
            started.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0,
        )
    }

    @Test
    fun custom_tabs_from_activity_context_keeps_task() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        // Compose's LocalContext is often a wrapped ContextWrapper: follow baseContext to find the Activity.
        val wrapped = ContextThemeWrapper(activity, 0)

        assertTrue(openExternalUrl(wrapped, url))

        val started = shadowOf(activity).nextStartedActivity
        assertNotNull("should launch from the Activity", started)
        assertEquals(url, started.dataString)
        assertEquals(
            "an Activity context adds no NEW_TASK, so Custom Tabs stays in this task and returns here",
            0,
            started.flags and Intent.FLAG_ACTIVITY_NEW_TASK,
        )
    }
}
