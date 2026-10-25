import Foundation
import Testing
@testable import Oriveo

/// Case-by-case run of the shared fixture rejection-recovery.v1.json: the one-tap action comes only from a
/// signature hit recorded on the failed message itself. By the rejected key it offers resend without images /
/// files / videos; for param_rejected it offers resend without that parameter; a miss, or a negative-cache hit
/// alone, offers no action. A hit also writes the negative cache. The kill-switch copy ids follow the three
/// media keys.
/// Assertions come from the output of production `InputRejectionFlow.record` and `AssistantMessageRecoveryBuilder.makeConfig`.
@Suite("Shared rejection-recovery cases: one-tap action after a rejection and kill-switch copy ids", .serialized, .sharedProcessState)
@MainActor
struct RejectionRecoveryContractTests {

    private static let expectedIDs: Set<String> = [
        "vision_rejected_resend_without_images",
        "file_rejected_resend_without_files",
        "video_rejected_resend_without_videos",
        "param_rejected_resend_without_param",
        "no_match_no_media_action",
        "cached_state_alone_offers_nothing",
        "kill_switch_image",
        "kill_switch_file",
        "kill_switch_video",
    ]

    @Test("The fixture id set matches this suite's cases one to one")
    func fixtureIDsAreLocked() throws {
        let fixture = try CapabilitySharedFixture.load("rejection-recovery.v1.json")
        let actions = try #require(fixture["actionCases"] as? [[String: Any]])
        let copies = try #require(fixture["killSwitchCopyCases"] as? [[String: Any]])
        let ids = (actions + copies).compactMap { $0["id"] as? String }
        #expect(ids.count == Self.expectedIDs.count)
        #expect(Set(ids) == Self.expectedIDs)
    }

    @Test("REJECTION_RECOVERY_vision_rejected_resend_without_images")
    func visionRejected() throws { try runActionCase("vision_rejected_resend_without_images") }

    @Test("REJECTION_RECOVERY_file_rejected_resend_without_files")
    func fileRejected() throws { try runActionCase("file_rejected_resend_without_files") }

    @Test("REJECTION_RECOVERY_video_rejected_resend_without_videos")
    func videoRejected() throws { try runActionCase("video_rejected_resend_without_videos") }

    @Test("REJECTION_RECOVERY_param_rejected_resend_without_param")
    func paramRejected() throws { try runActionCase("param_rejected_resend_without_param") }

    @Test("REJECTION_RECOVERY_no_match_no_media_action")
    func noMatch() throws { try runActionCase("no_match_no_media_action") }

    @Test("REJECTION_RECOVERY_cached_state_alone_offers_nothing")
    func cachedStateAlone() throws { try runActionCase("cached_state_alone_offers_nothing") }

    @Test("REJECTION_RECOVERY_kill_switch_image")
    func killSwitchImage() throws { try runCopyCase("kill_switch_image") }

    @Test("REJECTION_RECOVERY_kill_switch_file")
    func killSwitchFile() throws { try runCopyCase("kill_switch_file") }

    @Test("REJECTION_RECOVERY_kill_switch_video")
    func killSwitchVideo() throws { try runCopyCase("kill_switch_video") }

    // MARK: - Action cases

    /// Fixture action vocabulary -> production recovery card action.
    private static let actionKinds: [String: MessageRecoveryActionKind] = [
        "resend_without_images": .resendWithoutImages,
        "resend_without_files": .resendWithoutFiles,
        "resend_without_videos": .resendWithoutVideos,
        "resend_without_parameter": .resendWithoutParameter,
    ]

    /// Fixture secondaryAction vocabulary -> production recovery card action.
    private static let secondaryKinds: [String: MessageRecoveryActionKind] = [
        "switch_model": .switchModel,
    ]

    /// Wire family and the upstream error text for each media key; the signature table is injected, and the
    /// three keys and the parameter go through the same production decision.
    private static let mediaFamilies: [String: (family: String, message: String)] = [
        CapabilityEvidenceFacade.visionInputKey: ("openai_chat.image_url", "image input is not supported"),
        CapabilityEvidenceFacade.fileInputKey: ("openai_chat.file", "file input is not supported"),
        CapabilityEvidenceFacade.videoInputKey: ("openai_chat.video_url", "video input is not supported"),
    ]

    private static func signatures(parameter: String) throws -> InputRejectionSignatures {
        let json = #"""
        {"byWireFamily": {
          "openai_chat.image_url": [{"signatureId": "test.image_rejected", "httpStatus": 400,
            "messagePattern": "image input is not supported", "kind": "input_rejected", "capabilityKey": "vision_input"}],
          "openai_chat.file": [{"signatureId": "test.file_rejected", "httpStatus": 400,
            "messagePattern": "file input is not supported", "kind": "input_rejected", "capabilityKey": "file_input"}],
          "openai_chat.video_url": [{"signatureId": "test.video_rejected", "httpStatus": 400,
            "messagePattern": "video input is not supported", "kind": "input_rejected", "capabilityKey": "video_input"}]
        }, "byProtocol": {
          "openai_chat": [{"signatureId": "test.param_rejected", "httpStatus": 400,
            "messagePattern": "does not support \#(parameter)", "kind": "param_rejected", "parameter": "\#(parameter)"}]
        }}
        """#
        return try #require(InputRejectionSignatures(data: Data(json.utf8)))
    }

    private static func control(family: String) throws -> MetadataClient.CapabilityControl {
        let json = #"{"state":"auto_available","sourceRefs":["qwen.docs"],"wireFamily":"\#(family)"}"#
        return try JSONDecoder().decode(MetadataClient.CapabilityControl.self, from: Data(json.utf8))
    }

    private func runActionCase(_ id: String) throws {
        let fixture = try CapabilitySharedFixture.load("rejection-recovery.v1.json")
        let cases = try #require(fixture["actionCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "\(id)")
        let expect = try #require(item["expect"] as? [String: Any], "\(id)")
        #expect(item["connection"] as? String == "official", "\(id)")
        let match = item["match"] as? [String: Any]
        let parameter = match?["parameter"] as? String ?? "temperature"
        let signatures = try Self.signatures(parameter: parameter)

        // This request actually carried an image (the three-key cases swap in the rejected key); the miss case
        // reports an error unrelated to any signature.
        let matchedKey = match?["capabilityKey"] as? String
        let carriedKey = matchedKey ?? CapabilityEvidenceFacade.visionInputKey
        let media = try #require(Self.mediaFamilies[carriedKey], "\(id)")
        let body: String = switch match?["kind"] as? String {
        case "input_rejected": #"{"error":{"message":"\#(media.message)"}}"#
        case "param_rejected": #"{"error":{"message":"This model does not support \#(parameter)"}}"#
        default: #"{"error":{"message":"The server had an error while processing your request"}}"#
        }

        let cache = CapabilityNegativeCache(
            defaults: UserDefaults(suiteName: "RejectionRecoveryContractTests.\(UUID().uuidString)")!
        )
        let connectionId = UUID().uuidString
        let modelId = "recovery-model"
        let controls = [carriedKey: try Self.control(family: media.family)]
        let revision = CapabilityNegativeCache.verdictRevision(.init(
            state: "auto_available", wireFamily: media.family, sourceRefs: ["qwen.docs"]
        ))
        if item["negativeCacheAlreadyHit"] as? Bool == true {
            // A negative-cache entry recorded earlier: this failed message did not hit a signature itself, so it cannot borrow the entry to offer an action.
            cache.record(
                connectionId: connectionId, modelId: modelId, wireFamily: media.family,
                capabilityKey: carriedKey, signatureId: "earlier.rejection", verdictRevision: revision
            )
            #expect(cache.isRejected(
                connectionId: connectionId, modelId: modelId, wireFamily: media.family,
                capabilityKey: carriedKey, verdictRevision: revision
            ), "\(id) precondition: the negative cache is already hit")
        }

        let rejection = InputRejectionFlow.record(
            .init(
                form: .official, connectionId: connectionId, modelId: modelId,
                outputStarted: false, carriedCapabilityKeys: [carriedKey],
                httpStatus: 400, rawBody: body, controls: controls, transport: "openai_chat"
            ),
            signatures: signatures, negativeCache: cache
        )

        // Negative cache: a hit writes the rejected key; a miss writes nothing (an existing entry stays as is).
        let expectsCache = try #require(expect["negativeCache"] as? Bool, "\(id)")
        #expect((rejection != nil) == expectsCache, "\(id)")
        if let rejection {
            let entry = cache.entry(
                connectionId: connectionId, modelId: modelId, wireFamily: rejection.wireFamily,
                capabilityKey: rejection.capabilityKey
            )
            #expect(entry?.signatureId == rejection.signatureId, "\(id)")
            if match?["kind"] as? String == "param_rejected" {
                #expect(rejection.capabilityKey == InputRejectionFlow.parameterCapabilityKey(parameter), "\(id)")
            } else {
                #expect(rejection.capabilityKey == matchedKey, "\(id)")
            }
        } else {
            let entry = cache.entry(
                connectionId: connectionId, modelId: modelId, wireFamily: media.family, capabilityKey: carriedKey
            )
            if item["negativeCacheAlreadyHit"] as? Bool == true {
                #expect(entry?.signatureId == "earlier.rejection", "\(id)")
            } else {
                #expect(entry == nil, "\(id)")
            }
        }

        // Recovery card: the failed message only keeps the marker from this hit, and the card is built by production makeConfig.
        var message = TestFactories.makeMessage(role: .assistant, text: "", providerKind: .qwen)
        message.state = .failed
        message.recoveryPrimaryAction = rejection.flatMap {
            officialInputRejectedRecoveryAction(capabilityKey: $0.capabilityKey)
        }
        let model = ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "Qwen", resolvedModelName: modelId,
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: message.text.hashValue, isStreaming: false,
            providerMetadataVersion: 0, isLastInConversation: true
        )
        var retried = 0
        let config = try #require(AssistantMessageRecoveryBuilder.makeConfig(
            for: model, isSendingMessage: false, isDismissed: false, isTechnicalDetailExpanded: false,
            onRetry: { retried += 1 }, onContinue: {}, onRegenerate: {}, onEditMessage: {},
            onSwitchModelRequested: {}, onDismiss: {}, onTechnicalDetailVisibilityChanged: { _ in }
        ), "\(id)")
        let layout = resolveMessageRecoveryCardActionLayout(
            for: .failed, shouldOfferModelSwitch: false,
            recoveryPrimaryAction: recoveryPrimaryAction(for: message)
        )
        let rejectionActions = Set(Self.actionKinds.values)
        let rejectionTitles = Set(rejectionActions.map(localizedMessageRecoveryActionTitle))

        if let expectedAction = expect["action"] as? String {
            let kind = try #require(Self.actionKinds[expectedAction], "\(id)")
            #expect(layout.primary == kind, "\(id)")
            #expect(config.primaryTitle == localizedMessageRecoveryActionTitle(kind), "\(id)")
            // Card layout: exactly two buttons, the action first and switch model second (fixture secondaryAction).
            let secondary = try #require(Self.secondaryKinds[expect["secondaryAction"] as? String ?? ""], "\(id)")
            #expect(layout.secondary == secondary, "\(id)")
            #expect(layout.tertiary == nil, "\(id)")
            #expect(config.secondaryTitle == localizedMessageRecoveryActionTitle(secondary), "\(id)")
            #expect(config.tertiaryTitle == nil, "\(id)")
            if kind == .resendWithoutParameter {
                // Reuses the existing 16-language "Retry without this setting" in the Chat table; no new copy.
                #expect(config.primaryTitle == L10n.tr("Retry without this setting", table: .chat), "\(id)")
                try assertResendOmitsParameter(parameter, message: message, modelId: modelId, id: id)
            } else {
                let medium = try #require(InputCapabilityCopy.Medium(capabilityKey: matchedKey ?? ""), "\(id)")
                #expect(config.primaryTitle == InputCapabilityCopy.resendWithout(medium), "\(id)")
            }
            // Tapping is a normal resend: the outbound drops the rejected media / parameter per the negative cache and keeps everything else.
            config.primaryAction()
            #expect(retried == 1, "\(id)")
        } else {
            #expect(message.recoveryPrimaryAction == nil, "\(id)")
            #expect(!rejectionActions.contains(layout.primary), "\(id)")
            #expect(layout.secondary.map { !rejectionActions.contains($0) } ?? true, "\(id)")
            #expect(!rejectionTitles.contains(config.primaryTitle), "\(id)")
            #expect(!rejectionTitles.contains(config.secondaryTitle ?? ""), "\(id)")
            #expect(!rejectionTitles.contains(config.tertiaryTitle ?? ""), "\(id)")
        }
    }

    /// "Resend without this parameter" explicitly omits the rejected parameter for this one resend: the failed
    /// message records the parameter name, and the resend goes through the production outbound gate without it.
    /// It is omitted even when the negative cache is empty (a new connection whose shared cache was never
    /// written); outside this resend the parameter is sent as usual.
    private func assertResendOmitsParameter(
        _ parameter: String, message: ChatMessage, modelId: String, id: String
    ) throws {
        #expect(message.recoveryPrimaryAction == officialParameterRejectedRecoveryAction + ":" + parameter, "\(id)")
        let disposition = LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: message.errorTitle, recoveryDescriptorCount: nil,
            recoveryPrimaryAction: message.recoveryPrimaryAction
        )
        #expect(disposition == .omitParameterForExplicitRetry(parameter), "\(id)")
        // An old value without a parameter name: stays readable and degrades to relying on the negative cache alone.
        #expect(LocalCustomFragmentDisposition.forExplicitRetry(
            errorTitle: nil, recoveryDescriptorCount: nil, recoveryPrimaryAction: officialParameterRejectedRecoveryAction
        ) == .include, "\(id)")

        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen)
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: TestFactories.makeModel(id: modelId), partitionID: "rejection-recovery-user",
            hasExplicitValue: true, effectiveTransport: TransportKind.openaiChat.rawValue
        )
        #expect(CapabilityNegativeCache.shared.entry(
            connectionId: provider.id.uuidString, modelId: identity.query.effectiveModelID,
            wireFamily: TransportKind.openaiChat.rawValue,
            capabilityKey: InputRejectionFlow.parameterCapabilityKey(parameter)
        ) == nil, "\(id) precondition: the negative cache is empty")
        func outbound(_ omitted: Set<String>) -> [String: Any] {
            var body: [String: Any] = ["model": modelId, parameter: 1.0]
            CapabilityEvidenceRequestContext.$current.withValue(identity) {
                CapabilityRecipeResendContext.$omittedParameters.withValue(omitted) {
                    ProfileParamsResolver.applyTemperatureGate(to: &body, resolved: nil)
                }
            }
            return body
        }
        #expect(outbound(disposition.omittedParameters)[parameter] == nil, "\(id) the resend body does not contain \(parameter)")
        #expect(outbound([])[parameter] != nil, "\(id) a normal request follows the (empty) negative cache and sends it")
    }

    // MARK: - Kill-switch copy id cases

    private func runCopyCase(_ id: String) throws {
        let fixture = try CapabilitySharedFixture.load("rejection-recovery.v1.json")
        let cases = try #require(fixture["killSwitchCopyCases"] as? [[String: Any]])
        let item = try #require(cases.first { $0["id"] as? String == id }, "\(id)")
        let key = try #require(item["key"] as? String, "\(id)")
        let expect = try #require(item["expect"] as? [String: Any], "\(id)")
        let medium = try #require(InputCapabilityCopy.Medium(capabilityKey: key), "\(id)")
        #expect(InputCapabilityCopy.disabledCopyId(.killSwitch, medium) == expect["copyId"] as? String, "\(id)")
        // Each medium has its own sentence; the image one is not reused for all three.
        let others = InputCapabilityCopy.Medium.allCases.filter { $0 != medium }
        for other in others {
            #expect(
                InputCapabilityCopy.disabledKey(.killSwitch, medium) != InputCapabilityCopy.disabledKey(.killSwitch, other),
                "\(id)"
            )
        }
    }
}
