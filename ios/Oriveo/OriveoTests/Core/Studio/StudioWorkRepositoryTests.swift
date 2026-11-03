import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Work repository cases from the shared fixture `studio_data_model.v1.json`: `versionCases`
/// (built per `versionCasesHarness`), `repository.listCases` on `repository.seeds.list`, and the
/// create / rename / insert rules of `repository.rules`. Every op runs at now = 9000.
@Suite("StudioWorkRepositoryTests")
struct StudioWorkRepositoryTests {
    private static let now: Int64 = 9000

    /// versionCases with a `delete:` step need deleteVersion, which lands with the delete card;
    /// the list must match the fixture exactly so no new case is skipped silently.
    private static let versionCasesDeferredToDeleteCard: Set<String> = ["delete_keeps_numbers_stable"]

    // MARK: - Fixture cases

    @Test func testVersionCases_matchFixture() async throws {
        let fixture = try Fixture()
        let cases = try #require(fixture.root["versionCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let needingDelete = Set(cases.filter { (($0["action"] as? String) ?? "").contains("delete:") }
            .compactMap { $0["caseId"] as? String })
        #expect(needingDelete == Self.versionCasesDeferredToDeleteCard)

        for entry in cases {
            let caseId = try #require(entry["caseId"] as? String)
            if Self.versionCasesDeferredToDeleteCard.contains(caseId) { continue }
            try await Self.runVersionCase(entry, caseId: caseId, fixture: fixture)
        }
    }

    @Test func testListCases_matchFixture() async throws {
        let fixture = try Fixture()
        let cases = try #require(fixture.repository["listCases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        try Self.insertSeed(fixture.seed("list"), fixture: fixture, into: database.pool)

        for entry in cases {
            let caseId = try #require(entry["caseId"] as? String)
            #expect(entry["seed"] as? String == "list", "\(caseId) seed")
            let op = try #require(entry["op"] as? String, "\(caseId)")
            let parts = op.split(separator: ":").map(String.init)
            let partition = try #require(parts.count >= 2 ? parts[1] : nil, "\(caseId) op \(op)")
            let repository = StudioWorkRepository(writer: database.pool, partitionUID: partition, now: { Self.now })
            switch parts[0] {
            case "list":
                let expected = try #require(entry["expect"] as? [String], "\(caseId)").map(fixture.id)
                let listed = try await repository.list().map(\.id)
                #expect(listed == expected, "\(caseId)")
            case "get":
                let workId = try #require(parts.count == 3 ? parts[2] : nil, "\(caseId) op \(op)")
                let detail = try await repository.detail(workId: fixture.id(workId))
                #expect(detail?.work.id == (entry["expect"] as? String).map(fixture.id), "\(caseId)")
            default:
                Issue.record("\(caseId): unknown op \(op)")
            }
        }
    }

    // MARK: - Rules

    @Test func testCreateWork_defaults() async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let repository = StudioWorkRepository(writer: database.pool, partitionUID: "uid-a", now: { Self.now })

        let created = try await repository.createWork(
            id: nil, source: .chat, title: "Window coffee", chatConversationId: "CONV-1", chatMessageId: "MSG-1"
        )

        #expect(UUID(uuidString: created.id)?.uuidString == created.id, "new id is an upper-case canonical UUID")
        #expect(created.revision == 1)
        #expect(created.baseRevision == 0)
        #expect(created.syncState == .pending)
        #expect(created.createdAt == Self.now)
        #expect(created.updatedAt == Self.now)
        #expect(created.deletedAt == nil)
        #expect(created.accountPartition == "uid-a")
        #expect(created.source == StudioWorkSource.chat.rawValue)
        #expect(created.title == "Window coffee")
        #expect(created.chatConversationId == "CONV-1")
        #expect(created.chatMessageId == "MSG-1")
        #expect(created.favorite == false)
        #expect(created.currentVersionId == nil)
        #expect(created.selectedVersionIds.isEmpty)
        #expect(created.deletedVersionIds.isEmpty)
        let stored = try Self.storedWork(created.id, in: database.pool)
        #expect(stored == created)

        let lower = "b7e0c1d2-3a4b-4c5d-8e6f-708192a3b4c5"
        let given = try await repository.createWork(id: lower, source: .studio, title: nil)
        #expect(given.id == lower.uppercased(), "a given id is stored upper-case")
        let detail = try await repository.detail(workId: lower)
        #expect(detail?.work == given)
    }

    @Test func testCreateWork_existingIdNoRevive() async throws {
        let fixture = try Fixture()
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        try Self.insertSeed(fixture.seed("list"), fixture: fixture, into: database.pool)
        let repository = StudioWorkRepository(writer: database.pool, partitionUID: "uid-a", now: { Self.now })

        for alias in ["W3", "W"] {
            let workId = fixture.id(alias)
            let before = try #require(try Self.storedWork(workId, in: database.pool))
            let returned = try await repository.createWork(
                id: workId.lowercased(), source: .chat, title: "Other", chatConversationId: "CONV-9", chatMessageId: "MSG-9"
            )
            let after = try Self.storedWork(workId, in: database.pool)
            #expect(returned == before, "\(alias): the existing row is returned as is")
            #expect(after == before, "\(alias): the existing row is not written")
        }
        let tombstone = try await repository.detail(workId: fixture.id("W3"))
        #expect(tombstone == nil, "a tombstone is not revived")
    }

    @Test func testRename_sameValueNoop() async throws {
        let fixture = try Fixture()
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        try Self.insertSeed(fixture.seed("list"), fixture: fixture, into: database.pool)
        let repository = StudioWorkRepository(writer: database.pool, partitionUID: "uid-a", now: { Self.now })
        let workId = fixture.id("W")
        let before = try #require(try Self.storedWork(workId, in: database.pool))

        try await repository.rename(workId: workId, title: try #require(before.title))
        try await repository.setFavorite(workId: workId, before.favorite)
        let unchanged = try Self.storedWork(workId, in: database.pool)
        #expect(unchanged == before, "same title / favorite leaves the row untouched")

        try await repository.rename(workId: workId, title: "Renamed")
        let renamed = try #require(try Self.storedWork(workId, in: database.pool))
        #expect(renamed.title == "Renamed")
        #expect(renamed.revision == before.revision + 1)
        #expect(renamed.updatedAt == Self.now)
        #expect(renamed.syncState == .pending)
        #expect(renamed.baseRevision == before.baseRevision, "baseRevision is only written by sync")

        try await repository.setFavorite(workId: workId, !before.favorite)
        let favored = try #require(try Self.storedWork(workId, in: database.pool))
        #expect(favored.favorite == !before.favorite)
        #expect(favored.revision == before.revision + 2)
    }

    @Test func testInsertRound_rejectsTombstone() async throws {
        let fixture = try Fixture()
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        try Self.insertSeed(fixture.seed("list"), fixture: fixture, into: database.pool)
        let repository = StudioWorkRepository(writer: database.pool, partitionUID: "uid-a", now: { Self.now })
        let tombstoneId = fixture.id("W3")
        let before = try Self.storedWork(tombstoneId, in: database.pool)

        for workId in [tombstoneId, "F0000001-0000-4000-8000-000000000001"] {
            let roundId = UUID().uuidString
            let round = StudioRoundRow(id: roundId, workId: workId, index: 1, operation: "generate", status: "completed")
            let version = StudioVersionRow(
                id: UUID().uuidString, roundId: roundId, workId: workId, assetId: UUID().uuidString, createdAt: 1
            )
            let ref = StudioRoundRefRow(roundId: roundId, order: 0, assetId: UUID().uuidString, role: "style")
            await #expect(throws: StudioWorkRepositoryError.self, "\(workId)") {
                try await repository.insertRound(round, versions: [version], refs: [ref])
            }
        }

        for table in [StudioWorkSchema.roundsTable, StudioWorkSchema.versionsTable, StudioWorkSchema.roundRefsTable] {
            #expect(try Self.rowCount(table, in: database.pool) == 0, "\(table) must stay empty")
        }
        let after = try Self.storedWork(tombstoneId, in: database.pool)
        #expect(after == before, "the tombstone row is not written")
    }

    // MARK: - versionCases harness

    private static func runVersionCase(_ entry: [String: Any], caseId: String, fixture: Fixture) async throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let repository = StudioWorkRepository(writer: database.pool, partitionUID: "uid-a", now: { Self.now })
        let work = try await repository.createWork(id: nil, source: .studio, title: nil)
        let harness = VersionHarness(repository: repository, workId: work.id, aliases: fixture.ids)

        let round = try #require(entry["round"] as? [String: Any], "\(caseId)")
        let requested = try #require(Self.int(round["n"]), "\(caseId)")
        let delivered = try #require(Self.int(round["delivered"]), "\(caseId)")
        let action = try #require(entry["action"] as? String, "\(caseId)")
        var steps = action.split(separator: ";").map(String.init)
        var underTest: [String] = []
        if let first = steps.first, first.hasPrefix("keep_order:") {
            steps.removeFirst()
            let list = first.dropFirst("keep_order:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").map(String.init)
            for alias in list {
                try await harness.addFinishedRound([alias], requested: 1)
            }
        } else {
            if (round["previous"] as? Bool) == true {
                try await harness.addFinishedRound(["P"], requested: 1)
            }
            underTest = delivered > 0 ? (1...delivered).map { "c\($0)" } : []
            try await harness.addFinishedRound(underTest, requested: requested)
        }

        for step in steps {
            if step == "start_next_round" {
                try await repository.resolvePendingPick(workId: work.id)
                continue
            }
            for part in step.split(separator: ",") {
                let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else {
                    Issue.record("\(caseId): unknown step \(part)")
                    continue
                }
                let versionId = harness.id(pieces[1])
                switch pieces[0] {
                case "pick": try await repository.pick(workId: work.id, versionId: versionId)
                case "also": try await repository.alsoKeep(workId: work.id, versionId: versionId)
                default: Issue.record("\(caseId): unknown step \(part)")
                }
            }
        }

        let expect = try #require(entry["expect"] as? [String: Any], "\(caseId)")
        let loaded = try await repository.detail(workId: work.id)
        let detail = try #require(loaded, "\(caseId): detail")
        if let kept = expect["kept"] as? [String] {
            let candidates = Set(underTest.map(harness.id))
            let selected = detail.work.selectedVersionIds.filter(candidates.contains)
            let keptRows = Set(detail.versions.filter { $0.kept && candidates.contains($0.id) }.map(\.id))
            #expect(selected == kept.map(harness.id), "\(caseId): kept in selectedVersionIds order")
            #expect(keptRows == Set(selected), "\(caseId): kept flags match selectedVersionIds")
        }
        if expect.keys.contains("current") {
            let current = (expect["current"] as? String).map(harness.id)
            #expect(detail.work.currentVersionId == current, "\(caseId): current")
        }
        if let pending = Self.int(expect["pendingPick"]) {
            let count = try await repository.pendingPickCount(workId: work.id)
            #expect(count == pending, "\(caseId): pendingPick")
        }
        if let numbers = expect["numbers"] as? [String: Any] {
            for (alias, value) in numbers {
                let number = try await repository.versionNumber(workId: work.id, versionId: harness.id(alias))
                #expect(number == Self.int(value), "\(caseId): number of \(alias)")
            }
        }
    }

    /// Builds the rounds of one versionCase: aliases missing from `repository.ids` get a fresh id,
    /// candidates of a round get strictly increasing createdAt.
    private final class VersionHarness {
        let repository: StudioWorkRepository
        let workId: String
        private var aliases: [String: String]
        private var nextIndex = 1
        private var nextStamp: Int64 = 100

        init(repository: StudioWorkRepository, workId: String, aliases: [String: String]) {
            self.repository = repository
            self.workId = workId
            self.aliases = aliases
        }

        func id(_ alias: String) -> String {
            if let known = aliases[alias] { return known }
            let fresh = UUID().uuidString
            aliases[alias] = fresh
            return fresh
        }

        func addFinishedRound(_ versionAliases: [String], requested: Int) async throws {
            let roundId = UUID().uuidString
            let versionIds = versionAliases.map(id)
            let status = versionIds.isEmpty ? "failed" : versionIds.count == requested ? "completed" : "partial"
            let round = StudioRoundRow(
                id: roundId, workId: workId, index: nextIndex, operation: "generate", status: status,
                nRequested: requested, nDelivered: versionIds.count
            )
            nextIndex += 1
            var versions: [StudioVersionRow] = []
            for versionId in versionIds {
                nextStamp += 1
                versions.append(StudioVersionRow(
                    id: versionId, roundId: roundId, workId: workId, assetId: UUID().uuidString,
                    width: 1024, height: 1024, mime: "image/png", createdAt: nextStamp
                ))
            }
            try await repository.insertRound(round, versions: versions, refs: [])
            try await repository.finishRound(workId: workId, roundId: roundId)
        }
    }

    // MARK: - Fixture access

    private struct Fixture {
        let root: [String: Any]
        let repository: [String: Any]
        let ids: [String: String]

        init() throws {
            root = try StudioByokTasksContractTests.jsonObject(["studio_data_model.v1.json"])
            repository = try #require(root["repository"] as? [String: Any])
            ids = try #require(repository["ids"] as? [String: String])
        }

        func seed(_ name: String) throws -> [String: Any] {
            let seeds = try #require(repository["seeds"] as? [String: Any])
            return try #require(seeds[name] as? [String: Any], "seed \(name)")
        }

        func id(_ alias: String) -> String { ids[alias] ?? alias }
    }

    /// Writes a fixture seed straight into the tables; NOT NULL columns the seed leaves out get any valid value.
    private static func insertSeed(_ seed: [String: Any], fixture: Fixture, into pool: DatabasePool) throws {
        let alias: (Any?) -> String? = { ($0 as? String).map(fixture.id) }
        let idList: (Any?) throws -> String = { value in
            let ids = (value as? [String] ?? []).map(fixture.id)
            return String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
        }
        let works = seed["works"] as? [[String: Any]] ?? []
        let rounds = seed["rounds"] as? [[String: Any]] ?? []
        let versions = seed["versions"] as? [[String: Any]] ?? []
        let refs = seed["refs"] as? [[String: Any]] ?? []
        try pool.write { db in
            for work in works {
                try db.execute(
                    sql: """
                        INSERT INTO studio_works (id, title, currentVersionId, source, chatConversationId, chatMessageId,
                            favorite, selectedVersionIds, deletedVersionIds, createdAt, updatedAt, deletedAt, revision,
                            baseRevision, accountPartition, syncState)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        alias(work["id"]), work["title"] as? String, alias(work["currentVersionId"]),
                        (work["source"] as? String) ?? "studio", work["chatConversationId"] as? String,
                        work["chatMessageId"] as? String, (work["favorite"] as? Bool) ?? false,
                        try idList(work["selectedVersionIds"]), try idList(work["deletedVersionIds"]),
                        int64(work["createdAt"]), int64(work["updatedAt"]), int64(work["deletedAt"]),
                        int64(work["revision"]), int64(work["baseRevision"]), work["accountPartition"] as? String,
                        work["syncState"] as? String,
                    ]
                )
            }
            for round in rounds {
                try db.execute(
                    sql: """
                        INSERT INTO studio_rounds (id, workId, "index", baseVersionId, operation, status)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        alias(round["id"]), alias(round["workId"]), int64(round["index"]), alias(round["baseVersionId"]),
                        (round["operation"] as? String) ?? "generate", round["status"] as? String,
                    ]
                )
            }
            for version in versions {
                try db.execute(
                    sql: """
                        INSERT INTO studio_versions (id, roundId, workId, parentVersionId, assetId, kept, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        alias(version["id"]), alias(version["roundId"]), alias(version["workId"]),
                        alias(version["parentVersionId"]), alias(version["assetId"]),
                        (version["kept"] as? Bool) ?? false, int64(version["createdAt"]),
                    ]
                )
            }
            for ref in refs {
                try db.execute(
                    sql: "INSERT INTO studio_round_refs (roundId, \"order\", assetId, role) VALUES (?, ?, ?, ?)",
                    arguments: [alias(ref["roundId"]), int64(ref["order"]), alias(ref["assetId"]), ref["role"] as? String]
                )
            }
        }
    }

    /// The raw work row, tombstones included (synchronous read).
    private static func storedWork(_ id: String, in pool: DatabasePool) throws -> StudioWorkRow? {
        try pool.read { db in try StudioWorkRepository.fetchWork(db, id: id) }
    }

    private static func rowCount(_ table: String, in pool: DatabasePool) throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1 }
    }

    private static func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}
