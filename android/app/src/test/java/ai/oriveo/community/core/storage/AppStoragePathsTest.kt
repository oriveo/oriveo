package ai.oriveo.community.core.storage

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppStoragePathsTest {
    /** Counts getCacheDir / getFilesDir calls: both system methods hit the disk on every call. */
    private class CountingContext(base: Context) : ContextWrapper(base) {
        var cacheDirCalls = 0
        var filesDirCalls = 0
        override fun getCacheDir(): File { cacheDirCalls++; return super.getCacheDir() }
        override fun getFilesDir(): File { filesDirCalls++; return super.getFilesDir() }
    }

    @Test fun cacheAndFilesPaths_doNotTouchDisk() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val ctx = CountingContext(app)

        val cache = AppStoragePaths.cacheDir(ctx)
        val files = AppStoragePaths.filesDir(ctx)

        assertEquals(0, ctx.cacheDirCalls)
        assertEquals(0, ctx.filesDirCalls)
        assertEquals(app.cacheDir.absolutePath, cache.absolutePath)
        assertEquals(app.filesDir.absolutePath, files.absolutePath)
    }
}
