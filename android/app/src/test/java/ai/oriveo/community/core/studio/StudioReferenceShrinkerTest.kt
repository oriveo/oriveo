package ai.oriveo.community.core.studio

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.abs
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Shrinker cases shared by name across iOS / Android / Web: downscale, no upscale, alpha on white,
 * EXIF applied, undecodable input.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class StudioReferenceShrinkerTest {
    private fun encode(bitmap: Bitmap, format: Bitmap.CompressFormat): ByteArray =
        ByteArrayOutputStream().use { out ->
            assertTrue(bitmap.compress(format, 95, out))
            out.toByteArray()
        }

    private fun solid(width: Int, height: Int, color: Int): Bitmap =
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }

    private fun decode(bytes: ByteArray): Bitmap =
        checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)) { "output does not decode" }

    private suspend fun shrinkOk(bytes: ByteArray, mime: String): Bitmap {
        val result = StudioReferenceShrinker.shrink(bytes, mime)
        assertNotNull("shrink returned null", result)
        assertEquals("image/jpeg", result!!.second)
        return decode(result.first)
    }

    @Test
    fun `shrink downscales_long_edge`() = runTest {
        val png = encode(solid(3000, 1500, Color.RED), Bitmap.CompressFormat.PNG)
        val out = shrinkOk(png, "image/png")
        assertTrue("width ${out.width}", abs(out.width - 2048) <= 1)
        assertTrue("height ${out.height}", abs(out.height - 1024) <= 1)
    }

    @Test
    fun `shrink small_not_upscaled`() = runTest {
        val png = encode(solid(800, 600, Color.BLUE), Bitmap.CompressFormat.PNG)
        val out = shrinkOk(png, "image/png")
        assertEquals(800, out.width)
        assertEquals(600, out.height)
    }

    @Test
    fun `shrink alpha_flattened_white`() = runTest {
        val png = encode(solid(64, 64, Color.TRANSPARENT), Bitmap.CompressFormat.PNG)
        val out = shrinkOk(png, "image/png")
        val center = out.getPixel(out.width / 2, out.height / 2)
        assertTrue("red ${Color.red(center)}", Color.red(center) >= 250)
        assertTrue("green ${Color.green(center)}", Color.green(center) >= 250)
        assertTrue("blue ${Color.blue(center)}", Color.blue(center) >= 250)
    }

    @Test
    fun `shrink exif_applied`() = runTest {
        val file = File.createTempFile("reference", ".jpg")
        file.outputStream().use { solid(300, 100, Color.GREEN).compress(Bitmap.CompressFormat.JPEG, 95, it) }
        ExifInterface(file.absolutePath).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val jpeg = file.readBytes().also { file.delete() }

        val result = StudioReferenceShrinker.shrink(jpeg, "image/jpeg")
        assertNotNull("shrink returned null", result)
        val out = decode(result!!.first)
        assertEquals(100, out.width)
        assertEquals(300, out.height)
        val orientation = ExifInterface(result.first.inputStream())
            .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED)
        assertTrue(
            "orientation=$orientation",
            orientation == ExifInterface.ORIENTATION_UNDEFINED || orientation == ExifInterface.ORIENTATION_NORMAL,
        )
    }

    @Test
    fun `shrink undecodable_returns_null`() = runTest {
        assertNull(StudioReferenceShrinker.shrink("not an image".toByteArray(), "image/png"))
    }
}
