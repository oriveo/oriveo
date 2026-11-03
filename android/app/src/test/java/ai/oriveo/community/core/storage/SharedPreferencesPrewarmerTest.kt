package ai.oriveo.community.core.storage

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/** Cold-start background prewarm of every xml file under shared_prefs. */
@RunWith(RobolectricTestRunner::class)
class SharedPreferencesPrewarmerTest {

    private val app: Context = ApplicationProvider.getApplicationContext()
    private val prefsDir: File get() = File(app.applicationInfo.dataDir, "shared_prefs")
    private val extraFiles = mutableListOf<File>()

    @After
    fun tearDown() {
        listOf("prewarm_a", "prewarm_b").forEach {
            app.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()
        }
        extraFiles.forEach { it.delete() }
    }

    @Test
    fun prewarm_loadsEveryPrefsFile() {
        app.getSharedPreferences("prewarm_a", Context.MODE_PRIVATE).edit().putString("k", "v").commit()
        app.getSharedPreferences("prewarm_b", Context.MODE_PRIVATE).edit().putInt("n", 7).commit()
        val recording = RecordingAppContext(app)

        val warmed = SharedPreferencesPrewarmer.prewarm(recording)

        assertTrue(warmed.containsAll(listOf("prewarm_a", "prewarm_b")))
        assertEquals(warmed.toSet(), recording.requested.toSet())
        // Read only; values unchanged
        assertEquals("v", app.getSharedPreferences("prewarm_a", Context.MODE_PRIVATE).getString("k", null))
        assertEquals(7, app.getSharedPreferences("prewarm_b", Context.MODE_PRIVATE).getInt("n", 0))
    }

    @Test
    fun prewarm_ignoresNonXmlAndBak() {
        app.getSharedPreferences("prewarm_a", Context.MODE_PRIVATE).edit().putString("k", "v").commit()
        prefsDir.mkdirs()
        listOf("prewarm_a.xml.bak", "notes.txt", ".xml").forEach { name ->
            File(prefsDir, name).also { it.writeText("x"); extraFiles += it }
        }
        File(prefsDir, "subdir.xml").also { it.mkdirs(); extraFiles += it }
        val recording = RecordingAppContext(app)

        val warmed = SharedPreferencesPrewarmer.prewarm(recording)

        assertTrue("prewarm_a" in warmed)
        listOf("prewarm_a.xml", "notes.txt", "notes", "", "subdir", "prewarm_a.xml.bak").forEach {
            assertTrue("unexpected $it", it !in recording.requested)
        }
    }

    @Test
    fun prewarm_usesApplicationContext() {
        app.getSharedPreferences("prewarm_a", Context.MODE_PRIVATE).edit().putString("k", "v").commit()
        val appContext = RecordingAppContext(app)
        val outer = OuterContext(appContext)

        SharedPreferencesPrewarmer.prewarm(outer)

        assertEquals(0, outer.directCalls)
        assertTrue("prewarm_a" in appContext.requested)
    }

    /** Is its own applicationContext; records the requested prefs names. */
    private class RecordingAppContext(base: Context) : ContextWrapper(base) {
        val requested = mutableListOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            requested += name
            return super.getSharedPreferences(name, mode)
        }
    }

    /** Outer context that is not the application context: fetching prefs directly on it counts as a violation. */
    private class OuterContext(private val appContext: Context) : ContextWrapper(appContext) {
        var directCalls = 0
        override fun getApplicationContext(): Context = appContext
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            directCalls += 1
            return super.getSharedPreferences(name, mode)
        }
    }
}
