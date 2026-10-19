import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Contract: display condition of the "memory" mini badge, popover rows (first line / deleted), "this is wrong" going to the memory page, and the toolbar indicator reading items.
@Suite("Memory used presentation", .serialized)
@MainActor
struct MemoryUsedPresentationTests {

    private static func item(
        _ id: String,
        _ content: String,
        kind: MemoryKind = .fact,
        status: MemoryStatus = .active,
        layer: MemoryLayer = .semantic
    ) -> MemoryItem {
        ContextPipelineTests.memoryItem(
            id, kind, content, status: status, layer: layer, createdAt: "2026-01-01T00:00:01Z"
        )
    }

    private static func answer(ids: [String], state: ChatMessageState = .delivered, role: ChatRole = .assistant) -> ChatMessage {
        var message = TestFactories.makeMessage(role: role, text: "Answer", state: state)
        message.memoryItemIds = ids
        return message
    }

    @Test func chipShownWithIds() {
        #expect(MemoryUsedPresentation.showsChip(for: Self.answer(ids: ["mem-a"]), isStreaming: false))
        // An answer stopped midway by the user also records the ids, and is shown the same way
        #expect(MemoryUsedPresentation.showsChip(for: Self.answer(ids: ["mem-a"], state: .interrupted), isStreaming: false))
    }

    @Test func chipHiddenWithoutIdsOrStreaming() {
        #expect(!MemoryUsedPresentation.showsChip(for: Self.answer(ids: []), isStreaming: false))
        #expect(!MemoryUsedPresentation.showsChip(for: Self.answer(ids: ["mem-a"]), isStreaming: true))
        #expect(!MemoryUsedPresentation.showsChip(for: Self.answer(ids: ["mem-a"], state: .generating), isStreaming: false))
        #expect(!MemoryUsedPresentation.showsChip(for: Self.answer(ids: ["mem-a"], role: .user), isStreaming: false))
    }

    @Test func listsItemsAndDeleted() {
        let long = String(repeating: "\u{957F}", count: 70)
        let removed = MemoryItems.tombstone(
            Self.item("mem-b", "Old project"), mutationId: "tomb-b", deviceId: "device-test", deletedAt: "2026-01-02T00:00:00Z"
        )
        let items = [
            Self.item("mem-a", "  \n  Lives in Berlin  \nSecond line"),
            removed,
            Self.item("mem-d", long),
            Self.item("mem-e", String(repeating: "👍🏽", count: 61)),
        ]

        let rows = MemoryUsedPresentation.rows(ids: ["mem-d", "MEM-A", "mem-b", "mem-c", "mem-e"], items: items)

        #expect(rows.map(\.id) == ["mem-d", "mem-a", "mem-b", "mem-c", "mem-e"], "in the order recorded with the answer")
        #expect(rows[0].headline == String(repeating: "\u{957F}", count: 60) + "…")
        #expect(rows[1].headline == "Lives in Berlin", "takes the first non-empty line, trimming leading and trailing whitespace")
        #expect(rows[2].isDeleted, "tombstone -> deleted")
        #expect(rows[3].isDeleted, "absent locally -> deleted")
        #expect(rows[4].headline == String(repeating: "👍🏽", count: 60) + "…", "counted by glyph")
        #expect(MemoryUsedPresentation.headline(for: "Short") == "Short")
        #expect(MemoryUsedPresentation.headline(for: String(repeating: "a", count: 60)) == String(repeating: "a", count: 60))
    }

    @Test func fixOpensEditor() {
        let state = AppState(seedDemoData: false, sessionUID: "memory-used-\(UUID().uuidString)")
        let rows = MemoryUsedPresentation.rows(ids: ["MEM-A"], items: [Self.item("mem-a", "Lives in Berlin")])
        state.openMemory(editItemId: rows.first?.id)

        #expect(state.pendingMemoryEditItemID == "mem-a")
        let navigation = state.navigation
        #expect(navigation.path.last == .memory, "opens the Settings memory page")
        #expect(state.consumePendingMemoryEditItemID() == "mem-a")
        #expect(state.pendingMemoryEditItemID == nil, "cleared once taken")

        // Opening the memory page without an item: no stale pending edit id is left
        state.openMemory(editItemId: "mem-a")
        state.openMemory()
        #expect(state.pendingMemoryEditItemID == nil)
    }

    @Test func toolbarIndicatorFollowsItems() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "memory-used-\(UUID().uuidString)")
        state.preferences.memoryText = "Legacy memory text."

        // Only the old field and no items: not shown
        try await ContextPipelineTests.seedMemory(state, [])
        #expect(!MemoryUsedPresentation.showsToolbarIndicator(useMemory: true, items: state.memoryItemsCache.items))

        // Paused, conflict and episodic do not count
        try await ContextPipelineTests.seedMemory(state, [
            Self.item("mem-p", "Paused", status: .paused),
            Self.item("mem-c", "Conflicted", status: .conflicted),
            Self.item("mem-e", "Episodic", kind: .event, layer: .episodic),
        ])
        #expect(!MemoryUsedPresentation.showsToolbarIndicator(useMemory: true, items: state.memoryItemsCache.items))

        try await ContextPipelineTests.seedMemory(state, [
            Self.item("mem-a", "Lives in Berlin\nmore"),
            Self.item("mem-b", "Answer briefly", kind: .instruction),
            Self.item("mem-p", "Paused", status: .paused),
        ])
        let items = state.memoryItemsCache.items
        #expect(MemoryUsedPresentation.showsToolbarIndicator(useMemory: true, items: items))
        #expect(!MemoryUsedPresentation.showsToolbarIndicator(useMemory: false, items: items), "conversation switch is off")
        let preview = MemoryUsedPresentation.toolbarPreview(items: items).split(separator: "\n").map(String.init)
        #expect(Set(preview) == ["Lives in Berlin", "Answer briefly"], "the preview lists the first line of each item")
        #expect(!preview.contains { $0.contains("Legacy") })
    }
}
