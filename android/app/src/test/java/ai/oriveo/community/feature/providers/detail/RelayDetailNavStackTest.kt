package ai.oriveo.community.feature.providers.detail

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Detail page sub-page layers (NAV-RELAY-01 to 03): the production stack type [RelayDetailNavStack] is pushed / popped layer by layer,
 * its encoding round-trips (rememberSaveable restore); the detail page uses it plus one BackHandler to go back layer by layer.
 */
class RelayDetailNavStackTest {

    private fun restored(stack: RelayDetailNavStack): RelayDetailNavStack =
        RelayDetailNavStack.decode(RelayDetailNavStack.encode(stack))

    @Test
    fun `NAV-RELAY-01 detail to library to advanced pops twice back to detail`() {
        var stack = RelayDetailNavStack()
        assertTrue(stack.isEmpty)
        stack = stack.push(RelayDetailLayer.Library())
        assertTrue(stack.showsLibrary)
        stack = stack.push(RelayDetailLayer.Advanced("gpt-4o", readOnly = false))
        assertEquals(RelayDetailLayer.Advanced("gpt-4o", readOnly = false), stack.advanced)
        // Layers are restored unchanged after rotation / process recreation.
        assertEquals(stack, restored(stack))

        stack = stack.pop()
        assertEquals(RelayDetailLayer.Library(), stack.top)
        assertNull(stack.advanced)
        stack = stack.pop()
        assertTrue("two backs return to the detail page", stack.isEmpty)
        assertFalse(stack.showsLibrary)
    }

    @Test
    fun `NAV-RELAY-02 detail to keys pops once back to detail`() {
        var stack = RelayDetailNavStack().push(RelayDetailLayer.Keys)
        assertTrue(stack.showsKeys)
        assertFalse(stack.showsLibrary)
        assertEquals(stack, restored(stack))
        stack = stack.pop()
        assertTrue(stack.isEmpty)
        assertFalse(stack.showsKeys)
    }

    @Test
    fun `NAV-RELAY-03 read-only advanced from the library pops once back to the library`() {
        var stack = RelayDetailNavStack()
            .push(RelayDetailLayer.Library())
            .push(RelayDetailLayer.Advanced("vendor/model|v2", readOnly = true))
        assertEquals(true, stack.advanced?.readOnly)
        // A model id may contain `/` and `|`, and the encoding still round-trips.
        assertEquals(stack, restored(stack))
        stack = stack.pop()
        assertEquals(RelayDetailLayer.Library(), stack.top)
        assertTrue(stack.showsLibrary)
    }

    @Test
    fun `NAV-RELAY screen keeps one saveable stack and pops one layer per back`() {
        val screen = File("src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt")
            .takeIf { it.exists() }
            ?: File("app/src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailScreen.kt")
        val text = screen.readText()
        assertTrue("the layer stack must be saveable", "rememberSaveable(stateSaver = RelayDetailNavStack.Saver)" in text)
        assertTrue("back pops only one layer at a time", "BackHandler(enabled = !relayNavStack.isEmpty)" in text)
        assertFalse("the old non-saveable sub-page flag no longer exists", "var showModelLibrary by remember" in text)
        assertFalse("the old non-saveable advanced page id no longer exists", "var advancedModelID" in text)
    }
}
