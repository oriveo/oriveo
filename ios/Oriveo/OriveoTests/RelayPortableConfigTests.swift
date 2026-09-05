import Foundation
import Testing
@testable import Oriveo

@Suite("Relay portable config • outbound allowlist", .serialized)
struct RelayPortableConfigTests {

    private struct PortableContract: Decodable {
        let version: Int
        let allFields: [String]
        let portableFields: [String]
        let localOnlyFields: [LocalOnlyField]
        let cases: [Case]
    }

    private struct LocalOnlyField: Decodable {
        let field: String
        let reason: String
    }

    private struct Case: Decodable {
        let caseId: String
        let input: JSONValue
        let expect: JSONValue
    }

    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
            self = .object(try container.decode([String: JSONValue].self))
        }

        var foundation: Any {
            switch self {
            case .object(let value): return value.mapValues(\.foundation)
            case .array(let value): return value.map(\.foundation)
            case .string(let value): return value
            case .number(let value): return value == value.rounded() ? Int(value) : value
            case .bool(let value): return value
            case .null: return NSNull()
            }
        }
    }

    private func loadContract() throws -> PortableContract {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("relay")
                .appendingPathComponent("portable-config.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(PortableContract.self, from: Data(contentsOf: candidate))
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("Every Field Is Registered")
    func everyFieldIsRegistered() throws {
        let contract = try loadContract()
        #expect(contract.version == 1)
        #expect(Set(RelayRequestedConfig.CodingKeys.allCases.map(\.rawValue)) == Set(contract.allFields))
        #expect(RelayRequestedConfig.portableFieldNames == Set(contract.portableFields))
        #expect(
            Set(contract.localOnlyFields.map(\.field))
                == Set(contract.allFields).subtracting(contract.portableFields)
        )
    }

    @Test("Cases Round Trip Through Production Sanitizer")
    func casesRoundTripThroughProductionSanitizer() throws {
        let contract = try loadContract()
        let encoder = JSONEncoder()

        for item in contract.cases {
            guard case .object = item.input, case .object(let expected) = item.expect else {
                Issue.record("\(item.caseId): fixture input/expect must be objects")
                continue
            }
            let inputData = try JSONSerialization.data(withJSONObject: item.input.foundation)
            let requested = try JSONDecoder().decode(RelayRequestedConfig.self, from: inputData)

            let portableData = try encoder.encode(requested.credentialFreePortableCopy())
            let portable = try #require(
                try JSONSerialization.jsonObject(with: portableData) as? [String: Any]
            )

            for (key, value) in expected {
                let actual = (portable[key] ?? NSNull()) as AnyObject
                #expect(
                    actual.isEqual(value.foundation as AnyObject),
                    "\(item.caseId): \(key) is \(portable[key] ?? "<missing>")"
                )
            }
            for entry in contract.localOnlyFields {
                #expect(portable[entry.field] == nil, "\(item.caseId): \(entry.field) must never leave the device")
            }
            #expect(
                Set(portable.keys).subtracting(contract.portableFields).isEmpty,
                "\(item.caseId): unregistered outbound fields"
            )
            #expect(
                !String(decoding: portableData, as: UTF8.self).contains("secret"),
                "\(item.caseId): sanitized copy still carries a credential literal"
            )
        }
    }
}
