import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Server record CRUD, the server limit and atomic writes, plus the state kept for each server: connection state,
/// tool snapshots, permissions, conversation switches and step payloads. Runs the full migrator against a
/// standalone temporary GRDB database.
@Suite("MCP server store")
struct McpServerStoreTests {

    // MARK: - Server record CRUD

    @Test("an inserted record reads back by id and in the full list with every field intact")
    func insertAndFetchRoundTrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let plain = McpServerRecord(
            name: "Linear",
            slug: "linear",
            url: "https://mcp.linear.app/mcp",
            authKind: .auto,
            localOnly: false,
            iconURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let local = McpServerRecord(
            name: "Home Lab",
            slug: "homelab",
            url: "https://user:pw@mcp.example.com/mcp?token=abc",
            authKind: .token,
            localOnly: true,
            iconURL: "https://mcp.example.com/icon.png",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        try store.insertServer(plain)
        try store.insertServer(local)

        #expect(try store.serverCount() == 2)
        #expect(try store.fetchServer(id: plain.id) == plain)
        // A localOnly row stores only the display URL (the caller keeps the full URL in the credential store); every other field is intact.
        var storedLocal = local
        storedLocal.url = "https://mcp.example.com/mcp"
        #expect(try store.fetchServer(id: local.id) == storedLocal)
        #expect(try store.fetchAllServers() == [plain, storedLocal], "ascending by createdAt")
    }

    @Test("a localOnly record stores only the display URL whatever the caller passes, on both insert and update")
    func localOnlyRowNeverStoresSecretURL() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        var record = McpTestRecords.record(slug: "secret", url: "https://mcp.example.com/mcp?token=abc", localOnly: true)
        try database.store.insertServer(record)
        #expect(try database.store.fetchServer(id: record.id)?.url == "https://mcp.example.com/mcp")

        record.url = "https://u:p@mcp.example.com/a1b2c3d4e5f6g7h8i9j0/mcp"
        try database.store.updateServer(record)
        #expect(try database.store.fetchServer(id: record.id)?.url == "https://mcp.example.com/…/mcp")
    }

    @Test("display URL: for every URL in the local-only fixture the display URL is no longer localOnly; a clean URL only loses its fragment")
    func displayURLStripsEverySecretSignal() throws {
        let fixture = try McpFixture.json("local-only.json")
        let cases = fixture["cases"]?.arrayValue ?? []
        #expect(!cases.isEmpty)
        for item in cases {
            guard let url = item.objectValue?["url"]?.stringValue else { continue }
            let display = McpLocalOnly.displayURL(url)
            #expect(!McpLocalOnly.isLocalOnly(display), "\(url) → \(display)")
            if !McpLocalOnly.isLocalOnly(url) {
                #expect(display == url.components(separatedBy: "#")[0], "a clean URL only loses its fragment: \(url)")
            }
        }
        #expect(McpLocalOnly.displayURL("https://mcp.example.com:8443/x?y=1") == "https://mcp.example.com:8443/x")
        // Idempotent: a display URL maps to itself.
        let masked = McpLocalOnly.displayURL("https://mcp.example.com/a1b2c3d4e5f6g7h8i9j0/mcp?k=v")
        #expect(masked == "https://mcp.example.com/…/mcp")
        #expect(McpLocalOnly.displayURL(masked) == masked)
    }

    @Test("an unknown id reads back nil")
    func fetchUnknownServerIsNil() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }

        #expect(try database.store.fetchServer(id: UUID()) == nil)
        #expect(try database.store.fetchAllServers().isEmpty)
        #expect(try database.store.serverCount() == 0)
    }

    @Test("update changes only the editable fields; slug / createdAt / id stay put")
    func updateServerKeepsImmutableFields() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        var record = McpTestRecords.record(slug: "linear", name: "Linear", url: "https://mcp.linear.app/mcp")
        try store.insertServer(record)

        record.name = "Linear (work)"
        record.url = "https://mcp.linear.app/mcp/v2"
        record.authKind = .token
        record.localOnly = true
        record.iconURL = "https://mcp.linear.app/icon.png"
        record.updatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        record.schemaVersion = 2
        try store.updateServer(record)

        let fetched = try #require(try store.fetchServer(id: record.id))
        #expect(fetched.name == "Linear (work)")
        #expect(fetched.url == "https://mcp.linear.app/mcp/v2")
        #expect(fetched.authKind == .token)
        #expect(fetched.localOnly)
        #expect(fetched.iconURL == "https://mcp.linear.app/icon.png")
        #expect(fetched.updatedAt == Date(timeIntervalSince1970: 1_700_000_500))
        #expect(fetched.schemaVersion == 2)
        #expect(fetched.slug == "linear", "the slug never changes after creation")
        #expect(fetched.createdAt == record.createdAt)
    }

    @Test("deleting a server removes the record and everything kept for it, revokes its conversation grants and leaves other servers alone")
    func deleteRemovesRecordAndEverythingKeptForIt() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let doomed = McpTestRecords.record(slug: "doomed")
        let survivor = McpTestRecords.record(slug: "survivor")
        try store.insertServer(doomed)
        try store.insertServer(survivor)
        let (conversation, messages) = try database.insertConversation(messageCount: 1)

        try store.saveConnectionState(
            McpConnectionState(serverId: doomed.id, status: .connected, sessionId: "session-1")
        )
        try store.saveConnectionState(McpConnectionState(serverId: survivor.id, status: .connected))
        try store.replaceToolSnapshots(serverId: doomed.id, snapshots: [
            McpTestRecords.snapshot(serverId: doomed.id, toolName: "get_issue")
        ])
        try store.setToolPermission(.ask, serverId: doomed.id, toolName: "get_issue")
        try store.setServerEnabled(true, conversationId: conversation, serverId: doomed.id)
        try store.setServerEnabled(true, conversationId: conversation, serverId: survivor.id)
        try store.saveStepPayload(
            messageID: messages[0], stepID: "doomed-step", serverId: doomed.id, arguments: "{}", resultPrefix: "r"
        )
        try store.saveStepPayload(
            messageID: messages[0], stepID: "survivor-step", serverId: survivor.id, arguments: "{}", resultPrefix: "kept"
        )
        McpConversationGrants.shared.grant(conversationId: conversation, serverId: doomed.id, toolName: "get_issue")

        try store.deleteServer(id: doomed.id)

        #expect(try store.fetchServer(id: doomed.id) == nil)
        #expect(try store.fetchServer(id: survivor.id) == survivor)
        #expect(try store.fetchConnectionState(serverId: doomed.id) == nil)
        #expect(try store.fetchToolSnapshots(serverId: doomed.id).isEmpty)
        #expect(try store.fetchToolPermissions(serverId: doomed.id).isEmpty)
        #expect(try store.fetchEnabledServerIds(conversationId: conversation) == [survivor.id])
        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "doomed-step") == nil)
        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "survivor-step")?.resultPrefix == "kept")
        #expect(!McpConversationGrants.shared.isGranted(conversationId: conversation, serverId: doomed.id, toolName: "get_issue"))
        #expect(try database.nonEmptyTables() == [
            "mcp_server": 1,
            "mcp_connection_state": 1,
            "mcp_conversation_switch": 1,
            "mcp_step_payload": 1,
        ], "only the surviving server's rows remain")

        // Deleting an id that is not there changes nothing.
        try store.deleteServer(id: UUID())
        #expect(try store.fetchAllServers() == [survivor])
    }

    // MARK: - Limit

    @Test("the default limit is the fallback config value of 20; the 21st record is rejected")
    func defaultLimitIsFallbackTwenty() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        #expect(McpRuntimeConfig.fallback.maxServers == 20)
        for index in 0..<20 {
            try store.insertServer(McpTestRecords.record(slug: "s\(index)"))
        }
        #expect(try store.serverCount() == 20)
        #expect(throws: McpStoreError.limitReached(max: 20)) {
            try store.insertServer(McpTestRecords.record(slug: "overflow"))
        }
        #expect(try store.serverCount() == 20, "a rejected insert must leave no record behind")
    }

    @Test("a passed-in maxServers overrides the fallback")
    func customLimitIsHonored() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        try store.insertServer(McpTestRecords.record(slug: "a"), maxServers: 2)
        try store.insertServer(McpTestRecords.record(slug: "b"), maxServers: 2)
        #expect(throws: McpStoreError.limitReached(max: 2)) {
            try store.insertServer(McpTestRecords.record(slug: "c"), maxServers: 2)
        }
    }

    @Test("the limit counts only readable rows: a row with an unknown authKind is invisible to the user and takes no slot")
    func limitCountsOnlyReadableRows() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        // A sign-in method written by a newer client that this version does not know.
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO mcp_server (id, name, slug, url, authKind, localOnly, createdAt, updatedAt, schemaVersion)
                VALUES (?, 'Future', 'future', 'https://mcp.example.com/future', 'passkey', 0, 1, 1, 9)
                """, arguments: [UUID().uuidString])
        }
        #expect(try store.fetchAllServers().isEmpty, "an unreadable row does not show up in the list")
        #expect(try store.serverCount() == 0, "and does not count toward the limit")

        try store.insertServer(McpTestRecords.record(slug: "a"), maxServers: 1)
        #expect(try store.serverCount() == 1)
        #expect(throws: McpStoreError.limitReached(max: 1)) {
            try store.insertServer(McpTestRecords.record(slug: "b"), maxServers: 1)
        }
        #expect(throws: McpStoreError.limitReached(max: 1)) {
            try store.addServer(McpTestRecords.addition(name: "B"), maxServers: 1)
        }
    }

    // MARK: - slug uniqueness

    @Test("a slug already taken by another server is rejected")
    func slugConflictRejected() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        try store.insertServer(McpTestRecords.record(slug: "linear"))
        #expect(throws: McpStoreError.slugConflict("linear")) {
            try store.insertServer(McpTestRecords.record(slug: "linear"))
        }
        #expect(try store.serverCount() == 1)
        try store.insertServer(McpTestRecords.record(slug: "linearwork"), maxServers: 5)
        #expect(try store.serverCount() == 2)
    }

    // MARK: - Atomic writes

    @Test("addServer: record, snapshots, permissions and connection state land in one transaction; the slug is generated and deduplicated inside it")
    func addServerWritesEverythingAtomically() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let first = McpTestRecords.addition(name: "My Notion")
        let record = try store.addServer(first, maxServers: 20)
        #expect(record.slug == "mynotion")
        #expect(try store.fetchServer(id: first.id) == record)
        #expect(try store.fetchToolSnapshots(serverId: first.id).map(\.toolName) == ["create_issue", "get_issue"])
        #expect(try store.fetchToolPermissions(serverId: first.id) == ["get_issue": .ask, "create_issue": .ask])
        #expect(try store.fetchConnectionState(serverId: first.id)?.status == .connected)

        // Adding the same name again: the slug goes through `unique` and gets a digits-only suffix.
        let second = try store.addServer(McpTestRecords.addition(name: "My Notion"), maxServers: 20)
        #expect(second.slug == "mynotion2")
    }

    @Test("addServer: a primary-key clash with an existing server fails outright; the existing record and its local state lose no rows")
    func addServerNeverTouchesExistingServer() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let existing = McpTestRecords.addition(name: "Linear", tools: ["get_issue"])
        let saved = try store.addServer(existing, maxServers: 20)

        let clash = McpTestRecords.addition(id: existing.id, name: "Impostor", url: "https://evil.example.com/mcp", tools: ["steal"])
        #expect(throws: McpStoreError.serverExists(existing.id)) {
            try store.addServer(clash, maxServers: 20)
        }
        #expect(throws: McpStoreError.serverExists(existing.id)) {
            try store.insertServer(McpTestRecords.record(id: existing.id, slug: "impostor"))
        }

        #expect(try store.fetchServer(id: existing.id) == saved)
        #expect(try store.fetchToolSnapshots(serverId: existing.id).map(\.toolName) == ["get_issue"])
        #expect(try store.fetchToolPermissions(serverId: existing.id) == ["get_issue": .ask])
        #expect(try store.fetchConnectionState(serverId: existing.id)?.status == .connected)
        #expect(try store.serverCount() == 1)
    }

    @Test("addServer: a failure midway rolls everything back and leaves nothing in the six tables")
    func addServerRollsBackOnMidwayFailure() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }

        // Two snapshots with the same name: the second one hits the primary key after the server row and the first snapshot are already written in the transaction.
        var addition = McpTestRecords.addition(name: "Broken", tools: ["dup"])
        addition.snapshots.append(McpTestRecords.snapshot(serverId: addition.id, toolName: "dup"))

        #expect(throws: (any Error).self) {
            try database.store.addServer(addition, maxServers: 20)
        }
        #expect(try database.nonEmptyTables() == [:])
    }

    // MARK: - State kept for a server

    @Test("connection state is overwritten per serverId and reads back")
    func connectionStateRoundTrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let id = UUID()
        try store.saveConnectionState(
            McpConnectionState(
                serverId: id,
                status: .needsAuth,
                lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000),
                negotiatedVersion: "2025-11-25",
                generation: .session,
                sessionId: "session-1"
            )
        )
        #expect(
            try store.fetchConnectionState(serverId: id) == McpConnectionState(
                serverId: id,
                status: .needsAuth,
                lastSuccessAt: Date(timeIntervalSince1970: 1_700_000_000),
                negotiatedVersion: "2025-11-25",
                generation: .session,
                sessionId: "session-1"
            )
        )

        try store.saveConnectionState(McpConnectionState(serverId: id, status: .connected))
        let updated = try #require(try store.fetchConnectionState(serverId: id))
        #expect(updated.status == .connected)
        #expect(updated.sessionId == nil)
    }

    @Test("tool snapshots are replaced as a whole; the quarantine flag is stored with the snapshot")
    func toolSnapshotReplace() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let serverId = UUID()
        try store.replaceToolSnapshots(serverId: serverId, snapshots: [
            McpTestRecords.snapshot(serverId: serverId, toolName: "get_issue", readOnly: true),
            McpTestRecords.snapshot(serverId: serverId, toolName: "create_issue", pendingReview: true),
        ])

        let fetched = try store.fetchToolSnapshots(serverId: serverId)
        #expect(fetched.map(\.toolName) == ["create_issue", "get_issue"], "ascending by toolName")
        let readOnly = try #require(fetched.first { $0.toolName == "get_issue" })
        #expect(readOnly.readOnly)
        #expect(!readOnly.pendingReview)
        #expect(readOnly.contentHash == McpTestRecords.snapshot(serverId: serverId, toolName: "get_issue", readOnly: true).contentHash)
        #expect(fetched.first { $0.toolName == "create_issue" }?.pendingReview == true)

        try store.replaceToolSnapshots(serverId: serverId, snapshots: [McpTestRecords.snapshot(serverId: serverId, toolName: "list_issues")])
        #expect(try store.fetchToolSnapshots(serverId: serverId).map(\.toolName) == ["list_issues"])
    }

    @Test("saveToolCatalog: snapshots and permissions land in one transaction; permissions that are not listed stay untouched")
    func saveToolCatalogWritesSnapshotsAndPermissionsTogether() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let serverId = UUID()
        try store.setToolPermission(.auto, serverId: serverId, toolName: "search")
        try store.setToolPermission(.off, serverId: serverId, toolName: "delete_issue")

        try store.saveToolCatalog(
            serverId: serverId,
            snapshots: [
                McpTestRecords.snapshot(serverId: serverId, toolName: "search"),
                McpTestRecords.snapshot(serverId: serverId, toolName: "delete_issue"),
            ],
            permissions: ["search": .ask]
        )
        #expect(try store.fetchToolSnapshots(serverId: serverId).map(\.toolName) == ["delete_issue", "search"])
        #expect(try store.fetchToolPermissions(serverId: serverId) == ["search": .ask, "delete_issue": .off])
    }

    @Test("the input schema keeps its property order across a store round trip: the argument summary is unchanged (fixture three_scalars_joined)")
    func inputSchemaKeepsPropertyOrderAcrossPersistence() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let cases = try McpFixture.json("args-summary.json")["cases"]?.arrayValue ?? []
        let item = try #require(cases.first { $0["caseId"]?.stringValue == "three_scalars_joined" })
        let schema = try #require(item["inputSchema"])
        let arguments = try #require(item["arguments"])
        let expected = try #require(item["expect"]?["summary"]?.stringValue)
        // Precondition: the property order is not alphabetical, so storing key-sorted canonical JSON would yield the wrong summary.
        let propertyOrder = schema["properties"]?.objectValue?.keys ?? []
        #expect(propertyOrder == ["city", "unit", "days", "verbose"])
        #expect(propertyOrder != propertyOrder.sorted())

        let serverId = UUID()
        var snapshot = McpTestRecords.snapshot(serverId: serverId, toolName: "get_forecast")
        snapshot.inputSchema = schema
        snapshot.annotations = .object(JSONObject([("title", .string("Forecast")), ("readOnlyHint", .bool(true))]))
        try store.replaceToolSnapshots(serverId: serverId, snapshots: [snapshot])

        let stored = try #require(try store.fetchToolSnapshots(serverId: serverId).first)
        #expect(stored.inputSchema == schema, "the input schema matches key for key and in order after the round trip")
        #expect(stored.inputSchema["properties"]?.objectValue?.keys == propertyOrder)
        #expect(stored.annotations == snapshot.annotations)
        #expect(McpArgsSummary.summary(inputSchema: stored.inputSchema, arguments: arguments) == expected)
        #expect(expected == "New York · metric · 3")
        // Canonical JSON is only used for hashing: changing the storage format must not change the hash.
        #expect(McpToolHash.contentHash(
            name: stored.toolName, description: stored.description,
            inputSchema: stored.inputSchema, annotations: stored.annotations
        ) == McpToolHash.contentHash(
            name: snapshot.toolName, description: snapshot.description,
            inputSchema: snapshot.inputSchema, annotations: snapshot.annotations
        ))
    }

    @Test("tool permissions are overwritten per serverId + original tool name")
    func toolPermissionRoundTrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let serverId = UUID()
        try store.setToolPermission(.ask, serverId: serverId, toolName: "create_issue")
        try store.setToolPermission(.off, serverId: serverId, toolName: "delete_issue")
        #expect(try store.fetchToolPermissions(serverId: serverId) == ["create_issue": .ask, "delete_issue": .off])

        try store.setToolPermission(.auto, serverId: serverId, toolName: "create_issue")
        #expect(try store.fetchToolPermissions(serverId: serverId) == ["create_issue": .auto, "delete_issue": .off])
    }

    @Test("conversation toggles are added and removed per conversationId")
    func conversationSwitchRoundTrip() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let first = UUID()
        let second = UUID()
        let conversationA = UUID()
        let conversationB = UUID()
        try store.setServerEnabled(true, conversationId: conversationA, serverId: first)
        try store.setServerEnabled(true, conversationId: conversationA, serverId: second)
        try store.setServerEnabled(true, conversationId: conversationB, serverId: second)

        #expect(Set(try store.fetchEnabledServerIds(conversationId: conversationA)) == [first, second])
        #expect(try store.fetchEnabledServerIds(conversationId: conversationB) == [second])

        try store.setServerEnabled(false, conversationId: conversationA, serverId: first)
        #expect(try store.fetchEnabledServerIds(conversationId: conversationA) == [second])
    }

    @Test("step payloads are truncated at the limit without splitting a multi-byte character")
    func stepPayloadIsCapped() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let ascii = String(repeating: "a", count: 20_000)
        let result = String(repeating: "b", count: 3_000)
        let firstMessage = UUID()
        try store.saveStepPayload(messageID: firstMessage, stepID: "step-1", arguments: ascii, resultPrefix: result)

        let fetched = try #require(try store.fetchStepPayload(messageID: firstMessage, stepID: "step-1"))
        #expect(fetched.arguments == String(repeating: "a", count: McpServerStore.maxStepArgumentsBytes))
        #expect(fetched.resultPrefix == String(repeating: "b", count: McpServerStore.maxStepResultPrefixBytes))

        let cjk = String(repeating: "あ", count: 20_000)
        let secondMessage = UUID()
        try store.saveStepPayload(messageID: secondMessage, stepID: "step-2", arguments: cjk, resultPrefix: nil)
        let cappedCJK = try #require(try store.fetchStepPayload(messageID: secondMessage, stepID: "step-2")?.arguments)
        #expect(cappedCJK.utf8.count <= McpServerStore.maxStepArgumentsBytes)
        #expect(cappedCJK.allSatisfy { $0 == "あ" }, "a multi-byte character must never be split")
    }

    // MARK: - Cleanup when a conversation or message is deleted

    @Test("deleting a message removes its step payloads and leaves other messages alone")
    func deletingMessageClearsItsStepPayloads() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (_, messages) = try database.insertConversation(messageCount: 2)
        try store.saveStepPayload(messageID: messages[0], stepID: "s1", arguments: "{}", resultPrefix: "secret result")
        try store.saveStepPayload(messageID: messages[0], stepID: "s2", arguments: "{}", resultPrefix: nil)
        try store.saveStepPayload(messageID: messages[1], stepID: "s1", arguments: "{}", resultPrefix: "kept")

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: [messages[0].uuidString])
        }
        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "s1") == nil)
        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "s2") == nil)
        #expect(try store.fetchStepPayload(messageID: messages[1], stepID: "s1")?.resultPrefix == "kept")
    }

    @Test("deleting a conversation removes its toggles and the step payloads of all its messages, and leaves other conversations alone")
    func deletingConversationClearsSwitchesAndPayloads() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (doomed, doomedMessages) = try database.insertConversation(messageCount: 2)
        let (kept, keptMessages) = try database.insertConversation(messageCount: 1)
        let server = UUID()
        try store.setServerEnabled(true, conversationId: doomed, serverId: server)
        try store.setServerEnabled(true, conversationId: kept, serverId: server)
        for message in doomedMessages + keptMessages {
            try store.saveStepPayload(messageID: message, stepID: "s1", arguments: "{}", resultPrefix: "r")
        }

        // Delete only the conversation row: the foreign key cascades to its messages.
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [doomed.uuidString])
        }

        #expect(try store.fetchEnabledServerIds(conversationId: doomed).isEmpty)
        #expect(try store.fetchEnabledServerIds(conversationId: kept) == [server])
        for message in doomedMessages {
            #expect(try store.fetchStepPayload(messageID: message, stepID: "s1") == nil)
        }
        #expect(try store.fetchStepPayload(messageID: keptMessages[0], stepID: "s1") != nil)
        let leftover = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_step_payload")
        }
        #expect(leftover == 1)
    }

    @Test("the production delete entry point ConversationStore.deleteConversation triggers the same cleanup")
    func conversationStoreDeletionClearsMcpState() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (conversation, messages) = try database.insertConversation(messageCount: 1)
        try store.setServerEnabled(true, conversationId: conversation, serverId: UUID())
        try store.saveStepPayload(messageID: messages[0], stepID: "s1", arguments: "{}", resultPrefix: "r")

        let conversations = ConversationStore(
            dbPool: database.pool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true))
        )
        try conversations.deleteConversation(id: conversation)
        #expect(try database.nonEmptyTables() == [:])
    }

    // The store has two more ways of removing rows besides `deleteConversation`: writing the whole list of
    // conversations back with one missing, and writing a thread back with messages missing. Neither knows
    // about MCP, so the cleanup rests entirely on the triggers.

    @Test("writing the conversation list back without a conversation clears its switches and step payloads and leaves other conversations alone")
    func replacingConversationsWithoutOneClearsMcpState() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (doomed, doomedMessages) = try database.insertConversation(messageCount: 2)
        let (kept, keptMessages) = try database.insertConversation(messageCount: 1)
        let server = UUID()
        try store.setServerEnabled(true, conversationId: doomed, serverId: server)
        try store.setServerEnabled(true, conversationId: kept, serverId: server)
        for message in doomedMessages + keptMessages {
            try store.saveStepPayload(messageID: message, stepID: "s1", arguments: "{}", resultPrefix: "r")
        }

        let conversations = ConversationStore(
            dbPool: database.pool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true))
        )
        try Self.makeRowsReadableAsModels(database)
        let projection = try conversations.fetchAllConversations(hydrateFilePayloads: false)
        #expect(Set(projection.map(\.id)) == [doomed, kept])
        try conversations.replaceAllConversations(projection.filter { $0.id != doomed })

        #expect(try store.fetchEnabledServerIds(conversationId: doomed).isEmpty)
        #expect(try store.fetchEnabledServerIds(conversationId: kept) == [server])
        for message in doomedMessages {
            #expect(try store.fetchStepPayload(messageID: message, stepID: "s1") == nil)
        }
        #expect(try store.fetchStepPayload(messageID: keptMessages[0], stepID: "s1")?.resultPrefix == "r")
    }

    @Test("writing a thread back without a message, by explicit id or by difference, clears its step payloads and leaves other messages alone")
    func writingThreadBackWithoutMessageClearsStepPayloads() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (conversationID, messages) = try database.insertConversation(messageCount: 3)
        for message in messages {
            try store.saveStepPayload(messageID: message, stepID: "s1", arguments: "{}", resultPrefix: "r")
        }
        let conversations = ConversationStore(
            dbPool: database.pool,
            attachmentFileStore: AttachmentFileStore(rootDirectory: database.directory.appendingPathComponent("Files", isDirectory: true))
        )
        try Self.makeRowsReadableAsModels(database)
        func thread() throws -> Conversation {
            try #require(try conversations.fetchAllConversations(hydrateFilePayloads: false).first { $0.id == conversationID })
        }

        // The message is taken out of the thread in memory and its id is handed to the store explicitly.
        var updated = try thread()
        #expect(Set(updated.messages.map(\.id)) == Set(messages))
        updated.messages.removeAll { $0.id == messages[0] }
        try conversations.upsertConversation(updated, deletingMessageIDs: [messages[0]])

        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "s1") == nil)
        #expect(try store.fetchStepPayload(messageID: messages[1], stepID: "s1")?.resultPrefix == "r")
        #expect(try store.fetchStepPayload(messageID: messages[2], stepID: "s1")?.resultPrefix == "r")

        // Writing a complete thread back deletes the messages the database has and the thread does not,
        // which is the path deleting a message and edit-and-resend take.
        updated = try thread()
        updated.messages.removeAll { $0.id == messages[1] }
        try conversations.upsertConversation(updated)

        #expect(try store.fetchStepPayload(messageID: messages[1], stepID: "s1") == nil)
        #expect(try store.fetchStepPayload(messageID: messages[2], stepID: "s1")?.resultPrefix == "r")
    }

    /// `insertConversation` fills the required columns only, and its `providerID` is not a UUID, so the
    /// row would be dropped when read as a model; this gives it a valid value.
    private static func makeRowsReadableAsModels(_ database: McpTestDatabase) throws {
        try database.pool.write { db in
            try db.execute(sql: "UPDATE conversation SET providerID = ?", arguments: [UUID().uuidString])
        }
    }

    @Test("a message upsert (ON CONFLICT DO UPDATE) does not trigger the cleanup: editing a message keeps its step payloads")
    func upsertingMessageKeepsStepPayloads() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let store = database.store

        let (conversation, messages) = try database.insertConversation(messageCount: 1)
        try store.saveStepPayload(messageID: messages[0], stepID: "s1", arguments: "{}", resultPrefix: "r")
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO message (id, conversationID, role, providerKind, providerName, modelName, state)
                    VALUES (?, ?, 'assistant', 'openAI', 'OpenAI', 'gpt-x', 'delivered')
                    ON CONFLICT(id) DO UPDATE SET text = 'edited'
                    """,
                arguments: [messages[0].uuidString, conversation.uuidString]
            )
        }
        #expect(try store.fetchStepPayload(messageID: messages[0], stepID: "s1")?.resultPrefix == "r")
    }
}
