import Foundation
import Testing
@testable import Oriveo

/// BYOK image task management cases shared by all three clients: reads
/// the shared studio contracts fixture `byok_image_tasks.v1.json` (contractId "byok_image_tasks.v1")
/// and runs spec, timeout, retry, transportPhase (iOS table), aggregate, queue and
/// reconcile against `StudioByokTasks`.
@Suite("StudioByokTasksContractTests")
struct StudioByokTasksContractTests {
    static let contractId = "byok_image_tasks.v1"
    static let fixtureName = "byok_image_tasks.v1.json"

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
        let data = try Data(contentsOf: repoFile(["\u{5171}\u{4EAB}", "studio-contracts"] + components))
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

    /// JSON null and a missing member both read as nil.
    static func int(_ value: Any?) -> Int? {
        value is NSNull ? nil : (value as? NSNumber)?.intValue
    }

    static func string(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    static func kind(_ value: Any?, _ caseId: String) throws -> StudioImageErrorKind? {
        guard let raw = string(value) else { return nil }
        return try #require(StudioImageErrorKind(rawValue: raw), "\(caseId) unknown errorKind \(raw)")
    }

    static func event(_ raw: [String: Any], _ caseId: String) throws -> StudioByokTasks.QueueEvent {
        let id = try #require(raw["id"] as? String, "\(caseId) event id")
        switch raw["type"] as? String {
        case "submit": return .submit(id)
        case "finish": return .finish(id)
        case "cancel": return .cancel(id)
        case "response": return .response(id)
        default:
            Issue.record("\(caseId) unknown event type")
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    static func effect(_ raw: [String: Any], _ caseId: String) throws -> StudioByokTasks.QueueEffect {
        let id = try #require(raw["id"] as? String, "\(caseId) effect id")
        switch raw["type"] as? String {
        case "start": return .start(id)
        case "cancelled":
            let billed = try #require(raw["mayBeBilled"] as? Bool, "\(caseId) mayBeBilled")
            return .cancelled(id, mayBeBilled: billed)
        case "accept": return .accept(id)
        case "drop": return .drop(id)
        default:
            Issue.record("\(caseId) unknown effect type")
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    @Test("spec: constants and wire names equal the fixture spec")
    func spec() throws {
        let spec = try #require(try Self.fixture()["spec"] as? [String: Any])
        #expect(Self.int(spec["defaultTimeoutSeconds"]) == StudioByokTasks.defaultTimeoutSeconds)
        #expect(Self.int(spec["maxTimeoutSeconds"]) == StudioByokTasks.maxTimeoutSeconds)
        #expect(Self.int(spec["maxConcurrentRounds"]) == StudioByokTasks.maxConcurrentRounds)
        #expect(Self.int(spec["maxAutoRetries"]) == StudioByokTasks.maxAutoRetries)
        #expect(spec["phases"] as? [String] == StudioByokTasks.Phase.allCases.map(\.rawValue))
        #expect(
            spec["reconcileActions"] as? [String]
                == StudioByokTasks.ReconcileAction.allCases.map(\.rawValue)
        )
        #expect(
            spec["roundStatuses"] as? [String] == StudioByokTasks.RoundStatus.allCases.map(\.rawValue)
        )
    }

    @Test("timeout: effectiveTimeoutSeconds per caseId")
    func timeout() throws {
        let cases = try #require(try Self.fixture()["timeout"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let expected = try #require(Self.int(testCase["expect"]), "\(caseId) expect")
            let actual = StudioByokTasks.effectiveTimeoutSeconds(Self.int(testCase["timeoutSeconds"]))
            #expect(actual == expected, "\(caseId)")
        }
    }

    @Test("retry: retryDecision(phase, attempt) per caseId")
    func retry() throws {
        let cases = try #require(try Self.fixture()["retry"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let rawPhase = try #require(testCase["phase"] as? String, "\(caseId) phase")
            let phase = try #require(StudioByokTasks.Phase(rawValue: rawPhase), "\(caseId) phase")
            let attempt = try #require(Self.int(testCase["attempt"]), "\(caseId) attempt")
            let expect = try #require(testCase["expect"] as? [String: Any], "\(caseId) expect")
            let expected = StudioByokTasks.RetryDecision(
                retry: try #require(expect["retry"] as? Bool, "\(caseId) retry"),
                errorKind: try Self.kind(expect["errorKind"], caseId),
                retried: try #require(expect["retried"] as? Bool, "\(caseId) retried"),
                mayBeBilled: try #require(expect["mayBeBilled"] as? Bool, "\(caseId) mayBeBilled")
            )
            #expect(StudioByokTasks.retryDecision(phase: phase, attempt: attempt) == expected, "\(caseId)")
        }
    }

    @Test("transportPhase: iOS table maps URLError codes and covers every phase")
    func transportPhase() throws {
        let tables = try #require(try Self.fixture()["transportPhase"] as? [String: Any])
        let cases = try #require(tables["ios"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        var covered: Set<String> = []
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let code = try #require(Self.int(testCase["urlErrorCode"]), "\(caseId) urlErrorCode")
            let expected = try #require(testCase["expect"] as? String, "\(caseId) expect")
            covered.insert(expected)
            #expect(StudioByokTasks.transportPhase(urlErrorCode: code).rawValue == expected, "\(caseId)")
        }
        #expect(covered == Set(StudioByokTasks.Phase.allCases.map(\.rawValue)))
    }

    @Test("aggregate: aggregate(n, batches, results, cancelled) per caseId")
    func aggregate() throws {
        let cases = try #require(try Self.fixture()["aggregate"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let input = try #require(testCase["input"] as? [String: Any], "\(caseId) input")
            let expect = try #require(testCase["expect"] as? [String: Any], "\(caseId) expect")
            let rawResults = try #require(input["results"] as? [[String: Any]], "\(caseId) results")
            let results = try rawResults.map { raw in
                StudioByokTasks.BatchResult(
                    images: try #require(Self.int(raw["images"]), "\(caseId) images"),
                    errorKind: try Self.kind(raw["errorKind"], caseId)
                )
            }
            let actual = StudioByokTasks.aggregate(
                n: try #require(Self.int(input["n"]), "\(caseId) n"),
                batches: try #require(input["batches"] as? [Int], "\(caseId) batches"),
                results: results,
                cancelled: try #require(input["cancelled"] as? Bool, "\(caseId) cancelled")
            )
            let rawStatus = try #require(expect["status"] as? String, "\(caseId) status")
            let expected = StudioByokTasks.Aggregate(
                status: try #require(StudioByokTasks.RoundStatus(rawValue: rawStatus), "\(caseId) status"),
                delivered: try #require(Self.int(expect["delivered"]), "\(caseId) delivered"),
                errorKind: try Self.kind(expect["errorKind"], caseId)
            )
            #expect(actual == expected, "\(caseId)")
        }
    }

    @Test("queue: reduce step by step compares running, queued and effects")
    func queue() throws {
        let cases = try #require(try Self.fixture()["queue"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let steps = try #require(testCase["steps"] as? [[String: Any]], "\(caseId) steps")
            var state = StudioByokTasks.QueueState()
            for (index, step) in steps.enumerated() {
                let label = "\(caseId)#\(index)"
                let event = try Self.event(try #require(step["event"] as? [String: Any], "\(label) event"), label)
                let expect = try #require(step["expect"] as? [String: Any], "\(label) expect")
                let rawEffects = try #require(expect["effects"] as? [[String: Any]], "\(label) effects")
                let expectedEffects = try rawEffects.map { try Self.effect($0, label) }
                let effects = state.reduce(event)
                #expect(state.running == expect["running"] as? [String], "\(label) running")
                #expect(state.queued == expect["queued"] as? [String], "\(label) queued")
                #expect(effects == expectedEffects, "\(label) effects")
            }
        }
    }

    @Test("reconcile: launch reconciliation action per caseId")
    func reconcile() throws {
        let cases = try #require(try Self.fixture()["reconcile"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for testCase in cases {
            let caseId = try #require(testCase["caseId"] as? String)
            let input = try #require(testCase["input"] as? [String: Any], "\(caseId) input")
            let rawExpected = try #require(testCase["expect"] as? String, "\(caseId) expect")
            let expected = try #require(
                StudioByokTasks.ReconcileAction(rawValue: rawExpected), "\(caseId) expect"
            )
            let actual = StudioByokTasks.reconcile(
                status: try #require(input["status"] as? String, "\(caseId) status"),
                startedAtMs: Self.int(input["startedAtMs"]).map(Int64.init),
                nowMs: Int64(try #require(Self.int(input["nowMs"]), "\(caseId) nowMs")),
                timeoutSeconds: Self.int(input["timeoutSeconds"]),
                responseReceived: try #require(input["responseReceived"] as? Bool, "\(caseId) responseReceived"),
                transferActive: try #require(input["transferActive"] as? Bool, "\(caseId) transferActive")
            )
            #expect(actual == expected, "\(caseId)")
        }
    }
}
