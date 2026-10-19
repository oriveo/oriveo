import Foundation
import OriveoProviderKit
import Testing

// Runs each *Cases group of `shared/context-contracts/memory-items.v2.json` case by case: inputs are mapped by fixture field name onto the production
// MemoryItems pure functions, the output is converted to a JSON shape, and every key that appears in expected is compared (strings byte for byte); the test name is the fixture case id.

/// Generic JSON value for the fixture; it can be encoded back to feed Decodable input types.
private indirect enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let value): "\(value)"
        case .number(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .array(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .object(let fields):
            "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!.description)" }.joined(separator: ", ") + "}"
        }
    }

    subscript(key: String) -> JSONValue {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }

    var isNull: Bool { self == .null }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    func has(_ key: String) -> Bool {
        if case .object(let fields) = self { return fields[key] != nil }
        return false
    }

    /// Re-encode then decode as T (MemoryItem goes through the production decoder, which fills in missing fields).
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func strings(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
    }
}

/// expected is a subset of actual: objects compare only the keys expected has; arrays item by item with equal counts.
private func subsetMismatch(expected: JSONValue, actual: JSONValue, path: String) -> String? {
    switch (expected, actual) {
    case (.object(let expectedFields), .object(let actualFields)):
        for key in expectedFields.keys.sorted() {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard let actualValue = actualFields[key] else { return "\(childPath): missing" }
            if let mismatch = subsetMismatch(expected: expectedFields[key]!, actual: actualValue, path: childPath) {
                return mismatch
            }
        }
        return nil
    case (.array(let expectedItems), .array(let actualItems)):
        guard expectedItems.count == actualItems.count else {
            return "\(path): count \(actualItems.count) != \(expectedItems.count) actual \(actual)"
        }
        for (index, (expectedItem, actualItem)) in zip(expectedItems, actualItems).enumerated() {
            if let mismatch = subsetMismatch(expected: expectedItem, actual: actualItem, path: "\(path)[\(index)]") {
                return mismatch
            }
        }
        return nil
    case (.string(let expectedText), .string(let actualText)):
        return Array(expectedText.utf8) == Array(actualText.utf8) ? nil : "\(path): \(actual) != \(expected)"
    default:
        return expected == actual ? nil : "\(path): \(actual) != \(expected)"
    }
}

private enum MemoryContract {
    static let root: JSONValue = (try? JSONDecoder().decode(
        JSONValue.self, from: ContextContractFixture.data("memory-items.v2.json")
    )) ?? .null

    static func caseIds(_ group: String, where include: (JSONValue) -> Bool = { _ in true }) -> [String] {
        root[group].array.filter { include($0["input"]) }.compactMap { $0["id"].string }
    }

    static func item(_ group: String, _ caseId: String) throws -> (input: JSONValue, expected: JSONValue) {
        let found = try #require(root[group].array.first { $0["id"].string == caseId }, "\(group)/\(caseId)")
        return (found["input"], found["expected"])
    }
}

private func check(_ caseId: String, expected: JSONValue, actual: JSONValue) {
    let mismatch = subsetMismatch(expected: expected, actual: actual, path: "")
    #expect(mismatch == nil, "\(caseId): \(mismatch ?? "")")
}

private func items(_ value: JSONValue) throws -> [MemoryItem] {
    try value.decode([MemoryItem].self)
}

private func itemsJSON(_ items: [MemoryItem]) throws -> JSONValue {
    .array(try items.map { try JSONValue.encoded($0) })
}

private func status(_ value: JSONValue, _ caseId: String) throws -> MemoryStatus {
    try #require(value.string.flatMap(MemoryStatus.init(rawValue:)), "\(caseId)")
}

private func version(_ value: JSONValue, _ caseId: String) throws -> MemoryVersion? {
    if value.isNull { return nil }
    return MemoryVersion(
        revision: try #require(value["revision"].int, "\(caseId)"),
        mutationId: try #require(value["mutationId"].string, "\(caseId)"),
        status: try status(value["status"], caseId),
        content: try #require(value["content"].string, "\(caseId)"),
        sensitivity: try sensitivity(value["sensitivity"], caseId)
    )
}

/// When the case input omits sensitivity it is normal.
private func sensitivity(_ value: JSONValue, _ caseId: String) throws -> MemorySensitivity {
    if value.isNull { return .normal }
    return try #require(value.string.flatMap(MemorySensitivity.init(rawValue:)), "\(caseId)")
}

private func pendingEdit(_ value: JSONValue, _ caseId: String) throws -> MemoryPendingEdit? {
    if value.isNull { return nil }
    return MemoryPendingEdit(
        mutationId: try #require(value["mutationId"].string, "\(caseId)"),
        baseRevision: try #require(value["baseRevision"].int, "\(caseId)"),
        status: try status(value["status"], caseId),
        content: try #require(value["content"].string, "\(caseId)"),
        sensitivity: try sensitivity(value["sensitivity"], caseId)
    )
}

private func prefs(_ value: JSONValue) -> MemoryLegacyPrefs {
    MemoryLegacyPrefs(
        memoryText: value["memoryText"].string,
        memoryTextDigest: value["memoryTextDigest"].string,
        antiForgetEnabled: value["antiForgetEnabled"].bool ?? false,
        antiForgetText: value["antiForgetText"].string,
        memoryUpdatedAt: value["memoryUpdatedAt"].string
    )
}

private func compileJSON(_ compile: MemoryLegacyCompile?) -> JSONValue {
    compile.map {
        .object(["memoryText": .string($0.memoryText), "memoryTextDigest": .string($0.memoryTextDigest)])
    } ?? .null
}

/// The new mutation used when the original conflict item is pushed as a local change, generated by the caller; the fixture does not compare it.
private let conflictMutationId = "f0000000-0000-4000-8000-0000000000ff"
/// The deletion time of the tombstone when a legacy client clears memoryText, supplied by the caller; the fixture does not compare it.
private let legacyDeletedAt = "2026-10-16T00:00:00Z"

@Suite("ContextContractMemoryItems")
struct ContextContractMemoryItemsTests {
    @Test("constants")
    func constants() throws {
        let root = MemoryContract.root
        let constants = root["constants"]
        #expect(MemoryContract.caseIds("canonicalCases").count == 2)
        // Key order follows the CodingKeys declaration (JSONEncoder does not guarantee output order).
        #expect(MemoryItem.fieldOrder == root["fieldOrder"].array.compactMap(\.string))
        #expect(MemoryItems.schemaVersion == root["defaults"]["schemaVersion"].int)
        #expect(MemoryItems.uuidNamespace == constants["uuidNamespace"]["value"].string)
        #expect(MemoryItems.legacyMemoryTextKey == constants["legacyKeys"]["memoryText"].string)
        #expect(MemoryItems.legacyAntiForgetKey == constants["legacyKeys"]["antiForget"].string)
        #expect(MemoryItems.migrationMutationSuffix == constants["migrationMutationSuffix"].string)
        #expect(MemoryItems.contentMaxCodePoints == constants["contentMaxCodePoints"].int)
        #expect(MemoryItems.organizeSystemPrompt == constants["organizeSystemPrompt"].string)
        #expect(MemoryItems.organizeMaxItems == constants["organizeMaxItems"].int)
        #expect(MemoryItems.rawViewSeparator == constants["rawViewSeparator"].string)
    }

    @Test(arguments: MemoryContract.caseIds("canonicalCases"))
    func canonical(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("canonicalCases", caseId)
        let actual = MemoryItems.canonical(try input.decode(MemoryItem.self))
        check(caseId, expected: expected, actual: try JSONValue.encoded(actual))
    }

    @Test(arguments: MemoryContract.caseIds("migrationCases"))
    func migrate(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("migrationCases", caseId)
        let actual = MemoryItems.migrate(
            uid: try #require(input["uid"].string),
            deviceId: try #require(input["deviceId"].string),
            prefs: prefs(input)
        )
        check(caseId, expected: expected, actual: try itemsJSON(actual))
    }

    @Test(arguments: MemoryContract.caseIds("injectableCases"))
    func injectable(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("injectableCases", caseId)
        let now = try #require(input["now"].string.flatMap(MemoryItems.instant))
        let actual = MemoryItems.injectable(
            try items(input["items"]),
            conversationId: input["conversationId"].string,
            folderId: input["folderId"].string,
            now: now
        )
        check(caseId, expected: expected, actual: .object([
            "standingInstructions": .strings(actual.standingInstructions.map(\.id)),
            "memory": .strings(actual.memory.map(\.id)),
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("orderCases"))
    func listOrder(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("orderCases", caseId)
        let actual = MemoryItems.listOrder(try items(input["items"]))
        check(caseId, expected: expected, actual: .strings(actual.map(\.id)))
    }

    @Test(arguments: MemoryContract.caseIds("tombstoneCases"))
    func tombstone(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("tombstoneCases", caseId)
        let actual = MemoryItems.tombstone(
            try input["item"].decode(MemoryItem.self),
            mutationId: try #require(input["mutationId"].string),
            deviceId: try #require(input["deviceId"].string),
            deletedAt: try #require(input["deletedAt"].string)
        )
        check(caseId, expected: expected, actual: try JSONValue.encoded(actual))
    }

    @Test(arguments: MemoryContract.caseIds("mergeCases"))
    func merge(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("mergeCases", caseId)
        let actual = MemoryItems.merge(
            local: try version(input["local"], caseId),
            remote: try #require(try version(input["remote"], caseId)),
            pending: try pendingEdit(input["pending"], caseId)
        )
        check(caseId, expected: expected, actual: .object([
            "result": .string(actual.result.rawValue),
            "keep": .strings(actual.keep),
            "status": .string(actual.status.rawValue),
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("pushCases"))
    func push(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("pushCases", caseId)
        let action = MemoryItems.push(
            remote: try version(input["remote"], caseId),
            pending: try #require(try pendingEdit(input["pending"], caseId))
        )
        let actual: JSONValue = switch action {
        case .write(let revision): .object(["action": .string("write"), "revision": .number(Double(revision))])
        case .confirmed: .object(["action": .string("confirmed")])
        case .dropPending: .object(["action": .string("dropPending")])
        case .conflict: .object(["action": .string("conflict")])
        case .retract(let revision): .object(["action": .string("retract"), "revision": .number(Double(revision))])
        case .localOnly(let baseRevision):
            .object(["action": .string("localOnly"), "baseRevision": .number(Double(baseRevision))])
        }
        check(caseId, expected: expected, actual: actual)
    }

    @Test(arguments: MemoryContract.caseIds("conflictCases"))
    func conflictCopy(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("conflictCases", caseId)
        let pending = try input["pending"].decode(MemoryItem.self)
        let actual = MemoryItems.conflict(
            itemId: try #require(input["itemId"].string),
            pending: pending,
            remote: try input["remote"].decode(MemoryItem.self),
            mutationId: conflictMutationId,
            deviceId: pending.deviceId
        )
        check(caseId, expected: expected, actual: .object([
            "original": try JSONValue.encoded(actual.original),
            "copy": try JSONValue.encoded(actual.copy),
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("compileCases"))
    func compileLegacy(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("compileCases", caseId)
        let actual = MemoryItems.compileLegacy(uid: try #require(input["uid"].string), items: try items(input["items"]))
        check(caseId, expected: expected, actual: compileJSON(actual))
    }

    @Test(arguments: MemoryContract.caseIds("legacySyncCases"))
    func legacySync(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("legacySyncCases", caseId)
        let actual = MemoryItems.legacySync(
            uid: try #require(input["uid"].string),
            migrated: try #require(input["migrated"].bool as Bool?),
            deviceId: try #require(input["deviceId"].string),
            items: try items(input["items"]),
            prefs: prefs(input["prefs"]),
            deletedAt: legacyDeletedAt
        )
        check(caseId, expected: expected, actual: .object([
            "create": try itemsJSON(actual.create),
            "update": try itemsJSON(actual.update),
            "writePrefs": actual.writePrefs.map {
                .object([
                    "memoryText": .string($0.memoryText),
                    "memoryTextDigest": .string($0.memoryTextDigest),
                    "textChanged": .bool(actual.textChanged),
                ])
            } ?? .null,
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("rawViewCases") { !$0.has("text") })
    func rawRender(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("rawViewCases", caseId)
        let actual = MemoryItems.rawRender(try items(input["items"]))
        check(caseId, expected: expected, actual: .object(["text": .string(actual)]))
    }

    @Test(arguments: MemoryContract.caseIds("rawViewCases") { $0.has("text") })
    func rawApply(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("rawViewCases", caseId)
        var newIds = input["newIds"].array.compactMap(\.string).makeIterator()
        let result = MemoryItems.rawApply(
            try items(input["items"]),
            text: try #require(input["text"].string),
            newId: { newIds.next() ?? "" }
        )
        let actual: JSONValue = switch result {
        case .tooLong(let index):
            .object(["error": .string("tooLong"), "index": .number(Double(index))])
        case .ops(let ops):
            .object(["ops": .array(ops.map { op in
                switch op {
                case .update(let id, let content):
                    .object(["op": .string("update"), "id": .string(id), "content": .string(content)])
                case .create(let id, let kind, let content):
                    .object([
                        "op": .string("create"), "id": .string(id),
                        "kind": .string(kind.rawValue), "content": .string(content),
                    ])
                case .delete(let id):
                    .object(["op": .string("delete"), "id": .string(id)])
                }
            })])
        }
        check(caseId, expected: expected, actual: actual)
    }

    @Test(arguments: MemoryContract.caseIds("organizeCases") { $0.has("content") })
    func organizeRequest(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("organizeCases", caseId)
        let actual = MemoryItems.organizeRequest(content: try #require(input["content"].string))
        check(caseId, expected: expected, actual: .object([
            "system": .string(actual.system),
            "messages": .array(actual.messages.map {
                .object(["role": .string($0.role.rawValue), "text": .string($0.text)])
            }),
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("organizeCases") { $0.has("response") })
    func organizeParse(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("organizeCases", caseId)
        let actual = MemoryItems.organizeParse(try #require(input["response"].string))
        check(caseId, expected: expected, actual: .array(actual.map {
            .object(["kind": .string($0.kind.rawValue), "content": .string($0.content)])
        }))
    }

    @Test(arguments: MemoryContract.caseIds("backupCases") { !$0.has("mode") })
    func backupSection(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("backupCases", caseId)
        let actual = MemoryItems.backupSection(try items(input["items"]))
        check(caseId, expected: expected, actual: .object([
            "memorySchemaVersion": .number(Double(actual.memorySchemaVersion)),
            "memoryItems": try itemsJSON(actual.memoryItems),
        ]))
    }

    @Test(arguments: MemoryContract.caseIds("backupCases") { $0.has("mode") })
    func backupMerge(_ caseId: String) throws {
        let (input, expected) = try MemoryContract.item("backupCases", caseId)
        let backup = input["backup"]
        let mode = try #require(input["mode"].string.flatMap(MemoryBackupMode.init(rawValue:)))
        let local = try items(input["local"])
        let actual = MemoryItems.backupMerge(
            mode: mode,
            local: local,
            backup: MemoryBackupInput(
                memoryItems: backup.has("memoryItems") ? try items(backup["memoryItems"]) : nil,
                preferences: backup.has("preferences") ? prefs(backup["preferences"]) : nil
            ),
            uid: input["uid"].string ?? "",
            deviceId: input["deviceId"].string ?? ""
        )
        let tombstonedIds = mode == .replace ? MemoryItems.backupReplaceTombstonedIds(local: local, replaced: actual) : []
        check(caseId, expected: expected, actual: .object([
            "items": try itemsJSON(actual),
            "tombstonedIds": .array(tombstonedIds.map { .string($0) }),
        ]))
    }
}
