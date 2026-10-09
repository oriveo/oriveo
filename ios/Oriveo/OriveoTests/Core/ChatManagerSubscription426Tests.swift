import Foundation
import Testing
@testable import Oriveo

private final class Subscription426URLProtocol: URLProtocol, @unchecked Sendable {
    /// The upstream 426 body, the same on every platform. `code` and `error` are what the upstream returns
    /// to an outdated client; the outer JSON key names follow the fixture in `ChatFailurePresentationTests`.
    static let body = Data(#"{"code":"ClientVersionRejected","error":"Your Grok CLI version (1.0.4) is outdated. Please update to version 1.0.13 or later via `grok update` or the installation documentation."}"#.utf8)

    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url ?? URL(string: "https://subscription.invalid")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 426,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func subscription426Session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Subscription426URLProtocol.self]
    return URLSession(configuration: configuration)
}

/// How a subscription 426 is wired into the send path. `ChatFailurePresentationTests` stops at
/// `mapHTTPError`; that ChatManager really refreshes the configuration on a 426 and really stores the
/// sentence written for the user on the failed message was not asserted before.
///
/// Every assertion is made on an object produced by the production path: the request is sent by the real
/// `GrokService` (only the credential preparation is replaced by an injected outbound context), the error
/// comes from the real mapping, and the failed message is stored by `ChatManager`. Only the configuration
/// refresh, which goes straight to the network, is replaced by a recorder.
@Suite("ChatManager subscription 426 wiring", .serialized)
@MainActor
struct ChatManagerSubscription426Tests {
    private static let sentClientVersion = "1.0.4"

    private func loadGrokSubscriptionMetadata() async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "grok",
              "displayName": "Grok",
              "defaultBaseURL": "https://api.x.ai/v1",
              "protocolFeatures": {
                "authMethod": "bearer",
                "subscriptionAuth": {
                  "enabled": true,
                  "flow": "oauth_device_code",
                  "clientId": "subscription-426-test-client",
                  "scopes": "openid profile email",
                  "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                  "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                  "trustedAuthHosts": ["auth.x.ai"],
                  "trustedVerificationHosts": ["accounts.x.ai"],
                  "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
                  "requiredHeaders": {"x-grok-client-version": "\(Self.sentClientVersion)"},
                  "apiBackend": "responses"
                }
              }
            }
          ]
        }
        """, metadataETag: "subscription-426-etag")
    }

    private func failedAssistantMessage(in state: AppState, conversationID: UUID) -> ChatMessage? {
        state.conversations.first { $0.id == conversationID }?
            .messages.last { $0.state == .failed }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("A Grok subscription rejected with 426 stores the subscription-unavailable copy and refreshes the configuration on every rejection")
    func subscription426FailsWithSubscriptionCopyAndRefreshes() async throws {
        final class Recorder {
            var events: [String] = []
        }

        Subscription426URLProtocol.requests = []
        try await loadGrokSubscriptionMetadata()

        let providerID = UUID()
        defer { Subscription426URLProtocol.requests = [] }

        var model = TestFactories.makeModel(id: "grok-4.6", capabilities: [.text], isDefault: true)
        model.upstreamAPIBackend = "responses"
        var provider = TestFactories.makeProvider(id: providerID, kind: .grok, models: [model])
        provider.authMode = .subscription

        let state = AppState(
            seedDemoData: false,
            sessionUID: "subscription-426-\(UUID().uuidString)",
            providerSession: subscription426Session()
        )
        let conversation = TestFactories.makeConversation(
            providerID: providerID,
            providerKind: .grok,
            modelID: model.id
        )
        state.providers = [provider]
        state.upsertConversationProjection(conversation)

        // Only the credential preparation is replaced (it lives in the Keychain, which an unsigned test host
        // cannot use); recognizing the 426 and storing the failed message still run on the production path.
        let resourceBase = "https://cli-chat-proxy.grok.com/v1"
        let prepared = GrokSubscriptionRuntime.Prepared(
            accessToken: "subscription-426-access-token",
            context: GrokSubscriptionRequestContext(
                chatURL: try #require(URL(string: "\(resourceBase)/chat/completions")),
                responsesURL: URL(string: "\(resourceBase)/responses"),
                requiredHeaders: ["x-grok-client-version": Self.sentClientVersion],
                transport: TransportKind.openaiResponses.rawValue
            ),
            didRefresh: false
        )
        state.chatManager.grokSubscriptionPreparer = { _ in .success(prepared) }

        let recorder = Recorder()
        state.chatManager.subscriptionConfigurationRefresher = { recorder.events.append("refresh") }

        _ = await state.sendMessage("Hello", in: conversation.id)
        try await waitUntil { failedAssistantMessage(in: state, conversationID: conversation.id) != nil }

        let request = try #require(Subscription426URLProtocol.requests.first, "The subscription request was never sent")
        #expect(request.url?.host == "cli-chat-proxy.grok.com")
        #expect(request.value(forHTTPHeaderField: "x-grok-client-version") == Self.sentClientVersion)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-426-access-token")

        let failed = try #require(
            failedAssistantMessage(in: state, conversationID: conversation.id),
            "The send path stored no failed message"
        )
        #expect(failed.errorTitle == ProviderServiceError.SubscriptionLane.grok.titleKey)
        let detail = try #require(failed.errorDetail)
        #expect(!detail.isEmpty)
        #expect(detail == failed.text, "The stored detail of a subscription failure is the sentence written for the user")
        for leaked in ["grok update", "CLI", "ClientVersionRejected", "1.0.13"] {
            #expect(!detail.contains(leaked), "The failure card must not show the upstream text (\(leaked)): \(detail)")
            #expect(!failed.text.contains(leaked), "The failure body must not show the upstream text (\(leaked)): \(failed.text)")
        }
        #expect(ChatFailurePresentation.offersModelSwitch(
            errorTitle: failed.errorTitle, errorDetail: failed.errorDetail, bodyText: failed.text
        ))

        #expect(recorder.events == ["refresh"])

        // The user sends again: the configuration is refreshed again before the failure lands.
        let failedCount = { state.conversations.first { $0.id == conversation.id }?
            .messages.filter { $0.state == .failed }.count ?? 0 }
        let before = failedCount()
        _ = await state.sendMessage("Hello again", in: conversation.id)
        try await waitUntil { failedCount() == before + 1 }
        #expect(failedCount() == before + 1, "The second send should store a failed message as well")
        #expect(recorder.events == ["refresh", "refresh"])

        await MetadataClient.shared.resetForTesting()
    }
}
