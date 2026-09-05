//  ProviderKeyValidatorTests.swift
//  OriveoTests

import Foundation
import Testing
@testable import Oriveo

@Suite("Provider Key Validator Tests")
struct ProviderKeyValidatorTests {

    private typealias Signal = MetadataClient.ProviderValidation.InvalidKeySignal

    private func judge(_ status: Int, _ body: String, _ signals: [Signal]) -> ProviderKeyValidator.Result {
        ProviderKeyValidator.judge(statusCode: status, body: Data(body.utf8), signals: signals)
    }


    @Test("Two Hundred Is Valid")
    func twoHundredIsValid() {
        #expect(judge(200, #"{"data":[]}"#, [Signal(status: 401, bodyIncludes: nil)]).isValid)
        #expect(judge(204, "", [Signal(status: 204, bodyIncludes: nil)]).isValid)
    }

    @Test("Status Only Signal Matches Invalid")
    func statusOnlySignalMatchesInvalid() {
        let result = judge(401, #"{"error":"unauthorized"}"#, [Signal(status: 401, bodyIncludes: nil)])
        #expect(result == .invalid(httpStatus: 401))
    }

    @Test("Unmatched Status Is Unverified")
    func unmatchedStatusIsUnverified() {
        let signals = [Signal(status: 401, bodyIncludes: nil)]
        #expect(judge(404, "not found", signals).isUnverified)
        #expect(judge(429, "rate limited", signals).isUnverified)
        #expect(judge(500, "boom", signals).isUnverified)
        #expect(judge(403, "forbidden", signals).isUnverified)
    }


    @Test("Body Includes Is And")
    func bodyIncludesIsAnd() {
        let signals = [Signal(status: 400, bodyIncludes: ["API key not valid", "INVALID_ARGUMENT"])]
        #expect(judge(400, #"{"error":{"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#, signals)
            == .invalid(httpStatus: 400))
        #expect(judge(400, #"{"error":{"message":"API key not valid"}}"#, signals).isUnverified)
        #expect(judge(400, "bad request", signals).isUnverified)
    }

    @Test("Body Includes Case Sensitive")
    func bodyIncludesCaseSensitive() {
        let signals = [Signal(status: 400, bodyIncludes: ["Incorrect API key"])]
        #expect(judge(400, "Incorrect API key provided", signals) == .invalid(httpStatus: 400))
        #expect(judge(400, "incorrect api key provided", signals).isUnverified)
    }

    @Test("Empty Body Includes Equals Nil")
    func emptyBodyIncludesEqualsNil() {
        let signals = [Signal(status: 401, bodyIncludes: [])]
        #expect(judge(401, "anything", signals) == .invalid(httpStatus: 401))
    }


    @Test("Bearer401 Is Invalid")
    func bearer401IsInvalid() {
        let signals = [Signal(status: 401, bodyIncludes: nil)]
        #expect(judge(401, #"{"error":{"code":"invalid_api_key"}}"#, signals) == .invalid(httpStatus: 401))
    }

    @Test("Grok400 And401")
    func grok400And401() {
        let signals = [
            Signal(status: 400, bodyIncludes: ["Incorrect API key", "invalid argument"]),
            Signal(status: 401, bodyIncludes: nil),
        ]
        #expect(judge(400, "Incorrect API key provided as invalid argument", signals)
            == .invalid(httpStatus: 400))
        #expect(judge(401, "unauthorized", signals) == .invalid(httpStatus: 401))
        #expect(judge(400, "Incorrect API key provided", signals).isUnverified)
    }

    @Test("Gemini:400 API key not valid → INVALID;403 → INVALID")
    func gemini400And403() {
        let signals = [
            Signal(status: 400, bodyIncludes: ["API key not valid", "INVALID_ARGUMENT"]),
            Signal(status: 403, bodyIncludes: nil),
        ]
        #expect(judge(400, #"{"error":{"message":"API key not valid. INVALID_ARGUMENT"}}"#, signals)
            == .invalid(httpStatus: 400))
        #expect(judge(403, "PERMISSION_DENIED", signals) == .invalid(httpStatus: 403))
        #expect(judge(200, #"{"models":[]}"#, signals).isValid)
    }

    @Test("Open Router Key Probe401")
    func openRouterKeyProbe401() {
        let signals = [Signal(status: 401, bodyIncludes: nil)]
        #expect(judge(401, #"{"error":{"message":"No auth credentials found"}}"#, signals)
            == .invalid(httpStatus: 401))
        #expect(judge(200, #"{"data":{"limit":null,"usage":0}}"#, signals).isValid)
    }

    @Test("Mini Max Http Only")
    func miniMaxHttpOnly() {
        let signals = [Signal(status: 401, bodyIncludes: nil)]
        let body = #"{"base_resp":{"status_code":2049,"status_msg":"invalid api key"}}"#
        #expect(judge(401, body, signals) == .invalid(httpStatus: 401))
        #expect(judge(200, #"{"base_resp":{"status_code":1004}}"#, signals).isValid)
    }


    @Test("Query Key Appends Key")
    func queryKeyAppendsKey() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            probePath: "/v1beta/models",
            authMode: .queryKey,
            apiKey: "AIza-secret"
        )
        #expect(url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?key=AIza-secret")
    }

    @Test("Anthropic Version Dedup")
    func anthropicVersionDedup() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://api.anthropic.com/v1",
            probePath: "/v1/models",
            authMode: .xApiKey,
            apiKey: "sk-ant-xxx"
        )
        #expect(url?.absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("Bare Host With Versioned Probe")
    func bareHostWithVersionedProbe() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://api.anthropic.com",
            probePath: "/v1/models",
            authMode: .xApiKey,
            apiKey: "sk-ant-xxx"
        )
        #expect(url?.absoluteString == "https://api.anthropic.com/v1/models")
    }

    @Test("Open AINo False Dedup")
    func openAINoFalseDedup() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://api.openai.com/v1",
            probePath: "/models",
            authMode: .bearer,
            apiKey: "sk-xxx"
        )
        #expect(url?.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test("Open Router Key URL")
    func openRouterKeyURL() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://openrouter.ai/api/v1",
            probePath: "/key",
            authMode: .bearer,
            apiKey: "sk-or-xxx"
        )
        #expect(url?.absoluteString == "https://openrouter.ai/api/v1/key")
    }

    @Test("Slash Normalization")
    func slashNormalization() {
        let url = ProviderKeyValidator.buildProbeURL(
            baseURL: "https://api.openai.com/v1/",
            probePath: "/models",
            authMode: .bearer,
            apiKey: "sk-xxx"
        )
        #expect(url?.absoluteString == "https://api.openai.com/v1/models")
    }


    @Test("authMode bearer → Authorization Bearer")
    func bearerHeader() {
        var request = URLRequest(url: URL(string: "https://x/models")!)
        ProviderKeyValidator.applyAuthHeaders(to: &request, authMode: .bearer, headerProfile: .none, apiKey: "k1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k1")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("authMode x_api_key + anthropic_v2023_06_01 → x-api-key + anthropic-version")
    func xApiKeyAnthropicHeaders() {
        var request = URLRequest(url: URL(string: "https://x/models")!)
        ProviderKeyValidator.applyAuthHeaders(
            to: &request,
            authMode: .xApiKey,
            headerProfile: .anthropicV2023,
            apiKey: "k2"
        )
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k2")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Open Router Headers")
    func openRouterHeaders() {
        var request = URLRequest(url: URL(string: "https://x/key")!)
        ProviderKeyValidator.applyAuthHeaders(
            to: &request,
            authMode: .bearer,
            headerProfile: .openRouter,
            apiKey: "k3"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k3")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://github.com/oriveo/oriveo")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Oriveo")
    }

    @Test("Query Key No Auth Header")
    func queryKeyNoAuthHeader() {
        var request = URLRequest(url: URL(string: "https://x/models?key=k4")!)
        ProviderKeyValidator.applyAuthHeaders(to: &request, authMode: .queryKey, headerProfile: .none, apiKey: "k4")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }


    @Test("Unknown Enum Raw Values")
    func unknownEnumRawValues() {
        #expect(ProviderKeyValidator.AuthMode(rawValue: "magic") == nil)
        #expect(ProviderKeyValidator.AuthMode(rawValue: nil) == nil)
        #expect(ProviderKeyValidator.AuthMode(rawValue: "  ") == nil)
        #expect(ProviderKeyValidator.HeaderProfile(rawValue: "magic") == nil)
        #expect(ProviderKeyValidator.AuthMode(rawValue: "bearer") == .bearer)
        #expect(ProviderKeyValidator.AuthMode(rawValue: "x_api_key") == .xApiKey)
        #expect(ProviderKeyValidator.AuthMode(rawValue: "query_key") == .queryKey)
        #expect(ProviderKeyValidator.HeaderProfile(rawValue: "anthropic_v2023_06_01") == .anthropicV2023)
        #expect(ProviderKeyValidator.HeaderProfile(rawValue: "openrouter") == .openRouter)
    }
}
