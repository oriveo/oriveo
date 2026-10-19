package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryItemScope
import ai.oriveo.community.core.context.MemoryItems
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.context.MemoryLayer
import ai.oriveo.community.core.context.MemoryScopeType
import ai.oriveo.community.core.context.MemoryServerTime
import ai.oriveo.community.core.context.MemoryStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/** Settings › Memory: pure values of the grouped list and the editor. */
class MemoryItemListPresentationTest {

    @Test
    fun groups_in_list_order() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                item("p1", MemoryKind.DECISION, "Ship on Friday"),
                item("i1", MemoryKind.CONSTRAINT, "Never use emoji"),
                item("a1", MemoryKind.FACT, "Lives in Cairo"),
                item("pr1", MemoryKind.PREFERENCE, "Short answers"),
                item("a2", MemoryKind.IDENTITY, "Novelist", pinned = true),
                item("i2", MemoryKind.INSTRUCTION, "Answer in Arabic"),
                item("p2", MemoryKind.GOAL, "Finish draft"),
                item("p3", MemoryKind.PROJECT, "History novel"),
            ),
            deviceId = LOCAL,
        )

        assertEquals(
            listOf(MemoryItemGroup.About, MemoryItemGroup.Preferences, MemoryItemGroup.Instructions, MemoryItemGroup.Projects),
            presentation.sections.map { it.group },
        )
        // Within a group by listOrder: pinned first.
        assertEquals("a2", presentation.sections.first().rows.first().item.id)
        assertTrue(presentation.sections.first().rows.first().pinned)
        assertEquals(setOf("a1", "a2"), presentation.sections[0].rows.map { it.item.id }.toSet())
        assertEquals(setOf("i1", "i2"), presentation.sections[2].rows.map { it.item.id }.toSet())
        assertEquals(setOf("p1", "p2", "p3"), presentation.sections[3].rows.map { it.item.id }.toSet())
        assertTrue(presentation.conflicts.isEmpty())

        // An empty group shows no title.
        val onlyPrefs = buildMemoryItemListPresentation(listOf(item("x", MemoryKind.PREFERENCE, "Dark mode")), LOCAL)
        assertEquals(listOf(MemoryItemGroup.Preferences), onlyPrefs.sections.map { it.group })
    }

    @Test
    fun hides_deleted_and_episodic() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                item("gone", MemoryKind.IDENTITY, "", status = MemoryStatus.DELETED),
                item("ev", MemoryKind.EVENT, "Met Sam", layer = MemoryLayer.EPISODIC),
                item("keep", MemoryKind.IDENTITY, "Novelist"),
            ),
            deviceId = LOCAL,
        )

        assertEquals(listOf("keep"), presentation.sections.flatMap { s -> s.rows.map { it.item.id } })
        assertTrue(buildMemoryItemListPresentation(listOf(item("gone", MemoryKind.FACT, "", status = MemoryStatus.DELETED)), LOCAL).isEmpty)
    }

    @Test
    fun paused_badge() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                item("paused", MemoryKind.INSTRUCTION, "Answer in Arabic", status = MemoryStatus.PAUSED),
                item("live", MemoryKind.INSTRUCTION, "Be brief"),
            ),
            deviceId = LOCAL,
        )

        val rows = presentation.sections.single().rows.associateBy { it.item.id }
        assertTrue(rows.getValue("paused").paused)
        assertFalse(rows.getValue("live").paused)
    }

    @Test
    fun conflict_pairs_this_device_first() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                item("g1", MemoryKind.PREFERENCE, "Short, with code", status = MemoryStatus.CONFLICTED, conflictGroupId = "g1", deviceId = OTHER),
                item("c1", MemoryKind.PREFERENCE, "Short answers", status = MemoryStatus.CONFLICTED, conflictGroupId = "g1", deviceId = LOCAL),
                item("g2", MemoryKind.FACT, "Lives in Cairo", status = MemoryStatus.CONFLICTED, conflictGroupId = "g2", deviceId = OTHER),
                item("c2", MemoryKind.FACT, "Lives in Giza", status = MemoryStatus.CONFLICTED, conflictGroupId = "g2", deviceId = LOCAL),
                item("plain", MemoryKind.PREFERENCE, "Dark mode"),
            ),
            deviceId = LOCAL,
        )

        assertEquals(setOf("g1", "g2"), presentation.conflicts.map { it.groupId }.toSet())
        val g1 = presentation.conflicts.single { it.groupId == "g1" }
        assertEquals(listOf("c1", "g1"), g1.entries.map { it.item.id })
        assertEquals(listOf(true, false), g1.entries.map { it.isThisDevice })
        // Conflicted items no longer appear in the normal groups.
        assertEquals(listOf("plain"), presentation.sections.flatMap { s -> s.rows.map { it.item.id } })
    }

    @Test
    fun editor_category_mapping() {
        assertEquals(MemoryKind.IDENTITY, MemoryItemEditorState(null, MemoryItemGroup.About, "x").kind)
        assertEquals(MemoryKind.PREFERENCE, MemoryItemEditorState(null, MemoryItemGroup.Preferences, "x").kind)
        assertEquals(MemoryKind.INSTRUCTION, MemoryItemEditorState(null, MemoryItemGroup.Instructions, "x").kind)
        assertEquals(MemoryKind.PROJECT, MemoryItemEditorState(null, MemoryItemGroup.Projects, "x").kind)
        // An existing fact stays a fact in "About me"; moving to another group maps by group.
        assertEquals(MemoryKind.FACT, MemoryItemEditorState("f", MemoryItemGroup.About, "x", MemoryKind.FACT).kind)
        assertEquals(MemoryKind.PREFERENCE, MemoryItemEditorState("f", MemoryItemGroup.Preferences, "x", MemoryKind.FACT).kind)
        // Opening an existing item preselects the group by kind.
        assertEquals(MemoryItemGroup.Instructions, MemoryItemGroup.of(MemoryKind.CONSTRAINT))
        assertEquals(MemoryItemGroup.Projects, MemoryItemGroup.of(MemoryKind.GOAL))
        assertEquals(null, MemoryItemGroup.of(MemoryKind.EVENT))
    }

    @Test
    fun keeps_kind_when_category_unchanged() {
        // Category unchanged: the original kind is kept as is (constraint is not rewritten to instruction, goal does not become project).
        assertEquals(MemoryKind.CONSTRAINT, MemoryItemEditorState("c", MemoryItemGroup.Instructions, "x", MemoryKind.CONSTRAINT).kind)
        assertEquals(MemoryKind.GOAL, MemoryItemEditorState("g", MemoryItemGroup.Projects, "x", MemoryKind.GOAL).kind)
        assertEquals(MemoryKind.DECISION, MemoryItemEditorState("d", MemoryItemGroup.Projects, "x", MemoryKind.DECISION).kind)
        assertEquals(MemoryKind.FACT, MemoryItemEditorState("f", MemoryItemGroup.About, "x", MemoryKind.FACT).kind)
        // Category changed: map by the new group.
        assertEquals(MemoryKind.PROJECT, MemoryItemEditorState("c", MemoryItemGroup.Projects, "x", MemoryKind.CONSTRAINT).kind)
        assertEquals(MemoryKind.INSTRUCTION, MemoryItemEditorState("g", MemoryItemGroup.Instructions, "x", MemoryKind.GOAL).kind)
    }

    @Test
    fun hides_superseded_and_expired() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                item("old", MemoryKind.PREFERENCE, "Long answers", status = MemoryStatus.SUPERSEDED),
                item("stale", MemoryKind.PROJECT, "Old launch", status = MemoryStatus.EXPIRED),
                item("keep", MemoryKind.PREFERENCE, "Short answers"),
            ),
            deviceId = LOCAL,
        )

        assertEquals(listOf("keep"), presentation.sections.flatMap { s -> s.rows.map { it.item.id } })
        assertTrue(
            buildMemoryItemListPresentation(
                listOf(
                    item("old", MemoryKind.FACT, "x", status = MemoryStatus.SUPERSEDED),
                    item("stale", MemoryKind.GOAL, "y", status = MemoryStatus.EXPIRED),
                ),
                LOCAL,
            ).isEmpty,
        )
    }

    @Test
    fun conflict_label_by_copy_device() {
        // The original item's deviceId is the device that pushed it and takes no part in the judgment; only copies count (id != conflictGroupId).
        val remoteCopy = buildMemoryItemListPresentation(
            listOf(
                item("g1", MemoryKind.PREFERENCE, "Short answers", status = MemoryStatus.CONFLICTED, conflictGroupId = "g1", deviceId = LOCAL),
                item("c1", MemoryKind.PREFERENCE, "Short, with code", status = MemoryStatus.CONFLICTED, conflictGroupId = "g1", deviceId = OTHER),
            ),
            deviceId = LOCAL,
        ).conflicts.single()
        assertEquals(listOf("g1", "c1"), remoteCopy.entries.map { it.item.id })
        assertEquals(listOf(true, false), remoteCopy.entries.map { it.isThisDevice })

        val localCopy = buildMemoryItemListPresentation(
            listOf(
                item("g2", MemoryKind.FACT, "Lives in Cairo", status = MemoryStatus.CONFLICTED, conflictGroupId = "g2", deviceId = LOCAL),
                item("c2", MemoryKind.FACT, "Lives in Giza", status = MemoryStatus.CONFLICTED, conflictGroupId = "g2", deviceId = LOCAL),
            ),
            deviceId = LOCAL,
        ).conflicts.single()
        assertEquals(listOf("c2", "g2"), localCopy.entries.map { it.item.id })
        assertEquals(listOf(true, false), localCopy.entries.map { it.isThisDevice })
    }

    @Test
    fun editor_limit_2000() {
        // Counted by code point: an emoji counts as 1.
        val atLimit = "😀".repeat(2000)
        val counter = MemoryEditorCounter.of(atLimit)
        assertEquals(2000, counter.count)
        assertFalse(counter.tooLong)
        assertTrue(counter.canSave)

        val over = MemoryEditorCounter.of("a".repeat(2001))
        assertEquals(2001, over.count)
        assertTrue(over.tooLong)
        assertFalse(over.canSave)

        assertFalse(MemoryEditorCounter.of("   ").canSave)
        assertEquals(2000, MemoryEditorCounter.LIMIT)
    }

    // ---- Events and decisions group, L3 conflict pairs, editor kind options ----

    @Test
    fun episodic_group_filters_and_sorts_newest_first() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                l3("old", "2026-01-02T00:00:00Z", "Picked Postgres"),
                l3("new", "2026-10-15T00:00:00Z", "Moved to Lisbon", kind = MemoryKind.EVENT),
                l3("paused", "2026-05-01T00:00:00Z", "Paused one", status = MemoryStatus.PAUSED),
                l3("fallback", null, "No occurredAt", createdAt = "2026-08-09T10:00:00Z"),
                l3("gone", "2026-10-16T00:00:00Z", "Deleted", status = MemoryStatus.DELETED),
                l3("superseded", "2026-10-16T00:00:00Z", "Old", status = MemoryStatus.SUPERSEDED),
                l3("folder", "2026-03-01T00:00:00Z", "Folder one", scope = MemoryItemScope(MemoryScopeType.FOLDER, "f1")),
                l3("lost", "2026-02-01T00:00:00Z", "Unknown folder", scope = MemoryItemScope(MemoryScopeType.FOLDER, "f9")),
                l3("chat", "2026-04-01T00:00:00Z", "One chat", scope = MemoryItemScope(MemoryScopeType.CONVERSATION, "c1")),
                item("l2", MemoryKind.DECISION, "Semantic decision"),
            ),
            deviceId = LOCAL,
            folderNames = mapOf("f1" to "Work"),
        )

        val rows = presentation.episodic.rows
        assertEquals(listOf("new", "fallback", "paused", "chat", "folder", "lost", "old"), rows.map { it.item.id })
        assertEquals("2026-10-15", rows.first().date)
        assertEquals("2026-08-09", rows[1].date)
        assertEquals(MemoryEpisodicScope.AllChats, rows.first().scope)
        assertEquals(MemoryEpisodicScope.Folder("Work"), rows.first { it.item.id == "folder" }.scope)
        assertEquals(MemoryEpisodicScope.Folder(null), rows.first { it.item.id == "lost" }.scope)
        assertEquals(MemoryEpisodicScope.OneChat, rows.first { it.item.id == "chat" }.scope)
        assertTrue(rows.first { it.item.id == "paused" }.row.paused)
        // The four L2 groups do not take L3; an L2 decision stays in "Projects".
        assertEquals(listOf("l2"), presentation.sections.flatMap { s -> s.rows.map { it.item.id } })
        // The raw-text view likewise excludes L3.
        assertEquals("Semantic decision", MemoryItems.rawRender(listOf(item("l2", MemoryKind.DECISION, "Semantic decision"), l3("x", null, "L3 only"))))
    }

    @Test
    fun episodic_only_page_is_not_empty() {
        val presentation = buildMemoryItemListPresentation(listOf(l3("e", "2026-10-01T00:00:00Z", "Event")), LOCAL)
        assertFalse(presentation.isEmpty)
        assertTrue(presentation.sections.isEmpty())
        assertEquals(MemoryScreenMode.Items, buildMemoryScreenPresentation(!presentation.isEmpty, false).mode)
    }

    @Test
    fun episodic_folds_past_twenty() {
        val twenty = (1..20).map { l3("e%02d".format(it), "2026-01-%02dT00:00:00Z".format(it), "Event $it") }
        val atLimit = buildMemoryItemListPresentation(twenty, LOCAL).episodic
        assertFalse(atLimit.isFolded)
        assertEquals(20, atLimit.visibleRows(expanded = false).size)

        val over = buildMemoryItemListPresentation(twenty + l3("e21", "2026-01-21T00:00:00Z", "Event 21"), LOCAL).episodic
        assertTrue(over.isFolded)
        assertEquals(21, over.total)
        assertEquals(20, over.visibleRows(expanded = false).size)
        assertEquals("e21", over.visibleRows(expanded = false).first().item.id)
        assertEquals(21, over.visibleRows(expanded = true).size)
        assertEquals(20, MemoryEpisodicSection.FOLD_LIMIT)
    }

    @Test
    fun l3_conflict_pairs_newer_by_time_then_id() {
        val presentation = buildMemoryItemListPresentation(
            listOf(
                l3("a-old", "2026-03-04T00:00:00Z", "Use MySQL", status = MemoryStatus.CONFLICTED, conflictGroupId = "a-old"),
                l3("a-new", "2026-09-10T00:00:00Z", "Use Postgres", status = MemoryStatus.CONFLICTED, conflictGroupId = "a-old"),
                l3("b1", "2026-05-05T00:00:00Z", "Tie one", status = MemoryStatus.CONFLICTED, conflictGroupId = "b1"),
                l3("b2", "2026-05-05T00:00:00Z", "Tie two", status = MemoryStatus.CONFLICTED, conflictGroupId = "b1"),
            ),
            deviceId = LOCAL,
        )

        assertTrue(presentation.conflicts.isEmpty())
        assertTrue(presentation.episodic.rows.isEmpty())
        val byGroup = presentation.l3Conflicts.associateBy { it.groupId }
        assertEquals("a-new", byGroup.getValue("a-old").newer.item.id)
        assertEquals("09-10", byGroup.getValue("a-old").newer.monthDay)
        assertEquals("a-old", byGroup.getValue("a-old").older.item.id)
        assertEquals("03-04", byGroup.getValue("a-old").older.monthDay)
        assertEquals("b2", byGroup.getValue("b1").newer.item.id)
        assertEquals("b1", byGroup.getValue("b1").older.item.id)
    }

    @Test
    fun editor_kind_options_by_layer() {
        val l2 = MemoryItemEditorState(null, MemoryItemGroup.Projects, "x")
        assertFalse(l2.isEpisodic)
        assertFalse(MemoryKind.DECISION in l2.kindOptions)
        assertFalse(MemoryKind.EVENT in l2.kindOptions)
        assertNull(l2.occurredAt)

        val l3 = MemoryItemEditorState(
            null,
            MemoryItemGroup.Projects,
            "x",
            layer = MemoryLayer.EPISODIC,
            date = LocalDate.of(2026, 10, 17),
        )
        assertEquals(listOf(MemoryKind.DECISION, MemoryKind.EVENT), l3.kindOptions)
        assertEquals(MemoryKind.DECISION, l3.kind)
        assertEquals(MemoryKind.EVENT, l3.copy(episodicKind = MemoryKind.EVENT).kind)
        assertEquals("2026-10-17T00:00:00Z", l3.occurredAt)
    }

    @Suppress("LongParameterList")
    private fun l3(
        id: String,
        occurredAt: String?,
        content: String,
        kind: MemoryKind = MemoryKind.DECISION,
        status: MemoryStatus = MemoryStatus.ACTIVE,
        scope: MemoryItemScope = MemoryItemScope(),
        conflictGroupId: String? = null,
        createdAt: String = "2026-01-01T00:00:00Z",
    ) = MemoryItem(
        id = id,
        layer = MemoryLayer.EPISODIC,
        kind = kind,
        status = status,
        content = content,
        scope = scope,
        mutationId = "m-$id",
        deviceId = LOCAL,
        conflictGroupId = conflictGroupId,
        occurredAt = occurredAt,
        createdAt = MemoryServerTime.At(createdAt),
    )

    private fun item(
        id: String,
        kind: MemoryKind,
        content: String,
        status: MemoryStatus = MemoryStatus.ACTIVE,
        pinned: Boolean = false,
        layer: MemoryLayer = MemoryLayer.SEMANTIC,
        conflictGroupId: String? = null,
        deviceId: String = LOCAL,
    ) = MemoryItem(
        id = id,
        layer = layer,
        kind = kind,
        status = status,
        content = content,
        pinned = pinned,
        mutationId = "m-$id",
        deviceId = deviceId,
        conflictGroupId = conflictGroupId,
    )

    private companion object {
        const val LOCAL = "device-local"
        const val OTHER = "device-other"
    }
}
