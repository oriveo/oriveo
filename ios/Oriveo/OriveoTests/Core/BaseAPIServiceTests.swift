import Foundation
import Testing
@testable import Oriveo

@Suite("BaseAPIService")
struct BaseAPIServiceTests {
    @Test("Apply Headers Adds Native User Agent")
    func applyHeadersAddsNativeUserAgent() {
        let service = BaseAPIService()
        var request = URLRequest(url: URL(string: "https://example.com")!)

        service.applyHeaders(to: &request, apiKey: "sk-test")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Oriveo/") == true)
    }

    @Test("Map HTTPError Identifies Responses Protocol Mismatch")
    func mapHTTPErrorIdentifiesResponsesProtocolMismatch() {
        let service = BaseAPIService()
        let body = #"{"error":{"message":"Unknown parameter: 'input[4].content[1].url'.","type":"invalid_request_error","param":"input[4].content[1].url","code":"unknown_parameter"}}"#
        let data = body.data(using: .utf8)!

        let error = service.mapHTTPError(statusCode: 400, data: data, isRelay: true)

        guard case let .upstream(statusCode, detail) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(statusCode == 400)
        #expect(detail.localizedCaseInsensitiveContains("Responses"))
        #expect(detail.localizedCaseInsensitiveContains("Codex"))
    }

    @Test("mapHTTPError:402 → quotaExceeded")
    func mapHTTPErrorClassifies402AsQuotaExceeded() {
        let service = BaseAPIService()
        let body = #"{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}"#
        let data = body.data(using: .utf8)!

        let error = service.mapHTTPError(statusCode: 402, data: data)

        guard case .quotaExceeded = error else {
            Issue.record("expected .quotaExceeded, got \(error)")
            return
        }
    }

    @Test("Map HTTPError Ignores Unrelated Unknown Parameter")
    func mapHTTPErrorIgnoresUnrelatedUnknownParameter() {
        let service = BaseAPIService()
        let body = #"{"error":{"message":"Unknown parameter: 'foobar'.","type":"invalid_request_error","param":"foobar","code":"unknown_parameter"}}"#
        let data = body.data(using: .utf8)!

        let error = service.mapHTTPError(statusCode: 400, data: data)

        guard case let .upstream(_, detail) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(!detail.localizedCaseInsensitiveContains("OpenAI Responses protocol"))
    }


    private static let anthropicInvalidKeyBody =
        #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#

    private static let openAIModelNotFoundBody =
        #"{"error":{"message":"The model `gpt-99` does not exist or you do not have access to it.","type":"invalid_request_error","code":"model_not_found"}}"#

    private static let openAIModelNotFoundMessage =
        "The model `gpt-99` does not exist or you do not have access to it."

    private static func looksLikeRelayGuidance(_ detail: String) -> Bool {
        detail.contains("Upstream error:")
            || detail.contains("Providers →")
            || detail.localizedCaseInsensitiveContains("custom LLM")
    }

    @Test("Official Anthropic Invalid Key Does Not Get Relay Guidance")
    func officialAnthropicInvalidKeyDoesNotGetRelayGuidance() {
        let service = BaseAPIService()
        let data = Data(Self.anthropicInvalidKeyBody.utf8)

        let error = service.mapHTTPError(statusCode: 401, data: data)

        guard case let .invalidAPIKey(detail) = error else {
            Issue.record("expected .invalidAPIKey, got \(error)")
            return
        }
        #expect(detail == "invalid x-api-key")
        #expect(!Self.looksLikeRelayGuidance(detail))
    }

    @Test("Official Anthropic Forbidden Does Not Get Relay Guidance")
    func officialAnthropicForbiddenDoesNotGetRelayGuidance() {
        let service = BaseAPIService()
        let data = Data(Self.anthropicInvalidKeyBody.utf8)

        let error = service.mapHTTPError(statusCode: 403, data: data)

        guard case let .invalidAPIKey(detail) = error else {
            Issue.record("expected .invalidAPIKey, got \(error)")
            return
        }
        #expect(!Self.looksLikeRelayGuidance(detail))
    }

    @Test(
        "Official Provider model_not_found (real OpenAI/Moonshot payload) maps to generic upstream, no relay guidance",
        arguments: [404, 400]
    )
    func officialModelNotFoundDoesNotGetRelayGuidance(statusCode: Int) {
        let service = BaseAPIService()
        let data = Data(Self.openAIModelNotFoundBody.utf8)

        let error = service.mapHTTPError(
            statusCode: statusCode, data: data,
            url: URL(string: "https://api.openai.com/v1/chat/completions")
        )

        guard case let .upstream(code, detail) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(code == statusCode)
        #expect(detail == Self.openAIModelNotFoundMessage)
        #expect(!Self.looksLikeRelayGuidance(detail))
    }

    @Test("Relay Auth Mismatch Keeps Guidance")
    func relayAuthMismatchKeepsGuidance() {
        let service = BaseAPIService()
        let data = Data(Self.anthropicInvalidKeyBody.utf8)

        let error = service.mapHTTPError(statusCode: 401, data: data, isRelay: true)

        guard case let .invalidAPIKey(detail) = error else {
            Issue.record("expected .invalidAPIKey, got \(error)")
            return
        }
        #expect(Self.looksLikeRelayGuidance(detail))
        #expect(detail.localizedCaseInsensitiveContains("x-api-key"))
        #expect(detail.contains("Auth"))
        #expect(detail.contains("Upstream error: invalid x-api-key"))
    }

    @Test(
        "relay model_not_found still keeps the relay change-model guidance (no regression)",
        arguments: [404, 400]
    )
    func relayModelUnavailableKeepsGuidance(statusCode: Int) {
        let service = BaseAPIService()
        let data = Data(Self.openAIModelNotFoundBody.utf8)

        let error = service.mapHTTPError(
            statusCode: statusCode, data: data,
            url: URL(string: "https://relay.example.com/v1/chat/completions"), isRelay: true
        )

        guard case let .upstream(code, detail) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(code == statusCode)
        #expect(Self.looksLikeRelayGuidance(detail))
        #expect(detail.contains("Model"))
        #expect(detail.contains("Upstream error: " + Self.openAIModelNotFoundMessage))
    }

    @Test("Relay Chinese Model Unavailable Keeps Guidance")
    func relayChineseModelUnavailableKeepsGuidance() {
        let service = BaseAPIService()
        let data = Data(#"{"code":404,"msg":"model is not supported, please switch models"}"#.utf8)

        let error = service.mapHTTPError(statusCode: 404, data: data, isRelay: true)

        guard case let .upstream(_, detail) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(Self.looksLikeRelayGuidance(detail))
        #expect(detail.contains("Upstream error: model is not supported, please switch models"))
    }
}
