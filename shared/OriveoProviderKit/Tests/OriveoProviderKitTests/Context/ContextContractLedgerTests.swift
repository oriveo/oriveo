import Foundation
import OriveoProviderKit
import Testing

// Ledger: the rho calibration table is isolated by (transportInstanceId, modelId), defaults to rho0 and is serializable;
// the manifest log keeps only the latest 50 entries per conversation, and conversations do not evict each other.

@Suite("ContextContractLedger")
struct ContextContractLedgerTests {
    private func sampled(_ table: inout RhoCalibrationTable, _ key: RhoCalibrationKey, observed: Int, times: Int) {
        for _ in 0..<times {
            table.recordSample(for: key, observedInput: observed, mediaTokens: 0, textBytes: 1000)
        }
    }

    @Test("defaults to rho0 when uncalibrated")
    func missingKeyDefaultsToRho0() {
        let table = RhoCalibrationTable()
        let calibration = table.calibration(for: RhoCalibrationKey(transportInstanceId: "t1", modelId: "m1"))
        #expect(calibration.n == 0)
        #expect(calibration.rho == RhoCalibration.rho0)
        #expect(calibration.rho == 0.5)
        #expect(calibration.rhoHi == 0.5)
    }

    @Test("isolated by the transport and model keys")
    func keysAreIsolated() {
        var table = RhoCalibrationTable()
        let a = RhoCalibrationKey(transportInstanceId: "t1", modelId: "m1")
        let sameTransportOtherModel = RhoCalibrationKey(transportInstanceId: "t1", modelId: "m2")
        let otherTransportSameModel = RhoCalibrationKey(transportInstanceId: "t2", modelId: "m1")
        sampled(&table, a, observed: 300, times: 3)
        table.recordOverflowMiss(for: sameTransportOtherModel)

        #expect(table.calibration(for: a).n == 3)
        #expect(ContextContractFixture.close(table.calibration(for: a).rho, 0.3))
        #expect(table.calibration(for: sameTransportOtherModel).n == 0)
        #expect(table.calibration(for: sameTransportOtherModel).rho == 0.625)
        #expect(table.calibration(for: otherTransportSameModel) == RhoCalibration())
    }

    @Test("Codable round trip preserves all entries and seed samples")
    func tableRoundTrips() throws {
        var table = RhoCalibrationTable()
        let a = RhoCalibrationKey(transportInstanceId: "t1", modelId: "m1")
        let b = RhoCalibrationKey(transportInstanceId: "t2", modelId: "m2")
        sampled(&table, a, observed: 300, times: 4)
        sampled(&table, b, observed: 280, times: 2)

        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(RhoCalibrationTable.self, from: data)
        #expect(decoded == table)
        #expect(decoded.calibration(for: b).n == 2)
        // The 3rd sample reseeds rho with the mean of 1..3: a half-calibrated entry after decoding must be able to continue calibrating.
        var resumed = decoded
        #expect(decoded.calibration(for: b).seeds == [0.28, 0.28])
        resumed.recordSample(for: b, observedInput: 320, mediaTokens: 0, textBytes: 1000)
        #expect(ContextContractFixture.close(resumed.calibration(for: b).rho, (0.28 + 0.28 + 0.32) / 3))
    }

    private func manifest(_ requestId: String, conversation: String) -> ContextManifest {
        ContextManifest(
            requestId: requestId,
            conversationId: conversation,
            purpose: .chat,
            transport: "anthropic-1",
            model: "claude",
            W: 200_000,
            O: 8192,
            B: 180_000,
            basis: .estimated,
            estimatedInput: 621,
            observedInput: nil,
            segments: [ContextManifestSegment(kind: .memory, tokens: 40, items: 2, omitted: 0)],
            checkpointId: nil,
            tailFrom: nil,
            unansweredMerged: 0,
            reminder: false,
            stopReason: nil,
            createdAt: 1_760_000_000_123
        )
    }

    @Test("the 51st entry evicts the oldest")
    func logKeepsLatestFifty() {
        var log = ContextManifestLog()
        for index in 1...51 {
            log.append(manifest("r\(index)", conversation: "c1"))
        }
        let kept = log.manifests(conversationId: "c1")
        #expect(ContextManifestLog.capacityPerConversation == 50)
        #expect(kept.count == 50)
        #expect(kept.first?.requestId == "r2")
        #expect(kept.last?.requestId == "r51")
        #expect(log.latest(conversationId: "c1")?.requestId == "r51")
        #expect(log.latest(conversationId: "missing") == nil)
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test("RhoCalibration encodes as {n, rho, seeds}, and recording returns a new value")
    func calibrationJSONShape() throws {
        let original = RhoCalibration()
        let sampled = original.recordingSample(observedInput: 300, mediaTokens: 0, textBytes: 1000)
        #expect(original == RhoCalibration())
        let object = try jsonObject(sampled)
        #expect(Set(object.keys) == ["n", "rho", "seeds"])
        #expect(object["n"] as? Int == 1)
        #expect(object["rho"] as? Double == 0.5)
        #expect(object["seeds"] as? [Double] == [0.3])
    }

    @Test("RhoCalibrationTable encodes as {version:1, entries:[...]}")
    func tableJSONShape() throws {
        var table = RhoCalibrationTable()
        table.recordSample(
            for: RhoCalibrationKey(transportInstanceId: "t1", modelId: "m1"),
            observedInput: 300, mediaTokens: 0, textBytes: 1000
        )
        let object = try jsonObject(table)
        #expect(Set(object.keys) == ["version", "entries"])
        #expect(object["version"] as? Int == 1)
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(Set(entry.keys) == ["transportInstanceId", "modelId", "n", "rho", "seeds"])
        #expect(entry["transportInstanceId"] as? String == "t1")
        #expect(entry["modelId"] as? String == "m1")
        #expect(entry["n"] as? Int == 1)
        #expect(entry["seeds"] as? [Double] == [0.3])
    }

    @Test("manifest createdAt encodes as an epoch-millisecond integer, and segment kind as a closed-set string")
    func manifestJSONShape() throws {
        let object = try jsonObject(manifest("r1", conversation: "c1"))
        #expect((object["createdAt"] as? NSNumber)?.int64Value == 1_760_000_000_123)
        #expect(object["createdAt"] is NSNumber)
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.first?["kind"] as? String == "memory")
        #expect(object["purpose"] as? String == "chat")
    }

    @Test("isolated by conversation; other conversations are not evicted")
    func logIsolatedPerConversation() throws {
        var log = ContextManifestLog()
        log.append(manifest("other", conversation: "c2"))
        for index in 1...60 {
            log.append(manifest("r\(index)", conversation: "c1"))
        }
        #expect(log.manifests(conversationId: "c1").count == 50)
        #expect(log.manifests(conversationId: "c2").map(\.requestId) == ["other"])
        #expect(log.manifests(conversationId: "missing").isEmpty)

        let decoded = try JSONDecoder().decode(ContextManifestLog.self, from: JSONEncoder().encode(log))
        #expect(decoded == log)
    }
}
