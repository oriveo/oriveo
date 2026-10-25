import Foundation
import Testing
@testable import Oriveo

/// Shared fixture `tool-call-order.v1.json`: the order in which the tool_call verdict is decided for official
/// and subscription connections. Each case's verdict / sendsTools comes from production
/// `ToolCallCapabilityPolicy.decide`; memory is written through production `record`.
/// Order: first-hand > catalog evidence (does not fall back to the top-level toolCall) > rejection memory
/// (same revision, hand-entered declaration unchanged) > modelFacts (usable on a catalog miss) > local
/// hand-entered declaration > memory true > unknown (fail open, tools are sent).
@Suite("tool_call verdict order, shared fixture", .serialized, .sharedProcessState)
struct ToolCallOrderContractTests {
    private static let fixtureName = "tool-call-order.v1.json"
    private static let expectedIDs: Set<String> = [
        "catalog_evidence_supported",
        "catalog_evidence_unsupported",
        "catalog_evidence_missing_no_top_level_fallback",
        "hand_entered_model_facts_beat_local",
        "hand_entered_local_when_no_model_facts",
        "hand_entered_memory_when_no_declaration",
        "hand_entered_model_facts_beat_memory",
        "hand_entered_nothing_fail_open",
        "hand_entered_rejection_beats_model_facts",
        "hand_entered_rejection_beats_local_declaration",
        "hand_entered_rejection_stale_facts_revision",
        "hand_entered_rejection_void_after_declaration_edit",
        "hand_entered_memory_true_does_not_beat_model_facts_false",
        "catalog_evidence_beats_rejection",
        "catalog_evidence_missing_rejection_applies",
        "subscription_rejection_beats_model_facts",
    ]

    private static func cases() throws -> [[String: Any]] {
        let fixture = try CapabilitySharedFixture.load(fixtureName)
        return try #require(fixture["cases"] as? [[String: Any]])
    }

    private static func item(_ id: String) throws -> [String: Any] {
        try #require(cases().first { $0["id"] as? String == id }, "Fixture is missing \(id)")
    }

    /// The three states in the fixture: true / false / null (including a missing key).
    private static func triState(_ raw: Any?) -> Bool? {
        raw as? Bool
    }

    private static let evidenceGoldenName = "tool-call-order-evidence.v1.json"

    private static func golden() throws -> [String: Any] {
        try CapabilitySharedFixture.load(evidenceGoldenName)
    }

    /// Catalog cases use the golden subject's model id (the golden payload holds only that one entry); cases outside the catalog use an id specific to the case, so the catalog is guaranteed to miss.
    private static func modelID(_ id: String, item: [String: Any]) throws -> String {
        guard item["catalog"] is [String: Any] else {
            return "tool-call-order-" + id.replacingOccurrences(of: "_", with: "-")
        }
        let subject = try #require(try golden()["subject"] as? [String: Any])
        return try #require(subject["modelId"] as? String)
    }

    /// The golden's injected clock `clock.nowMs`: the evidence time window is judged by it, and observed / expiry times are not shifted.
    private static func goldenNow() throws -> Date {
        let clock = try #require(try golden()["clock"] as? [String: Any])
        let nowMs = try #require((clock["nowMs"] as? NSNumber)?.int64Value)
        return Date(timeIntervalSince1970: Double(nowMs) / 1_000)
    }

    /// This case's metadata: catalog cases take the whole lean payload golden serialized by the production server
    /// (`payloads.<supported|unsupported|missing>.lean`, with the evidence view embedded as is) and only write the
    /// top-level toolCall per the fixture; cases outside the catalog carry no providers. Both only add
    /// modelFacts / modelFactsRevision at the top level.
    private static func metadataPayload(id: String, item: [String: Any]) throws -> String {
        let modelID = try modelID(id, item: item)
        var payload: [String: Any]
        if let catalog = item["catalog"] as? [String: Any] {
            let variant = catalog["evidence"] as? String ?? "missing"
            let payloads = try #require(try golden()["payloads"] as? [String: Any])
            let lean = try #require(payloads[variant] as? [String: Any], "Golden is missing payloads.\(variant)")
            payload = try #require(lean["lean"] as? [String: Any], "Golden is missing payloads.\(variant).lean")
            var providers = try #require(payload["providers"] as? [String: Any])
            var openAI = try #require(providers["openAI"] as? [String: Any])
            var models = try #require(openAI["models"] as? [String: Any])
            var entry = try #require(models[modelID] as? [String: Any], "Golden is missing \(modelID)")
            entry["toolCall"] = catalog["topLevelToolCall"] ?? NSNull()
            models[modelID] = entry
            openAI["models"] = models
            providers["openAI"] = openAI
            payload["providers"] = providers
        } else {
            payload = [
                "version": 1,
                "view": "lean",
                "contractVersion": 1,
                "capabilityContractVersion": 2,
                "providers": [String: Any](),
            ]
        }
        if let fact = triState(item["modelFacts"]) {
            payload["modelFacts"] = [
                try #require(MetadataClient.modelFactsKey(providerKind: .openAI, modelID: modelID)): [
                    "source": "models_dev", "toolCall": fact,
                ],
            ]
        }
        // The current revision is the fixture's factsRevision (regardless of whether modelFacts exist).
        if let revision = item["factsRevision"] as? String {
            payload["modelFactsRevision"] = revision
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func run(_ id: String) async throws {
        let item = try item(id)
        let expect = try #require(item["expect"] as? [String: Any], "\(id)")
        let modelID = try modelID(id, item: item)
        let isCatalog = item["catalog"] is [String: Any]
        let isSubscription = item["form"] as? String == "subscription"

        await MetadataClient.shared.resetForTesting()
        // An evidence candidate binds to the revision (ETag) of this response; a candidate without an ETag does not authorize requests.
        try await MetadataClient.shared.loadForTesting(
            json: metadataPayload(id: id, item: item), metadataETag: "tool-call-order-\(id)"
        )

        // Catalog models are not hand-entered; outside the catalog = an official hand-entered model whose local explicit declaration sits on model.toolCall.
        // A subscription model is neither in the catalog nor hand-entered. A catalog hit that also carries memory =
        // a hand-entered id resolved to the catalog: in production only such a catalog model has connection memory (memoryEligible).
        let catalogWithMemory = isCatalog && item["memory"] is [String: Any]
        var model = TestFactories.makeModel(
            id: modelID, capabilities: [.text], isManual: !isSubscription && (!isCatalog || catalogWithMemory)
        )
        let declaration = isCatalog ? nil : triState(item["localDeclaration"])
        var provider = TestFactories.makeProvider(kind: .openAI, models: [model])
        if isSubscription { provider.authMode = .subscription }
        #expect(
            MetadataClient.shared.syncModelFactsRevision() == item["factsRevision"] as? String,
            "\(id): the current revision does not match the fixture"
        )
        #expect(
            (MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: .openAI) != nil) == isCatalog,
            "\(id): catalog hit does not match the fixture"
        )

        let store = try makeR4MemoryStore()
        if let memory = item["memory"] as? [String: Any] {
            let remembered = try #require(memory["value"] as? Bool, "\(id) memory.value")
            let edited = memory["declarationEditedAfterRecord"] as? Bool == true
            // The model at record time: the declaration edited after recording = the declaration at record time differs from now.
            model.toolCall = edited ? (declaration == nil ? true : nil) : declaration
            // Memory is written under the revision at record time: when it differs from the current one, switch to that revision first, record through the production write entry, then switch back.
            let recordedRevision = memory["factsRevision"] as? String
            if recordedRevision != item["factsRevision"] as? String {
                var stale = item
                stale["factsRevision"] = recordedRevision ?? NSNull()
                try await MetadataClient.shared.loadForTesting(
                    json: metadataPayload(id: id, item: stale), metadataETag: "tool-call-order-\(id)-recorded"
                )
            }
            let reason: ToolCallMemoryReason = remembered ? .structuredToolCalls : .toolsRejected4xx
            if ToolCallCapabilityPolicy.memoryEligible(provider: provider, model: model) {
                RelayRejectionRecording.rememberToolCall(
                    provider: provider, model: model, toolCall: remembered, reason: reason,
                    statusCode: remembered ? nil : 400, sentTransport: nil, memory: store
                )
            } else {
                // Catalog models do not write memory in production; write one directly to verify that catalog evidence still beats it.
                #expect(store.record(connectionID: provider.id, modelID: modelID, toolCall: remembered, reason: reason))
            }
            #expect(store.count() == 1, "\(id): memory was not written")
            if recordedRevision != item["factsRevision"] as? String {
                try await MetadataClient.shared.loadForTesting(
                    json: metadataPayload(id: id, item: item), metadataETag: "tool-call-order-\(id)"
                )
            }
        }
        model.toolCall = declaration

        let now = try Self.goldenNow()
        let decision = ToolCallCapabilityPolicy.decide(provider: provider, model: model, memory: store, now: now)
        #expect(decision.verdict == triState(expect["verdict"]), "\(id) verdict")
        #expect(decision.allowed == (expect["sendsTools"] as? Bool), "\(id) sendsTools")
        #expect(
            ToolCallCapabilityPolicy.permitsToolsOutbound(provider: provider, model: model, memory: store, now: now)
                == (expect["sendsTools"] as? Bool),
            "\(id) outbound"
        )
        await MetadataClient.shared.resetForTesting()
    }

    @Test("The fixture id set is locked")
    func idSetIsLocked() throws {
        let ids = try Self.cases().compactMap { $0["id"] as? String }
        #expect(ids.count == Self.expectedIDs.count)
        #expect(Set(ids) == Self.expectedIDs)
    }

    @Test func TOOL_CALL_ORDER_catalog_evidence_supported() async throws {
        try await Self.run("catalog_evidence_supported")
    }

    @Test func TOOL_CALL_ORDER_catalog_evidence_unsupported() async throws {
        try await Self.run("catalog_evidence_unsupported")
    }

    @Test func TOOL_CALL_ORDER_catalog_evidence_missing_no_top_level_fallback() async throws {
        try await Self.run("catalog_evidence_missing_no_top_level_fallback")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_model_facts_beat_local() async throws {
        try await Self.run("hand_entered_model_facts_beat_local")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_local_when_no_model_facts() async throws {
        try await Self.run("hand_entered_local_when_no_model_facts")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_memory_when_no_declaration() async throws {
        try await Self.run("hand_entered_memory_when_no_declaration")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_model_facts_beat_memory() async throws {
        try await Self.run("hand_entered_model_facts_beat_memory")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_nothing_fail_open() async throws {
        try await Self.run("hand_entered_nothing_fail_open")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_rejection_beats_model_facts() async throws {
        try await Self.run("hand_entered_rejection_beats_model_facts")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_rejection_beats_local_declaration() async throws {
        try await Self.run("hand_entered_rejection_beats_local_declaration")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_rejection_stale_facts_revision() async throws {
        try await Self.run("hand_entered_rejection_stale_facts_revision")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_rejection_void_after_declaration_edit() async throws {
        try await Self.run("hand_entered_rejection_void_after_declaration_edit")
    }

    @Test func TOOL_CALL_ORDER_hand_entered_memory_true_does_not_beat_model_facts_false() async throws {
        try await Self.run("hand_entered_memory_true_does_not_beat_model_facts_false")
    }

    @Test func TOOL_CALL_ORDER_catalog_evidence_beats_rejection() async throws {
        try await Self.run("catalog_evidence_beats_rejection")
    }

    @Test func TOOL_CALL_ORDER_subscription_rejection_beats_model_facts() async throws {
        try await Self.run("subscription_rejection_beats_model_facts")
    }

    @Test func TOOL_CALL_ORDER_catalog_evidence_missing_rejection_applies() async throws {
        try await Self.run("catalog_evidence_missing_rejection_applies")
    }
}
