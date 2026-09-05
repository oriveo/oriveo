package ai.oriveo.community.core.model

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test


class CapabilityExecutionCollectorWebDispatchTest {

    private var fired = 0

    private fun collector() = CapabilityExecutionCollector(onWebSearchDispatched = { fired += 1 })

    private fun CapabilityExecutionCollector.compileWeb(owner: String = "web") = recordCompiled(
        owner = owner,
        evidenceSignals = listOf(CapabilityResponseEvidenceSignal("citations", "/citations", nonEmpty = true)),
        revision = "rev-1",
        recipeRef = "openai.$owner.v1",
    )

    @Test
    fun `web recipe that reaches the wire fires exactly once`() = runTest {
        val collector = collector()
        collector.compileWeb()
        collector.confirmDispatched()

        assertEquals(1, fired)
    }

    @Test
    fun `repeated dispatch confirmation never double counts one send`() = runTest {
        val collector = collector()
        collector.compileWeb()
        
        collector.confirmDispatched()
        collector.confirmDispatched()
        collector.confirmDispatched()

        assertEquals(1, fired)
    }

    @Test
    fun `compiled but never dispatched request does not count as usage`() = runTest {
        val collector = collector()
        collector.compileWeb()

        assertEquals(0, fired)
    }

    @Test
    fun `other capability owners never masquerade as web search`() = runTest {
        val collector = collector()
        collector.compileWeb(owner = "reasoning")
        collector.compileWeb(owner = "generation")
        collector.confirmDispatched()

        assertEquals(0, fired)
    }

    @Test
    fun `local custom web fragment on the wire counts as usage`() = runTest {
        val collector = collector()
        collector.recordCustom(owner = "web", revision = null, appliedPointers = setOf("/enable_search"))
        collector.confirmDispatched()

        assertEquals(1, fired)
    }

    @Test
    fun `legacy injection without a runtime recipe still counts`() = runTest {
        val collector = collector()
        collector.noteLegacyWebSearchDispatched()
        collector.confirmDispatched()

        assertEquals(1, fired)
    }

    @Test
    fun `a send with no web configuration at all reports nothing`() = runTest {
        val collector = collector()
        collector.confirmDispatched()

        assertEquals(0, fired)
    }
}
