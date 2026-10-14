import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-TRIG: pure selection for automatic web-probe triggering, going case by case through the `triggerCases` of
/// `shared/test-fixtures/relay/web-probe.v1.json`; now is injected by the fixture and the system clock is never read.
@Suite("RL2-WEBPROBE-TRIG - web probe automatic trigger selection")
struct RelayWebProbeTriggerTests {
    nonisolated private static func loadFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/web-probe.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return (object as? [String: Any]) ?? [:]
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    nonisolated private static let cases: [[String: Any]] =
        ((try? loadFixture())?["triggerCases"] as? [[String: Any]]) ?? []
    nonisolated private static let caseIds: [String] = cases.compactMap { $0["caseId"] as? String }

    private static let forms: [String: ProviderForm] = [
        "RELAY": .relay, "BYOK": .official, "SUB": .subscription,
    ]

    private static func date(_ text: Any?) throws -> Date {
        try #require((text as? String).flatMap { ISO8601DateFormatter().date(from: $0) }, "time \(String(describing: text))")
    }

    @Test("RL2-WEBPROBE-TRIG fixture is not empty")
    func fixtureLoaded() {
        #expect(Self.caseIds.count >= 20)
    }

    @Test("RL2-WEBPROBE-07 TRIG", arguments: caseIds)
    func trigger(caseId: String) throws {
        let label = "RL2-WEBPROBE-TRIG-\(caseId)"
        let testCase = try #require(Self.cases.first { $0["caseId"] as? String == caseId }, "\(label)")
        let eventObject = try #require(testCase["event"] as? [String: Any], "\(label) event")
        let fragments = testCase["fragments"] as? [String: [String: Any]] ?? [:]
        let transport = eventObject["transport"] as? String ?? ""
        let modelID = eventObject["modelId"] as? String ?? ""
        /// A fragment exists on the event's transport -> one candidate for that model.
        let single: [RelayWebProbeTrigger.Candidate] = fragments[transport].map {
            [RelayWebProbeTrigger.Candidate(modelID: modelID, transport: transport, fragmentHash: RelayWebProbe.fragmentHash($0))]
        } ?? []

        let event: RelayWebProbeTrigger.Event
        var candidates: [RelayWebProbeTrigger.Candidate] = []
        switch eventObject["type"] as? String {
        case "saveFragment":
            event = .saveFragment
            let fragment = try #require(eventObject["fragment"] as? [String: Any], "\(label) fragment")
            let hash = RelayWebProbe.fragmentHash(fragment)
            candidates = (testCase["enabledOnTransport"] as? [String] ?? []).map {
                RelayWebProbeTrigger.Candidate(modelID: $0, transport: transport, fragmentHash: hash)
            }
        case "enableModel":
            switch eventObject["lazyVerify"] as? String {
            case "passed": event = .enableModel(.passed)
            case "failed": event = .enableModel(.failed)
            default: event = .enableModel(.notRun)
            }
            candidates = single
        case "manualTest":
            event = .manualTest
            candidates = single
        case "retest":
            event = .retest
            candidates = single
        case "redetect":
            event = .redetect
        case "addConnection":
            event = .addConnection
        default:
            Issue.record("\(label): unrecognized event \(String(describing: eventObject["type"]))")
            return
        }

        let history = try (testCase["autoHistory"] as? [[String: Any]] ?? []).map { entry in
            RelayWebProbeTrigger.HistoryEntry(
                connectionID: try #require(entry["connectionId"] as? String),
                modelID: try #require(entry["modelId"] as? String),
                transport: try #require(entry["transport"] as? String),
                fragmentHash: try #require(entry["fragmentHash"] as? String),
                sentAt: try Self.date(entry["sentAt"])
            )
        }
        // Community edition has no FREE / MANAGED forms; those fixture cases do not apply.
        guard let form = Self.forms[testCase["form"] as? String ?? ""] else { return }
        let selection = RelayWebProbeTrigger.select(
            event: event, form: form, candidates: candidates, history: history,
            now: try Self.date(testCase["now"]), connectionID: try #require(testCase["connectionId"] as? String)
        )
        let expect = try #require(testCase["expect"] as? [String: Any], "\(label) expect")
        #expect(selection.probe.map(\.modelID) == expect["probe"] as? [String], "\(label) probe")
        #expect(selection.untested.map(\.modelID) == expect["untested"] as? [String], "\(label) untested")
        if let counts = expect["countsTowardCap"] as? Bool {
            #expect(selection.countsTowardCap == counts, "\(label) countsTowardCap")
        }
    }
}
