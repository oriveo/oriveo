import Foundation
import Testing
@testable import Oriveo

// MARK: - Tool catalog
//
// Hashing and change detection follow the shared fixture `tool-hash.json` vector by vector; the permission and
// outbound-filter cases pin the default-permission and quarantine rules. Every asserted value comes from the production code path (`McpToolCatalog`); the fixture only supplies inputs and expected values.

private let catalogServerId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func toolDefinition(_ value: JSONValue) throws -> McpToolDefinition {
    try #require(McpToolDefinition(json: value), "the fixture tool definition should parse")
}

private func settled(_ snapshot: McpToolSnapshot) -> McpToolSnapshot {
    var copy = snapshot
    copy.pendingReview = false
    return copy
}

@Suite("MCP tool catalog")
struct McpToolCatalogTests {

    // MARK: - Default permission

    @Test("tools declared read-only run automatically; everything else (including undeclared ones) asks every time")
    func defaultPermissionFollowsD03() {
        let snapshots = [
            makeSnapshot(name: "read", readOnly: true),
            makeSnapshot(name: "write", readOnly: false),
            makeSnapshot(name: "undeclared", readOnly: false),
        ]
        let permissions = McpToolCatalog.defaultPermissions(for: snapshots)
        #expect(permissions["read"] == .auto)
        #expect(permissions["write"] == .ask)
        #expect(permissions["undeclared"] == .ask, "a tool without a declaration is treated as one that modifies data")
    }

    @Test("display name priority: title -> annotations.title -> name")
    func displayTitlePriority() throws {
        let withTitle = McpToolDefinition(
            name: "raw_name",
            title: "Top Title",
            annotations: .object(JSONObject([("title", .string("Annotation Title"))]))
        )
        #expect(withTitle.displayTitle == "Top Title")

        let annotationOnly = McpToolDefinition(
            name: "raw_name",
            annotations: .object(JSONObject([("title", .string("Annotation Title"))]))
        )
        #expect(annotationOnly.displayTitle == "Annotation Title")

        let bare = McpToolDefinition(name: "raw_name")
        #expect(bare.displayTitle == "raw_name")
    }

    // MARK: - Content hash (fixture tool-hash.json)

    @Test("content hashes match tool-hash.json vector by vector, and key order does not affect the result")
    func hashMatchesFixtureVectors() throws {
        let root = try McpFixture.json("tool-hash.json")
        let cases = try #require(root["cases"]?.arrayValue)
        #expect(cases.count == 5)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let before = try toolDefinition(try #require(item["before"]))
            let after = try toolDefinition(try #require(item["after"]))
            let beforeHash = McpToolCatalog.contentHash(before)
            let afterHash = McpToolCatalog.contentHash(after)
            let expect = item["expect"]

            if item["expectEqual"]?.boolValue == true {
                #expect(beforeHash == afterHash, "\(caseId) should be equivalent")
                if let frozen = expect?["hash"]?.stringValue {
                    #expect(beforeHash == frozen, "\(caseId) hash")
                }
            } else {
                #expect(beforeHash != afterHash, "\(caseId) should count as a change")
                #expect(beforeHash == expect?["beforeHash"]?.stringValue, "\(caseId) beforeHash")
                #expect(afterHash == expect?["afterHash"]?.stringValue, "\(caseId) afterHash")
            }
        }
    }

    // MARK: - Change detection and quarantine

    @Test("a changed description counts as changed and is quarantined until confirmed; the hashes before and after match the fixture vector")
    func descriptionChangeIsIsolated() throws {
        let (before, after, beforeHash, afterHash) = try hashVector("description_changed_one_word")
        let settledSnapshot = settled(try firstSnapshot(of: before))
        #expect(settledSnapshot.contentHash == beforeHash)

        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(incoming.contentHash == afterHash)
        #expect(incoming.pendingReview, "a changed tool must be quarantined until confirmed")

        #expect(McpToolCatalog.changes(existing: [settledSnapshot], incoming: [incoming])
            == [McpToolChange(kind: .changed, toolName: "get_weather", title: after.displayTitle)])

        // A quarantined tool is not part of the tools sent to the model.
        let permissions = McpToolCatalog.defaultPermissions(for: [incoming])
        #expect(McpToolCatalog.outboundSnapshots([incoming], permissions: permissions).isEmpty)

        // If the current definition is still `after` at confirmation, the quarantine lifts; if the server reverted to `before`, it stays.
        let confirmed = try #require(McpToolCatalog.confirmed(incoming, against: after, runtimeConfig: .fallback))
        #expect(confirmed.pendingReview == false)
        #expect(McpToolCatalog.confirmed(incoming, against: before, runtimeConfig: .fallback) == nil)
    }

    @Test("a changed input schema counts as changed and is quarantined")
    func schemaChangeIsIsolated() throws {
        let (before, after, beforeHash, afterHash) = try hashVector("input_schema_changed_new_property")
        let settledSnapshot = settled(try firstSnapshot(of: before))
        #expect(settledSnapshot.contentHash == beforeHash)

        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(incoming.contentHash == afterHash)
        #expect(incoming.pendingReview)
        #expect(McpToolCatalog.changes(existing: [settledSnapshot], incoming: [incoming]).map(\.kind) == [.changed])
    }

    @Test("a change in annotations is a content change too")
    func annotationsChangeIsDetected() throws {
        let (before, after, beforeHash, afterHash) = try hashVector("annotations_changed_is_also_a_change")
        let settledSnapshot = settled(try firstSnapshot(of: before))
        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(settledSnapshot.contentHash == beforeHash)
        #expect(incoming.contentHash == afterHash)
        #expect(incoming.pendingReview)
    }

    @Test("a different key order that is otherwise equivalent is not a change and keeps the existing quarantine flag")
    func keyOrderEquivalentIsNotAChange() throws {
        let root = try McpFixture.json("tool-hash.json")
        let cases = try #require(root["cases"]?.arrayValue)
        let item = try #require(cases.first { $0["caseId"]?.stringValue == "key_order_irrelevant_equivalent" })
        let before = try toolDefinition(try #require(item["before"]))
        let after = try toolDefinition(try #require(item["after"]))
        let frozen = try #require(item["expect"]?["hash"]?.stringValue)

        let settledSnapshot = settled(try firstSnapshot(of: before))
        #expect(settledSnapshot.contentHash == frozen)
        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(incoming.contentHash == settledSnapshot.contentHash)
        #expect(incoming.pendingReview == false, "an unchanged tool must not be quarantined again")
        #expect(McpToolCatalog.changes(existing: [settledSnapshot], incoming: [incoming]).isEmpty)
    }

    @Test("a new tool counts as added and is quarantined; it goes outbound only after confirmation")
    func addedToolIsIsolatedUntilConfirmed() throws {
        let definition = try toolDefinition(try #require(McpFixture.json("tool-hash.json")["cases"]?.arrayValue?.first?["before"]))
        let snapshot = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [definition], runtimeConfig: .fallback, existing: []
        ).first)
        #expect(snapshot.pendingReview, "a new tool is quarantined until the user confirms it")
        #expect(McpToolCatalog.changes(existing: [], incoming: [snapshot]).map(\.kind) == [.added])
        #expect(McpToolCatalog.outboundSnapshots([snapshot], permissions: McpToolCatalog.defaultPermissions(for: [snapshot])).isEmpty)

        let confirmed = try #require(McpToolCatalog.confirmed(snapshot, against: definition, runtimeConfig: .fallback))
        #expect(confirmed.pendingReview == false)
        #expect(McpToolCatalog.outboundSnapshots([confirmed], permissions: McpToolCatalog.defaultPermissions(for: [confirmed])).count == 1)
    }

    @Test("a removed tool counts as removed")
    func removedToolIsDetected() throws {
        let snapshot = makeSnapshot(name: "gone", readOnly: true)
        let changes = McpToolCatalog.changes(existing: [snapshot], incoming: [])
        #expect(changes == [McpToolChange(kind: .removed, toolName: "gone", title: snapshot.title)])
    }

    @Test("batch confirmation: a tool changed again during confirmation stays quarantined and is reported by name")
    func batchConfirmKeepsChangedToolsIsolated() throws {
        let (before, after, _, _) = try hashVector("description_changed_one_word")
        let pending = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [before], runtimeConfig: .fallback, existing: []
        ).first)
        // By the time the user confirms, the server has already changed it to `after`: the hash does not match, so it stays quarantined.
        let result = McpToolCatalog.confirm([pending], definitions: [after], permissions: [:], runtimeConfig: .fallback)
        #expect(result.stillPending == ["get_weather"])
        #expect(result.snapshots.first?.pendingReview == true)
        #expect(result.permissions.isEmpty, "a tool whose confirmation was rejected yields no permission")
    }

    // MARK: - A display-title change is a change too

    @Test("a display-title-only change with an identical hash counts as changed and returns to quarantine, staying off the wire until confirmed")
    func titleOnlyChangeIsIsolated() throws {
        let schema = JSONValue.object(JSONObject([("type", .string("object"))]))
        let before = McpToolDefinition(name: "run", title: "Search issues", description: "Does things", inputSchema: schema)
        let after = McpToolDefinition(name: "run", title: "Delete everything", description: "Does things", inputSchema: schema)
        // Precondition: the title is not part of the hash (frozen by the tool-hash.json fixture), so both definitions hash the same.
        #expect(McpToolCatalog.contentHash(before) == McpToolCatalog.contentHash(after))

        let settledSnapshot = settled(try firstSnapshot(of: before))
        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(incoming.title == "Delete everything")
        #expect(incoming.contentHash == settledSnapshot.contentHash)
        #expect(incoming.pendingReview, "a tool whose title changed must return to quarantine")
        #expect(McpToolCatalog.changes(existing: [settledSnapshot], incoming: [incoming])
            == [McpToolChange(kind: .changed, toolName: "run", title: "Delete everything")])
        #expect(McpToolCatalog.outboundSnapshots([incoming], permissions: ["run": .auto]).isEmpty)
    }

    @Test("when annotations.title is the display title, changing it returns the tool to quarantine as well")
    func annotationTitleChangeIsIsolated() throws {
        let before = McpToolDefinition(name: "run", annotations: .object(JSONObject([("title", .string("Read"))])))
        let after = McpToolDefinition(name: "run", annotations: .object(JSONObject([("title", .string("Write"))])))
        let settledSnapshot = settled(try firstSnapshot(of: before))
        let incoming = try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [after], runtimeConfig: .fallback, existing: [settledSnapshot]
        ).first)
        #expect(incoming.pendingReview)
        #expect(incoming.title == "Write")
    }

    @Test("a title at confirmation that differs from what the user saw rejects the confirmation and keeps the quarantine")
    func confirmRejectsTitleChangedDuringReview() throws {
        let schema = JSONValue.object(JSONObject([("type", .string("object"))]))
        let shown = McpToolDefinition(name: "run", title: "Search issues", inputSchema: schema)
        let current = McpToolDefinition(name: "run", title: "Delete everything", inputSchema: schema)
        let pending = try firstSnapshot(of: shown)
        #expect(McpToolCatalog.confirmed(pending, against: current, runtimeConfig: .fallback) == nil)
        #expect(McpToolCatalog.confirmed(pending, against: shown, runtimeConfig: .fallback)?.pendingReview == false)
    }

    // MARK: - Confirming a change can lower a permission but never raise it

    @Test("a read-only tool that now writes data falls back from run automatically to ask every time after confirmation")
    func confirmDowngradesAutoWhenNoLongerReadOnly() throws {
        let readOnly = McpToolDefinition(
            name: "sync", description: "Reads", annotations: .object(JSONObject([("readOnlyHint", .bool(true))]))
        )
        let writes = McpToolDefinition(
            name: "sync", description: "Reads and writes", annotations: .object(JSONObject([("readOnlyHint", .bool(false))]))
        )
        let settledSnapshot = settled(try firstSnapshot(of: readOnly))
        #expect(McpToolCatalog.defaultPermissions(for: [settledSnapshot]) == ["sync": .auto])

        let incoming = McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [writes], runtimeConfig: .fallback, existing: [settledSnapshot]
        )
        #expect(incoming.first?.pendingReview == true)
        let result = McpToolCatalog.confirm(
            incoming, definitions: [writes], permissions: ["sync": .auto], runtimeConfig: .fallback
        )
        #expect(result.stillPending.isEmpty)
        #expect(result.snapshots.first?.pendingReview == false)
        #expect(result.snapshots.first?.readOnly == false)
        #expect(result.permissions == ["sync": .ask], "confirming means acknowledging the change, not agreeing that writes need no prompt")
    }

    @Test("dropping the read-only declaration (no declaration) falls back the same way")
    func confirmDowngradesWhenReadOnlyHintRemoved() throws {
        let readOnly = McpToolDefinition(name: "sync", annotations: .object(JSONObject([("readOnlyHint", .bool(true))])))
        let undeclared = McpToolDefinition(name: "sync")
        let settledSnapshot = settled(try firstSnapshot(of: readOnly))
        let incoming = McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [undeclared], runtimeConfig: .fallback, existing: [settledSnapshot]
        )
        let result = McpToolCatalog.confirm(
            incoming, definitions: [undeclared], permissions: ["sync": .auto], runtimeConfig: .fallback
        )
        #expect(result.permissions == ["sync": .ask])
    }

    @Test("lower only, never raise: every other case leaves the permission alone, and new tools get the default")
    func confirmNeverLoosensPermissions() throws {
        let readOnlyAnnotations = JSONValue.object(JSONObject([("readOnlyHint", .bool(true))]))
        // A writing tool that became read-only: ask every time does not turn into run automatically.
        let becameReadOnly = McpToolDefinition(name: "became_read_only", description: "v2", annotations: readOnlyAnnotations)
        // A tool that is still read-only with a changed description: run automatically stays.
        let stillReadOnly = McpToolDefinition(name: "still_read_only", description: "v2", annotations: readOnlyAnnotations)
        // A tool the user turned off: still "Don't use" after confirmation.
        let off = McpToolDefinition(name: "off", description: "v2")
        // The two new tools have no permission record, so they get the default.
        let newReadOnly = McpToolDefinition(name: "new_read_only", annotations: readOnlyAnnotations)
        let newWrite = McpToolDefinition(name: "new_write")
        // An unchanged tool: a writing tool the user set to run automatically is not part of this confirmation and stays as is.
        let untouched = McpToolDefinition(name: "untouched", description: "same")

        let existing = [
            settled(try firstSnapshot(of: McpToolDefinition(name: "became_read_only", description: "v1"))),
            settled(try firstSnapshot(of: McpToolDefinition(name: "still_read_only", description: "v1", annotations: readOnlyAnnotations))),
            settled(try firstSnapshot(of: McpToolDefinition(name: "off", description: "v1"))),
            settled(try firstSnapshot(of: untouched)),
        ]
        let definitions = [becameReadOnly, stillReadOnly, off, newReadOnly, newWrite, untouched]
        let incoming = McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: definitions, runtimeConfig: .fallback, existing: existing
        )
        #expect(incoming.filter(\.pendingReview).map(\.toolName)
            == ["became_read_only", "still_read_only", "off", "new_read_only", "new_write"])

        let before: [String: McpToolPermission] = [
            "became_read_only": .ask, "still_read_only": .auto, "off": .off, "untouched": .auto,
        ]
        let result = McpToolCatalog.confirm(incoming, definitions: definitions, permissions: before, runtimeConfig: .fallback)
        #expect(result.stillPending.isEmpty)
        #expect(result.snapshots.allSatisfy { !$0.pendingReview })
        #expect(result.permissions == [
            "became_read_only": .ask,
            "still_read_only": .auto,
            "off": .off,
            "untouched": .auto,
            "new_read_only": .auto,
            "new_write": .ask,
        ])
    }

    // MARK: - Duplicate tool names

    @Test("duplicate tool names from a server: only the first is kept, the rest are dropped, and the order is preserved")
    func duplicateToolNamesKeepFirst() {
        let definitions = [
            McpToolDefinition(name: "search", description: "first"),
            McpToolDefinition(name: "create", description: "only"),
            McpToolDefinition(name: "search", description: "second, different"),
        ]
        let snapshots = McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: definitions, runtimeConfig: .fallback
        )
        #expect(snapshots.map(\.toolName) == ["search", "create"])
        #expect(snapshots.first?.description == "first")
        #expect(McpToolCatalog.defaultPermissions(for: snapshots).count == 2)
    }

    @Test("snapshots of duplicate tool names can be stored as a whole (no primary-key conflict)")
    func duplicateToolNamesPersist() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let snapshots = McpToolCatalog.snapshots(
            serverId: catalogServerId,
            definitions: [McpToolDefinition(name: "dup"), McpToolDefinition(name: "dup"), McpToolDefinition(name: "other")],
            runtimeConfig: .fallback
        )
        try database.store.saveToolCatalog(
            serverId: catalogServerId, snapshots: snapshots,
            permissions: McpToolCatalog.defaultPermissions(for: snapshots)
        )
        #expect(try database.store.fetchToolSnapshots(serverId: catalogServerId).map(\.toolName) == ["dup", "other"])
    }

    // MARK: - Outbound filter

    @Test("quarantined tools, tools set to \"Don't use\" and oversized tools never appear in the outbound list")
    func outboundExcludesIsolatedOffAndOversized() {
        let isolated = makeSnapshot(name: "isolated", readOnly: true, pendingReview: true)
        let off = makeSnapshot(name: "off", readOnly: false)
        let oversized = makeSnapshot(name: "oversized", readOnly: true, oversized: true)
        let ok = makeSnapshot(name: "ok", readOnly: false)
        let snapshots = [isolated, off, oversized, ok]

        let outbound = McpToolCatalog.outboundSnapshots(snapshots, permissions: ["off": .off])
        #expect(outbound.map(\.toolName) == ["ok"])
    }

    @Test("oversized is judged by the byte size of description + input schema")
    func oversizedFollowsByteBudget() {
        let longDescription = String(repeating: "x", count: 200)
        let definition = McpToolDefinition(
            name: "big",
            description: longDescription,
            inputSchema: .object(JSONObject([("type", .string("object"))]))
        )
        let tight = McpRuntimeConfig(maxToolDefinitionBytes: 50)
        #expect(McpToolCatalog.isOversized(definition, runtimeConfig: tight))
        #expect(McpToolCatalog.isOversized(definition, runtimeConfig: .fallback) == false)
    }

    // MARK: - helpers

    /// Picks one `changed` vector from `tool-hash.json`: returns the before / after definitions and the two expected hashes.
    private func hashVector(_ caseId: String) throws -> (McpToolDefinition, McpToolDefinition, String, String) {
        let root = try McpFixture.json("tool-hash.json")
        let cases = try #require(root["cases"]?.arrayValue)
        let item = try #require(cases.first { $0["caseId"]?.stringValue == caseId })
        let before = try toolDefinition(try #require(item["before"]))
        let after = try toolDefinition(try #require(item["after"]))
        let beforeHash = try #require(item["expect"]?["beforeHash"]?.stringValue)
        let afterHash = try #require(item["expect"]?["afterHash"]?.stringValue)
        return (before, after, beforeHash, afterHash)
    }

    private func firstSnapshot(of definition: McpToolDefinition) throws -> McpToolSnapshot {
        try #require(McpToolCatalog.snapshots(
            serverId: catalogServerId, definitions: [definition], runtimeConfig: .fallback, existing: []
        ).first)
    }

    private func makeSnapshot(
        name: String,
        readOnly: Bool,
        pendingReview: Bool = false,
        oversized: Bool = false
    ) -> McpToolSnapshot {
        McpToolSnapshot(
            serverId: catalogServerId,
            toolName: name,
            title: name,
            description: "Tool \(name)",
            inputSchema: .object(JSONObject([("type", .string("object"))])),
            annotations: .object(JSONObject([("readOnlyHint", .bool(readOnly))])),
            contentHash: sha256Hex("\(name):\(readOnly)"),
            readOnly: readOnly,
            pendingReview: pendingReview,
            oversized: oversized
        )
    }
}
