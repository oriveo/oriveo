import Foundation
import Testing
@testable import Oriveo

/// Contract-driven tests for the local lifecycle invariants of capability preferences.
/// Single source of truth: shared `model-contracts/capability_preference_sync.v1.json#localLifecycleInvariants`.
/// Each fixture case maps to exactly one test below; `fixtureCaseSetMatchesImplementedCases` locks the set.
@MainActor
@Suite("Capability preference local lifecycle invariants", .serialized)
struct CapabilityPreferenceLocalLifecycleTests {
    private static let implementedCaseIDs: Set<String> = [
        "CPL-01_merge_keeps_local_record_beyond_wire_cap",
        "CPL-02_self_echo_keeps_uppercase_conversation_lookup",
        "CPL-03_send_resolution_forward_ports_same_transport",
        "CPL-04_draft_migration_forward_ports_same_transport",
        "CPL-05_local_eviction_by_recency_not_record_id",
        "CPL-06_merge_keeps_local_record_pushed_out_by_remote",
    ]

    @Test("CPL fixture case set matches the implemented CPL tests")
    func fixtureCaseSetMatchesImplementedCases() throws {
        let ids = try Self.cases().compactMap { $0["caseId"] as? String }
        #expect(ids.count == Self.implementedCaseIDs.count)
        #expect(Set(ids) == Self.implementedCaseIDs)
    }

    @Test("CPL-01 merging the self echo keeps the local record beyond the wire cap")
    func cpl01MergeKeepsLocalRecordBeyondWireCap() throws {
        let fixture = try Self.fixtureCase("CPL-01_merge_keeps_local_record_beyond_wire_cap")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let identity = try Self.identity(fixture)
        let seed = try #require(fixture["seed"] as? [String: Any])
        let count = try #require(seed["count"] as? Int)
        let values = try Self.values(seed["values"])
        for index in 0..<count {
            store.setCapabilityPreferences(
                values, providerID: identity.providerID, modelID: identity.modelID,
                conversationID: try Self.conversationID(index: index), transportIdentity: identity.transport
            )
        }
        let expected = try #require(fixture["expected"] as? [String: Any])

        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(exported.records.count == expected["exportedRecordCount"] as? Int)
        CapabilityPreferenceSyncContract.merge(exported, settings: store)

        let lookup = try Self.uuid(expected["lookupConversationId"])
        #expect(store.capabilityPreferences(
            providerID: identity.providerID, modelID: identity.modelID,
            conversationID: lookup, transportIdentity: identity.transport
        ) == (try Self.values(expected["lookupValues"])))
    }

    @Test("CPL-02 self echo keeps both uppercase and lowercase conversation lookups")
    func cpl02SelfEchoKeepsUppercaseConversationLookup() throws {
        let fixture = try Self.fixtureCase("CPL-02_self_echo_keeps_uppercase_conversation_lookup")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let identity = try Self.identity(fixture)
        let write = try #require(fixture["write"] as? [String: Any])
        let conversation = try Self.uuid(write["conversationId"])
        store.setCapabilityPreferences(
            try Self.values(write["values"]), providerID: identity.providerID, modelID: identity.modelID,
            conversationID: conversation, transportIdentity: identity.transport
        )
        let expected = try #require(fixture["expected"] as? [String: Any])

        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(exported.records.map(\.conversationId) == [expected["exportedConversationId"] as? String])
        CapabilityPreferenceSyncContract.merge(exported, settings: store)

        let lookups = try #require(expected["lookups"] as? [[String: Any]])
        #expect(lookups.count == 2)
        for lookup in lookups {
            let id = try Self.uuid(lookup["conversationId"])
            #expect(store.capabilityPreferences(
                providerID: identity.providerID, modelID: identity.modelID,
                conversationID: id, transportIdentity: identity.transport
            ) == (try Self.values(lookup["values"])), "lookup \(lookup["conversationId"] ?? "")")
        }
    }

    @Test("CPL-03 send and display reads forward-port across runtime revisions of the same transport")
    func cpl03SendResolutionForwardPortsSameTransport() throws {
        let fixture = try Self.fixtureCase("CPL-03_send_resolution_forward_ports_same_transport")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let write = try #require(fixture["write"] as? [String: Any])
        let providerID = try Self.uuid(write["providerId"])
        let modelID = try #require(write["canonicalModelId"] as? String)
        let conversation = try Self.uuid(write["conversationId"])
        store.setCapabilityPreferences(
            try Self.values(write["values"]), providerID: providerID, modelID: modelID,
            conversationID: conversation, transportIdentity: try #require(write["transportIdentity"] as? String)
        )

        let reads = try #require(fixture["reads"] as? [[String: Any]])
        #expect(reads.count == 3)
        for read in reads {
            let path = try #require(read["path"] as? String)
            let transport = try #require(read["transportIdentity"] as? String)
            let actual: CapabilityPreferenceValues
            switch path {
            case "send":
                // Same store entry and same projections as ChatManager.requestedCapabilitySelection:
                // web intent comes from the outbound `resolve`, the reasoning mirror from
                // `displaySelection` (nil means no layer ever stored a tier).
                let scopes = store.capabilityScopeValues(
                    providerID: providerID, modelID: modelID, conversationID: conversation,
                    skillID: nil, transportIdentity: transport
                )
                let outbound = CapabilityPreferenceValueResolver.resolve(
                    conversation: scopes.conversation, skill: scopes.skill,
                    connectionModel: scopes.connectionModel, connection: scopes.connection
                )
                let mirrored = CapabilityPreferenceValueResolver.displaySelection(
                    conversation: scopes.conversation, skill: scopes.skill,
                    connectionModel: scopes.connectionModel, connection: scopes.connection
                )
                actual = CapabilityPreferenceValues(web: outbound.web, reasoningIntent: mirrored.reasoningIntent)
            case "display":
                actual = store.displayCapabilityPreferences(
                    providerID: providerID, modelID: modelID, conversationID: conversation,
                    skillID: nil, transportIdentity: transport
                )
            default:
                Issue.record("unknown read path \(path)")
                continue
            }
            #expect(actual == (try Self.values(read["expected"])), "\(path) @ \(transport)")
        }
    }

    @Test("CPL-04 draft migration forward-ports a draft written under an older runtime revision")
    func cpl04DraftMigrationForwardPortsSameTransport() throws {
        let fixture = try Self.fixtureCase("CPL-04_draft_migration_forward_ports_same_transport")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let write = try #require(fixture["write"] as? [String: Any])
        let providerID = try Self.uuid(write["providerId"])
        let modelID = try #require(write["canonicalModelId"] as? String)
        let draft = try Self.uuid(write["draftId"])
        let draftTransport = try #require(write["transportIdentity"] as? String)
        store.setCapabilityPreferences(
            try Self.values(write["values"]), providerID: providerID, modelID: modelID,
            conversationID: draft, transportIdentity: draftTransport
        )
        let action = try #require(fixture["action"] as? [String: Any])
        let destination = try Self.uuid(action["migrateDraftTo"])
        let currentTransport = try #require(action["currentTransportIdentity"] as? String)

        store.migrateCapabilitySession(
            providerID: providerID, modelID: modelID, from: draft, to: destination,
            transportIdentity: currentTransport
        )

        let expected = try #require(fixture["expected"] as? [String: Any])
        let lookup = try #require(expected["conversationLookup"] as? [String: Any])
        let lookupID = try Self.uuid(lookup["conversationId"])
        #expect(store.capabilityPreferences(
            providerID: providerID, modelID: modelID, conversationID: lookupID,
            transportIdentity: try #require(lookup["transportIdentity"] as? String)
        ) == (try Self.values(lookup["values"])))
        let draftRemains = try #require(expected["draftRemains"] as? Bool)
        for transport in [draftTransport, currentTransport] {
            let remaining = store.capabilityPreferences(
                providerID: providerID, modelID: modelID, conversationID: draft, transportIdentity: transport
            )
            #expect((remaining != nil) == draftRemains, "draft @ \(transport)")
        }
    }

    @Test("CPL-05 local eviction drops the least recently expressed record, not the lowest record id")
    func cpl05LocalEvictionByRecencyNotRecordID() throws {
        let fixture = try Self.fixtureCase("CPL-05_local_eviction_by_recency_not_record_id")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let identity = try Self.identity(fixture)
        let seed = try #require(fixture["seed"] as? [String: Any])
        #expect(seed["writeOrder"] as? String == "ascending index")
        let count = try #require(seed["count"] as? Int)
        let seedValues = try Self.values(seed["values"])
        for index in 0..<count {
            store.setCapabilityPreferences(
                seedValues, providerID: identity.providerID, modelID: identity.modelID,
                conversationID: try Self.conversationID(index: index), transportIdentity: identity.transport
            )
        }
        let write = try #require(fixture["write"] as? [String: Any])
        store.setCapabilityPreferences(
            try Self.values(write["values"]), providerID: identity.providerID, modelID: identity.modelID,
            conversationID: try Self.uuid(write["conversationId"]),
            transportIdentity: identity.transport
        )

        let expected = try #require(fixture["expected"] as? [String: Any])
        func lookup(_ raw: String) throws -> CapabilityPreferenceValues? {
            store.capabilityPreferences(
                providerID: identity.providerID, modelID: identity.modelID,
                conversationID: try Self.uuid(raw), transportIdentity: identity.transport
            )
        }
        for raw in try #require(expected["retained"] as? [String]) {
            #expect(try lookup(raw) != nil, "retained \(raw)")
        }
        for raw in try #require(expected["evicted"] as? [String]) {
            #expect(try lookup(raw) == nil, "evicted \(raw)")
        }
        // Every seeded record is synchronizable, so the export count equals the local record count.
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.count
            == expected["localRecordCount"] as? Int)
    }

    @Test("CPL-06 a remote record that pushes a local record out of the envelope does not drop it locally")
    func cpl06MergeKeepsLocalRecordPushedOutByRemote() throws {
        let fixture = try Self.fixtureCase("CPL-06_merge_keeps_local_record_pushed_out_by_remote")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let identity = try Self.identity(fixture)
        let seed = try #require(fixture["seed"] as? [String: Any])
        #expect(seed["writeOrder"] as? String == "ascending index")
        let count = try #require(seed["count"] as? Int)
        let values = try Self.values(seed["values"])
        for index in 0..<count {
            store.setCapabilityPreferences(
                values, providerID: identity.providerID, modelID: identity.modelID,
                conversationID: try Self.conversationID(index: index), transportIdentity: identity.transport
            )
        }
        let extraObject = try #require(fixture["remoteExtraRecord"] as? [String: Any])
        let extra = try JSONDecoder().decode(
            CapabilityPreferenceSyncRecord.self, from: JSONSerialization.data(withJSONObject: extraObject)
        )
        let local = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        let remote = CapabilityPreferenceSyncPayload(
            schemaVersion: 2,
            records: (local.records + [extra]).sorted { $0.recordId < $1.recordId },
            tombstones: local.tombstones
        )

        CapabilityPreferenceSyncContract.merge(remote, settings: store)

        let expected = try #require(fixture["expected"] as? [String: Any])
        #expect(store.capabilityPreferences(
            providerID: identity.providerID, modelID: identity.modelID,
            conversationID: try Self.uuid(expected["lookupConversationId"]), transportIdentity: identity.transport
        ) == (try Self.values(expected["lookupValues"])))
        #expect(store.connectionCapabilityPreferences(
            providerID: identity.providerID, modelID: identity.modelID, transportIdentity: identity.transport
        ) == (try Self.values(expected["connectionValues"])))
        #expect(CapabilityPreferenceSyncContract.exportPayload(settings: store).records.count
            == expected["exportedRecordCount"] as? Int)
    }

    /// iOS-only companion of rule `mergeNeverDropsLocalOutsideWire`: a record that can never enter
    /// the envelope (web = custom selects a local-only fragment) must survive a merge as well.
    @Test("CPL-iOS-custom_survives_merge a local web=custom record survives merging the self echo")
    func cplIOSCustomSurvivesMerge() throws {
        let fixture = try Self.fixtureCase("CPL-02_self_echo_keeps_uppercase_conversation_lookup")
        let (store, cleanup) = Self.isolatedStore()
        defer { cleanup() }
        let identity = try Self.identity(fixture)
        let conversation = UUID()
        let custom = CapabilityPreferenceValues(web: .custom, reasoningIntent: "deep")
        store.setCapabilityPreferences(
            custom, providerID: identity.providerID, modelID: identity.modelID,
            conversationID: conversation, transportIdentity: identity.transport
        )

        let exported = CapabilityPreferenceSyncContract.exportPayload(settings: store)
        #expect(exported.records.isEmpty)
        CapabilityPreferenceSyncContract.merge(exported, settings: store)

        #expect(store.capabilityPreferences(
            providerID: identity.providerID, modelID: identity.modelID,
            conversationID: conversation, transportIdentity: identity.transport
        ) == custom)
    }

    // MARK: - Fixture helpers

    private struct Identity {
        let providerID: UUID
        let modelID: String
        let transport: String
    }

    private static func isolatedStore() -> (GenerationParameterSettingsStore, () -> Void) {
        let suiteName = "capability-local-lifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = GenerationParameterSettingsStore(
            defaults: defaults, capabilityDidChange: {}, generationDidChange: {}
        )
        return (store, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static func identity(_ fixture: [String: Any]) throws -> Identity {
        let raw = try #require(fixture["identity"] as? [String: Any])
        let transport = try #require(raw["transportIdentity"] as? String)
        let decoded = try #require(CapabilityPreferenceRuntimeIdentity.decode(transport))
        #expect(decoded.finalTransport == raw["finalTransport"] as? String)
        #expect(decoded.runtimeRevision == raw["runtimeRevision"] as? String)
        return Identity(
            providerID: try Self.uuid(raw["providerId"]),
            modelID: try #require(raw["canonicalModelId"] as? String),
            transport: transport
        )
    }

    /// Mirrors the fixture `conversationIdPattern` `00000000-0000-4000-8000-{index:012d}`.
    private static func conversationID(index: Int) throws -> UUID {
        try #require(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)))
    }

    private static func values(_ raw: Any?) throws -> CapabilityPreferenceValues {
        let object = try #require(raw as? [String: Any])
        let rawWeb = try #require(object["web"] as? String)
        let web = try #require(CapabilityWebPreference(rawValue: rawWeb))
        return CapabilityPreferenceValues(web: web, reasoningIntent: object["reasoningIntent"] as? String)
    }

    private static func uuid(_ raw: Any?) throws -> UUID {
        let string = try #require(raw as? String)
        return try #require(UUID(uuidString: string))
    }

    private static func fixtureCase(_ id: String) throws -> [String: Any] {
        try #require(try cases().first { $0["caseId"] as? String == id })
    }

    private static func cases() throws -> [[String: Any]] {
        let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any]
        let section = try #require(contract?["localLifecycleInvariants"] as? [String: Any])
        return try #require(section["cases"] as? [[String: Any]])
    }

    private static func fixtureURL() -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != "/" {
            let candidate = current
                .appendingPathComponent("\u{5171}\u{4EAB}")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent("capability_preference_sync.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current.deleteLastPathComponent()
        }
        preconditionFailure("Unable to locate capability_preference_sync.v1.json")
    }
}
