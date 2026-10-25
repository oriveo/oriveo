import Foundation
import Testing
@testable import Oriveo

/// Regression for the delivered contract and decoding semantics of Codex (ChatGPT subscription sign-in).
///
/// Same as Grok: the client uses whatever it is given, so these tests decode **the JSON the server actually delivers**
/// all the way to a usable config instead of hand-building fields. A missing key or a misspelled host must turn red locally.
@Suite("Codex subscription · auth contract", .sharedProcessState)
struct OpenAISubscriptionAuthTests {
    /// Verbatim the same as the delivered openAI protocolFeatures.subscriptionAuth.
    /// Whenever the delivered value changes, this must change with it: it is the local copy of what production will deliver.
    static let seedSubscriptionJSON = """
    {
      "enabled": true,
      "flow": "codex_device_code",
      "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
      "deviceAuthorizationEndpoint": "https://auth.openai.com/api/accounts/deviceauth/usercode",
      "deviceTokenEndpoint": "https://auth.openai.com/api/accounts/deviceauth/token",
      "tokenEndpoint": "https://auth.openai.com/oauth/token",
      "verificationURL": "https://auth.openai.com/codex/device",
      "redirectURI": "https://auth.openai.com/deviceauth/callback",
      "trustedAuthHosts": ["auth.openai.com"],
      "trustedVerificationHosts": ["auth.openai.com"],
      "resourceBaseURL": "https://chatgpt.com/backend-api/codex",
      "requiredHeaders": {
        "originator": "oriveo",
        "version": "0.148.0",
        "OpenAI-Beta": "responses=experimental"
      },
      "chatPath": "/responses",
      "modelsPath": "/models",
      "pollIntervalSeconds": 5,
      "pollTimeoutSeconds": 900,
      "minAppVersion": {"ios": "1.2.6"},
      "disabledNotice": null
    }
    """

    private static func raw(_ json: String) -> MetadataClient.RawGrokSubscriptionAuth {
        try! JSONDecoder().decode(
            MetadataClient.RawGrokSubscriptionAuth.self,
            from: Data(json.utf8)
        )
    }

    private static func resolvedConfig(_ json: String = seedSubscriptionJSON, appVersion: String = "1.2.6") -> OpenAISubscriptionAuthConfig {
        guard case let .available(config) = OpenAISubscriptionAuthResolver.resolve(raw: raw(json), appVersion: appVersion) else {
            Issue.record("expected .available")
            fatalError("expected .available")
        }
        return config
    }

    @Test("the delivered subscriptionAuth decodes all the way to a usable config")
    func seedResolvesToAvailable() {
        let config = Self.resolvedConfig()
        #expect(config.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(config.deviceAuthorizationEndpoint.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/usercode")
        #expect(config.deviceTokenEndpoint.absoluteString == "https://auth.openai.com/api/accounts/deviceauth/token")
        #expect(config.tokenEndpoint.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(config.verificationURL.absoluteString == "https://auth.openai.com/codex/device")
        #expect(config.redirectURI.absoluteString == "https://auth.openai.com/deviceauth/callback")
        #expect(config.requiredHeaders["originator"] == "oriveo")
        #expect(config.requiredHeaders["OpenAI-Beta"] == "responses=experimental")
    }

    @Test("responses/models URLs are joined from the delivered paths without a duplicated /codex or /v1 segment")
    func endpointsJoinCleanly() {
        let config = Self.resolvedConfig()
        // resourceBaseURL already contains /backend-api/codex; the paths only add /responses and /models and must not produce /codex/codex.
        #expect(config.responsesURL?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(config.modelsURL?.absoluteString == "https://chatgpt.com/backend-api/codex/models")
    }

    @Test("when the backend delivers nothing the entry does not appear at all, instead of degrading into a button that goes nowhere")
    func missingRawIsUnavailable() {
        #expect(OpenAISubscriptionAuthResolver.resolve(raw: nil) == .unavailable)
    }

    @Test("an unrecognized flow steps aside: an old client does not force device-code logic onto a new authorization method")
    func unknownFlowIsUnavailable() {
        let json = Self.seedSubscriptionJSON.replacingOccurrences(of: "codex_device_code", with: "some_future_flow")
        #expect(OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(json)) == .unavailable)
    }

    @Test("a closed kill switch is disabled rather than unavailable: connected users need to see the reason")
    func killSwitchIsDisabled() {
        let json = Self.seedSubscriptionJSON.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false")
        if case .disabled = OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(json)) {
        } else {
            Issue.record("expected .disabled")
        }
    }

    @Test("the resourceBaseURL host must be exactly chatgpt.com so it cannot be swapped for another domain")
    func resourceHostPinned() {
        let json = Self.seedSubscriptionJSON.replacingOccurrences(
            of: "https://chatgpt.com/backend-api/codex",
            with: "https://evil.example.com/backend-api/codex"
        )
        #expect(OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(json), appVersion: "1.2.6") == .unavailable)
    }

    @Test("an auth endpoint host outside the trusted list is always rejected: this is the gate against phishing redirects")
    func authEndpointHostRejected() {
        let json = Self.seedSubscriptionJSON.replacingOccurrences(
            of: "https://auth.openai.com/oauth/token",
            with: "https://auth.evil.com/oauth/token"
        )
        #expect(OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(json), appVersion: "1.2.6") == .unavailable)
    }

    @Test("a client below minAppVersion steps aside as disabled rather than silently unavailable")
    func belowMinVersionIsDisabled() {
        if case .disabled = OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(Self.seedSubscriptionJSON), appVersion: "1.2.5") {
        } else {
            Issue.record("expected .disabled for below-min version")
        }
    }

    @Test("a client at or above minAppVersion passes")
    func atOrAboveMinVersionAvailable() {
        for version in ["1.2.6", "1.2.10", "1.3.0"] {
            if case .available = OpenAISubscriptionAuthResolver.resolve(raw: Self.raw(Self.seedSubscriptionJSON), appVersion: version) {
            } else {
                Issue.record("expected .available for \(version)")
            }
        }
    }

    @Test("the four hard failures each map to a distinct meaning (outside the device-poll path)")
    func failureMapping() {
        let empty = Data("{}".utf8)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 401, data: empty) == .unauthorized)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 403, data: empty) == .subscriptionNotEligible)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 426, data: empty) == .clientVersionRejected)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 429, data: empty) == .quotaExhausted)
    }

    @Test("a quota error code takes precedence over the status code and maps to quotaExhausted")
    func quotaErrorCodeWins() {
        let body = Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 400, data: body) == .quotaExhausted)
    }

    @Test("usage_not_included means \"plan not eligible\" rather than \"quota exhausted\": the remedies are opposite")
    func usageNotIncludedIsPlanIneligibility() {
        // Failure semantics: 403 / usage_not_included = the account's plan does not support Codex (upgrade the
        // subscription or use an API key); 429 / usage_limit_reached = this period's quota is used up (wait for the next
        // period). Mapping the former to quotaExhausted as well once made users wait for a "quota" that never recovers on its own.
        let notIncluded = Data("{\"error\":{\"code\":\"usage_not_included\"}}".utf8)
        let limitReached = Data("{\"error\":{\"code\":\"usage_limit_reached\"}}".utf8)

        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 403, data: notIncluded) == .subscriptionNotEligible)
        // The error code takes precedence over the status code: when upstream sends usage_not_included with a 429 it is still a plan problem.
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 429, data: notIncluded) == .subscriptionNotEligible)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 429, data: limitReached) == .quotaExhausted)
        // They must be two different results: landing in the same case would point the user in the opposite direction.
        #expect(
            OpenAISubscriptionOAuthClient.mapFailure(status: 403, data: notIncluded)
                != OpenAISubscriptionOAuthClient.mapFailure(status: 429, data: limitReached)
        )
    }

    @Test("a refresh-invalidated error code means the user has to sign in again")
    func refreshInvalidatedMapsToUnauthorized() {
        let body = Data("{\"error\":\"refresh_token_invalidated\"}".utf8)
        #expect(OpenAISubscriptionOAuthClient.mapFailure(status: 401, data: body) == .unauthorized)
    }

    @Test("dead-end failures get no retry button, recoverable failures do")
    func retryGating() {
        #expect(OpenAISubscriptionError.codeExpired.allowsRetry)
        #expect(OpenAISubscriptionError.accessDenied.allowsRetry)
        #expect(!OpenAISubscriptionError.subscriptionNotEligible.allowsRetry)
        #expect(!OpenAISubscriptionError.unauthorized.allowsRetry)
        #expect(!OpenAISubscriptionError.quotaExhausted.allowsRetry)
    }

    @Test("only clientVersionRejected forces a config refresh")
    func onlyVersionRejectedForcesRefresh() {
        #expect(OpenAISubscriptionError.clientVersionRejected.requiresConfigRefresh)
        #expect(!OpenAISubscriptionError.unauthorized.requiresConfigRefresh)
        #expect(!OpenAISubscriptionError.quotaExhausted.requiresConfigRefresh)
    }

    @Test("the /models response is parsed by slug, filtering hidden entries and entries unsupported in the API")
    func modelsParsingFiltersAndOrders() throws {
        // The shape comes from a /models response captured from a real pro account (trimmed to the fields the decision needs).
        // Key regression: parse models[].slug (not data[].id); keep only visibility=list with supported_in_api=true;
        // the order is the upstream priority (the first is the default).
        let json = """
        {"models":[
          {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true},
          {"slug":"gpt-5.6-terra","visibility":"list","supported_in_api":true},
          {"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true},
          {"slug":"gpt-5.5","visibility":"list","supported_in_api":true},
          {"slug":"gpt-5.3-codex-spark","visibility":"list","supported_in_api":false},
          {"slug":"codex-auto-review","visibility":"hide","supported_in_api":true}
        ]}
        """
        let slugs = try OpenAISubscriptionOAuthClient.parseModelSlugs(from: Data(json.utf8))
        #expect(slugs == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
    }

    @Test("chatgpt_account_id sits under a namespaced claim, not at the top level of the JWT")
    func accountIDFromNamespacedClaim() {
        // During the token exchange the accountID is decoded from the id_token and stored with the credential; this is the
        // original source of the accountID. Note it is only a fallback for the catalog fetch: on that path the accountID is
        // passed in by the caller (registration uses tokens.accountID, resync uses the Keychain value), because the id_token
        // carries this claim while the access token is not guaranteed to.
        func base64url(_ dict: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: dict)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = base64url([
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "809e76a1-acct",
                "chatgpt_plan_type": "pro"
            ]
        ])
        let jwt = "header.\(payload).sig"
        #expect(OpenAIJWTClaims.string(jwt, claim: "chatgpt_account_id") == "809e76a1-acct")
        #expect(OpenAIJWTClaims.string(jwt, claim: "chatgpt_plan_type") == "pro")
    }

    @Test("the web search / reasoning / vision capabilities declared per model upstream must be decoded, not just the slug")
    func modelDescriptorsCarryUpstreamDeclaredCapabilities() throws {
        // Copied field by field from a real response, without any simplification.
        //
        // An earlier version of this fixture also claimed its shape came from a real response, yet
        // `supported_reasoning_levels` had been hand-written as a flat string array. Upstream really sends an array of
        // objects [{effort, description}, ...]. The consequence was twofold: (1) the tier table was always empty, so every
        // subscription model showed "this model does not support thinking"; (2) worse, decoding an object array as [String]
        // fails the whole Item, which fails the whole catalog and gets reported as "cannot connect to Codex" although
        // upstream answered 200. A fake fixture is more dangerous than no test.
        let data = Data("""
        {"models":[
          {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,
           "web_search_tool_type":"text_and_image","default_reasoning_level":"low",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Fast responses with lighter reasoning"},
             {"effort":"medium","description":"Balances speed and reasoning depth"},
             {"effort":"high","description":"Greater reasoning depth"},
             {"effort":"xhigh","description":"Extra high reasoning depth"},
             {"effort":"max","description":"Maximum reasoning depth"},
             {"effort":"ultra","description":"Maximum reasoning with delegation"}],
           "input_modalities":["text","image"],"context_window":272000},
          {"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true,
           "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
           "supported_reasoning_levels":[
             {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
             {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
             {"effort":"max","description":"Max"}],
           "input_modalities":["text","image"],"context_window":272000}
        ]}
        """.utf8)

        let descriptors = try OpenAISubscriptionOAuthClient.parseModelDescriptors(from: data)
        #expect(descriptors.count == 2)

        let sol = try #require(descriptors.first)
        #expect(sol.slug == "gpt-5.6-sol")
        #expect(sol.supportsWebSearch)
        #expect(sol.supportsReasoning)
        #expect(sol.supportsImageInput)
        #expect(sol.defaultReasoningLevel == "low")
        // Tiers come from the effort field of each object; not a single tier may be missing.
        #expect(sol.supportedReasoningLevels == ["low", "medium", "high", "xhigh", "max", "ultra"])

        let luna = descriptors[1]
        #expect(luna.supportedReasoningLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(luna.supportsReasoning)
        #expect(luna.supportsWebSearch)

        // Legacy entry point: the slug list still works and keeps its order.
        #expect(try OpenAISubscriptionOAuthClient.parseModelSlugs(from: data) == ["gpt-5.6-sol", "gpt-5.6-luna"])
    }

    @Test("constructed boundary case: an empty string or empty array upstream means unsupported, and a capability must never be guessed from the slug")
    func modelDescriptorsDoNotInventCapabilities() throws {
        // This one is constructed, not a real upstream response: in real responses every model carries its full capabilities.
        let data = Data("""
        {"models":[
          {"slug":"no-caps","visibility":"list","supported_in_api":true},
          {"slug":"empty-caps","visibility":"list","supported_in_api":true,
           "web_search_tool_type":"","supported_reasoning_levels":[],
           "input_modalities":["text"]}
        ]}
        """.utf8)

        let descriptors = try OpenAISubscriptionOAuthClient.parseModelDescriptors(from: data)
        #expect(descriptors.count == 2)
        for item in descriptors {
            #expect(!item.supportsWebSearch)
            #expect(!item.supportsReasoning)
            #expect(!item.supportsImageInput)
        }
        #expect(descriptors[0].contextWindow == nil)
    }

    @Test("one bad entry drops only itself and must not ruin the whole catalog")
    func brokenEntryDoesNotKillWholeCatalog() throws {
        // Previously slug was non-optional and [Item] was all-or-nothing: if any single model was broken, the catalog lost
        // every entry and the user saw "cannot connect to Codex". The criterion is to skip entries one by one.
        let data = Data("""
        {"models":[
          {"visibility":"list","supported_in_api":true},
          {"slug":"good-1","visibility":"list","supported_in_api":true,
           "context_window":272000.0},
          {"slug":"good-2","visibility":"list","supported_in_api":true,
           "supported_reasoning_levels":[{"description":"no effort"},{"effort":"high"}]}
        ]}
        """.utf8)

        let descriptors = try OpenAISubscriptionOAuthClient.parseModelDescriptors(from: data)
        // The entry without a slug is dropped; the other two must both remain.
        #expect(descriptors.map(\.slug) == ["good-1", "good-2"])
        // A fractional context_window must not invalidate the whole model.
        #expect(descriptors[0].contextWindow == 272000)
        // A tier item without effort is skipped and does not pollute the tier table.
        #expect(descriptors[1].supportedReasoningLevels == ["high"])
    }

    @Test("a flat string array from upstream is still accepted, so the tier table cannot go empty again")
    func flatReasoningLevelsStillWork() throws {
        let data = Data("""
        {"models":[{"slug":"flat","visibility":"list","supported_in_api":true,
         "supported_reasoning_levels":["low","high"]}]}
        """.utf8)
        let descriptors = try OpenAISubscriptionOAuthClient.parseModelDescriptors(from: data)
        #expect(descriptors.first?.supportedReasoningLevels == ["low", "high"])
    }

    @Test("reasoning effort only takes values declared upstream, and nothing is sent when upstream declares none")
    func reasoningEffortNeverLeavesUpstreamDeclaredSet() {
        // The rule being guarded is never to send an effort value upstream does not recognize.
        // Admission uses the tier table declared by upstream /models: recognized values are sent, unrecognized ones degrade or are not sent.
        // If upstream renames a tier one day, this mismatches automatically and sends nothing instead of keeping on sending an old value.
        let full = ["low", "medium", "high"]
        #expect(OpenAIService.codexReasoningEffort(for: .fast, declaredLevels: full) == "low")
        #expect(OpenAIService.codexReasoningEffort(for: .balanced, declaredLevels: full) == "medium")
        #expect(OpenAIService.codexReasoningEffort(for: .deep, declaredLevels: full) == "high")
        // automatic leaves the choice to upstream's default_reasoning_level and does not choose for the user.
        #expect(OpenAIService.codexReasoningEffort(for: .automatic, declaredLevels: full) == nil)

        // When upstream has no xhigh, max degrades to the high it recognizes instead of sending a value that comes back as 400.
        #expect(OpenAIService.codexReasoningEffort(for: .max, declaredLevels: full) == "high")
        #expect(OpenAIService.codexReasoningEffort(for: .max, declaredLevels: ["xhigh", "high"]) == "xhigh")

        // With an incomplete tier table, values are still taken only from within the table.
        #expect(OpenAIService.codexReasoningEffort(for: .fast, declaredLevels: ["high"]) == nil)
        #expect(OpenAIService.codexReasoningEffort(for: .deep, declaredLevels: ["low"]) == nil)

        // Upstream declares nothing -> nothing is sent.
        for mode in [ReasoningMode.fast, .balanced, .deep, .max, .automatic] {
            #expect(OpenAIService.codexReasoningEffort(for: mode, declaredLevels: []) == nil)
        }
    }

    @Test("refresh proactively 5 minutes before expiry and not while it is still early")
    func needsRefreshTiming() {
        let now = Date()
        func token(expiresIn: TimeInterval) -> OpenAISubscriptionTokens {
            OpenAISubscriptionTokens(
                accessToken: "a", refreshToken: "r", idToken: nil,
                expiresAt: now.addingTimeInterval(expiresIn),
                accountID: "acct_1", planType: "pro", obtainedAt: now
            )
        }
        #expect(token(expiresIn: 200).needsRefresh(now: now))       // 200s left < 300s leeway
        #expect(!token(expiresIn: 3600).needsRefresh(now: now))     // 1h left, no refresh
        // Without an expiry time (upstream did not say) there is no proactive refresh.
        let noExpiry = OpenAISubscriptionTokens(
            accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: nil,
            accountID: "acct_1", planType: nil, obtainedAt: now
        )
        #expect(!noExpiry.needsRefresh(now: now))
    }

    @Test("a refresh response with only an access_token keeps the old credential identity and does not force the user to sign in again")
    func refreshWithoutIDTokenKeepsAccountIdentity() async throws {
        // A refresh response usually returns neither a refresh_token nor an id_token, and the id_token is exactly what carries
        // the chatgpt_account_id claim. Throwing as soon as the accountID could not be decoded made every refresh fail: the
        // grace window only covers the last 5 minutes before expiry, after which it is .unauthorized, and the user had to
        // sign in again every time a token really expired. This case runs the production refreshTokens path, not a hand-built object.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionTokenURLProtocol.self]
        let client = OpenAISubscriptionOAuthClient(session: URLSession(configuration: configuration))

        let now = Date()
        let stored = OpenAISubscriptionTokens(
            accessToken: "old-access",
            refreshToken: "r-old",
            idToken: codexJWT([
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct-established",
                    "chatgpt_plan_type": "pro"
                ]
            ]),
            expiresAt: now.addingTimeInterval(60),
            accountID: "acct-established",
            planType: "pro",
            obtainedAt: now.addingTimeInterval(-3600)
        )

        let refreshed = try await client.refreshTokens(
            config: Self.resolvedConfig(),
            refreshToken: "r-old",
            previous: stored
        )

        #expect(refreshed.accessToken == SubscriptionTokenURLProtocol.claimlessAccessToken)
        // Outbound requests always carry chatgpt-account-id; when the new token lacks it the old one must be kept.
        #expect(refreshed.accountID == "acct-established")
        // The response did not return a refresh_token, so keep the old one; otherwise one refresh would wipe out the ability to refresh.
        #expect(refreshed.refreshToken == "r-old")
        #expect(refreshed.planType == "pro")
        // The expiry must come from the new access_token's exp; keeping the old value would put it straight back into the refresh window.
        let expiresAt = try #require(refreshed.expiresAt)
        #expect(expiresAt > now.addingTimeInterval(1800))
    }

    @Test("the first PKCE exchange that cannot decode chatgpt_account_id must still fail and is not loosened by the refresh carry-over logic")
    func firstExchangeStillRequiresAccountID() async {
        // A refresh can carry the old value over, but the first exchange has no old value to carry: if the accountID cannot
        // be decoded this time, what gets stored is a credential whose outbound requests necessarily lack the
        // chatgpt-account-id header, and the user hits "authorization succeeded but the model list cannot be loaded",
        // which is a shape that really occurred on a device.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionTokenURLProtocol.self]
        let client = OpenAISubscriptionOAuthClient(session: URLSession(configuration: configuration))

        let error = await #expect(throws: OpenAISubscriptionError.self) {
            _ = try await client.exchangeAuthorizationCode(
                config: Self.resolvedConfig(),
                code: "auth-code-1",
                codeVerifier: "verifier-1"
            )
        }
        #expect(error == .upstream(status: 200, body: "missing chatgpt_account_id"))
    }

    @Test("a transient network failure while polling is not fatal: the app necessarily goes to the background while the user enters the code in the browser")
    @MainActor
    func pollSurvivesTransientFailureWhileUserIsInBrowser() async throws {
        // On a real device: before the code was fully entered, switching back from Safari to the app showed "cannot connect to Codex".
        // The device flow requires the user to switch to the browser to authorize, and on iOS switching away puts the app in the
        // background, so the in-flight polling request is interrupted by the system (transport). Treating that as terminal would
        // mean the act of completing authorization itself breaks authorization. This case makes the first poll fail with a transport
        // error and requires the state machine to keep polling and finally succeed.
        SubscriptionPollURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionPollURLProtocol.self]
        let client = OpenAISubscriptionOAuthClient(session: URLSession(configuration: configuration))

        let model = OpenAISubscriptionAuthorizationModel(client: client)
        // The interval is given as 1 second by the upstream usercode response, so the case does not idle for the 5 seconds of the delivered config.
        model.start(config: Self.resolvedConfig())

        // Wait for the state machine to finish: fail once -> continue -> succeed the second time.
        var waited = 0
        while waited < 60 {
            if case .succeeded = model.phase { break }
            if case .failed = model.phase { break }
            try await Task.sleep(for: .milliseconds(250))
            waited += 1
        }

        #expect(SubscriptionPollURLProtocol.pollAttempts >= 2, "a transient failure must be followed by another poll instead of being treated as fatal")
        guard case let .succeeded(tokens) = model.phase else {
            Issue.record("Expected authorization to finally succeed, got phase = \(model.phase)")
            return
        }
        #expect(tokens.accountID == "acct-from-id-token")
    }
}

/// Minimal upstream simulation of the Codex device flow: the first poll uses a transport error to simulate "the app went to
/// the background and the request was interrupted", after which it returns an authorization_code, and the tokenEndpoint
/// then exchanges it for a token carrying the namespaced claim.
private final class SubscriptionPollURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pollAttempts = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        pollAttempts = 0
    }

    private static func nextPollAttempt() -> Int {
        lock.lock(); defer { lock.unlock() }
        pollAttempts += 1
        return pollAttempts
    }

    static func base64URL(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        func respond(_ status: Int, _ body: String) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        switch url.path {
        case "/api/accounts/deviceauth/usercode":
            respond(200, #"{"device_auth_id":"dev-1","user_code":"ABCD-1234","interval":1,"expires_in":120}"#)
        case "/api/accounts/deviceauth/token":
            if Self.nextPollAttempt() == 1 {
                // First attempt: simulate the app going to the background and the connection being cut, which is exactly what happens on a device.
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            respond(200, #"{"authorization_code":"auth-code-1","code_verifier":"verifier-1"}"#)
        case "/oauth/token":
            let payload = Self.base64URL([
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct-from-id-token",
                    "chatgpt_plan_type": "pro"
                ]
            ])
            respond(200, """
            {"access_token":"header.\(payload).sig","refresh_token":"r-1","id_token":"header.\(payload).sig"}
            """)
        default:
            respond(404, "{}")
        }
    }
}

/// Builds a JWT of **real shape**: `header.<base64url(JSON payload)>.signature`.
///
/// It must use the real shape rather than a simplified fake string: `chatgpt_account_id` hangs under the
/// `https://api.openai.com/auth` namespace instead of the payload's top level, and this nesting level is exactly where past incidents happened.
private func codexJWT(_ payload: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let encoded = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

/// Minimal upstream simulation of the `tokenEndpoint`: both grant paths answer with the **shape of a real refresh response**:
/// only an access_token, no id_token, no refresh_token, and the access_token's payload holds only other claims, specifically
/// without `chatgpt_account_id`.
///
/// It branches on the `grant_type` in the request body and uses no mutable static state, so cases can run in parallel.
private final class SubscriptionTokenURLProtocol: URLProtocol, @unchecked Sendable {
    /// The namespace is present but `chatgpt_account_id` is not: this is the kind of token a refresh yields.
    static let claimlessAccessToken = codexJWT([
        "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
        "https://api.openai.com/auth": ["chatgpt_user_id": "user-1"]
    ])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// URLSession converts `httpBody` into a stream before handing it to the URLProtocol, so reading `httpBody` directly is usually nil.
    private static func bodyText(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        func respond(_ status: Int, _ body: String) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        guard url.path == "/oauth/token" else {
            respond(404, "{}")
            return
        }
        let body = Self.bodyText(request)
        if body.contains("grant_type=refresh_token") {
            respond(200, #"{"access_token":"\#(Self.claimlessAccessToken)","expires_in":3600}"#)
        } else {
            // The first exchange gets the same "accountID cannot be decoded" receipt, to pin that it must fail.
            respond(200, #"{"access_token":"\#(Self.claimlessAccessToken)"}"#)
        }
    }
}
