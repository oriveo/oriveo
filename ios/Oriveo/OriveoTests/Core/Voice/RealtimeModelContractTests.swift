import Foundation
import Testing
@testable import Oriveo

/// Replays shared/voice-contracts/realtime-model.v1.json against RealtimeModelPolicy
/// (failureCases / pickerCases / capabilityCases / migrationCases / lifecycleCases / selectionCases /
/// catalogSequenceCases / constants / copy).
@Suite("Realtime model contract")
struct RealtimeModelContractTests {
    private typealias Policy = RealtimeModelPolicy

    static func repoFile(_ relative: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func json(_ relative: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: repoFile(relative))) as? [String: Any])
    }

    /// Full fixture; the later picker and migration groups also read from here.
    static func fixture() throws -> [String: Any] {
        try json("shared/voice-contracts/realtime-model.v1.json")
    }

    static func cases(_ group: String) throws -> [[String: Any]] {
        try #require(try fixture()[group] as? [[String: Any]], "\(group)")
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// Fixture input → signal; mismatched types and unknown fields are always ignored (same convention as the reference implementation).
    private static func signal(_ json: [String: Any]) -> Policy.FailureSignal {
        let http = number(json["httpStatus"]).flatMap { $0 == $0.rounded() ? Int($0) : nil }
        return Policy.FailureSignal(
            httpStatus: http,
            errorCode: json["errorCode"] as? String,
            endedReason: json["endedReason"] as? String,
            catalogHasModel: bool(json["catalogHasModel"]),
            elapsedSec: number(json["elapsedSec"]),
            maxSessionSec: number(json["maxSessionSec"]),
            connectError: bool(json["connectError"]),
            connectTimedOut: bool(json["connectTimedOut"]),
            reopenFailed: bool(json["reopenFailed"]),
            uplinkBacklogMs: number(json["uplinkBacklogMs"])
        )
    }

    @Test("constants match the fixture")
    func constants() throws {
        let c = try #require(try Self.fixture()["constants"] as? [String: Any])
        typealias K = Policy.Constants
        let ints: [String: Int] = [
            "connectTimeoutMs": K.connectTimeoutMs, "uplinkBacklogMs": K.uplinkBacklogMs,
            "autoReopenAttempts": K.autoReopenAttempts, "geminiHandleReconnects": K.geminiHandleReconnects,
        ]
        #expect(Set(c.keys) == Set(ints.keys))
        for (key, value) in ints { #expect((c[key] as? NSNumber)?.intValue == value, "\(key)") }
    }

    @Test("failure cases match the fixture")
    func failureCases() throws {
        let cases = try Self.cases("failureCases")
        #expect(cases.count >= 23)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let got = Policy.classifyFailure(Self.signal(input))
            #expect(got.category.rawValue == expected["category"] as? String, "\(id) category")
            #expect(got.copyKey == expected["copyKey"] as? String, "\(id) copyKey")
            #expect(got.copyArg.rawValue == expected["copyArg"] as? String, "\(id) copyArg")
            #expect(got.actions.map(\.rawValue) == expected["actions"] as? [String], "\(id) actions")
            let keys = try #require(expected["actionCopyKeys"] as? [Any], "\(id)")
            #expect(got.actionCopyKeys == keys.map { $0 as? String }, "\(id) actionCopyKeys")
            #expect(got.buttonCopyKeys == expected["buttonCopyKeys"] as? [String], "\(id) buttonCopyKeys")
        }
    }

    @Test("capability cases match the fixture")
    func capabilityCases() throws {
        let cases = try Self.cases("capabilityCases")
        #expect(cases.count >= 3)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let kind = try #require(Policy.ModelKind(rawValue: input["modelKind"] as? String ?? ""), "\(id)")
            let mode = try #require(Policy.ComposerMode(rawValue: input["mode"] as? String ?? ""), "\(id)")
            let got = Policy.capability(modelKind: kind, mode: mode)
            let strings: [String: String?] = [
                "attachments": got.attachments, "attachmentsReasonKey": got.attachmentsReasonKey,
                "webSearch": got.webSearch, "webSearchReasonKey": got.webSearchReasonKey,
                "thinking": got.thinking, "thinkingReasonKey": got.thinkingReasonKey,
                "tools": got.tools, "toolsReasonKey": got.toolsReasonKey,
                "regenerateEdit": got.regenerateEdit, "setAsDefault": got.setAsDefault,
                "dictation": got.dictation, "voiceEntry": got.voiceEntry,
                "visionTile": got.visionTile, "fileTile": got.fileTile, "panelSummary": got.panelSummary,
            ]
            let bools: [String: Bool] = ["sendsTools": got.sendsTools, "writesLastUsedModel": got.writesLastUsedModel]
            #expect(Set(expected.keys) == Set(strings.keys).union(bools.keys), "\(id) fields")
            for (key, value) in strings { #expect(value == expected[key] as? String, "\(id) \(key)") }
            for (key, value) in bools { #expect(Self.bool(expected[key]) == value, "\(id) \(key)") }
        }
    }

    @Test("lifecycle cases match the fixture")
    func lifecycleCases() throws {
        let cases = try Self.cases("lifecycleCases")
        #expect(cases.count >= 6)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let event = try #require(Policy.LifecycleEvent(rawValue: input["event"] as? String ?? ""), "\(id)")
            let got = Policy.lifecycle(event)
            #expect(got.action.rawValue == expected["action"] as? String, "\(id) action")
            #expect(got.reducerInput?.rawValue == expected["reducerInput"] as? String, "\(id) reducerInput")
        }
    }

    private static func connections(_ value: Any?) throws -> [Policy.Connection] {
        let list = value as? [[String: Any]] ?? []
        return try list.map { c in
            let auth = try #require(Policy.ConnectionAuth(rawValue: c["auth"] as? String ?? ""), "auth")
            let models = (c["textModels"] as? [[String: Any]] ?? []).map {
                Policy.TextModel(
                    model: $0["model"] as? String ?? "",
                    webSearch: bool($0["webSearch"]) == true,
                    thinking: bool($0["thinking"]) == true
                )
            }
            return Policy.Connection(
                id: c["id"] as? String ?? "", providerKind: c["providerKind"] as? String ?? "",
                auth: auth, textModels: models
            )
        }
    }

    private static func catalog(_ value: Any?) -> Policy.RealtimeCatalog {
        let map = value as? [String: [[String: Any]]] ?? [:]
        return map.mapValues { list in
            list.map { Policy.RealtimeCatalogEntry(model: $0["model"] as? String ?? "", isDefault: bool($0["isDefault"]) == true) }
        }
    }

    @Test("picker cases match the fixture")
    func pickerCases() throws {
        let cases = try Self.cases("pickerCases")
        #expect(cases.count >= 11)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let context = try #require(Policy.PickerContext(rawValue: input["context"] as? String ?? ""), "\(id)")
            let filters = try (input["filters"] as? [String] ?? []).map {
                try #require(Policy.PickerFilter(rawValue: $0), "\(id) filter \($0)")
            }
            let selected = (input["selected"] as? [String: Any]).map {
                Policy.PickerSelected(connectionId: $0["connectionId"] as? String ?? "", model: $0["model"] as? String ?? "")
            }
            let got = Policy.pickerRows(Policy.PickerInput(
                context: context, filters: filters,
                connections: try Self.connections(input["connections"]),
                realtimeCatalog: Self.catalog(input["realtimeCatalog"]),
                selected: selected
            ))
            #expect(got.showsRealtimeFilter == Self.bool(expected["showsRealtimeFilter"]), "\(id) showsRealtimeFilter")
            let groups = try #require(expected["groups"] as? [[String: Any]], "\(id)")
            let want = groups.map { g in
                Policy.PickerGroup(
                    connectionId: g["connectionId"] as? String ?? "",
                    rows: (g["rows"] as? [[String: Any]] ?? []).map {
                        Policy.PickerRow(
                            model: $0["model"] as? String ?? "",
                            kind: Policy.ModelKind(rawValue: $0["kind"] as? String ?? "") ?? .text
                        )
                    }
                )
            }
            #expect(got.groups == want, "\(id) groups")
            #expect(expected.keys.contains("selectedRow"), "\(id) selectedRow present")
            let wantRow = try (expected["selectedRow"] as? [String: Any]).map { r in
                Policy.SelectedRow(
                    connectionId: r["connectionId"] as? String ?? "",
                    model: r["model"] as? String ?? "",
                    kind: try #require(Policy.ModelKind(rawValue: r["kind"] as? String ?? ""), "\(id) selectedRow kind")
                )
            }
            #expect(got.selectedRow == wantRow, "\(id) selectedRow")
        }
    }

    /// The connection in the selection input carries only providerKind / auth; null = connection deleted.
    private static func selectionConnection(_ value: Any?) throws -> Policy.Connection? {
        guard let c = value as? [String: Any] else { return nil }
        let auth = try #require(Policy.ConnectionAuth(rawValue: c["auth"] as? String ?? ""), "auth")
        return Policy.Connection(id: c["id"] as? String ?? "", providerKind: c["providerKind"] as? String ?? "", auth: auth, textModels: [])
    }

    /// null = catalog not ready
    private static func optionalCatalog(_ value: Any?) -> Policy.RealtimeCatalog? {
        value is [String: Any] ? catalog(value) : nil
    }

    @Test("selection cases match the fixture")
    func selectionCases() throws {
        let cases = try Self.cases("selectionCases")
        #expect(cases.count >= 8)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let got = Policy.realtimeSelection(
                connection: try Self.selectionConnection(input["connection"]),
                model: input["model"] as? String ?? "",
                realtimeCatalog: Self.optionalCatalog(input["realtimeCatalog"])
            )
            #expect(Set(expected.keys) == ["isRealtime", "catalogReady"], "\(id) fields")
            #expect(got.isRealtime == Self.bool(expected["isRealtime"]), "\(id) isRealtime")
            #expect(got.catalogReady == Self.bool(expected["catalogReady"]), "\(id) catalogReady")
        }
    }

    @Test("awaits_voice_catalog_cases: waits only when the catalog is nil and the model is not in the text table")
    func awaits_voice_catalog_cases() {
        func conn(_ auth: Policy.ConnectionAuth, text: [String] = []) -> Policy.Connection {
            Policy.Connection(
                id: "c1", providerKind: "openAI", auth: auth,
                textModels: text.map { Policy.TextModel(model: $0, webSearch: false, thinking: false) }
            )
        }
        let ready: Policy.RealtimeCatalog = ["openAI": [Policy.RealtimeCatalogEntry(model: "gpt-realtime", isDefault: true)]]
        let cases: [(id: String, connection: Policy.Connection?, model: String, catalog: Policy.RealtimeCatalog?, awaits: Bool)] = [
            ("nil-catalog-not-in-text", conn(.apiKey, text: ["gpt-5.4"]), "gpt-realtime", nil, true),
            ("nil-catalog-empty-text", conn(.apiKey), "custom-model", nil, true),
            ("nil-catalog-in-text", conn(.apiKey, text: ["gpt-5.4"]), "gpt-5.4", nil, false),
            ("subscription", conn(.subscription), "gpt-realtime", nil, false),
            ("relay", conn(.relay), "gpt-realtime", nil, false),
            ("managed", conn(.managed), "gpt-realtime", nil, false),
            ("free", conn(.free), "gpt-realtime", nil, false),
            ("connection-gone", nil, "gpt-realtime", nil, false),
            ("empty-model", conn(.apiKey), "", nil, false),
            ("catalog-ready", conn(.apiKey), "gpt-realtime", ready, false),
            ("catalog-ready-empty", conn(.apiKey), "gpt-realtime", [:], false),
        ]
        for item in cases {
            let got = Policy.awaitsVoiceCatalog(connection: item.connection, model: item.model, realtimeCatalog: item.catalog)
            #expect(got == item.awaits, "\(item.id)")
        }
    }

    @Test("catalog sequence cases match the fixture")
    func catalogSequenceCases() throws {
        let cases = try Self.cases("catalogSequenceCases")
        #expect(cases.count >= 2)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [[String: Any]], "\(id)")
            let catalogs = try #require(input["catalogs"] as? [Any], "\(id)").map { Self.optionalCatalog($0) }
            let got = Policy.catalogSequence(
                connection: try Self.selectionConnection(input["connection"]),
                model: input["model"] as? String ?? "",
                catalogs: catalogs
            )
            let want = expected.map {
                Policy.CatalogStep(recompute: Self.bool($0["recompute"]) == true, isRealtime: Self.bool($0["isRealtime"]) == true)
            }
            #expect(got == want, "\(id) steps")
        }
    }

    @Test("migration cases match the fixture")
    func migrationCases() throws {
        let cases = try Self.cases("migrationCases")
        #expect(cases.count >= 10)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any], "\(id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let oldChoice = (input["oldChoice"] as? [String: Any]).map {
                Policy.OldRealtimeChoice(
                    providerKind: $0["providerKind"] as? String ?? "",
                    model: $0["model"] as? String ?? "",
                    connectionId: $0["connectionId"] as? String ?? ""
                )
            }
            let answer: Policy.MigrationAnswer? = try (input["answer"] as? String).map {
                try #require(Policy.MigrationAnswer(rawValue: $0), "\(id) answer")
            }
            let got = Policy.migration(Policy.MigrationInput(
                oldKeyPresent: Self.bool(input["oldKeyPresent"]) == true,
                oldChoice: oldChoice,
                realtimeCatalog: Self.catalog(input["realtimeCatalog"]),
                connections: try Self.connections(input["connections"]),
                consented: Self.bool(input["consented"]) == true,
                answer: answer,
                disclosureDeclined: Self.bool(input["disclosureDeclined"]) == true
            ))
            #expect(Set(expected.keys) == ["showPrompt", "result", "deleteOldKeys", "showDisclosure"], "\(id) fields")
            #expect(got.showPrompt == Self.bool(expected["showPrompt"]), "\(id) showPrompt")
            #expect(got.result.rawValue == expected["result"] as? String, "\(id) result")
            #expect(got.deleteOldKeys == Self.bool(expected["deleteOldKeys"]), "\(id) deleteOldKeys")
            #expect(got.showDisclosure == Self.bool(expected["showDisclosure"]), "\(id) showDisclosure")
        }
    }

    /// Current copy keys (excluding retiredKeys and non-key values such as failureArg) go into Voice.xcstrings:
    /// source string = the mapped value in p3-copy settingsKeyMap.ios; without a mapping, the key en original text is used.
    @Test("copy keys map to Voice.xcstrings source strings")
    func copyKeysInVoiceTable() throws {
        let copy = try #require(try Self.fixture()["copy"] as? [String: Any])
        var keys: [String] = []
        for section in ["failure", "actions"] {
            let map = try #require(copy[section] as? [String: Any], "\(section)")
            keys += map.values.compactMap { $0 as? String }
        }
        for section in ["capability", "picker", "migration", "composer", "disclosure"] {
            keys += try #require(copy[section] as? [String], "\(section)")
        }
        // Every key produced by classification and projection is also in the copy section.
        let produced = Set(Policy.FailureCategory.allCases.map { Policy.copyKey(for: $0) })
            .union(Policy.FailureAction.allCases.compactMap { Policy.copyKey(for: $0) })
        #expect(produced.isSubset(of: Set(keys)))

        let p3 = try Self.json("shared/voice-contracts/p3-copy.v1.json")
        let iosMap = try #require((p3["settingsKeyMap"] as? [String: Any])?["ios"] as? [String: Any])
        let p3Keys = try #require(p3["keys"] as? [String: [String: Any]])
        let table = try Self.json("ios/Oriveo/Oriveo/Voice.xcstrings")
        let strings = try #require(table["strings"] as? [String: Any])
        for key in Set(keys).sorted() {
            let en = (p3Keys[key]?["values"] as? [String: String])?["en"]
            let source = iosMap[key] as? String ?? en
            #expect(source != nil, "\(key) has no iOS key")
            if let source { #expect(strings[source] != nil, "\(key) missing in Voice.xcstrings") }
        }
    }
}
