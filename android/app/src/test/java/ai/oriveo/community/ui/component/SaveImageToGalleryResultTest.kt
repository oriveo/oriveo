package ai.oriveo.community.ui.component

import android.content.ContentResolver
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Image viewer "Save to Photos": the return value must be the real outcome. On failure the button must
 * not show the "saved" check mark, and an error toast is shown. Runs the production
 * [saveImageToGallery] and replaces only the ContentResolver system boundary.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SaveImageToGalleryResultTest {

    private val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
    private val uri = Uri.parse("content://media/external/images/media/42")

    @Test
    fun `insert failure reports false and shows error toast`() = runBlocking {
        val resolver = mockk<ContentResolver>(relaxed = true)
        every { resolver.insert(any(), any()) } returns null
        val snackbar = GlobalSnackbarManager()

        assertFalse(saveImageToGallery(contextWith(resolver), bitmap, snackbar))
        assertSaveFailedToast(snackbar)
    }

    @Test
    fun `unopenable output stream reports false and removes the pending row`() = runBlocking {
        val resolver = mockk<ContentResolver>(relaxed = true)
        every { resolver.insert(any(), any()) } returns uri
        every { resolver.openOutputStream(uri) } returns null
        val snackbar = GlobalSnackbarManager()

        assertFalse(saveImageToGallery(contextWith(resolver), bitmap, snackbar))
        assertSaveFailedToast(snackbar)
        verify { resolver.delete(uri, null, null) }
    }

    @Test
    fun `successful write reports true without toast`() = runBlocking {
        val resolver = mockk<ContentResolver>(relaxed = true)
        val out = ByteArrayOutputStream()
        every { resolver.insert(any(), any()) } returns uri
        every { resolver.openOutputStream(uri) } returns out
        val snackbar = GlobalSnackbarManager()

        assertTrue(saveImageToGallery(contextWith(resolver), bitmap, snackbar))
        assertTrue("JPEG bytes must be written", out.size() > 0)
        assertNull(snackbar.active.value)
        verify(exactly = 0) { resolver.delete(any(), any(), any()) }
    }

    @Test
    fun `viewer only flips to saved when save succeeded`() {
        val source = File("src/main/java/ai/oriveo/community/ui/component/ImageViewerSheet.kt").readText()
        val onClick = source.substringAfter("scope.launch {").substringBefore("R.string.save_to_photos")
        assertTrue(onClick.contains("if (saveImageToGallery(context, bmp, snackbar))"))
        assertTrue(onClick.indexOf("savedToPhotos = true") > onClick.indexOf("if (saveImageToGallery("))
    }

    private fun assertSaveFailedToast(snackbar: GlobalSnackbarManager) {
        val message = snackbar.active.value?.message
        assertEquals(GlobalToastStyle.Error, message?.style)
        assertEquals(R.string.save_failed, (message?.message as UiText.Resource).resId)
    }

    private fun contextWith(resolver: ContentResolver): Context =
        object : ContextWrapper(RuntimeEnvironment.getApplication()) {
            override fun getContentResolver(): ContentResolver = resolver
        }
}
