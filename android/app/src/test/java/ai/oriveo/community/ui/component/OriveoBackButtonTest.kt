package ai.oriveo.community.ui.component

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTheme
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.w3c.dom.Element

/**
 * Shared back and close buttons: the glyphs use the same paths as iOS and web, the touch target is 48dp,
 * screen readers announce a labelled button, and a tap runs the caller's action.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class OriveoBackButtonTest {

    // The v2 rule runs on StandardTestDispatcher: wait for idle after composing and after clicking
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val ns = "http://schemas.android.com/apk/res/android"

    private fun drawable(name: String) = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder()
        .parse(File("src/main/res/drawable/$name.xml"))

    @Test
    fun `chevron drawable uses the shared design path and mirrors in RTL`() {
        val doc = drawable("ic_oriveo_back")
        val vector = doc.documentElement
        assertEquals("true", vector.getAttributeNS(ns, "autoMirrored"))
        assertEquals("22dp", vector.getAttributeNS(ns, "width"))
        assertEquals("24", vector.getAttributeNS(ns, "viewportWidth"))
        val path = doc.getElementsByTagName("path").item(0) as Element
        assertEquals("M14.5 5.5L8 12l6.5 6.5", path.getAttributeNS(ns, "pathData"))
        assertEquals("2.2", path.getAttributeNS(ns, "strokeWidth"))
        assertEquals("round", path.getAttributeNS(ns, "strokeLineCap"))
        assertEquals("round", path.getAttributeNS(ns, "strokeLineJoin"))
    }

    @Test
    fun `close drawable uses the shared design cross path`() {
        val doc = drawable("ic_oriveo_close")
        assertEquals("22dp", doc.documentElement.getAttributeNS(ns, "width"))
        val path = doc.getElementsByTagName("path").item(0) as Element
        assertEquals("M7 7l10 10M17 7L7 17", path.getAttributeNS(ns, "pathData"))
        assertEquals("2", path.getAttributeNS(ns, "strokeWidth"))
        assertEquals("round", path.getAttributeNS(ns, "strokeLineCap"))
    }

    @Test
    fun `back button is a 48dp labelled button that runs the caller action`() {
        var clicks = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                OriveoBackButton(onClick = { clicks += 1 })
            }
        }
        composeRule.waitForIdle()

        val back = activity.getString(ai.oriveo.community.R.string.back)
        composeRule.onNodeWithContentDescription(back)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertWidthIsEqualTo(48.dp)
            .assertHeightIsEqualTo(48.dp)
            .performClick()
        composeRule.waitForIdle()
        assertEquals(1, clicks)
    }

    @Test
    fun `close button is a 48dp labelled button that runs the caller action`() {
        var clicks = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                OriveoCloseButton(onClick = { clicks += 1 }, contentDescription = "Close")
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithContentDescription("Close")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertWidthIsEqualTo(48.dp)
            .assertHeightIsEqualTo(48.dp)
            .performClick()
        composeRule.waitForIdle()
        assertEquals(1, clicks)
    }
}
