package ai.oriveo.community.ui.theme

import android.graphics.drawable.VectorDrawable
import androidx.core.content.ContextCompat
import ai.oriveo.community.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * `res/drawable/ph_*.xml` is generated from the Phosphor SVG sources.
 * Inflate each one for real to prove AAPT accepts the expanded pathData (unstable shorthand parsing is a long-standing Android pitfall).
 */
@RunWith(RobolectricTestRunner::class)
class PhosphorDrawableTest {

    @Test
    fun everyGeneratedPhosphorDrawableInflatesAsVector() {
        val context = RuntimeEnvironment.getApplication()
        val ids = R.drawable::class.java.fields.filter { it.name.startsWith("ph_") }
        assertTrue("no ph_* drawables found", ids.isNotEmpty())
        // Every icon ships as a regular + duotone pair.
        val names = ids.map { it.name }.toSet()
        val regulars = names.filterNot { it.endsWith("_duotone") }
        assertEquals(regulars.size * 2, names.size)
        for (regular in regulars) assertTrue("$regular has no duotone twin", "${regular}_duotone" in names)
        for (field in ids) {
            val drawable = ContextCompat.getDrawable(context, field.getInt(null))
            assertTrue("${field.name} is not a VectorDrawable", drawable is VectorDrawable)
        }
    }
}
