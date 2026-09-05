package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderConnectionStateTest {

    @Test
    fun `Connected title returns Connected`() {
        assertEquals("Connected", ProviderConnectionState.Connected.title)
    }

    @Test
    fun `Syncing title returns Syncing`() {
        assertEquals("Syncing", ProviderConnectionState.Syncing.title)
    }

    @Test
    fun `Issue title returns Issue`() {
        assertEquals("Issue", ProviderConnectionState.Issue("some error").title)
    }

    @Test
    fun `Issue preserves error message`() {
        val message = "API key expired"
        val state = ProviderConnectionState.Issue(message)
        assertEquals(message, (state as ProviderConnectionState.Issue).message)
    }

    @Test
    fun `Issue with empty message`() {
        val state = ProviderConnectionState.Issue("")
        assertEquals("Issue", state.title)
        assertEquals("", state.message)
    }
}
