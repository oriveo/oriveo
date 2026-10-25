import Foundation
import Testing
@testable import Oriveo

/// Pure-logic contract of the Grok subscription sign-in.
///
/// Nothing here touches the network: delivered-config parsing, the host allowlist, the version gate, upstream error-code
/// translation and refresh timing are all offline decisions. They are also the parts most likely to be silently wrong while
/// showing up on a real device only as a vague error message.
/// Verifying the real chain (whether an endpoint is reachable, whether upstream accepts a parameter) is live evidence and is
/// not pretended to be covered by unit tests.
@Suite("Grok subscription · auth contract", .sharedProcessState)
struct GrokSubscriptionAuthTests {

    // MARK: - Fixtures

    /// Same shape as the delivered provider config; each case changes only the one field it tests.
    private func makeRaw(
        enabled: Bool? = true,
        flow: String? = "oauth_device_code",
        clientId: String? = "b1a00492-073a-47ea-816f-4c329264a828",
        scopes: String? = "openid profile email offline_access grok-cli:access api:access",
        deviceAuthorizationEndpoint: String? = "https://auth.x.ai/oauth2/device/code",
        tokenEndpoint: String? = "https://auth.x.ai/oauth2/token",
        revocationEndpoint: String? = "https://auth.x.ai/oauth2/revoke",
        trustedAuthHosts: [String]? = ["auth.x.ai"],
        trustedVerificationHosts: [String]? = ["accounts.x.ai", "x.ai"],
        resourceBaseURL: String? = "https://cli-chat-proxy.grok.com/v1",
        requiredHeaders: [String: String]? = ["x-grok-client-version": "1.0.4"],
        modelsPath: String? = "/models",
        chatPath: String? = "/chat/completions",
        responsesPath: String? = nil,
        apiBackend: String? = nil,
        pollIntervalSeconds: Int? = 5,
        pollTimeoutSeconds: Int? = 1800,
        minAppVersion: [String: String]? = ["ios": "1.2.7"],
        disabledNotice: String? = nil
    ) -> MetadataClient.RawGrokSubscriptionAuth {
        MetadataClient.RawGrokSubscriptionAuth(
            enabled: enabled,
            flow: flow,
            clientId: clientId,
            scopes: scopes,
            deviceAuthorizationEndpoint: deviceAuthorizationEndpoint,
            // Codex-only field: the Grok device flow does not use it, so it is always nil.
            deviceTokenEndpoint: nil,
            tokenEndpoint: tokenEndpoint,
            revocationEndpoint: revocationEndpoint,
            verificationURL: nil,
            redirectURI: nil,
            trustedAuthHosts: trustedAuthHosts,
            trustedVerificationHosts: trustedVerificationHosts,
            resourceBaseURL: resourceBaseURL,
            requiredHeaders: requiredHeaders,
            modelsPath: modelsPath,
            chatPath: chatPath,
            responsesPath: responsesPath,
            apiBackend: apiBackend,
            pollIntervalSeconds: pollIntervalSeconds,
            pollTimeoutSeconds: pollTimeoutSeconds,
            minAppVersion: minAppVersion,
            disabledNotice: disabledNotice
        )
    }

    private func resolvedConfig(
        _ raw: MetadataClient.RawGrokSubscriptionAuth,
        appVersion: String = "1.2.7"
    ) -> GrokSubscriptionAuthConfig? {
        guard case let .available(config) = GrokSubscriptionAuthResolver.resolve(
            raw: raw, appVersion: appVersion
        ) else { return nil }
        return config
    }

    // MARK: - Production payload end to end

    /// The grok entry the metadata endpoint actually delivers, captured from production.
    ///
    /// The cases above all start from a Raw value they build themselves, which only proves "given the right values the
    /// decision is right". They cannot prove that the JSON the backend really delivers decodes into a usable config. Without
    /// this link, any mismatch in the decoding layer leaves every unit test green while the entry never appears on a device.
    @Test("the provider config delivered in production decodes all the way to a usable config")
    func decodesProductionPayload() throws {
        let json = """
        {
          "kind": "grok",
          "displayName": "Grok",
          "defaultBaseURL": "https://api.x.ai/v1",
          "apiProtocol": "openai_compatible",
          "category": "direct",
          "supportsAutoSync": true,
          "sortOrder": 13,
          "protocolFeatures": {
            "authMethod": "bearer",
            "subscriptionAuth": {
              "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
              "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
              "disabledNotice": null,
              "enabled": true,
              "flow": "oauth_device_code",
              "minAppVersion": {"ios": "1.2.6"},
              "modelsPath": "/models",
              "chatPath": "/chat/completions",
              "pollIntervalSeconds": 5,
              "pollTimeoutSeconds": 1800,
              "requiredHeaders": {
                "x-grok-client-identifier": "oriveo",
                "x-grok-client-surface": "grok-build",
                "x-grok-client-version": "1.0.4",
                "x-xai-token-auth": "xai-grok-cli"
              },
              "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
              "revocationEndpoint": "https://auth.x.ai/oauth2/revoke",
              "scopes": "openid profile email offline_access grok-cli:access api:access",
              "tokenEndpoint": "https://auth.x.ai/oauth2/token",
              "trustedAuthHosts": ["auth.x.ai"],
              "trustedVerificationHosts": ["accounts.x.ai", "x.ai"]
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            MetadataClient.PublicProviderConfig.self, from: Data(json.utf8)
        )
        let raw = try #require(
            decoded.protocolFeatures?.subscriptionAuth,
            "protocolFeatures.subscriptionAuth did not decode: the decoding layer is broken"
        )

        // The version gate is judged against the development build that introduced the feature; writing the next release number would lock the development build itself out.
        let availability = GrokSubscriptionAuthResolver.resolve(raw: raw, appVersion: "1.2.6")
        guard case let .available(config) = availability else {
            Issue.record("The production payload was not judged available, got \(availability)")
            return
        }
        #expect(config.resourceBaseURL.absoluteString == "https://cli-chat-proxy.grok.com/v1")
        #expect(config.modelsURL?.absoluteString == "https://cli-chat-proxy.grok.com/v1/models")
        #expect(config.requiredHeaders["x-grok-client-version"] == "1.0.4")
    }

    /// The grok entry inside a full metadata response must decode too; decoding as a single entry does not mean it decodes inside an array.
    @Test("the subscription config can also be read from a full providerConfigs array")
    func decodesFromProviderConfigsArray() throws {
        let json = """
        [
          {"kind": "openAI", "displayName": "OpenAI", "defaultBaseURL": "https://api.openai.com/v1"},
          {
            "kind": "grok",
            "displayName": "Grok",
            "defaultBaseURL": "https://api.x.ai/v1",
            "protocolFeatures": {
              "authMethod": "bearer",
              "subscriptionAuth": {
                "enabled": true,
                "flow": "oauth_device_code",
                "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
                "scopes": "openid profile email",
                "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                "trustedAuthHosts": ["auth.x.ai"],
                "trustedVerificationHosts": ["accounts.x.ai"],
                "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
                "minAppVersion": {"ios": "1.2.6"}
              }
            }
          }
        ]
        """
        let configs = try JSONDecoder().decode(
            [MetadataClient.PublicProviderConfig].self, from: Data(json.utf8)
        )
        let grok = try #require(configs.first { $0.kind == "grok" })
        #expect(grok.protocolFeatures?.subscriptionAuth != nil)
        // An entry without protocolFeatures must not fail to decode, or the whole directory would be dropped with it.
        #expect(configs.first { $0.kind == "openAI" }?.protocolFeatures == nil)
    }

    // MARK: - Three availability states

    @Test("when the backend delivers nothing the entry does not appear at all, instead of degrading into a button that goes nowhere")
    func unavailableWhenNotServed() {
        #expect(GrokSubscriptionAuthResolver.resolve(raw: nil) == .unavailable)
    }

    @Test("a closed kill switch is disabled rather than unavailable: connected users need to see the reason")
    func killSwitchIsDistinctFromMissing() {
        let result = GrokSubscriptionAuthResolver.resolve(
            raw: makeRaw(enabled: false, disabledNotice: "Unavailable on the xAI side for now"),
            appVersion: "1.2.7"
        )
        #expect(result == .disabled(notice: "Unavailable on the xAI side for now"))
    }

    @Test("an unrecognized flow steps aside instead of forcing device-code logic onto a new authorization method")
    func unknownFlowIsUnavailable() {
        let result = GrokSubscriptionAuthResolver.resolve(
            raw: makeRaw(flow: "pkce_authorization_code"), appVersion: "1.2.7"
        )
        #expect(result == .unavailable)
    }

    @Test("a complete config resolves every field")
    func resolvesFullConfig() throws {
        let config = try #require(resolvedConfig(makeRaw()))
        #expect(config.clientID == "b1a00492-073a-47ea-816f-4c329264a828")
        #expect(config.tokenEndpoint.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(config.resourceBaseURL.absoluteString == "https://cli-chat-proxy.grok.com/v1")
        #expect(config.requiredHeaders["x-grok-client-version"] == "1.0.4")
        #expect(config.pollIntervalSeconds == 5)
        #expect(config.pollTimeoutSeconds == 1800)
    }

    // MARK: - A missing required field always degrades

    @Test(
        "any missing required field degrades the whole config to unavailable instead of assembling a partial config that strands the user halfway",
        arguments: [
            "clientId", "scopes", "resourceBaseURL",
            "deviceAuthorizationEndpoint", "tokenEndpoint",
            "trustedAuthHosts", "trustedVerificationHosts",
        ]
    )
    func missingRequiredFieldDegrades(field: String) {
        let raw: MetadataClient.RawGrokSubscriptionAuth
        switch field {
        case "clientId": raw = makeRaw(clientId: nil)
        case "scopes": raw = makeRaw(scopes: nil)
        case "resourceBaseURL": raw = makeRaw(resourceBaseURL: nil)
        case "deviceAuthorizationEndpoint": raw = makeRaw(deviceAuthorizationEndpoint: nil)
        case "tokenEndpoint": raw = makeRaw(tokenEndpoint: nil)
        case "trustedAuthHosts": raw = makeRaw(trustedAuthHosts: [])
        default: raw = makeRaw(trustedVerificationHosts: [])
        }
        #expect(GrokSubscriptionAuthResolver.resolve(raw: raw, appVersion: "1.2.7") == .unavailable)
    }

    @Test("the revocation endpoint is optional: missing an optional endpoint must not make the whole flow unavailable")
    func revocationEndpointIsOptional() throws {
        let config = try #require(resolvedConfig(makeRaw(revocationEndpoint: nil)))
        #expect(config.revocationEndpoint == nil)
    }

    // MARK: - Endpoint validation (the defense against a tampered config)

    @Test("an endpoint host outside the trusted list is always rejected: this is the gate against phishing redirects")
    func rejectsEndpointOutsideTrustedHosts() {
        let raw = makeRaw(tokenEndpoint: "https://evil.example.com/oauth2/token")
        #expect(GrokSubscriptionAuthResolver.resolve(raw: raw, appVersion: "1.2.7") == .unavailable)
    }

    @Test("a non-https endpoint is rejected")
    func rejectsPlainHTTPEndpoint() {
        let raw = makeRaw(tokenEndpoint: "http://auth.x.ai/oauth2/token")
        #expect(GrokSubscriptionAuthResolver.resolve(raw: raw, appVersion: "1.2.7") == .unavailable)
    }

    @Test("a URL carrying credentials or a changed port is always rejected")
    func rejectsURLWithCredentialsOrPort() {
        #expect(GrokSubscriptionAuthResolver.resolve(
            raw: makeRaw(tokenEndpoint: "https://user:pass@auth.x.ai/oauth2/token"),
            appVersion: "1.2.7"
        ) == .unavailable)
        #expect(GrokSubscriptionAuthResolver.resolve(
            raw: makeRaw(tokenEndpoint: "https://auth.x.ai:8443/oauth2/token"),
            appVersion: "1.2.7"
        ) == .unavailable)
    }

    @Test("the authorization page URL is judged by the verification allowlist: subdomains pass, other domains are rejected")
    func verificationURLWhitelist() throws {
        let config = try #require(resolvedConfig(makeRaw()))
        #expect(config.allowsVerificationURL(URL(string: "https://accounts.x.ai/oauth2/device?user_code=AAAA-BBBB")!))
        #expect(config.allowsVerificationURL(URL(string: "https://login.x.ai/device")!))
        #expect(!config.allowsVerificationURL(URL(string: "https://accounts.x.ai.evil.com/device")!))
        #expect(!config.allowsVerificationURL(URL(string: "http://accounts.x.ai/device")!))
        #expect(!config.allowsVerificationURL(URL(string: "https://evil.com/device")!))
    }

    @Test("the model catalog URL is joined from the delivered path")
    func modelsURLJoinsPath() throws {
        let config = try #require(resolvedConfig(makeRaw()))
        #expect(config.modelsURL?.absoluteString == "https://cli-chat-proxy.grok.com/v1/models")
    }

    @Test("a missing modelsPath falls back to /models instead of breaking the whole catalog fetch")
    func modelsPathFallsBack() throws {
        let config = try #require(resolvedConfig(makeRaw(modelsPath: nil)))
        #expect(config.modelsPath == "/models")
    }

    /// Regression sentinel for the 404 on the first message on a real device.
    ///
    /// The first version only swapped the baseURL for the subscription's CLI proxy, while the chat path still came from
    /// the provider transport (whose baseUrl is `https://api.x.ai` and whose path is `/v1/chat/completions`). The two sides
    /// disagree on who owns `/v1`, producing `.../v1/v1/chat/completions`, and upstream answered only 404. The catalog fetch
    /// escaped by luck because it has its own modelsPath, so the problem stayed hidden until a message was sent.
    @Test("the chat URL is joined from the delivered path without a duplicated /v1 segment")
    func chatURLHasNoDuplicatedVersionSegment() throws {
        let config = try #require(resolvedConfig(makeRaw()))
        let chat = try #require(config.chatURL?.absoluteString)
        #expect(chat == "https://cli-chat-proxy.grok.com/v1/chat/completions")
        #expect(!chat.contains("/v1/v1"))

        // The catalog URL follows the same rule from the same source, so pin it as well.
        let models = try #require(config.modelsURL?.absoluteString)
        #expect(models == "https://cli-chat-proxy.grok.com/v1/models")
        #expect(!models.contains("/v1/v1"))
    }

    @Test("a missing chatPath falls back to /chat/completions")
    func chatPathFallsBack() throws {
        let config = try #require(resolvedConfig(makeRaw(chatPath: nil)))
        #expect(config.chatPath == "/chat/completions")
        #expect(config.chatURL?.absoluteString == "https://cli-chat-proxy.grok.com/v1/chat/completions")
    }

    @Test("a missing responsesPath falls back to /responses and apiBackend is copied as delivered; both may be absent when the server does not deliver them")
    func responsesPathAndAPIBackendFallBack() throws {
        let legacy = try #require(resolvedConfig(makeRaw()))
        #expect(legacy.responsesPath == "/responses")
        #expect(legacy.responsesURL?.absoluteString == "https://cli-chat-proxy.grok.com/v1/responses")
        #expect(legacy.apiBackend == nil)
        #expect(GrokSubscriptionAuthConfig.transportKind(apiBackend: legacy.apiBackend) == nil)

        let seeded = try #require(resolvedConfig(makeRaw(responsesPath: "/responses", apiBackend: "responses")))
        #expect(seeded.apiBackend == "responses")
        #expect(GrokSubscriptionAuthConfig.transportKind(apiBackend: seeded.apiBackend) == .openaiResponses)
        #expect(GrokSubscriptionAuthConfig.transportKind(apiBackend: "chat") == .openaiChat)
        // An unknown value does not guess a protocol and is left to the next fallback level.
        #expect(GrokSubscriptionAuthConfig.transportKind(apiBackend: "grpc") == nil)
        #expect(!(seeded.responsesURL?.absoluteString.contains("/v1/v1") ?? true))
    }

    // MARK: - Version gate

    @Test("a client below minAppVersion steps aside as disabled rather than silently unavailable")
    func belowMinimumAppVersionIsDisabled() {
        let result = GrokSubscriptionAuthResolver.resolve(
            raw: makeRaw(minAppVersion: ["ios": "1.3.0"], disabledNotice: "Please update"),
            appVersion: "1.2.7"
        )
        #expect(result == .disabled(notice: "Please update"))
    }

    @Test("a client at or above minAppVersion passes")
    func atOrAboveMinimumIsAvailable() {
        #expect(resolvedConfig(makeRaw(), appVersion: "1.2.7") != nil)
        #expect(resolvedConfig(makeRaw(), appVersion: "1.3.0") != nil)
    }

    @Test("versions compare segment by segment and must not degrade into a string comparison")
    func versionComparisonIsNumeric() {
        // A string comparison would judge 1.2.10 < 1.2.9, so the newer version would be blocked by the version gate.
        #expect(GrokSubscriptionAuthResolver.compareVersions("1.2.10", "1.2.9") == 1)
        #expect(GrokSubscriptionAuthResolver.compareVersions("1.2.7", "1.2.7") == 0)
        #expect(GrokSubscriptionAuthResolver.compareVersions("1.2", "1.2.0") == 0)
        #expect(GrokSubscriptionAuthResolver.compareVersions("0.9.9", "1.0.0") == -1)
        #expect(GrokSubscriptionAuthResolver.compareVersions("1.2.7-beta", "1.2.7") == 0)
    }

    // MARK: - Upstream failure translation

    @Test("device-code intermediate states are expressed as 400 plus an error code; looking only at the status code would kill the flow")
    func pendingStatesComeFromErrorCode() {
        #expect(mapped(400, #"{"error":"authorization_pending"}"#) == .authorizationPending)
        #expect(mapped(400, #"{"error":"slow_down"}"#) == .slowDown)
        #expect(mapped(400, #"{"error":"expired_token"}"#) == .codeExpired)
        #expect(mapped(400, #"{"error":"access_denied"}"#) == .accessDenied)
    }

    @Test("the four hard failures each map to a distinct meaning and must not collapse into one generic error")
    func hardFailuresAreDistinct() {
        #expect(mapped(426, "") == .clientVersionRejected)
        #expect(mapped(403, "") == .subscriptionNotEligible)
        #expect(mapped(401, "") == .unauthorized)
        #expect(mapped(429, "") == .quotaExhausted)
    }

    @Test("only 426 forces a config refresh: it is the only early signal that xAI changed something again")
    func onlyClientVersionRejectionRefreshesConfig() {
        #expect(GrokSubscriptionError.clientVersionRejected.requiresConfigRefresh)
        #expect(!GrokSubscriptionError.subscriptionNotEligible.requiresConfigRefresh)
        #expect(!GrokSubscriptionError.unauthorized.requiresConfigRefresh)
        #expect(!GrokSubscriptionError.quotaExhausted.requiresConfigRefresh)
    }

    @Test("dead-end failures get no retry button so users do not tap in vain")
    func retryAffordanceMatchesRecoverability() {
        #expect(GrokSubscriptionError.codeExpired.allowsRetry)
        #expect(GrokSubscriptionError.accessDenied.allowsRetry)
        #expect(GrokSubscriptionError.transport("offline").allowsRetry)
        #expect(!GrokSubscriptionError.subscriptionNotEligible.allowsRetry)
        #expect(!GrokSubscriptionError.quotaExhausted.allowsRetry)
        #expect(!GrokSubscriptionError.clientVersionRejected.allowsRetry)
    }

    @Test("the messages of the four failures all differ: saying the same sentence would steer users to the wrong remedy")
    func userFacingMessagesAreDistinct() {
        let messages = [
            GrokSubscriptionError.clientVersionRejected.userFacingMessage,
            GrokSubscriptionError.subscriptionNotEligible.userFacingMessage,
            GrokSubscriptionError.unauthorized.userFacingMessage,
            GrokSubscriptionError.quotaExhausted.userFacingMessage,
        ]
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    private func mapped(_ status: Int, _ body: String) -> GrokSubscriptionError {
        GrokSubscriptionOAuthClient.mapFailure(status: status, data: Data(body.utf8))
    }

    // MARK: - Refresh timing

    @Test("refresh proactively 5 minutes before expiry to avoid random 401s where the token was valid at check time but expired by the time the request arrived")
    func refreshesAheadOfExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = GrokSubscriptionTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(240), // Expires in 4 minutes
            scopes: nil,
            obtainedAt: now
        )
        #expect(tokens.needsRefresh(now: now))
    }

    @Test("no refresh while the token is still fresh")
    func doesNotRefreshWhenFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = GrokSubscriptionTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: now.addingTimeInterval(3600),
            scopes: nil,
            obtainedAt: now
        )
        #expect(!tokens.needsRefresh(now: now))
    }

    @Test("without an upstream expiry time there is no proactive refresh, instead of refreshing on every request")
    func missingExpiryMeansNoProactiveRefresh() {
        let tokens = GrokSubscriptionTokens(
            accessToken: "a", refreshToken: "r", expiresAt: nil, scopes: nil, obtainedAt: Date()
        )
        #expect(!tokens.needsRefresh())
    }
}

/// Persistence compatibility after `authMode` was added to Provider.
@Suite("Grok subscription · provider persistence", .sharedProcessState)
struct GrokSubscriptionProviderPersistenceTests {

    @Test("legacy data without an authMode key decodes as apiKey, leaving existing provider behavior unchanged")
    func legacyProviderDecodesAsAPIKey() throws {
        // Removing authMode from a real encoding result is more trustworthy than hand-writing JSON: a hand-written
        // one has to guess the encoded shape of nested types such as status, and a wrong guess tests malformed data instead of legacy data.
        var provider = Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "xai-...abcd"
        )
        provider.authMode = .subscription

        let encoded = try JSONEncoder().encode(provider)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["authMode"] != nil, "first confirm the key is really written, otherwise the removal below is a no-op")
        object.removeValue(forKey: "authMode")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Provider.self, from: legacy)
        #expect(decoded.authMode == .apiKey)
    }

    @Test("authMode takes part in the local persistence round trip")
    func authModeSurvivesRoundTrip() throws {
        var provider = Provider(
            id: UUID(),
            kind: .grok,
            status: .connected,
            models: [],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "token",
            apiKeyPreview: ""
        )
        provider.authMode = .subscription

        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded.authMode == .subscription)
        // Plaintext credentials are never written into the Provider JSON: subscription tokens follow the same policy as apiKey.
        #expect(decoded.apiKey.isEmpty)
    }

    @Test("the subscription catalog follows the capabilities declared upstream, degrades when upstream says nothing, and is not hard-coded on the client")
    func modelDescriptorsFollowUpstreamDeclaredCapabilities() throws {
        // Field names come from the catalog cache the grok CLI writes to disk (its origin is cli-chat-proxy.grok.com/v1/models,
        // and its grok_version 1.0.4 matches the client version we deliver). Architecture decision:
        // capabilities must follow the API, otherwise every new model needs someone to patch code.
        let data = Data("""
        {"data":[
          {"id":"grok-4.6","name":"Grok 4.6","supports_backend_search":true,
           "api_backend":"responses",
           "supports_reasoning_effort":true,"context_window":500000,
           "reasoning_efforts":[{"value":"xhigh","default":false},{"value":"high","default":true},
                                {"value":"low","default":false}],
           "hidden":false,"supported_in_api":true},
          {"id":"grok-legacy","supports_backend_search":false,"supports_reasoning_effort":false,
           "hidden":false,"supported_in_api":true},
          {"id":"grok-internal","hidden":true},
          {"id":"grok-plain"}
        ]}
        """.utf8)

        let descriptors = try GrokSubscriptionOAuthClient.parseModelDescriptors(from: data)
        // Hidden entries are filtered out; entries that declare none of these fields (grok-plain) must be kept. The loose
        // filter is deliberate: emptying the catalog whenever a field is missing is a far worse regression than lacking a capability.
        #expect(descriptors.map(\.id) == ["grok-4.6", "grok-legacy", "grok-plain"])

        let flagship = try #require(descriptors.first)
        #expect(flagship.displayName == "Grok 4.6")
        #expect(flagship.supportsWebSearch)
        #expect(flagship.supportsReasoning)
        #expect(flagship.reasoningEfforts == ["xhigh", "high", "low"])
        #expect(flagship.defaultReasoningEffort == "high")
        #expect(flagship.contextWindow == 500000)
        // `api_backend` is the model-level source of truth for this chain's outbound protocol and is copied as is; when it is not declared it is nil (left to the delivered config as the fallback).
        #expect(flagship.apiBackend == "responses")
        #expect(descriptors[1].apiBackend == nil)

        // Upstream explicitly says unsupported -> unsupported; upstream says nothing -> also unsupported (never guess a capability from the id).
        #expect(!descriptors[1].supportsWebSearch)
        #expect(!descriptors[1].supportsReasoning)
        #expect(!descriptors[2].supportsWebSearch)
        #expect(!descriptors[2].supportsReasoning)
    }
}
