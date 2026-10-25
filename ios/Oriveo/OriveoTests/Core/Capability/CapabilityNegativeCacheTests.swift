import Foundation
import Testing
@testable import Oriveo

/// Reads the shared fixture `shared/test-fixtures/capability/<name>` (walks up from this test file to the repo root).
enum CapabilitySharedFixture {
    static func load(_ name: String) throws -> [String: Any] {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = current.appendingPathComponent("shared/test-fixtures/capability/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let object = try JSONSerialization.jsonObject(with: data)
                return try #require(object as? [String: Any])
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        Issue.record("Shared fixture \(name) not found")
        throw CancellationError()
    }
}

@Suite("CapabilityNegativeCache v2")
struct CapabilityNegativeCacheTests {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeCache(_ clock: Clock) -> CapabilityNegativeCache {
        let defaults = UserDefaults(suiteName: "CapabilityNegativeCacheTests.\(UUID().uuidString)")!
        return CapabilityNegativeCache(defaults: defaults, clock: { clock.now })
    }

    private static func verdict(from raw: Any?) -> CapabilityNegativeCache.Verdict? {
        guard let dict = raw as? [String: Any] else { return nil }
        return CapabilityNegativeCache.Verdict(
            state: dict["state"] as? String,
            reasonCode: dict["reasonCode"] as? String,
            wireFamily: dict["wireFamily"] as? String,
            sourceRefs: dict["sourceRefs"] as? [String]
        )
    }

    @Test func verdictRevisionCasesMatchFixtureByteForByte() throws {
        let fixture = try CapabilitySharedFixture.load("negative-cache.v1.json")
        let cases = try #require(fixture["verdictRevisionCases"] as? [[String: Any]])
        #expect(cases.count == 3)
        for item in cases {
            let id = item["id"] as? String ?? "?"
            let verdict = Self.verdict(from: item["verdict"])
            let canonical = CapabilityNegativeCache.canonical(verdict)
            let expectedCanonical = try #require(item["canonical"] as? String, "\(id)")
            #expect(Array(canonical.utf8) == Array(expectedCanonical.utf8), "\(id)")
            #expect(CapabilityNegativeCache.verdictRevision(verdict) == item["revision"] as? String, "\(id)")
        }
    }

    @Test func storageKeyAndTTL() {
        #expect(CapabilityNegativeCache.storageKey == "capability_negative_cache.v2")
        #expect(CapabilityNegativeCache.ttl == 604_800)
    }

    @Test func sameRevisionHits() {
        let clock = Clock()
        let cache = makeCache(clock)
        let revision = CapabilityNegativeCache.verdictRevision(nil)
        cache.record(
            connectionId: "c1", modelId: "qwen-max", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", signatureId: "dashscope.unexpected_item_type", verdictRevision: revision
        )
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "qwen-max", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "qwen-max", wireFamily: "openai_chat.file",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        let entry = cache.entry(
            connectionId: "c1", modelId: "qwen-max", wireFamily: "openai_chat.image_url", capabilityKey: "vision_input"
        )
        #expect(entry?.signatureId == "dashscope.unexpected_item_type")
        #expect(entry?.recordedAt == clock.now.timeIntervalSince1970)
    }

    @Test func revisionMismatchMissesButKeepsEntry() {
        let clock = Clock()
        let cache = makeCache(clock)
        let recorded = CapabilityNegativeCache.verdictRevision(nil)
        let changed = CapabilityNegativeCache.verdictRevision(
            .init(state: "unavailable", reasonCode: "r", wireFamily: "openai_chat", sourceRefs: ["b", "a"])
        )
        #expect(recorded != changed)
        cache.record(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", signatureId: "s", verdictRevision: recorded
        )
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: changed
        ))
        let entry = cache.entry(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url", capabilityKey: "vision_input"
        )
        #expect(entry?.verdictRevision == recorded)
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: recorded
        ))
    }

    @Test func expiresAfterSevenDays() {
        let clock = Clock()
        let cache = makeCache(clock)
        let revision = CapabilityNegativeCache.verdictRevision(nil)
        cache.record(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", signatureId: "s", verdictRevision: revision
        )
        clock.now = clock.now.addingTimeInterval(604_799)
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        clock.now = clock.now.addingTimeInterval(1)
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
    }

    @Test func parameterKeyIsStored() {
        let clock = Clock()
        let cache = makeCache(clock)
        let revision = CapabilityNegativeCache.verdictRevision(nil)
        cache.record(
            connectionId: "c1", modelId: "o3", wireFamily: "openai_chat",
            capabilityKey: "param:temperature", signatureId: "openai.unsupported_parameter", verdictRevision: revision
        )
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "o3", wireFamily: "openai_chat",
            capabilityKey: "param:temperature", verdictRevision: revision
        ))
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "o3", wireFamily: "openai_chat",
            capabilityKey: "param:top_p", verdictRevision: revision
        ))
    }

    /// Two consecutive reads decode only once: after the first read the backing store is changed behind the
    /// cache's back and the second read still returns the first copy; a write (including a clear) invalidates
    /// the copy and the next read decodes from the store again.
    @Test func load_is_cached_until_write() throws {
        let clock = Clock()
        let defaults = try #require(UserDefaults(suiteName: "CapabilityNegativeCacheTests.\(UUID().uuidString)"))
        let cache = CapabilityNegativeCache(defaults: defaults, clock: { clock.now })
        let revision = CapabilityNegativeCache.verdictRevision(nil)
        cache.record(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", signatureId: "s", verdictRevision: revision
        )
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))

        // Edit the store directly, bypassing the cache: the in-memory copy stays, so the second read does not decode again.
        let stored = try #require(defaults.data(forKey: CapabilityNegativeCache.storageKey))
        let other = CapabilityNegativeCache.Entry(
            connectionId: "c2", modelId: "m", wireFamily: "openai_chat.image_url", capabilityKey: "vision_input",
            recordedAt: clock.now.timeIntervalSince1970, signatureId: "s", verdictRevision: revision
        )
        defaults.set(try JSONEncoder().encode([other]), forKey: CapabilityNegativeCache.storageKey)
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        #expect(cache.entry(
            connectionId: "c2", modelId: "m", wireFamily: "openai_chat.image_url", capabilityKey: "vision_input"
        ) == nil)

        // A clear is also a write: the copy is invalidated and the read sees what is in the store now.
        cache.clearConnection("c-none")
        #expect(cache.entry(
            connectionId: "c2", modelId: "m", wireFamily: "openai_chat.image_url", capabilityKey: "vision_input"
        ) == other)
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))

        // A record is visible immediately after the write as well.
        defaults.set(stored, forKey: CapabilityNegativeCache.storageKey)
        #expect(!cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        cache.record(
            connectionId: "c3", modelId: "m", wireFamily: "openai_chat.file",
            capabilityKey: "file_input", signatureId: "s", verdictRevision: revision
        )
        #expect(cache.isRejected(
            connectionId: "c1", modelId: "m", wireFamily: "openai_chat.image_url",
            capabilityKey: "vision_input", verdictRevision: revision
        ))
        #expect(cache.isRejected(
            connectionId: "c3", modelId: "m", wireFamily: "openai_chat.file",
            capabilityKey: "file_input", verdictRevision: revision
        ))
    }
}

/// Production clear paths: deleting a connection or changing an override through ProviderManager clears v2 and v1 together.
@Suite("CapabilityNegativeCache v2 clear paths", .serialized, .sharedProcessState)
@MainActor
struct CapabilityNegativeCacheClearPathTests {
    private static var retainedStates: [AppState] = []

    private static func relayState(transport: RelayTransport) -> (AppState, Provider) {
        let model = TestFactories.makeModel(id: "m1", capabilities: [.text], isDefault: true)
        var provider = TestFactories.makeProvider(
            kind: .relay, models: [model], catalogModels: [model],
            apiKey: "sk-test", apiKeyPreview: "sk-…test", baseURLText: "https://api.myrelay.dev"
        )
        provider.relayRequested = RelayRequestedConfig(
            transport: transport, authMode: .bearer, securityMode: .remoteHTTPS
        )
        let state = AppState(seedDemoData: false, sessionUID: "capability-negcache-clear-\(UUID().uuidString)")
        state.providers = [provider]
        retainedStates.append(state)
        return (state, provider)
    }

    private static func recordV2(_ connectionID: String, family: String, key: String) {
        CapabilityNegativeCache.shared.record(
            connectionId: connectionID, modelId: "m1", wireFamily: family, capabilityKey: key,
            signatureId: "relay.classified_rejected", verdictRevision: CapabilityNegativeCache.verdictRevision(nil)
        )
    }

    private static func hasV2(_ connectionID: String, family: String, key: String) -> Bool {
        CapabilityNegativeCache.shared.entry(
            connectionId: connectionID, modelId: "m1", wireFamily: family, capabilityKey: key
        ) != nil
    }

    @Test func delete_connection_clears_v2_entries() {
        let (state, provider) = Self.relayState(transport: .openaiChatCompletions)
        let connectionID = provider.id.uuidString
        let other = UUID().uuidString
        defer {
            CapabilityNegativeCache.shared.clearConnection(connectionID)
            CapabilityNegativeCache.shared.clearConnection(other)
        }
        let vision = CapabilityEvidenceFacade.visionInputKey
        let file = CapabilityEvidenceFacade.fileInputKey
        Self.recordV2(connectionID, family: "openai_chat.image_url", key: vision)
        Self.recordV2(connectionID, family: "openai_responses.input_file", key: file)
        Self.recordV2(other, family: "openai_chat.image_url", key: vision)

        #expect(state.providerManager.removeProvider(provider.id))
        #expect(!Self.hasV2(connectionID, family: "openai_chat.image_url", key: vision))
        #expect(!Self.hasV2(connectionID, family: "openai_responses.input_file", key: file))
        #expect(Self.hasV2(other, family: "openai_chat.image_url", key: vision), "other connections stay untouched")
    }

    @Test func override_change_clears_v2_entries() {
        let (state, provider) = Self.relayState(transport: .openaiChatCompletions)
        let manager = state.providerManager
        let connectionID = provider.id.uuidString
        defer {
            CapabilityNegativeCache.shared.clearConnection(connectionID)
            RelayNegativeCache.shared.clearConnection(connectionID)
        }
        let vision = CapabilityEvidenceFacade.visionInputKey
        let file = CapabilityEvidenceFacade.fileInputKey
        let firstSend = RelayFirstSendTransport.current(provider: provider, model: provider.models[0])
        let visionFamily = CapabilityEvidenceProductionAdapter.relayWireFamily(transport: firstSend, key: vision)
        let fileFamily = CapabilityEvidenceProductionAdapter.relayWireFamily(transport: firstSend, key: file)
        #expect(visionFamily == "openai_chat.image_url")
        #expect(fileFamily == "openai_chat.file")
        Self.recordV2(connectionID, family: "openai_chat.image_url", key: vision)
        Self.recordV2(connectionID, family: "openai_chat.file", key: file)
        // An entry for the same key under another protocol family is not on the first-send protocol and is not cleared.
        Self.recordV2(connectionID, family: "openai_responses.input_image", key: vision)

        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .image, value: true)
        #expect(!Self.hasV2(connectionID, family: "openai_chat.image_url", key: vision))
        #expect(Self.hasV2(connectionID, family: "openai_chat.file", key: file), "only the same level is cleared")
        #expect(Self.hasV2(connectionID, family: "openai_responses.input_image", key: vision), "only the first-send protocol's family is cleared")

        // Auto leaves the negative cache alone.
        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .file, value: nil)
        #expect(Self.hasV2(connectionID, family: "openai_chat.file", key: file))

        manager.setRelayCapabilityOverride(providerID: provider.id, modelID: "m1", key: .file, value: false)
        #expect(!Self.hasV2(connectionID, family: "openai_chat.file", key: file))
    }
}
