import Foundation

/// Decides whether a chat image send moves to the studio pipeline, and maps studio failures
/// onto the chat error type. Pure functions only; the chat send path wires them in.
///
/// Truth table: `shared/studio-contracts/chat_image_dispatch.v1.json`, read by the
/// iOS / Android / Web contract tests alike.
nonisolated enum ChatImageDispatch {
    /// `spec.chatParams`: the fixed studio parameters of a chat image send.
    struct ChatParams: Equatable, Sendable {
        var aspect: String
        var resolution: ImageProfile.ResolutionTier
        var quality: ImageProfile.QualityTier
        var n: Int
    }

    /// One image of the user message being sent, in attachment order.
    struct Attachment: Equatable, Sendable {
        var id: String
        /// Whether the image bytes are available on this device.
        var hasBytes: Bool
    }

    /// A reference image handed to the studio executor.
    struct Image: Equatable, Sendable {
        var attachmentId: String
        var slot: Int
        var role: String
    }

    enum Decision: Equatable, Sendable {
        /// The existing chat image path, unchanged.
        case legacy
        case studio(operation: ImageProfile.Operation, images: [Image])
    }

    /// `spec.studioRoutes`: routes that move to the studio pipeline.
    static let studioRoutes: [ImageProfile.Route] = [
        .openaiImages, .xaiImages, .openrouterImages, .minimaxImageGeneration, .dashscopeMultimodal,
    ]

    /// `spec.legacyProviderKinds`: provider kinds that always keep the legacy path.
    static let legacyProviderKinds: [ProviderKind] = [.relay]

    /// `spec.chatParams`.
    static let chatParams = ChatParams(aspect: "1:1", resolution: .oneK, quality: .standard, n: 1)

    static func decide(
        providerKind: ProviderKind,
        legacyImageDispatch: Bool,
        profile: ImageProfile?,
        attachments: [Attachment]
    ) -> Decision {
        guard legacyImageDispatch,
              !legacyProviderKinds.contains(providerKind),
              let profile,
              studioRoutes.contains(profile.route)
        else { return .legacy }
        guard profile.operations.contains(.edit) else { return .studio(operation: .generate, images: []) }
        // A missing or non-positive maxReferenceImages counts as one reference image.
        let limit = profile.maxReferenceImages.flatMap { $0 > 0 ? $0 : nil } ?? 1
        let images = attachments.filter(\.hasBytes).prefix(limit).enumerated().map { index, attachment in
            Image(attachmentId: attachment.id, slot: index + 1, role: index == 0 ? "base" : "element")
        }
        return images.isEmpty ? .studio(operation: .generate, images: []) : .studio(operation: .edit, images: images)
    }

    /// `spec.errorMap` category for a studio failure kind; `nil` for `partial`, which completes.
    static func category(for kind: StudioImageErrorKind) -> String? {
        switch kind {
        case .refused, .invalidParam: return "upstream_400"
        case .auth: return "invalid_key"
        case .insufficientBalance: return "quota_exceeded"
        case .rateLimited: return "rate_limited"
        case .modelUnavailable: return "model_unavailable"
        case .upstreamError: return "upstream_502"
        case .timeout, .network: return "network"
        case .decodeFailed: return "empty_response"
        case .storageFull: return "upstream_507"
        case .partial: return nil
        }
    }

    /// The chat error for a failed studio run; `detail` carries the result message.
    /// `nil` for `partial`, which completes with the delivered images.
    static func chatFailure(kind: StudioImageErrorKind, message: String) -> ProviderServiceError? {
        switch category(for: kind) {
        case "upstream_400": return .upstream(statusCode: 400, detail: message)
        case "upstream_502": return .upstream(statusCode: 502, detail: message)
        case "upstream_507": return .upstream(statusCode: 507, detail: message)
        case "invalid_key": return .invalidAPIKey(detail: message)
        case "quota_exceeded": return .quotaExceeded(detail: message)
        case "rate_limited": return .rateLimited(detail: message)
        case "model_unavailable": return .modelUnavailable(detail: message)
        case "network": return .network(detail: message)
        case "empty_response": return .emptyResponse
        default: return nil
        }
    }
}
