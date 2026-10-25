import Foundation
import Testing

@testable import OriveoProviderKit

// metadata v2 schema validator: the real contract schema and the real bundled snapshot run clean, every keyword reports when broken on purpose,
// an unimplemented keyword throws at construction, and non-gzip input throws.

@Suite("metadata v2 schema validator")
struct MetadataPayloadSchemaValidatorTests {
    private typealias Validator = MetadataPayloadSchemaValidator
    private typealias Violation = MetadataPayloadSchemaValidator.Violation

    private static func fixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func contractValidator() throws -> Validator {
        try Validator(schemaData: Data(contentsOf: fixtureURL("shared/model-contracts/metadata_payload.v2.schema.json")))
    }

    private static func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private static func validator(_ schema: String) throws -> Validator {
        try Validator(schemaData: Data(schema.utf8))
    }

    /// The smallest valid data body of the full view; each case changes one thing on top of it.
    private static func fullPayload(provider: String = #"{"displayName":"P"}"#, extra: String = "") throws -> [String: Any] {
        let text = """
        {"metadataSchema":2,"metadataRevision":7,"generatedAt":"2026-10-18T12:00:00Z",
         "contractVersion":1,"providers":{"p":\(provider)}\(extra)}
        """
        return try #require(try json(text) as? [String: Any])
    }

    // MARK: 1. The real snapshot has 0 errors against the root schema

    @Test("the bundled snapshot, decompressed and wrapped as a GET /api/metadata response, has 0 errors against the root schema; the data body alone also has 0 errors against fullOrIndex")
    func bundledSnapshotPassesRootSchema() throws {
        let gz = try Data(contentsOf: Self.fixtureURL("shared/model-contracts/bundled-metadata.v2.json.gz"))
        let payload = try JSONSerialization.jsonObject(with: GzipData.gunzip(gz))
        let body = try #require(payload as? [String: Any])
        #expect((body["providers"] as? [String: Any])?.isEmpty == false)

        let validator = try Self.contractValidator()
        #expect(validator.validate(["code": 0, "message": "ok", "data": body]) == [])
        #expect(validator.validate(body, def: "fullOrIndex") == [])
    }

    // MARK: 2. Every keyword reports when broken on purpose

    @Test("the minimal full body is valid and is the baseline for the cases below")
    func baselineIsValid() throws {
        let validator = try Self.contractValidator()
        #expect(validator.validate(["data": try Self.fullPayload()]) == [])
        #expect(validator.validate(try Self.fullPayload(), def: "fullOrIndex") == [])
    }

    @Test("type: a string for code at the root")
    func typeViolation() throws {
        let violations = try Self.contractValidator().validate(["code": "0", "data": try Self.fullPayload()])
        #expect(violations == [Violation(instancePath: "/code", keyword: "type")])
    }

    @Test("type: 1.5 where an integer is expected is reported, 1.0 is not; a boolean is not an integer")
    func integerVersusNumberAndBoolean() throws {
        let validator = try Self.validator(#"{"type":"integer"}"#)
        #expect(validator.validate(try Self.json("1.5")) == [Violation(instancePath: "", keyword: "type")])
        #expect(validator.validate(try Self.json("1.0")) == [])
        #expect(validator.validate(try Self.json("0")) == [])
        #expect(validator.validate(try Self.json("true")) == [Violation(instancePath: "", keyword: "type")])
        let boolean = try Self.validator(#"{"type":"boolean"}"#)
        #expect(boolean.validate(try Self.json("1")) == [Violation(instancePath: "", keyword: "type")])
        #expect(boolean.validate(try Self.json("false")) == [])
    }

    @Test("type array: [\"integer\",\"null\"] accepts null and integers and rejects strings")
    func typeUnion() throws {
        let validator = try Self.contractValidator()
        let ok = #"{"displayName":"M","contextLength":null,"maxOutputTokens":4096}"#
        #expect(validator.validate(try Self.json(ok), def: "model") == [])
        let bad = #"{"displayName":"M","contextLength":"128k"}"#
        #expect(validator.validate(try Self.json(bad), def: "model")
            == [Violation(instancePath: "/contextLength", keyword: "type")])
    }

    @Test("required: providers missing")
    func requiredViolation() throws {
        var payload = try Self.fullPayload()
        payload["providers"] = nil
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "", keyword: "required")])
    }

    @Test("allOf + $ref: revisionFields referenced through allOf is missing metadataRevision")
    func allOfViolation() throws {
        var payload = try Self.fullPayload()
        payload["metadataRevision"] = nil
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "", keyword: "required")])
    }

    /// metadataSchema is the enum [2, 3] (schema 3 is the compact index / catalog).
    @Test("enum: metadataSchema 4 is reported (2 and 3 are valid)")
    func metadataSchemaEnumViolation() throws {
        var payload = try Self.fullPayload()
        let validator = try Self.contractValidator()
        for accepted in [2, 3] {
            payload["metadataSchema"] = accepted
            #expect(validator.validate(payload, def: "fullOrIndex") == [])
        }
        payload["metadataSchema"] = 4
        #expect(validator.validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/metadataSchema", keyword: "enum")])
    }

    @Test("const: boolean true does not equal the number 1")
    func constDistinguishesBooleanFromNumber() throws {
        let validator = try Self.validator(#"{"const":1}"#)
        #expect(validator.validate(try Self.json("true")) == [Violation(instancePath: "", keyword: "const")])
        #expect(validator.validate(try Self.json("1.0")) == [])
    }

    @Test("minimum: metadataRevision -1")
    func minimumViolation() throws {
        var payload = try Self.fullPayload()
        payload["metadataRevision"] = -1
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/metadataRevision", keyword: "minimum")])
    }

    @Test("format: generatedAt with month 13, no time zone, February 30 and a leap second that is not 23:59 UTC is reported; a 23:59 UTC leap second, a lowercase t and a whitespace separator are valid")
    func formatViolation() throws {
        let validator = try Self.contractValidator()
        for bad in ["2026-13-01T00:00:00Z", "2026-10-18T12:00:00", "2026-02-30T00:00:00Z", "2024-02-29T23:59:60.123+08:00", "yesterday"] {
            var payload = try Self.fullPayload()
            payload["generatedAt"] = bad
            #expect(validator.validate(payload, def: "fullOrIndex")
                == [Violation(instancePath: "/generatedAt", keyword: "format")], "\(bad)")
        }
        for good in ["2016-12-31T23:59:60Z", "2026-10-18t12:00:00z", "2026-10-18 12:00:00Z"] {
            var payload = try Self.fullPayload()
            payload["generatedAt"] = good
            #expect(validator.validate(payload, def: "fullOrIndex") == [], "\(good)")
        }
    }

    @Test("properties: contractVersion 1.5")
    func propertiesViolation() throws {
        var payload = try Self.fullPayload()
        payload["contractVersion"] = 1.5
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/contractVersion", keyword: "type")])
    }

    @Test("additionalProperties (schema): one provider under providers is not an object")
    func additionalPropertiesViolation() throws {
        let payload = try Self.fullPayload(provider: #""P""#)
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p", keyword: "type")])
    }

    @Test("additionalProperties: false rejects unlisted keys, and the JSON Pointer escapes ~ and /")
    func additionalPropertiesFalse() throws {
        let validator = try Self.validator(#"{"properties":{"a":{}},"additionalProperties":false}"#)
        #expect(validator.validate(try Self.json(#"{"a":1,"x/y~z":2}"#))
            == [Violation(instancePath: "/x~1y~0z", keyword: "additionalProperties")])
    }

    @Test("$ref: one provider under providers is missing displayName")
    func refViolation() throws {
        let payload = try Self.fullPayload(provider: #"{"modelCount":1}"#)
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p", keyword: "required")])
    }

    @Test("items + minLength: the id of the second retiredModels entry is an empty string")
    func itemsAndMinLengthViolation() throws {
        let payload = try Self.fullPayload(provider: #"{"displayName":"P","retiredModels":[{"id":"a"},{"id":""}]}"#)
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p/retiredModels/1/id", keyword: "minLength")])
    }

    @Test("minItems: an empty regionPricing array is reported, one entry is valid")
    func minItemsViolation() throws {
        let entry = #"{"regionScope":"global","currencyCode":"USD","pricingStatus":"unknown","pricingUnit":"per_token","pricing":null}"#
        let validator = try Self.contractValidator()
        let empty = try Self.fullPayload(provider: #"{"displayName":"P","models":{"m":{"displayName":"M","regionPricing":[]}}}"#)
        #expect(validator.validate(empty, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p/models/m/regionPricing", keyword: "minItems")])
        let one = try Self.fullPayload(provider: #"{"displayName":"P","models":{"m":{"displayName":"M","regionPricing":["# + entry + "]}}}")
        #expect(validator.validate(one, def: "fullOrIndex") == [])
        #expect(throws: Validator.SchemaError.invalidKeywordValue("minItems", schemaPath: "/minItems")) {
            try Self.validator(#"{"minItems":-1}"#)
        }
    }

    @Test("pattern: catalogRevision is not sha256:<64 lowercase hex digits>")
    func patternViolation() throws {
        let payload = try Self.fullPayload(provider: #"{"displayName":"P","catalogRevision":"sha256:ABC"}"#)
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p/catalogRevision", keyword: "pattern")])
    }

    @Test("enum: verdict.state with an unregistered value")
    func enumViolation() throws {
        let payload = try Self.fullPayload(provider: """
        {"displayName":"P","models":{"m":{"displayName":"M","capabilityControls":{"reasoning":{"state":"maybe"}}}}}
        """)
        #expect(try Self.contractValidator().validate(payload, def: "fullOrIndex")
            == [Violation(instancePath: "/providers/p/models/m/capabilityControls/reasoning/state", keyword: "enum")])
    }

    @Test("oneOf: data is neither full/index nor catalog")
    func oneOfViolation() throws {
        #expect(try Self.contractValidator().validate(["data": [String: Any]()])
            == [Violation(instancePath: "/data", keyword: "oneOf")])
    }

    @Test("oneOf: satisfying both branches is also reported")
    func oneOfBothBranches() throws {
        let validator = try Self.validator(#"{"oneOf":[{"type":"integer"},{"type":"number"}]}"#)
        #expect(validator.validate(try Self.json("1")) == [Violation(instancePath: "", keyword: "oneOf")])
        #expect(validator.validate(try Self.json("1.5")) == [])
    }

    // MARK: 3. An unimplemented keyword throws at construction

    @Test("an unimplemented keyword throws at construction with its location in the schema; annotation keywords are ignored")
    func unsupportedKeywordThrows() throws {
        #expect(throws: Validator.SchemaError.unsupportedKeyword("patternProperties", schemaPath: "/patternProperties")) {
            try Self.validator(#"{"type":"object","patternProperties":{}}"#)
        }
        #expect(throws: Validator.SchemaError.unsupportedKeyword("maxLength", schemaPath: "/$defs/a/properties/b/maxLength")) {
            try Self.validator(#"{"$defs":{"a":{"properties":{"b":{"maxLength":3}}}}}"#)
        }
        #expect(throws: Validator.SchemaError.unsupportedKeyword("format:email", schemaPath: "/format")) {
            try Self.validator(#"{"format":"email"}"#)
        }
        #expect(throws: Validator.SchemaError.unresolvedReference("#/$defs/missing", schemaPath: "/$ref")) {
            try Self.validator(##"{"$ref":"#/$defs/missing"}"##)
        }
        #expect(throws: Validator.SchemaError.unresolvedReference("other.json#/x", schemaPath: "/$ref")) {
            try Self.validator(##"{"$ref":"other.json#/x"}"##)
        }
        let annotated = try Self.validator(#"{"$schema":"x","$id":"y","$comment":"c","title":"t","description":"d","type":"string"}"#)
        #expect(annotated.validate("ok") == [])
    }

    // MARK: 4. Validate by $defs name

    @Test("validates catalog / lifecycle separately by $defs name; an unknown name does not pass")
    func validateByDefName() throws {
        let validator = try Self.contractValidator()
        let catalog = """
        {"metadataSchema":2,"metadataRevision":3,"generatedAt":"2026-10-18T00:00:00Z","view":"catalog",
         "provider":"openai","catalogRevision":"sha256:\(String(repeating: "a", count: 64))",
         "models":{"gpt":{"displayName":"GPT"}}}
        """
        #expect(validator.validate(try Self.json(catalog), def: "catalog") == [])
        #expect(validator.validate(["data": try Self.json(catalog)]) == [])
        #expect(validator.validate(try Self.json(catalog), def: "fullOrIndex")
            == [
                Violation(instancePath: "", keyword: "required"),
                Violation(instancePath: "", keyword: "required"),
                Violation(instancePath: "/view", keyword: "const"),
            ])

        #expect(validator.validate(try Self.json(#"{"state":"retired","shutdownAt":"2026-01-01T00:00:00Z"}"#), def: "lifecycle") == [])
        #expect(validator.validate(try Self.json(#"{"shutdownAt":"soon"}"#), def: "lifecycle")
            == [Violation(instancePath: "", keyword: "required"), Violation(instancePath: "/shutdownAt", keyword: "format")])

        #expect(validator.validate([String: Any](), def: "noSuchDef") == [Violation(instancePath: "", keyword: "$defs")])
    }

    // MARK: ⑤ gzip

    @Test("non-gzip input throws notGzip, truncated input throws truncated")
    func nonGzipThrows() throws {
        #expect(throws: GzipData.GzipError.notGzip) { try GzipData.gunzip(Data(#"{"a":1}"#.utf8)) }
        #expect(throws: GzipData.GzipError.notGzip) { try GzipData.gunzip(Data()) }
        #expect(throws: GzipData.GzipError.truncated) { try GzipData.gunzip(Data([0x1F, 0x8B, 8, 0])) }
        #expect(throws: GzipData.GzipError.unsupportedMethod(7)) {
            try GzipData.gunzip(Data([0x1F, 0x8B, 7, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0]))
        }
    }

    @Test("a header carrying FEXTRA / FNAME / FCOMMENT / FHCRC still decompresses to the same content")
    func optionalHeaderFieldsAreSkipped() throws {
        let gz = try Data(contentsOf: Self.fixtureURL("shared/model-contracts/bundled-metadata.v2.json.gz"))
        let plain = try GzipData.gunzip(gz)
        var bytes = [UInt8](gz)
        bytes[3] |= 0x04 | 0x08 | 0x10 | 0x02
        let optional: [UInt8] = [3, 0, 0xAA, 0xBB, 0xCC] + Array("name.json".utf8) + [0] + Array("note".utf8) + [0] + [0x12, 0x34]
        bytes.insert(contentsOf: optional, at: 10)
        #expect(try GzipData.gunzip(Data(bytes)) == plain)
    }

    // MARK: - CLOSURE dateTimeCases (shared fixture capability/cross-end-closure.v1.json)

    private static func dateTimeCases() throws -> [[String: Any]] {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("shared/test-fixtures/capability/cross-end-closure.v1.json")))
                as? [String: Any]
        )
        return try #require((root["dateTimeCases"] as? [String: Any])?["cases"] as? [[String: Any]])
    }

    /// Validates generatedAt (format: date-time) through the real contract schema: a valid case has no violation, every other case reports only format.
    private func checkDateTime(_ id: String) throws {
        let item = try #require(try Self.dateTimeCases().first { $0["id"] as? String == id }, "CLOSURE-\(id)")
        let value = try #require(item["value"] as? String)
        let valid = try #require(item["valid"] as? Bool)
        var payload = try Self.fullPayload()
        payload["generatedAt"] = value
        let violations = try Self.contractValidator().validate(payload, def: "fullOrIndex")
        #expect(violations == (valid ? [] : [Violation(instancePath: "/generatedAt", keyword: "format")]), "CLOSURE-\(id) \(value)")
    }

    private static let closureDateTimeIDs = [
        "dt_utc_z",
        "dt_fraction_offset",
        "dt_lowercase_t_z",
        "dt_space_separator",
        "dt_offset_without_colon",
        "dt_no_time_zone",
        "dt_hour_29",
        "dt_minute_60",
        "dt_offset_hour_24",
        "dt_offset_minute_60",
        "dt_feb_29_non_leap_year",
        "dt_feb_29_leap_year",
        "dt_month_13",
        "dt_leap_second_utc_2359",
        "dt_leap_second_negative_offset_is_utc_2359",
        "dt_leap_second_positive_offset_not_utc_2359",
        "dt_leap_second_midday",
        "dt_date_only",
    ]

    @Test("every CLOSURE dateTimeCases entry has a matching test")
    func closureDateTimeCasesCovered() throws {
        #expect(try Self.dateTimeCases().compactMap { $0["id"] as? String } == Self.closureDateTimeIDs)
    }

    @Test func test_CLOSURE_dt_utc_z() throws { try checkDateTime("dt_utc_z") }
    @Test func test_CLOSURE_dt_fraction_offset() throws { try checkDateTime("dt_fraction_offset") }
    @Test func test_CLOSURE_dt_lowercase_t_z() throws { try checkDateTime("dt_lowercase_t_z") }
    @Test func test_CLOSURE_dt_space_separator() throws { try checkDateTime("dt_space_separator") }
    @Test func test_CLOSURE_dt_offset_without_colon() throws { try checkDateTime("dt_offset_without_colon") }
    @Test func test_CLOSURE_dt_no_time_zone() throws { try checkDateTime("dt_no_time_zone") }
    @Test func test_CLOSURE_dt_hour_29() throws { try checkDateTime("dt_hour_29") }
    @Test func test_CLOSURE_dt_minute_60() throws { try checkDateTime("dt_minute_60") }
    @Test func test_CLOSURE_dt_offset_hour_24() throws { try checkDateTime("dt_offset_hour_24") }
    @Test func test_CLOSURE_dt_offset_minute_60() throws { try checkDateTime("dt_offset_minute_60") }
    @Test func test_CLOSURE_dt_feb_29_non_leap_year() throws { try checkDateTime("dt_feb_29_non_leap_year") }
    @Test func test_CLOSURE_dt_feb_29_leap_year() throws { try checkDateTime("dt_feb_29_leap_year") }
    @Test func test_CLOSURE_dt_month_13() throws { try checkDateTime("dt_month_13") }
    @Test func test_CLOSURE_dt_leap_second_utc_2359() throws { try checkDateTime("dt_leap_second_utc_2359") }
    @Test func test_CLOSURE_dt_leap_second_negative_offset_is_utc_2359() throws { try checkDateTime("dt_leap_second_negative_offset_is_utc_2359") }
    @Test func test_CLOSURE_dt_leap_second_positive_offset_not_utc_2359() throws { try checkDateTime("dt_leap_second_positive_offset_not_utc_2359") }
    @Test func test_CLOSURE_dt_leap_second_midday() throws { try checkDateTime("dt_leap_second_midday") }
    @Test func test_CLOSURE_dt_date_only() throws { try checkDateTime("dt_date_only") }
}
