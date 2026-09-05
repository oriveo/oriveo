import Foundation
import GRDB
import Testing
@testable import Oriveo

@Suite("NoteSearch", .serialized)
struct NoteSearchTests {

    private func seed(_ h: NoteStoreHarness, _ note: Note) throws {
        try h.store.upsertNote(note)
    }

    @Test("Title Hit")
    func titleHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "Deployment guide", body: "x"))
        let r = await asyncSearch(h, "Deployment")
        #expect(r.count == 1)
    }

    @Test("Body Hit")
    func bodyHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "T", body: "kubernetes rollout"))
        #expect(await asyncSearch(h, "kubernetes").count == 1)
    }

    @Test("User Note Hit")
    func userNoteHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "T", body: "B", userNote: "remember this caveat"))
        #expect(await asyncSearch(h, "caveat").count == 1)
    }

    @Test("Tag Hit")
    func tagHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "T", body: "B", tags: ["swift", "concurrency"]))
        #expect(await asyncSearch(h, "concurrency").count == 1)
    }

    @Test("Chinese Hit")
    func chineseHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "デプロイメモ", body: "ノートどうき"))
        #expect(await asyncSearch(h, "どうき").count == 1)
        #expect(await asyncSearch(h, "メモ").count == 1)
    }

    @Test("Soft Deleted Scope")
    func softDeletedScope() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        let note = NoteTestFactories.makeNote(title: "secret answer")
        try seed(h, note)
        try h.store.softDeleteNote(id: note.id, deletedAt: Date(), updatedAt: Date())
        #expect(await asyncSearch(h, "secret", includeDeleted: false).isEmpty)
        #expect(await asyncSearch(h, "secret", includeDeleted: true).count == 1)
    }

    @Test("Restore Re Hit")
    func restoreReHit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        let note = NoteTestFactories.makeNote(title: "findme")
        try seed(h, note)
        try h.store.softDeleteNote(id: note.id, deletedAt: Date(), updatedAt: Date())
        try h.store.restoreNote(id: note.id, updatedAt: Date())
        #expect(await asyncSearch(h, "findme").count == 1)
    }

    @Test("Body Update Reindex")
    func bodyUpdateReindex() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        var note = NoteTestFactories.makeNote(title: "T", body: "oldword content")
        try seed(h, note)
        note.body = "freshword content"
        try h.store.upsertNote(note)
        #expect(await asyncSearch(h, "oldword").isEmpty)
        #expect(await asyncSearch(h, "freshword").count == 1)
    }

    @Test("Empty Query")
    func emptyQuery() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        try seed(h, NoteTestFactories.makeNote(title: "a"))
        try seed(h, NoteTestFactories.makeNote(title: "b"))
        #expect(await asyncSearch(h, "   ").count == 2)
    }

    @Test("Recall Candidates Use Recent And FTS")
    func recallCandidatesUseRecentAndFTS() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        let relevantID = UUID()
        try seed(h, NoteTestFactories.makeNote(
            id: relevantID,
            title: "old kubernetes guide",
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        for index in 0..<8 {
            try seed(h, NoteTestFactories.makeNote(
                title: "recent note \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(100 + index))
            ))
        }

        let candidates = try await h.store.fetchRecallCandidates(
            terms: ["kubernetes"],
            recentLimit: 2,
            totalLimit: 4
        )

        #expect(candidates.count == 4)
        #expect(candidates.first?.id == relevantID)
        #expect(candidates.dropFirst().allSatisfy { $0.id != relevantID })
    }

    @Test("Recall Candidates Fill Recent Without Searchable Terms")
    func recallCandidatesFillRecentWithoutSearchableTerms() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        for index in 0..<6 {
            try seed(h, NoteTestFactories.makeNote(
                title: "Note \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }

        let candidates = try await h.store.fetchRecallCandidates(
            terms: ["Note"],
            recentLimit: 2,
            totalLimit: 4
        )

        #expect(candidates.count == 4)
    }

    @Test("Recall Candidates Exclude Trash And Respect Limit")
    func recallCandidatesExcludeTrashAndRespectLimit() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        for index in 0..<10 {
            try seed(h, NoteTestFactories.makeNote(
                title: "kubernetes note \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try seed(h, NoteTestFactories.makeNote(
            title: "kubernetes deleted",
            deletedAt: Date(timeIntervalSince1970: 100)
        ))

        let candidates = try await h.store.fetchRecallCandidates(
            terms: ["kubernetes"],
            recentLimit: 2,
            totalLimit: 5
        )

        #expect(candidates.count == 5)
        #expect(candidates.allSatisfy { $0.title != "kubernetes deleted" })
    }

    @Test("Recall Candidate Projection Bounds Large Fields")
    func recallCandidateProjectionBoundsLargeFields() async throws {
        let h = try NoteStoreHarness(); defer { h.cleanup() }
        let boundedID = UUID()
        let droppedID = UUID()
        let boundedTags = (0..<(NoteRecallCandidate.maxTags + 8)).map { index in
            "tag-\(index)-" + String(repeating: "x", count: NoteRecallCandidate.maxTagCharacters + 32)
        }
        try seed(h, NoteTestFactories.makeNote(
            id: boundedID,
            title: String(repeating: "t", count: NoteRecallCandidate.maxTitleCharacters + 100),
            body: String(repeating: "b", count: NoteRecallCandidate.maxBodyCharacters + 1_000),
            tags: boundedTags,
            updatedAt: Date(timeIntervalSince1970: 2)
        ))
        let overBudgetTags = (0..<100).map { index in
            "large-\(index)-" + String(repeating: "y", count: NoteRecallCandidate.maxTagCharacters + 100)
        }
        try seed(h, NoteTestFactories.makeNote(
            id: droppedID,
            title: "over budget tags",
            tags: overBudgetTags,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))

        let candidates = try await h.store.fetchRecallCandidates(
            terms: ["unmatched"],
            recentLimit: 2,
            totalLimit: 2
        )
        let bounded = try #require(candidates.first { $0.id == boundedID })
        let dropped = try #require(candidates.first { $0.id == droppedID })

        #expect(bounded.title.count == NoteRecallCandidate.maxTitleCharacters)
        #expect(bounded.body.count == NoteRecallCandidate.maxBodyCharacters)
        #expect(bounded.tags.count == NoteRecallCandidate.maxTags)
        #expect(bounded.tags.allSatisfy { $0.count <= NoteRecallCandidate.maxTagCharacters })
        #expect(dropped.tags.isEmpty)
    }

    private func asyncSearch(_ h: NoteStoreHarness, _ q: String, includeDeleted: Bool = false) async -> [NoteSummary] {
        (try? await h.store.searchNotes(query: q, includeDeleted: includeDeleted)) ?? []
    }
}
