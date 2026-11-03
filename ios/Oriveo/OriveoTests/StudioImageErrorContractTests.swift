import Foundation
import Testing
@testable import Oriveo

/// Image error normalization cases shared by all three clients: reads
/// `shared/model-contracts/image_error_samples.v1.json` (contractId "image_error_samples.v1")
/// and runs cases, kinds, realSamples and failureKinds against `StudioImageErrorKind`.
@Suite("StudioImageErrorContractTests")
struct StudioImageErrorContractTests {
    static let contractId = "image_error_samples.v1"
    static let fixtureName = "image_error_samples.v1.json"
    static let responseContractId = "image_response_samples.v1"

    static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func jsonObject(_ components: [String]) throws -> [String: Any] {
        let data = try Data(contentsOf: repoFile(["\u{5171}\u{4EAB}", "model-contracts"] + components))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    static func fixture() throws -> [String: Any] {
        let object = try jsonObject([fixtureName])
        #expect(object["contractId"] as? String == contractId)
        return object
    }

    /// JSON null and a missing member both read as "no body".
    static func body(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    /// `nil` (ok) is spelled "ok" in the fixture.
    static func wire(_ kind: StudioImageErrorKind?) -> String {
        kind?.rawValue ?? "ok"
    }

    /// Exhaustive over `StudioImageResponse.Failure`: a new case fails to compile here.
    static func allFailures() -> [StudioImageResponse.Failure] {
        let all: [StudioImageResponse.Failure] = [.network, .timeout, .decodeFailed]
        for failure in all {
            switch failure {
            case .network, .timeout, .decodeFailed: break
            }
        }
        return all
    }

    @Test("cases: classify(http, body, nRequested) per caseId")
    func cases() throws {
        let cases = try #require(try Self.fixture()["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let http = try #require(testCase["http"] as? Int, "\(caseId) http")
            let nRequested = try #require(testCase["nRequested"] as? Int, "\(caseId) nRequested")
            let expected = try #require(testCase["expectKind"] as? String, "\(caseId) expectKind")
            let kind = StudioImageErrorKind.classify(
                http: http, body: Self.body(testCase["body"]), nRequested: nRequested
            )
            #expect(Self.wire(kind) == expected, "\(caseId)")
        }
    }

    @Test("kinds: enum set equals fixture keys and policy matches per key")
    func kinds() throws {
        let kinds = try #require(try Self.fixture()["kinds"] as? [String: [String: Any]])
        #expect(Set(StudioImageErrorKind.allCases.map(\.rawValue)) == Set(kinds.keys))
        for (key, raw) in kinds {
            let kind = try #require(StudioImageErrorKind(rawValue: key), "\(key) missing from enum")
            let policy = StudioImageErrorKind.policy(kind)
            let quota = (raw["consumesFreeQuota"] as? String) ?? "none"
            let retry = (raw["autoRetry"] as? String) ?? "none"
            #expect(raw["consumesFreeQuota"] is String || (raw["consumesFreeQuota"] as? Bool) == false, "\(key) quota")
            #expect(raw["autoRetry"] is String || (raw["autoRetry"] as? Bool) == false, "\(key) retry")
            #expect(policy.consumesFreeQuota.rawValue == quota, "\(key) consumesFreeQuota")
            #expect(policy.autoRetry.rawValue == retry, "\(key) autoRetry")
            #expect(policy.ui == (raw["ui"] as? String), "\(key) ui")
            #expect(policy.report == ((raw["report"] as? Bool) ?? false), "\(key) report")
        }
    }

    @Test("realSamples: classify(meta.http, response, nRequested) equals expect.result")
    func realSamples() throws {
        let index = try Self.jsonObject([Self.responseContractId, "index.json"])
        let samples = try #require(index["samples"] as? [[String: Any]])
        #expect(!samples.isEmpty)
        for sample in samples {
            let file = try #require(sample["file"] as? String)
            let nRequested = try #require(sample["nRequested"] as? Int, "\(file) nRequested")
            let expect = try #require(sample["expect"] as? [String: Any], "\(file) expect")
            let expected = try #require(expect["result"] as? String, "\(file) result")
            let captured = try Self.jsonObject([Self.responseContractId, file])
            let meta = try #require(captured["meta"] as? [String: Any], "\(file) meta")
            let http = try #require(meta["http"] as? Int, "\(file) http")
            let kind = StudioImageErrorKind.classify(
                http: http, body: Self.body(captured["response"]), nRequested: nRequested
            )
            #expect(Self.wire(kind) == expected, "\(file)")
        }
    }

    @Test("failureKinds: every transport Failure maps to the kind with the same wire name")
    func failureKinds() throws {
        let kinds = try #require(try Self.fixture()["kinds"] as? [String: Any])
        for failure in Self.allFailures() {
            #expect(kinds[failure.rawValue] != nil, "\(failure.rawValue) not a fixture kind")
            #expect(failure.errorKind.rawValue == failure.rawValue, "\(failure.rawValue)")
        }
    }
}
