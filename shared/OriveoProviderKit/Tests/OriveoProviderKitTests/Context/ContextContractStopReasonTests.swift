import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/stop-reason.v1.json` case by case: inputs go through production StopReasonResolver, and failure messages carry the fixture case id.

private struct StopReasonContract: Decodable {
    struct Input: Decodable {
        var family: String
        var ended: String
        var finishRaw: String?
        var hadContent: Bool
    }

    struct Case: Decodable {
        var id: String
        var input: Input
        var expected: String
    }

    var `enum`: [String]
    var cases: [Case]
}

@Suite("ContextContractStopReason")
struct ContextContractStopReasonTests {
    private let contract: StopReasonContract

    init() throws {
        contract = try ContextContractFixture.load("stop-reason.v1.json")
    }

    @Test("enum closed set equals the fixture verbatim")
    func enumMatchesFixture() {
        #expect(StopReason.allCases.map(\.rawValue) == contract.enum)
    }

    @Test("cases")
    func cases() throws {
        #expect(contract.cases.count == 79)
        for item in contract.cases {
            let family = try #require(StopFamily(rawValue: item.input.family), "\(item.id)")
            let ended = try #require(StreamEnding(rawValue: item.input.ended), "\(item.id)")
            let expected = try #require(StopReason(rawValue: item.expected), "\(item.id)")
            let actual = StopReasonResolver.resolve(
                family: family, ended: ended, finishRaw: item.input.finishRaw, hadContent: item.input.hadContent
            )
            #expect(actual == expected, "\(item.id)")
        }
    }

    @Test("responsesFinishRaw joins incomplete:reason")
    func responsesFinishRaw() {
        #expect(StopReasonResolver.responsesFinishRaw(status: "completed", incompleteReason: nil) == "completed")
        #expect(StopReasonResolver.responsesFinishRaw(status: "failed", incompleteReason: nil) == "failed")
        #expect(
            StopReasonResolver.responsesFinishRaw(status: "incomplete", incompleteReason: "max_output_tokens")
                == "incomplete:max_output_tokens"
        )
        let raw = StopReasonResolver.responsesFinishRaw(status: "incomplete", incompleteReason: "content_filter")
        #expect(StopReasonResolver.resolve(family: .openaiResponses, ended: .clean, finishRaw: raw, hadContent: true) == .contentFilter)
    }

    @Test("responses_completed_with_reason_is_stop: completed with incomplete_details.reason is still recorded as completed -> stop")
    func responses_completed_with_reason_is_stop() {
        let raw = StopReasonResolver.responsesFinishRaw(status: "completed", incompleteReason: "max_output_tokens")
        #expect(raw == "completed")
        #expect(StopReasonResolver.resolve(family: .openaiResponses, ended: .clean, finishRaw: raw, hadContent: true) == .stop)
    }

    @Test("fromStored: null stays null, an unrecognized string is recorded as unknown")
    func fromStored() {
        #expect(StopReason.fromStored(nil) == nil)
        #expect(StopReason.fromStored("length") == .length)
        #expect(StopReason.fromStored("context_window_exceeded") == .contextWindowExceeded)
        #expect(StopReason.fromStored("bogus") == .unknown)
    }

    @Test("ContextManifest.stopReason is encoded as the fixture text and round-trips unchanged")
    func manifestRoundTrip() throws {
        for reason in StopReason.allCases {
            let manifest = ContextManifest(
                requestId: "r1", conversationId: "c1", purpose: .chat, transport: "anthropic-1", model: "claude",
                W: 200_000, O: 8192, B: 180_000, basis: .estimated, estimatedInput: 10, observedInput: nil,
                segments: [], checkpointId: nil, tailFrom: nil, unansweredMerged: 0, reminder: false,
                stopReason: reason, createdAt: 1_760_000_000_123
            )
            let data = try JSONEncoder().encode(manifest)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["stopReason"] as? String == reason.rawValue)
            #expect(try JSONDecoder().decode(ContextManifest.self, from: data) == manifest)
        }
    }
}
