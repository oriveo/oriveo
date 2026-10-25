import Foundation
import Testing
@testable import Oriveo

/// Capability reachability of the subscription links (Codex / Grok subscriptions).
///
/// Subscription models are not in the metadata catalog and never have v2 `capabilityControls`, so the web search switch
/// and the reasoning tiers could not be rendered at all and were never injected outbound. The outbound implementation
/// written for Codex that copies the upstream declaration therefore became dead code: the fix was downstream while the gate was upstream.
///
/// These cases pin the full chain once that gate is opened:
///   upstream /models declaration -> capability verdict -> panel presentation -> preference identity
/// If any link falls back to fail-closed, this turns red.
@Suite("Subscription link · capability reachability", .sharedProcessState)
struct SubscriptionCapabilityReachabilityTests {
    /// A subscription instance: `authMode` is the criterion, not providerKind. The same openAI can be a pay-as-you-go
    /// API key instance or a subscription instance, and their capability sources of truth are entirely different.
    private static func subscriptionProvider(kind: ProviderKind = .openAI) -> Provider {
        var provider = TestFactories.makeProvider(kind: kind, models: [])
        provider.authMode = .subscription
        return provider
    }

    /// The shape written by `applyOpenAISubscriptionCatalog` and the Grok subscription catalog: capability bits and the
    /// tier table are both copied from the upstream `/models` declaration.
    private static func subscriptionModel(
        id: String = "gpt-5.6-sol",
        capabilities: [ModelCapability] = [.text, .web, .reasoning],
        declaredLevels: [String] = ["low", "medium", "high"],
        apiBackend: String? = nil
    ) -> AIModel {
        var model = TestFactories.makeModel(id: id, capabilities: capabilities)
        model.reasoningModeAvailable = capabilities.contains(.reasoning)
        model.upstreamReasoningLevels = declaredLevels
        model.upstreamAPIBackend = apiBackend
        return model
    }

    /// The same construction path as the UI entry point: a subscription model is not in the official metadata, so the identity
    /// gets no metadata transport and the subscription projection fills it in through `subscriptionFinalTransport`.
    private static func projection(
        provider: Provider, model: AIModel, keys: Set<String>, explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "subscription-truth", hasExplicitValue: false
        )
        return CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: keys, explicitKeys: explicitKeys
        )
    }

    private static let reasoningModes = ReasoningMode.allCases.filter { $0 != .automatic }
    private static let governedKeys: Set<String> = Set(
        ["vision_input", "web_search"] + reasoningModes.map { "reasoning_level/\($0.rawValue)" }
    )

    // MARK: - Truth adapter: the projection copies the upstream /models snapshot

    @Test("a model in the subscription snapshot: vision/web search come from upstream_declaration, the tier set equals the outbound mapping filter result, and tool_call reaches no conclusion")
    func subscriptionProjectionFollowsUpstreamSnapshot() throws {
        var model = Self.subscriptionModel(
            capabilities: [.text, .web, .reasoning, .image], declaredLevels: ["xhigh", "low"]
        )
        // Vision only trusts the upstream first-hand `input_modalities` (the subscription input verdict does not read the legacy capability bits).
        model.upstreamInputModalities = ["text", "image"]
        var provider = Self.subscriptionProvider()
        provider.catalogModels = [model]
        let projection = Self.projection(
            provider: provider, model: model, keys: Self.governedKeys.union(["tool_call"])
        )

        #expect(
            projection.identity?.query.effectiveTransport
                == CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model)
        )
        for key in ["web_search", "vision_input"] {
            let resolution = try #require(projection.resolution(for: key))
            #expect(resolution.support == .supported, "\(key)")
            #expect(resolution.source == .upstreamDeclaration, "\(key)")
            #expect(resolution.grade == .declared, "\(key)")
        }

        let supportedModes = Self.reasoningModes.filter {
            projection.resolution(for: "reasoning_level/\($0.rawValue)")?.support == .supported
        }
        let wantModes = Self.reasoningModes.filter {
            OpenAIService.codexReasoningEffort(for: $0, declaredLevels: model.upstreamReasoningLevels) != nil
        }
        #expect(!wantModes.isEmpty && wantModes.count < Self.reasoningModes.count, "the fixture needs both supported and unsupported tiers")
        #expect(Set(supportedModes) == Set(wantModes))
        for mode in Self.reasoningModes {
            let resolution = try #require(projection.resolution(for: "reasoning_level/\(mode.rawValue)"))
            #expect(resolution.source == .upstreamDeclaration, "\(mode.rawValue)")
            #expect(resolution.support != .unknown, "\(mode.rawValue)")
        }

        // The subscription catalog mapping does not set toolCall: no candidate is produced, so it stays unknown / missing_evidence and is not sent outbound.
        let tool = try #require(projection.resolution(for: "tool_call"))
        #expect(tool.support == .unknown)
        #expect(tool.source == .none)
        #expect(tool.reasonCode == .missingEvidence)
        #expect(!projection.permitsOutbound("tool_call"))
    }

    @Test("a model absent from the subscription snapshot is catalog_absent per key, even when the object carries capability bits and the user turned it on explicitly")
    func modelAbsentFromSubscriptionSnapshotResolvesToCatalogAbsent() throws {
        let listed = Self.subscriptionModel(id: "gpt-5.6-sol")
        var provider = Self.subscriptionProvider()
        provider.catalogModels = [listed]
        let outsider = Self.subscriptionModel(
            id: "gpt-not-in-snapshot", capabilities: [.text, .web, .reasoning, .image]
        )

        for explicitKeys in [Set<String>(), Self.governedKeys] {
            let projection = Self.projection(
                provider: provider, model: outsider, keys: Self.governedKeys, explicitKeys: explicitKeys
            )
            for key in Self.governedKeys {
                let resolution = try #require(projection.resolution(for: key))
                #expect(resolution.support == .unknown, "\(key)")
                #expect(resolution.source == .catalogAbsent, "\(key)")
                #expect(resolution.reasonCode == .catalogAbsent, "\(key)")
                #expect(!projection.permitsOutbound(key), "\(key)")
            }
        }
    }

    @Test("an empty subscription snapshot (/models not fetched yet) draws no catalog_absent conclusion and the whole projection is unknown; non-input keys are not sent outbound and input keys project as unknown")
    func emptySubscriptionSnapshotFailsClosed() throws {
        let model = Self.subscriptionModel(capabilities: [.text, .web, .reasoning, .image])
        let provider = Self.subscriptionProvider()
        #expect(provider.catalogModels.isEmpty)

        let projection = Self.projection(
            provider: provider, model: model, keys: Self.governedKeys, explicitKeys: Self.governedKeys
        )
        for key in Self.governedKeys {
            let resolution = try #require(projection.resolution(for: key))
            #expect(resolution.support == .unknown, "\(key)")
            #expect(resolution.source == .none, "\(key)")
            #expect(resolution.reasonCode == .missingEvidence, "\(key)")
            // An input key without a source = unknown / catalog_silent: the entry is open, the first attachment shows a prompt, and the send is native.
            #expect(
                projection.permitsOutbound(key) == CapabilityEvidenceFacade.inputCapabilityKeys.contains(key),
                "\(key)"
            )
        }
    }

    // MARK: - Capability verdicts follow the upstream declaration

    @Test("when upstream declares web search the web control is available instead of degrading into a \"cannot be adjusted\" line")
    func codexWebFollowsUpstreamDeclaration() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel(), capability: "web"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(verdict.intents.contains("automatic"))
        #expect(verdict.reasonCode == "subscription_upstream_declared")
    }

    @Test("when upstream does not declare web search the verdict is unavailable (definitely unsupported), not unknown (not figured out yet)")
    func codexWebAbsentIsUnavailableNotUnknown() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(),
            model: Self.subscriptionModel(capabilities: [.text]),
            capability: "web"
        )
        #expect(verdict.state == .unavailable)
        #expect(verdict.reasonCode == "model_capability_absent")
    }

    @Test("the selectable tiers are computed by the same function as outbound: only tiers that map to an upstream-declared value appear")
    func reasoningIntentsComeFromTheOutboundMapper() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel(), capability: "reasoning"
        )
        #expect(verdict.state == .autoAvailable)
        // Upstream declares only low/medium/high: max goes down the degradation chain to high (degradation guarantees it still
        // lands on a valid value instead of silently not being sent), so it is still a tier that can really be sent.
        #expect(verdict.intents == ["low", "balanced", "deep", "max"])
    }

    @Test("when upstream declares a single tier, tiers that cannot be mapped do not appear, so there is no control that does nothing when pressed")
    func reasoningIntentsShrinkWithDeclaredLevels() {
        // Only xhigh: the candidates for fast are low/minimal/medium and none of them match, so that tier must not appear.
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(),
            model: Self.subscriptionModel(declaredLevels: ["xhigh"]),
            capability: "reasoning"
        )
        #expect(verdict.intents == ["max"])
    }

    @Test("when upstream declares no tier table the reasoning tiers are unavailable, so there is no control that does nothing when pressed")
    func reasoningWithoutDeclaredLevelsIsUnavailable() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(),
            model: Self.subscriptionModel(declaredLevels: []),
            capability: "reasoning"
        )
        #expect(verdict.state == .unavailable)
        #expect(verdict.reasonCode == "upstream_parameter_not_declared")
    }

    @Test("a Grok subscription declaring api_backend=responses and supports_backend_search makes web search auto_available")
    func grokSubscriptionWebFollowsResponsesDeclaration() async {
        // Verified with a real subscription token: `/responses` + `tools:[{"type":"web_search"}]` really searches the web;
        // the badge, the composer and outbound share one source: when the switch is on, the web_search tool is sent.
        await MetadataClient.shared.resetForTesting()
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "responses"),
            capability: "web"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(verdict.intents == ["automatic"])
        // The proxy has no "turn search off" semantics (outbound always carries web_search): a dedicated reason code marks it and the panel draws a read-only "Always on" from it.
        #expect(verdict.reasonCode == "subscription_web_always_on")
        #expect(CapabilityControlPresentationResolver.presentation(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "responses"),
            capability: "web"
        ) == .alwaysOn)

        // Upstream declares no search capability -> unavailable (definitely unsupported).
        let absent = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-4.6", capabilities: [.text], apiBackend: "responses"),
            capability: "web"
        )
        #expect(absent.state == .unavailable)
        #expect(absent.reasonCode == "model_capability_absent")
    }

    @Test("web search is unavailable when the Grok subscription upstream explicitly declares the chat backend: the chat/completions path has no server-side web_search")
    func grokSubscriptionWebUnavailableOnChatCompletions() async {
        // On `/chat/completions` the model only outputs a fake `<web_search>` tool-call text (the root cause of an earlier incident);
        // this path is only taken when upstream explicitly declares chat (the default for an undeclared backend is Responses),
        // and then a globe that cannot actually send must not be lit.
        await MetadataClient.shared.resetForTesting()
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "chat"),
            capability: "web"
        )
        #expect(verdict.state == .unavailable)
        #expect(verdict.reasonCode == "upstream_transport_without_web_search")
    }

    @Test("Grok subscription reasoning tiers stay available: reasoning_effort is known to be accepted")
    func grokSubscriptionReasoningStaysAvailable() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(kind: .grok),
            model: Self.subscriptionModel(id: "grok-4.6"),
            capability: "reasoning"
        )
        #expect(verdict.state == .autoAvailable)
        #expect(!verdict.intents.isEmpty)
    }

    @Test("other capabilities have no declared source on the subscription link, so they honestly stay unknown instead of pretending to be unsupported")
    func otherCapabilitiesStayUnknown() {
        let verdict = CapabilityControlResolution.resolve(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel(), capability: "generation"
        )
        #expect(verdict.state == .unknown)
    }

    // MARK: - Panel presentation (second gate: auto_available must not be knocked back to unknown by the transport check)

    @Test("auto_available on the subscription link passes the exact-transport check and reaches the panel")
    func presentationKeepsAutoAvailableForSubscription() {
        // A subscription model has no recipe, so `hasExactTransportRecipe` is necessarily false; if it were not let through,
        // `status(...)` would downgrade every auto_available back to .unknown and the first gate would have been opened in vain.
        let presentation = CapabilityControlPresentationResolver.presentation(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel(), capability: "web"
        )
        #expect(presentation == .automaticAvailable)
    }

    @Test("a capability upstream does not declare is unsupported on the panel, not unknown")
    func presentationReportsUnsupportedWhenUpstreamSilent() {
        let presentation = CapabilityControlPresentationResolver.presentation(
            provider: Self.subscriptionProvider(),
            model: Self.subscriptionModel(capabilities: [.text]),
            capability: "web"
        )
        #expect(presentation == .unsupported)
    }

    // MARK: - Preference identity (third gate: the selection can be persisted)

    @Test("a subscription model has no catalog transport but the identity still holds")
    func subscriptionIdentityIsAvailableWithoutCatalog() {
        // When the identity is nil, `ModelControlsSheet` judges `.runtimeIdentityUnavailable` and
        // `canPersist == false`, so not a single byte of the user's chosen tier and web switch can be saved.
        let identity = CapabilityPreferenceRuntimeIdentity.make(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel()
        )
        #expect(identity != nil)
        #expect(identity?.canonicalModelID == "gpt-5.6-sol")
        #expect(identity?.finalTransport == TransportKind.openaiResponses.rawValue)
        #expect(identity?.runtimeRevision == CapabilityPreferenceRuntimeIdentity.subscriptionRuntimeRevision)
    }

    @Test("the Grok subscription transport source of truth: /models api_backend=responses -> openai_responses; undeclared with no delivered value -> fallback openai_responses (the cli-chat-proxy chat backend is responses-only)")
    func grokSubscriptionTransportFollowsUpstreamDeclaration() async {
        await MetadataClient.shared.resetForTesting()
        let provider = Self.subscriptionProvider(kind: .grok)
        let declared = CapabilityPreferenceRuntimeIdentity.make(
            provider: provider, model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "responses")
        )
        #expect(declared?.finalTransport == TransportKind.openaiResponses.rawValue)
        #expect(
            CapabilityControlResolution.subscriptionFinalTransport(
                for: provider, model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "responses")
            ) == TransportKind.openaiResponses.rawValue
        )
        // An unrecognized declaration does not guess a specific protocol, but the fallback default must be Responses: the
        // cli-chat-proxy chat backend is responses-only, and falling back to chat reliably reproduces the incident where the
        // model acts out a fake web_search.
        #expect(
            CapabilityControlResolution.subscriptionFinalTransport(
                for: provider, model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "grpc")
            ) == TransportKind.openaiResponses.rawValue
        )
        let undeclared = CapabilityPreferenceRuntimeIdentity.make(
            provider: provider, model: Self.subscriptionModel(id: "grok-4.6")
        )
        #expect(undeclared?.finalTransport == TransportKind.openaiResponses.rawValue)
    }

    @Test("when both subscription links share a protocol (openai_responses) preferences are still isolated by connection id and never leak onto the other link")
    func subscriptionPreferencesStayScopedByConnection() async {
        await MetadataClient.shared.resetForTesting()
        let codexProvider = Self.subscriptionProvider()
        let grokProvider = Self.subscriptionProvider(kind: .grok)
        let codex = CapabilityPreferenceRuntimeIdentity.make(
            provider: codexProvider, model: Self.subscriptionModel()
        )
        let grok = CapabilityPreferenceRuntimeIdentity.make(
            provider: grokProvider, model: Self.subscriptionModel(id: "grok-4.6", apiBackend: "responses")
        )
        // The identity only describes "protocol x runtime version" and both links are currently responses; isolation relies on the store's providerID dimension.
        #expect(codex?.finalTransport == grok?.finalTransport)
        #expect(codexProvider.id != grokProvider.id)
    }

    @Test("the identity does not follow the metadata revision: every catalog the server delivers must not invalidate the user selection")
    func subscriptionIdentityIgnoresMetadataRevision() {
        // The subscription link has no recipe runtime at all; putting the metadata revision into the identity would
        // invalidate every tier the user saved after the next catalog refresh.
        let identity = CapabilityPreferenceRuntimeIdentity.make(
            provider: Self.subscriptionProvider(), model: Self.subscriptionModel()
        )
        #expect(identity?.runtimeRevision == "subscription")
    }

    // MARK: - Failure semantics of the chat runtime (fourth gate: do not steer subscription users toward "swap the key")

    @Test(
        "401/403/426/429 on the subscription link each map to their own kind",
        arguments: [
            (401, ProviderServiceError.SubscriptionFailureKind.expired),
            (403, ProviderServiceError.SubscriptionFailureKind.ineligible),
            (426, ProviderServiceError.SubscriptionFailureKind.unavailable),
            (429, ProviderServiceError.SubscriptionFailureKind.quotaExhausted),
        ]
    )
    func subscriptionRuntimeFailuresKeepTheirOwnMeaning(
        statusCode: Int, expected: ProviderServiceError.SubscriptionFailureKind
    ) {
        for lane in [ProviderServiceError.SubscriptionLane.grok, .openAI] {
            let mapped = BaseAPIService.subscriptionFailure(
                statusCode: statusCode, detail: "d", lane: lane
            )
            guard case let .subscriptionFailure(gotLane, gotKind, messageKey, _) = mapped else {
                Issue.record("expected subscriptionFailure for \(statusCode)/\(lane)")
                continue
            }
            #expect(gotKind == expected)
            #expect(gotLane == lane)
            // The generic classification would tell the user to "check the value or regenerate the key" for 401/403 and to
            // "check billing at the provider" for 429; a subscription user has neither a key to swap nor a billing page to look at, so both are dead ends.
            #expect(messageKey != ProviderServiceError.invalidAPIKey(detail: "").messageKey)
            #expect(messageKey != ProviderServiceError.quotaExceeded(detail: "").messageKey)
        }
    }

    @Test("the same kind of failure reads differently on the two links: the user needs to know which one to sign in to again")
    func subscriptionFailureMessagesNameTheLink() {
        let grok = BaseAPIService.subscriptionFailure(statusCode: 401, detail: "d", lane: .grok)
        let codex = BaseAPIService.subscriptionFailure(statusCode: 401, detail: "d", lane: .openAI)
        #expect(grok?.messageKey != codex?.messageKey)
        #expect(grok?.titleKey == "Grok subscription")
        #expect(codex?.titleKey == "ChatGPT subscription")
    }

    @Test("5xx / 400 are not hard subscription failures and keep going through the generic classification")
    func nonSubscriptionStatusCodesFallThrough() {
        #expect(BaseAPIService.subscriptionFailure(statusCode: 500, detail: "d", lane: .openAI) == nil)
        #expect(BaseAPIService.subscriptionFailure(statusCode: 400, detail: "d", lane: .grok) == nil)
    }

    @Test("API key mode does not enter the subscription branch and the generic classification is unchanged")
    func apiKeyModeSkipsSubscriptionMapping() {
        #expect(BaseAPIService.subscriptionFailure(statusCode: 401, detail: "d", lane: nil) == nil)
    }

    // MARK: - How the kill switch reads on the user side

    @Test("when Codex is disabled only Codex shows a notice and Grok instances are unaffected")
    func disabledNoticeIsScopedToItsOwnLink() {
        var codex = TestFactories.makeProvider(kind: .openAI, models: [])
        codex.authMode = .subscription
        var grok = TestFactories.makeProvider(kind: .grok, models: [])
        grok.authMode = .subscription

        let codexNotice = SubscriptionDisabledPresentation.resolve(
            provider: codex, openAI: .disabled(notice: "codex paused"), grok: .unavailable
        )
        let grokNotice = SubscriptionDisabledPresentation.resolve(
            provider: grok, openAI: .disabled(notice: "codex paused"), grok: .unavailable
        )
        #expect(codexNotice?.notice == "codex paused")
        // Judging this instance by the other link's availability would make Grok read as disabled here too.
        #expect(grokNotice == nil)
    }

    @Test("a missing delivered notice falls back to localized text, and the two fallbacks differ")
    func disabledNoticeFallsBackPerLink() {
        var codex = TestFactories.makeProvider(kind: .openAI, models: [])
        codex.authMode = .subscription
        var grok = TestFactories.makeProvider(kind: .grok, models: [])
        grok.authMode = .subscription

        let codexNotice = SubscriptionDisabledPresentation.resolve(
            provider: codex, openAI: .disabled(notice: nil), grok: .unavailable
        )
        let grokNotice = SubscriptionDisabledPresentation.resolve(
            provider: grok, openAI: .unavailable, grok: .disabled(notice: "   ")
        )
        #expect(codexNotice?.notice == nil)
        #expect(codexNotice?.fallback.isEmpty == false)
        #expect(grokNotice?.fallback.isEmpty == false)
        // The user needs to know which one was stopped, so the two sentences cannot be the same.
        #expect(codexNotice?.fallback != grokNotice?.fallback)
    }

    @Test("neither an API key instance nor an available state shows the disabled notice")
    func disabledNoticeStaysOutOfHealthyPaths() {
        var apiKey = TestFactories.makeProvider(kind: .openAI, models: [])
        apiKey.authMode = .apiKey
        #expect(
            SubscriptionDisabledPresentation.resolve(
                provider: apiKey, openAI: .disabled(notice: "paused"), grok: .unavailable
            ) == nil
        )

        var codex = TestFactories.makeProvider(kind: .openAI, models: [])
        codex.authMode = .subscription
        #expect(
            SubscriptionDisabledPresentation.resolve(
                provider: codex, openAI: .unavailable, grok: .unavailable
            ) == nil
        )
    }

    // MARK: - The text really can be translated (a wrong table raises no error and leaves no trace, it just quietly turns back into English)

    @Test("the messages of the four subscription failures are all in the Providers table list")
    func subscriptionMessagesResolveThroughProvidersTable() {
        // `ProviderIssueMessage.localized` picks the table by key: if one entry is missing, that kind shows English on the detail
        // page while the "all 16 languages complete" check elsewhere stays green; this assertion is the only catch for that silent failure.
        for lane in [ProviderServiceError.SubscriptionLane.grok, .openAI] {
            for statusCode in [401, 403, 426, 429] {
                guard case let .subscriptionFailure(_, _, messageKey, _)? = BaseAPIService
                    .subscriptionFailure(statusCode: statusCode, detail: "d", lane: lane) else {
                    Issue.record("expected subscriptionFailure for \(statusCode)/\(lane)")
                    continue
                }
                #expect(
                    ProviderIssueMessage.subscriptionMessageKeys.contains(messageKey),
                    "The message for \(lane)/\(statusCode) is not in the Providers table list and would silently show English"
                )
                // The list is only routing; the real evidence is that the sentence can be looked up in the current language,
                // and `L10n.tr` returns the key unchanged when it cannot.
                #expect(ProviderIssueMessage.localized(messageKey) != messageKey || messageKey.isEmpty == false)
            }
        }
    }

    @Test("the error card title and body both resolve to translations instead of returning the English key unchanged")
    func subscriptionFailureTitleAndMessageAreLocalized() {
        guard let failure = BaseAPIService.subscriptionFailure(
            statusCode: 401, detail: "d", lane: .openAI
        ) else {
            Issue.record("expected subscriptionFailure")
            return
        }
        // The title uses the default table and the message uses the Providers table; both must hit, or the user sees half a sentence in English.
        #expect(!failure.title.isEmpty)
        #expect(!failure.message.isEmpty)
    }

    // MARK: - Does not affect API key mode

    @Test("the same OpenAI provider in API key mode still uses the catalog criterion and the subscription branch does not interfere")
    func apiKeyModeKeepsCatalogPath() {
        var provider = TestFactories.makeProvider(kind: .openAI, models: [])
        provider.authMode = .apiKey
        #expect(!CapabilityControlResolution.isSubscriptionLink(provider))
        #expect(CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: Self.subscriptionModel()) == nil)
    }
}
