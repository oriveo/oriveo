package ai.oriveo.community.core.model

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.Executor

/**
 * No disk I/O at startup: constructing the capability-preference sync coordinator must not call getSharedPreferences (the first screen builds it on the main thread via SyncManager).
 * Reading prefs and registering the listener moves to the injected executor; after it runs, value changes still publish as before, with no extra publishes.
 */
@RunWith(RobolectricTestRunner::class)
class CapabilityPreferenceSyncStartupIoTest {
    private val app: Context get() = RuntimeEnvironment.getApplication()
    private val transport = "r1.b3BlbmFpX2NoYXQ.cnVudGltZS1yNw"
    private val providerID = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"

    /** Counts getSharedPreferences calls; applicationContext returns this, so production code that reads applicationContext is still counted. */
    private class CountingContext(base: Context) : ContextWrapper(base) {
        var prefsCalls = 0
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
            prefsCalls += 1
            return super.getSharedPreferences(name, mode)
        }
    }

    /** Collects tasks without running them; the test case drives them manually. */
    private class DeferredExecutor : Executor {
        val pending = mutableListOf<Runnable>()
        override fun execute(command: Runnable) { pending += command }
        fun runAll() { pending.toList().also { pending.clear() }.forEach { it.run() } }
    }

    @Before
    fun clearStores() {
        listOf("capability_preference_settings", "capability_preference_drafts")
            .forEach { app.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit() }
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun setWeb(web: CapabilityWebPreference) =
        CapabilityPreferenceStore.from(app).setConnectionModel(
            CapabilityPreferenceValues(web, null), providerID, "gpt-test", transport,
        )

    @Test
    fun coordinatorInit_doesNotTouchDisk() {
        val context = CountingContext(app)
        val executor = DeferredExecutor()
        CapabilityPreferenceSyncCoordinator(context, executor)
        assertEquals("SharedPreferences must not be read during construction", 0, context.prefsCalls)
        assertEquals("registration must be handed to the injected executor", 1, executor.pending.size)

        executor.runAll()
        assertEquals("the executor reads one prefs instance to register the listener", 1, context.prefsCalls)
    }

    @Test
    fun coordinator_publishesAfterBackgroundRegistration() {
        val context = CountingContext(app)
        val executor = DeferredExecutor()
        val coordinator = CapabilityPreferenceSyncCoordinator(context, executor)
        val published = mutableListOf<Map<String, Any>>()
        coordinator.bind { published += it }
        idle()
        assertEquals("local store is empty, so the first publish on bind is blocked by the empty-envelope gate", 0, published.size)

        executor.runAll()
        idle()
        assertEquals("the initial reconciliation after registration also sends nothing while the local store is empty", 0, published.size)

        setWeb(CapabilityWebPreference.Force)
        idle()
        assertEquals("changing one key still triggers the existing publish", 1, published.size)
        @Suppress("UNCHECKED_CAST")
        val records = published.single()["records"] as List<Map<String, Any>>
        assertEquals(providerID.lowercase(), records.single()["providerId"])
        coordinator.unbind()
    }

    @Test
    fun bindBeforeRegistration_publishesOnce() {
        val context = CountingContext(app)
        val executor = DeferredExecutor()
        val coordinator = CapabilityPreferenceSyncCoordinator(context, executor)
        val published = mutableListOf<Map<String, Any>>()
        // Bind before registration has run, then register: both the bind-time publish and the post-registration reschedule are blocked while the local store is empty, so no empty packet is sent.
        coordinator.bind { published += it }
        executor.runAll()
        idle()
        assertEquals("while the local store is empty, neither the bind-time publish nor the post-registration reschedule sends", 0, published.size)

        setWeb(CapabilityWebPreference.Force)
        idle()
        assertEquals("after registration completes, a value change publishes once", 1, published.size)
        coordinator.unbind()
    }
}
