import Foundation
import GRDB
import Testing
@testable import Oriveo

/// The v48 migration creates the four empty studio work tables whose columns match
/// `localTables` in the shared fixture `studio_data_model.v1.json`.
@Suite("StudioWorkSchemaMigrationTests")
struct StudioWorkSchemaMigrationTests {
    private static let lastBeforeStudioWorks = "v47_message_skill_manifest_tokens"
    private static let tables = ["studio_works", "studio_rounds", "studio_versions", "studio_round_refs"]

    @Test func migrationCreatesStudioTables() throws {
        let database = try McpTestDatabase.make(upTo: Self.lastBeforeStudioWorks)
        defer { database.cleanUp() }
        try database.pool.read { (db: Database) throws -> Void in
            for table in Self.tables {
                #expect(try !db.tableExists(table), "\(table) must not exist before the migration")
            }
        }

        try database.migrateToLatest()

        try database.pool.read { (db: Database) throws -> Void in
            for table in Self.tables {
                #expect(try db.tableExists(table), "\(table) must exist after the migration")
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
                #expect(rows == 0, "\(table) must be created empty")
            }
        }
    }

    @Test func columnsMatchFixtureLocalTables() throws {
        let fixture = try StudioByokTasksContractTests.jsonObject(["studio_data_model.v1.json"])
        let localTables = try #require(fixture["localTables"] as? [String: [String]])
        #expect(Set(localTables.keys) == Set(Self.tables))

        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        try database.pool.read { (db: Database) throws -> Void in
            for (table, expected) in localTables {
                let actual = try db.columns(in: table).map(\.name)
                #expect(Set(actual) == Set(expected), "\(table) columns differ from fixture localTables")
                #expect(actual.count == expected.count, "\(table) has duplicate or extra columns")
            }
        }
    }

    @Test func primaryKeysMatch() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let expected: [(table: String, columns: [String])] = [
            ("studio_works", ["id"]),
            ("studio_rounds", ["id"]),
            ("studio_versions", ["id"]),
            ("studio_round_refs", ["roundId", "order"]),
        ]
        try database.pool.read { (db: Database) throws -> Void in
            for item in expected {
                let actual = try db.primaryKey(item.table).columns
                #expect(actual == item.columns, "\(item.table) primary key is \(actual)")
            }
        }
    }

    @Test func assetIndexesExist() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let expected: [(table: String, columns: [String], unique: Bool)] = [
            ("studio_rounds", ["workId", "index"], true),
            ("studio_versions", ["workId"], false),
            ("studio_versions", ["roundId"], false),
            ("studio_versions", ["assetId"], false),
            ("studio_round_refs", ["assetId"], false),
            ("studio_works", ["updatedAt"], false),
        ]
        try database.pool.read { (db: Database) throws -> Void in
            for item in expected {
                let indexes = try db.indexes(on: item.table)
                let match = indexes.contains { $0.columns == item.columns && (!item.unique || $0.isUnique) }
                #expect(match, "missing index on \(item.table)(\(item.columns.joined(separator: ", ")))")
            }
            let foreignKeys: [(table: String, column: String, parent: String)] = [
                ("studio_rounds", "workId", "studio_works"),
                ("studio_versions", "roundId", "studio_rounds"),
                ("studio_round_refs", "roundId", "studio_rounds"),
            ]
            for fk in foreignKeys {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT \"table\", \"from\", on_delete FROM pragma_foreign_key_list(?)",
                    arguments: [fk.table]
                )
                let match = rows.contains { row in
                    row["table"] as String? == fk.parent && row["from"] as String? == fk.column
                        && row["on_delete"] as String? == "CASCADE"
                }
                #expect(match, "missing ON DELETE CASCADE foreign key \(fk.table).\(fk.column) -> \(fk.parent)")
            }
        }
    }
}
