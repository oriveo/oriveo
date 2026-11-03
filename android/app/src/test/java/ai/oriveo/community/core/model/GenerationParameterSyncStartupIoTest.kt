package ai.oriveo.community.core.model

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * No disk I/O at startup: neither Ledger.from nor the coordinator constructor may call getSharedPreferences (the first call loads the XML synchronously,
 * and Koin singletons are often resolved on the main thread).
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
        GenerationParameterSyncCoordinator(context)
        assertEquals("construction must not fetch SharedPreferences", 0, context.prefsCalls)
    }
}
