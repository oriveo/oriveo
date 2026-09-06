package ai.oriveo.community.feature.home

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import java.util.Calendar

class HomeViewModelTest {
    @Test
    fun `home header action buttons use compact lightweight toolbar sizing`() {
        assertEquals(8, HOME_HEADER_ACTION_SPACING_DP)
        assertEquals(40, HOME_HEADER_ACTION_BUTTON_SIZE_DP)
        assertEquals(20, HOME_HEADER_ACTION_ICON_SIZE_DP)
    }

    @Test
    fun `home hero pill model name strips vendor prefix and free suffix`() {
        assertEquals("DeepSeek V4 Flash", homeHeroPillModelName("DeepSeek: DeepSeek V4 Flash"))
        assertEquals("LFM2.5-1.2B-Instruct", homeHeroPillModelName("LiquidAI: LFM2.5-1.2B-Instruct (free)"))
        assertEquals("GPT-5.4", homeHeroPillModelName("GPT-5.4"))
    }

    @Test
    fun `classifyDate returns Today for current time`() {
        assertEquals(DateGroup.Today, classifyDate(System.currentTimeMillis()))
    }

    @Test
    fun `classifyDate returns Yesterday for yesterday timestamp`() {
        val cal = Calendar.getInstance()
        val todayStart = cal.apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val yesterdayTs = todayStart - 1000
        assertEquals(DateGroup.Yesterday, classifyDate(yesterdayTs))
    }

    @Test
    fun `classifyDate returns PastSevenDays for 3 days ago`() {
        val threeDaysAgo = System.currentTimeMillis() - 3 * 24 * 60 * 60 * 1000L
        assertEquals(DateGroup.PastSevenDays, classifyDate(threeDaysAgo))
    }

    @Test
    fun `classifyDate returns Earlier for 30 days ago`() {
        val thirtyDaysAgo = System.currentTimeMillis() - 30L * 24 * 60 * 60 * 1000L
        assertEquals(DateGroup.Earlier, classifyDate(thirtyDaysAgo))
    }

    @Test
    fun `classifyDate returns Today for start of today`() {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        assertEquals(DateGroup.Today, classifyDate(cal.timeInMillis))
    }

    // ── groupConversationsByDate ──

    @Test
    fun `groupConversationsByDate groups correctly`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "Today Chat", updatedAt = now),
            makeConversation("2", "Old Chat", updatedAt = now - 30L * 24 * 60 * 60 * 1000L),
        )
        val groups = groupConversationsByDate(conversations)
        assertTrue("Should have at least 2 groups", groups.size >= 2)
        assertEquals(DateGroup.Today, groups.first().first)
    }

    @Test
    fun `groupConversationsByDate sorted by group order`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "Old", updatedAt = now - 30L * 24 * 60 * 60 * 1000L),
            makeConversation("2", "Today", updatedAt = now),
        )
        val groups = groupConversationsByDate(conversations)
        if (groups.size >= 2) {
            assertTrue(
                "Today should come before Earlier",
                groups[0].first.order < groups[1].first.order,
            )
        }
    }

    @Test
    fun `groupConversationsByDate empty list returns empty`() {
        val groups = groupConversationsByDate(emptyList())
        assertTrue(groups.isEmpty())
    }

    @Test
    fun `groupConversationsByDate single item`() {
        val conversations = listOf(makeConversation("1", "Solo"))
        val groups = groupConversationsByDate(conversations)
        assertEquals(1, groups.size)
        assertEquals(1, groups.first().second.size)
    }

    @Test
    fun `groupConversationsByDate multiple in same group`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "Chat 1", updatedAt = now),
            makeConversation("2", "Chat 2", updatedAt = now - 1000),
        )
        val groups = groupConversationsByDate(conversations)
        assertEquals(1, groups.size)
        assertEquals(2, groups.first().second.size)
    }

    @Test
    fun `earlier section limits visible rows in normal mode`() {
        val conversations = (1..12).map { index ->
            makeConversation(index.toString(), "Conversation $index")
        }

        val display = resolveHomeSectionDisplay(
            group = DateGroup.Earlier,
            conversations = conversations,
            isEditing = false,
            earlierDisplayCount = 10,
        )

        assertEquals(10, display.conversations.size)
        assertEquals(2, display.remainingCount)
        assertEquals(
            listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "10"),
            display.conversations.map { it.id },
        )
    }

    @Test
    fun `earlier section shows all rows while editing`() {
        val conversations = (1..12).map { index ->
            makeConversation(index.toString(), "Conversation $index")
        }

        val display = resolveHomeSectionDisplay(
            group = DateGroup.Earlier,
            conversations = conversations,
            isEditing = true,
            earlierDisplayCount = 10,
        )

        assertEquals(conversations, display.conversations)
        assertEquals(0, display.remainingCount)
    }

    @Test
    fun `non earlier section does not paginate`() {
        val conversations = (1..8).map { index ->
            makeConversation(index.toString(), "Conversation $index")
        }

        val display = resolveHomeSectionDisplay(
            group = DateGroup.Today,
            conversations = conversations,
            isEditing = false,
            earlierDisplayCount = 10,
        )

        assertEquals(conversations, display.conversations)
        assertEquals(0, display.remainingCount)
    }

    // ── DateGroup ordering ──

    @Test
    fun `DateGroup ordering is correct`() {
        assertTrue(DateGroup.Today.order < DateGroup.Yesterday.order)
        assertTrue(DateGroup.Yesterday.order < DateGroup.PastSevenDays.order)
        assertTrue(DateGroup.PastSevenDays.order < DateGroup.Earlier.order)
    }

    @Test
    fun `DateGroup values are exhaustive`() {
        assertEquals(4, DateGroup.entries.size)
    }

    @Test
    fun `classifyDate handles epoch zero`() {
        assertEquals(DateGroup.Earlier, classifyDate(0L))
    }

    @Test
    fun `classifyDate handles very far future`() {
        val future = System.currentTimeMillis() + 365L * 24 * 60 * 60 * 1000L
        assertEquals(DateGroup.Today, classifyDate(future))
    }

    @Test
    fun `resolveBackendDomainLabel returns host and port for local url`() {
        assertEquals(
            "dev-machine.local:8080",
            resolveBackendDomainLabel("http://dev-machine.local:8080/"),
        )
    }

    @Test
    fun `resolveBackendDomainLabel returns host for production url`() {
        assertEquals(
            "catalog.example.com",
            resolveBackendDomainLabel("https://catalog.example.com"),
        )
    }

    /**
     * A build configured with an empty catalog base URL fetches no catalog at all. The label has
     * no host to report, and the caller substitutes a localized placeholder, so the one thing this
     * function must not do is invent a host.
     */
    @Test
    fun `resolveBackendDomainLabel is empty when no catalog url is configured`() {
        assertEquals("", resolveBackendDomainLabel(""))
        assertEquals("", resolveBackendDomainLabel("   "))
        assertEquals("", resolveBackendDomainLabel("/"))
    }

    @Test
    fun `groupConversationsByFolder groups and sorts once per folder`() {
        val now = System.currentTimeMillis()
        val grouped = groupConversationsByFolder(
            listOf(
                makeConversation("older", "Older", updatedAt = now - 2_000, folderID = "folder-a"),
                makeConversation("newer", "Newer", updatedAt = now - 1_000, folderID = "folder-a"),
                makeConversation("other", "Other", updatedAt = now - 500, folderID = "folder-b"),
                makeConversation("top-level", "Top Level", updatedAt = now),
            ),
        )

        assertEquals(listOf("newer", "older"), grouped.getValue("folder-a").map { it.id })
        assertEquals(listOf("other"), grouped.getValue("folder-b").map { it.id })
        assertFalse(grouped.containsKey(""))
    }

    private fun makeConversation(
        id: String,
        title: String,
        updatedAt: Long = System.currentTimeMillis(),
        folderID: String? = null,
    ) = Conversation(
        id = id,
        title = title,
        providerID = "p1",
        providerKind = ProviderKind.OpenAI,
        modelID = "m1",
        updatedAt = updatedAt,
        folderID = folderID,
    )

    @Test
    fun `TC-7-1-1 conversations in folders excluded from time groups`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "In Folder", updatedAt = now, folderID = "folder-1"),
            makeConversation("2", "No Folder", updatedAt = now),
        )
        val groups = groupConversationsByDate(conversations)
        val allGrouped = groups.flatMap { it.second }
        assertFalse("folder conversation should not appear", allGrouped.any { it.id == "1" })
        assertTrue("unfiled conversation should appear", allGrouped.any { it.id == "2" })
    }

    @Test
    fun `TC-7-1-2 conversations without folder appear in time groups`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "Chat A", updatedAt = now),
            makeConversation("2", "Chat B", updatedAt = now - 1000),
        )
        val groups = groupConversationsByDate(conversations)
        val allGrouped = groups.flatMap { it.second }
        assertTrue(allGrouped.any { it.id == "1" })
        assertTrue(allGrouped.any { it.id == "2" })
    }

    @Test
    fun `TC-7-1-3 all conversations in folders result in empty time groups`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "A", updatedAt = now, folderID = "folder-1"),
            makeConversation("2", "B", updatedAt = now, folderID = "folder-2"),
        )
        val groups = groupConversationsByDate(conversations)
        assertTrue("all in folders so no groups", groups.isEmpty())
    }

    @Test
    fun `TC-7-1-6 mixed conversations only unfiled appear in groups`() {
        val now = System.currentTimeMillis()
        val conversations = listOf(
            makeConversation("1", "Unfiled A", updatedAt = now),
            makeConversation("2", "In Folder", updatedAt = now, folderID = "folder-1"),
            makeConversation("3", "Unfiled B", updatedAt = now - 1000),
        )
        val groups = groupConversationsByDate(conversations)
        val allGrouped = groups.flatMap { it.second }
        assertEquals(2, allGrouped.size)
        assertFalse(allGrouped.any { it.folderID != null })
    }
}
