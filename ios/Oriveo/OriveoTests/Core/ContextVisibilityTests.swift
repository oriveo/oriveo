import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The usage summary pure function matches the usage.v1 fixture; the loader reads from the production ledger / checkpoint; the ring appears only for percent.
@Suite("Context visibility", .serialized)
@MainActor
struct ContextVisibilityTests {

    private static let rhoHi = 0.5

    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    // MARK: Fixtures

    private static func usageFixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/context-contracts/usage.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func summaryCases() throws -> [[String: Any]] {
        try #require(try usageFixture()["summaryCases"] as? [[String: Any]])
    }

    private static func manifest(from object: [String: Any], conversationId: String = "conversation") throws -> ContextManifest {
        let segments = try (object["segments"] as? [[String: Any]] ?? []).map { segment in
            let raw = segment["kind"] as? String ?? ""
            return ContextManifestSegment(
                kind: try #require(ContextSegmentKind(rawValue: raw)),
                tokens: try #require(segment["tokens"] as? Int),
                omitted: segment["omitted"] as? Int
            )
        }
        let createdAt = try #require(object["createdAt"] as? Int)
        return ContextManifest(
            requestId: "request-\(createdAt)",
            conversationId: conversationId,
            purpose: .chat,
            transport: "openai_chat",
            model: "gpt-x",
            W: object["W"] as? Int,
            O: 4_096,
            B: object["B"] as? Int,
            basis: .estimated,
            estimatedInput: try #require(object["estimatedInput"] as? Int),
            observedInput: object["observedInput"] as? Int,
            segments: segments,
            checkpointId: object["checkpointId"] as? String,
            unansweredMerged: 0,
            reminder: false,
            stopReason: StopReason.fromStored(object["stopReason"] as? String),
            createdAt: Int64(createdAt)
        )
    }

    private static func checkpoint(from object: Any?) throws -> ContextUsageCheckpoint? {
        guard let object = object as? [String: Any] else { return nil }
        return ContextUsageCheckpoint(
            count: try #require(object["count"] as? Int),
            latestCreatedAt: Int64(try #require(object["latestCreatedAt"] as? Int)),
            latestSummaryTokens: try #require(object["latestSummaryTokens"] as? Int)
        )
    }

    /// Projects the summary into the fixture's expected shape (nil -> NSNull) and compares field by field.
    private static func fixtureShape(_ summary: ContextUsageSummary) -> [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        return [
            "display": summary.display.rawValue,
            "reason": value(summary.reason?.rawValue),
            "percent": value(summary.percent),
            "estimatedPercent": value(summary.estimatedPercent),
            "tone": value(summary.tone?.rawValue),
            "ring": value(summary.ring.map { ["label": $0.label, "tone": $0.tone.rawValue] as [String: Any] }),
            "basis": value(summary.basis?.rawValue),
            "used": value(summary.used),
            "B": value(summary.B),
            "W": value(summary.W),
            "segments": value(summary.segments.map {
                [
                    "conversation": $0.conversation, "library": $0.library, "summary": $0.summary,
                    "instructions": $0.instructions, "memory": $0.memory, "free": $0.free,
                ] as [String: Any]
            }),
            "omitted": value(summary.omitted.map {
                ["notes": $0.notes, "knowledge": $0.knowledge, "memory": $0.memory] as [String: Any]
            }),
        ]
    }

    // MARK: Usage summary

    @Test func usage_summary_matches_fixture() throws {
        let cases = try Self.summaryCases()
        #expect(cases.count == 15)
        for testCase in cases {
            let id = try #require(testCase["id"] as? String)
            let input = try #require(testCase["input"] as? [String: Any])
            let expected = try #require(testCase["expected"] as? [String: Any])
            let manifests = try #require(input["manifests"] as? [[String: Any]]).map { try Self.manifest(from: $0) }
            let checkpoint = try Self.checkpoint(from: input["checkpoint"])
            // A missing input.currentB key means not passed (fall back to the ledger B); a present key with null means the current window is unknown.
            let summary = input.keys.contains("currentB")
                ? ContextUsageSummary.make(manifests: manifests, checkpoint: checkpoint, currentB: input["currentB"] as? Int)
                : ContextUsageSummary.make(manifests: manifests, checkpoint: checkpoint)
            let actual = Self.fixtureShape(summary)
            for key in expected.keys.sorted() {
                let lhs = actual[key] as Any
                let rhs = expected[key] as Any
                #expect(
                    NSDictionary(dictionary: ["v": lhs]).isEqual(to: ["v": rhs]),
                    "\(id).\(key): actual \(lhs) expected \(rhs)"
                )
            }
        }
    }

    /// Production path: ContextLedgerStore really writes the manifest and ContextCompactionStore really writes the checkpoint, and both are read through the loader.
    @Test func usage_summary_from_production_ledger() throws {
        let database = try McpTestDatabase.make()
        defer { database.cleanUp() }
        let ids = try database.insertConversation()
        let conversationId = ids.conversation.uuidString
        let ledger = ContextLedgerStore(dbPool: database.pool)
        let compaction = ContextCompactionStore(dbPool: database.pool)

        let empty = try ContextUsageSummary.load(
            ledger: ledger, compaction: compaction, conversationId: conversationId, messages: [], rhoHi: Self.rhoHi
        )
        #expect(empty.display == .none)
        #expect(empty.ring == nil)

        let messages = (0..<4).map { index in
            TestFactories.makeMessage(role: index.isMultiple(of: 2) ? .user : .assistant, text: "message \(index)")
        }
        let covered = messages.map { ContextCheckpoint.CoveredMessage(id: $0.id.uuidString, text: $0.text) }
        let checkpointText = "<oriveo-context-checkpoint>\n## Goal\nship\n</oriveo-context-checkpoint>"
        try compaction.save(ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: covered[1].id),
            kind: .summary,
            coversFrom: covered[0].id,
            coversTo: covered[1].id,
            coversDigest: ContextCheckpoint.coversDigest(Array(covered[0...1])),
            messagesCovered: 2,
            userMessageIds: [covered[0].id],
            text: checkpointText,
            summary: "## Goal\nship",
            language: "en",
            model: "gpt-x",
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: 1_500,
            cost: nil
        ))
        try ledger.appendManifest(Self.manifest(from: [
            "createdAt": 1_000, "B": 115_200, "W": 128_000, "estimatedInput": 45_000, "observedInput": 90_000,
            "stopReason": "stop",
        ], conversationId: conversationId))
        try ledger.appendManifest(Self.manifest(from: [
            "createdAt": 2_000, "B": 115_200, "W": 128_000, "estimatedInput": 45_000, "observedInput": 30_000,
            "stopReason": "stop", "segments": [["kind": "instructions", "tokens": 500], ["kind": "notes", "tokens": 700, "omitted": 3]],
        ], conversationId: conversationId))

        let summary = try ContextUsageSummary.load(
            ledger: ledger, compaction: compaction, conversationId: conversationId, messages: messages, rhoHi: Self.rhoHi
        )
        let summaryTokens = ContextBudget.estimateMessage(checkpointText, rhoHi: Self.rhoHi)
        #expect(summary.display == .percent)
        #expect(summary.percent == 27)
        #expect(summary.basis == .observed)
        #expect(summary.used == 30_000)
        #expect(summary.ring == ContextUsageSummary.Ring(label: "27", tone: .neutral))
        #expect(summary.checkpointCount == 1)
        #expect(summary.segments?.summary == summaryTokens)
        #expect(summary.segments?.library == 700)
        #expect(summary.segments?.conversation == 30_000 - 500 - 700 - summaryTokens)
        #expect(summary.omitted?.notes == 3)

        // The messages covered by the checkpoint are not in the loaded history: it does not count as a valid checkpoint and the summary section is 0.
        let unrelated = try ContextUsageSummary.load(
            ledger: ledger, compaction: compaction, conversationId: conversationId,
            messages: [TestFactories.makeMessage(role: .user, text: "other")], rhoHi: Self.rhoHi
        )
        #expect(unrelated.segments?.summary == 0)
        #expect(unrelated.checkpointCount == 0)
    }

    // MARK: Ring

    @Test func usage_ring_hidden_unless_percent() throws {
        for testCase in try Self.summaryCases() {
            let input = try #require(testCase["input"] as? [String: Any])
            let manifests = try #require(input["manifests"] as? [[String: Any]]).map { try Self.manifest(from: $0) }
            let summary = ContextUsageSummary.make(manifests: manifests, checkpoint: try Self.checkpoint(from: input["checkpoint"]))
            #expect((summary.ring != nil) == (summary.display == .percent), "\(testCase["id"] ?? "")")
            #expect(ContextUsageRing.isVisible(summary) == (summary.display == .percent))
        }
        #expect(ContextUsageRing.isVisible(nil) == false)

        let english = Locale(identifier: "en_US")
        let normal = ContextUsageSummary.make(manifests: [try Self.manifest(from: [
            "createdAt": 1, "B": 115_200, "W": 128_000, "estimatedInput": 1, "observedInput": 43_776, "stopReason": "stop",
        ])], checkpoint: nil)
        #expect(ContextUsageRing.accessibilityText(for: normal, locale: english) == L10n.format(
            L10n.tr("context_usage_ring_a11y", table: .chat), locale: english, 38,
            ContextCompactionSeparator.compactCount(115_200, locale: english)
        ))
        #expect(ContextUsageRing.accessibilityText(for: normal, locale: english).contains("38%"))
        let over = ContextUsageSummary.make(manifests: [try Self.manifest(from: [
            "createdAt": 1, "B": 115_200, "W": 128_000, "estimatedInput": 1, "observedInput": 116_000, "stopReason": "stop",
        ])], checkpoint: nil)
        #expect(over.ring?.label == "!")
        #expect(ContextUsageRing.accessibilityText(for: over, locale: english) == L10n.tr("context_usage_ring_over_a11y", table: .chat))
    }

    @Test func strings_present_in_16_locales() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root
            .appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings"))) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let placeholders: [String: [String]] = [
            "context_usage_ring_a11y": ["%lld", "%@"],
            "context_usage_ring_over_a11y": [],
        ]
        var problems: [String] = []
        for (key, required) in placeholders.sorted(by: { $0.key < $1.key }) {
            let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for locale in Self.locales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    problems.append("\(key) [\(locale)] missing")
                    continue
                }
                for token in required where !value.contains(token) {
                    problems.append("\(key) [\(locale)] lacks \(token)")
                }
                if value.contains("{") { problems.append("\(key) [\(locale)] unconverted placeholder") }
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }
}
