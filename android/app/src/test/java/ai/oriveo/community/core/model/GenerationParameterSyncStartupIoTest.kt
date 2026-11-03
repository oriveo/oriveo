package ai.oriveo.community.core.model

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.os.Looper
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.Executor

/**
 * No disk I/O at startup: neither Ledger.from nor the coordinator constructor may call getSharedPreferences (the first call loads the XML synchronously,
 * and Koin singletons are often resolved on the main thread). Fetching prefs and registering listeners moves to the injected executor; values changed after that still publish as before.
 */
@RunWith(RobolectricTestRunner::class)
class GenerationParameterSyncStartupIoTest {
    private val app: Context get() = RuntimeEnvironment.getApplication()

    /** Counts getSharedPreferences calls; applicationContext returns this, so production code that reads applicationContext is still counted. */
    private class CountingContext(base: Context) : ContextWrapper(base) {
        var prefsCalls = 0
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences {
            prefsCalls += 1
            return super.getSharedPreferences(name, mode)
        }
    }

    /** Collects tasks without running them; each test drives them manually. */
    private class DeferredExecutor : Executor {
        val pending = mutableListOf<Runnable>()
        override fun execute(command: Runnable) { pending += command }
        fun runAll() { pending.toList().also { pending.clear() }.forEach { it.run() } }
    }

    @Before
    fun clearStores() {
        listOf(
            GenerationParameterSettingsStore.PREFS_NAME,
            GenerationParameterPresetStore.PREFS_NAME,
            GenerationParameterSyncLedger.PREFS_NAME,
        ).forEach { app.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit() }
    }

    @Test
    fun ledgerFrom_doesNotTouchDiskUntilFirstRead() {
        val context = CountingContext(app)
        val ledger = GenerationParameterSyncLedger.from(context)
        assertEquals("construction must not fetch SharedPreferences", 0, context.prefsCalls)

        assertEquals(emptyList<GenerationParameterSyncTombstone>(), ledger.all())
        assertEquals("fetched only on the first read", 1, context.prefsCalls)
        ledger.all()
        assertEquals("prefs fetched only once", 1, context.prefsCalls)
    }

    @Test
    fun coordinatorInit_doesNotTouchDisk() {
        val context = CountingContext(app)
        val executor = DeferredExecutor()
        GenerationParameterSyncCoordinator(context, executor)
        assertEquals("construction must not fetch SharedPreferences", 0, context.prefsCalls)
        assertEquals("registration must be handed to the injected executor", 1, executor.pending.size)

        executor.runAll()
        assertEquals("executor fetches 3 prefs to register listeners", 3, context.prefsCalls)
    }

    @Test
    fun coordinator_publishesAfterBackgroundRegistration() {
        val context = CountingContext(app)
        val executor = DeferredExecutor()
        val coordinator = GenerationParameterSyncCoordinator(context, executor)
        val published = mutableListOf<Map<String, Any>>()
        coordinator.bind { published += it }
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("all local data empty, so the first publish on bind is blocked by the empty-envelope gate", 0, published.size)

        executor.runAll()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("the initial reconcile after registration also sends nothing outbound when local data is empty", 0, published.size)

        GenerationParameterSettingsStore.from(app).setModelDefaults(
            GenerationParameterOverrides(
                mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4))),
            ),
            providerID = "9A1195DE-3AF9-5888-ABC8-B8177C458C07", modelID = "gpt-test",
        )
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals("changing one key still triggers the original publish", 1, published.size)
        @Suppress("UNCHECKED_CAST")
        val records = published.single()["records"] as List<Map<String, Any>>
        assertTrue(records.single()["modelId"] == "gpt-test")
        coordinator.unbind()
    }
}
