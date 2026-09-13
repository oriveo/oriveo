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

    @Test("mapStreamError: production Nvidia overloaded → rateLimited")
    func mapStreamErrorClassifiesNvidiaOverloadedAsRateLimited() {
        let error = BaseAPIService.mapStreamError(
            type: nil,
            message: "Upstream error from Nvidia: Service temporarily overloaded"
        )
        guard case .rateLimited = error else {
            Issue.record("expected .rateLimited, got \(error)")
            return
        }
    }

    @Test("mapStreamError: unknown server_error stays upstream")
    func mapStreamErrorKeepsUnknownServerErrorAsUpstream() {
        let error = BaseAPIService.mapStreamError(
            type: "server_error",
            message: "The server had an error processing your request."
        )
        guard case .upstream(let status, _) = error else {
            Issue.record("expected .upstream, got \(error)")
            return
        }
        #expect(status == 200)
    }

    @Test("mapHTTPError: 200/500 overload body → rateLimited; true 5xx stays upstream")
    func mapHTTPErrorClassifiesOverloadWithoutSilencingReal5xx() {
        let service = BaseAPIService()
        let overloaded = #"{"error":{"message":"Upstream error from Nvidia: Service temporarily overloaded"}}"#
        guard case .rateLimited = service.mapHTTPError(statusCode: 200, data: Data(overloaded.utf8)) else {
            Issue.record("expected 200 overloaded → rateLimited")
            return
        }
        guard case .rateLimited = service.mapHTTPError(statusCode: 500, data: Data(overloaded.utf8)) else {
            Issue.record("expected 500 overloaded → rateLimited")
            return
        }
        guard case .upstream = service.mapHTTPError(
            statusCode: 502,
            data: Data(#"{"error":{"message":"bad gateway"}}"#.utf8)
        ) else {
            Issue.record("expected 502 without overload needles → upstream")
            return
        }
    }

    @Test("mapStreamError: account-seat overload / unavailable for free must not be rateLimited")
    func mapStreamErrorRejectsWideOverloadNeedles() {
        let accountSeats = BaseAPIService.mapStreamError(
            type: nil,
            message: "account overloaded with extra seats"
        )
        guard case .upstream = accountSeats else {
            Issue.record("expected account-seat prose → upstream, got \(accountSeats)")
            return
        }
        let unavailableForFree = BaseAPIService.mapStreamError(
            type: nil,
            message: "This model is unavailable for free"
        )
        guard case .upstream = unavailableForFree else {
            Issue.record("expected unavailable for free → upstream, got \(unavailableForFree)")
            return
        }
    }

    @Test("mapStreamError: quota exhaustion beats ResourceExhausted / overload")
    func mapStreamErrorPrefersQuotaOverOverload() {
        let error = BaseAPIService.mapStreamError(
            type: "RESOURCE_EXHAUSTED",
            message: "Resource has been exhausted (e.g. check quota)."
        )
        guard case .quotaExceeded = error else {
            Issue.record("expected .quotaExceeded, got \(error)")
            return
        }
        let mixed = BaseAPIService().mapHTTPError(
            statusCode: 429,
            data: Data(#"{"error":{"message":"ResourceExhausted: Worker local total request limit reached. Check quota."}}"#.utf8)
        )
        guard case .quotaExceeded = mixed else {
            Issue.record("expected mixed quota+overload 429 → quotaExceeded, got \(mixed)")
            return
        }
    }

    @Test("mapHTTPError: 401/403 with overload wording stay auth failures")
    func mapHTTPErrorKeepsAuthFailuresAheadOfOverload() {
        let service = BaseAPIService()
        let body = #"{"error":{"message":"Upstream error from Nvidia: Service temporarily overloaded"}}"#
        guard case .invalidAPIKey = service.mapHTTPError(statusCode: 401, data: Data(body.utf8)) else {
            Issue.record("expected 401 + overload wording → invalidAPIKey")
            return
        }
        guard case .invalidAPIKey = service.mapHTTPError(statusCode: 403, data: Data(body.utf8)) else {
            Issue.record("expected 403 + overload wording → invalidAPIKey")
            return
        }
    }

    @Test("mapOpenAICompatibleStreamError: production Nvidia overloaded JSON → rateLimited")
    func mapOpenAICompatibleStreamErrorClassifiesNvidiaOverloaded() {
        let error = BaseAPIService.mapOpenAICompatibleStreamError(
            from: Data(#"{"error":{"message":"Upstream error from Nvidia: Service temporarily overloaded"}}"#.utf8)
        )
        guard case .rateLimited = error else {
            Issue.record("expected .rateLimited, got \(String(describing: error))")
            return
        }
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
