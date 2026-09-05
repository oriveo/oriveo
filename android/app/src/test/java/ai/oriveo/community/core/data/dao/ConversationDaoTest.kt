package ai.oriveo.community.core.data.dao

import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationDaoTest {

    @Test
    fun `conversation dao exposes home pagination query methods`() {
        val methodNames = ConversationDao::class.java.methods.map { it.name }.toSet()

        assertTrue(methodNames.contains("observeUngroupedRecentWithCount"))
        assertTrue(methodNames.contains("observeUngroupedEarlierWithCount"))
        assertTrue(methodNames.contains("observeUngroupedEarlierCount"))
    }
}
