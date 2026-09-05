import Foundation
import Testing
@testable import Oriveo

@Suite("NoteReferenceCountBatch", .serialized)
struct NoteReferenceCountBatchTests {

    @Test("Batch Reference Count Matches Per Conversation Sum")
    func batchReferenceCountMatchesPerConversationSum() throws {
        let harness = try NoteStoreHarness()
        defer { harness.cleanup() }

        let first = UUID()
        let second = UUID()
        let unreferenced = UUID()

        for index in 0..<3 {
            try harness.store.upsertNote(
                NoteTestFactories.makeNote(title: "A\(index)", body: "a", sourceConversationId: first)
            )
        }
        try harness.store.upsertNote(
            NoteTestFactories.makeNote(title: "B", body: "b", sourceConversationId: second)
        )
        try harness.store.upsertNote(
            NoteTestFactories.makeNote(
                title: "C",
                body: "c",
                sourceConversationId: second,
                deletedAt: Date()
            )
        )

        let ids = [first, second, unreferenced]
        let perConversation = try ids.reduce(0) { try $0 + harness.store.referenceCount(conversationID: $1) }
        #expect(try harness.store.referenceCount(conversationIDs: ids) == perConversation)
        #expect(try harness.store.referenceCount(conversationIDs: ids) == 4)
        #expect(try harness.store.referenceCount(conversationIDs: []) == 0)
        #expect(try harness.store.referenceCount(conversationIDs: [unreferenced]) == 0)
    }
}
