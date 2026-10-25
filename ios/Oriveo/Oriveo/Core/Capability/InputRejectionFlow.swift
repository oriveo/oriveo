import Foundation

/// Feeds an input-capability rejection from an official connection back into the negative cache.
///
/// Decision: official connection, before any output of the first leg, the upstream error body matches an
/// `input_rejected` signature in the signature table, and the medium for that signature was actually carried
/// by this request. A hit records a v2 negative-cache entry (verdictRevision taken from the verdict at that
/// time). There is no retry; the recovery card offers "resend without images / files / videos" for the rejected
/// key, and after the user taps it the normal resend already hits the negative cache, so the outbound
/// projection strips that medium and writes a placeholder. Relay goes through `RelayRejectionRecording`;
/// nothing is recorded here for it.
///
/// Parameter branch: when no input signature matched, the `param_rejected` signatures of `byProtocol` for the
/// protocol of this request's wire are checked next; a hit records a v2 negative-cache entry
/// `param:<parameter name>` (wire family = protocol key, revision taken from the verdict of that parameter in
/// parameterSupport at that time). It only affects later requests and does not resend the failed one.
nonisolated enum InputRejectionFlow {
    /// The scene of one failed send.
    struct Attempt: Sendable {
        var form: ProviderForm
        /// Negative-cache connection key = provider.id, the same value as on the read side.
        var connectionId: String
        /// Negative-cache model key = `identity.query.effectiveModelID`, the same value as on the read side.
        var modelId: String
        /// Whether this assistant message already had output (text or reasoning) before the error.
        var outputStarted: Bool
        /// Input capability keys (e.g. `vision_input`) this request actually carried.
        var carriedCapabilityKeys: Set<String>
        var httpStatus: Int?
        var rawBody: String?
        /// The model's `capabilityControls` at send time; verdict and wire family are taken from here.
        var controls: [String: MetadataClient.CapabilityControl]?
        /// Outbound wire of this request (`TransportKind` vocabulary); parameter signatures are looked up by its protocol.
        var transport: String? = nil
        /// The model's parameterSupport at send time; the revision of a parameter entry is taken from here.
        var parameterSupport: MetadataClient.JSONValue? = nil
    }

    struct Rejection: Equatable, Sendable {
        let capabilityKey: String
        let signatureId: String
        let wireFamily: String
        let verdictRevision: String
    }

    static func parameterCapabilityKey(_ parameter: String) -> String { "param:" + parameter }

    /// Attachment kind -> input capability key.
    static func capabilityKey(for kind: AttachmentKind) -> String {
        switch kind {
        case .image: CapabilityEvidenceFacade.visionInputKey
        case .file: CapabilityEvidenceFacade.fileInputKey
        case .video: CapabilityEvidenceFacade.videoInputKey
        }
    }

    /// Input capability keys actually carried by this outbound request: the outbound messages contain that
    /// medium and the outbound projection lets the native part through. Media already stripped to a
    /// placeholder by the projection (negative-cache hit, unsupported verdict, ...) do not count as carried,
    /// so a rejection is not recorded again.
    static func carriedCapabilityKeys(
        messages: [ChatMessage],
        permitsOutbound: (String) -> Bool
    ) -> Set<String> {
        let present = Set(messages.flatMap { $0.attachments ?? [] }.map { capabilityKey(for: $0.kind) })
        return present.filter(permitsOutbound)
    }

    /// Pure decision: writes no cache.
    static func evaluate(
        _ attempt: Attempt,
        signatures: InputRejectionSignatures = .shared
    ) -> Rejection? {
        guard attempt.form == .official, !attempt.outputStarted,
              let status = attempt.httpStatus, let rawBody = attempt.rawBody else { return nil }
        // Only the wire families of the media actually carried are looked up; the order is fixed so the same
        // scene always gives the same conclusion. When the verdict names no protocol family (including a recipe
        // with the key missing = unknown), fall back to the (key, wire) table, the same table and rule as the
        // read side's officialInputProjection; if the wire cannot give a family either (unknown wire, text-only
        // wire), nothing is recorded.
        let carried = attempt.carriedCapabilityKeys.sorted().compactMap { key -> (String, String, MetadataClient.CapabilityControl?)? in
            let control = attempt.controls?[key]
            guard let family = control?.wireFamily
                    ?? CapabilityEvidenceFacade.inputWireFamily(key: key, transport: attempt.transport) else { return nil }
            return (key, family, control)
        }
        let body = Data(rawBody.utf8)
        for (key, family, control) in carried {
            let wireProtocol = family.split(separator: ".").first.map(String.init) ?? family
            guard let signature = signatures.match(
                status: status, body: body, protocol: wireProtocol, wireFamilies: [family]
            ), signature.kind == "input_rejected", signature.capabilityKey == key else { continue }
            // The revision is the verdict as is (nil when the key is missing), the same value as on the read
            // side; otherwise the entry would be recorded but never read.
            let revision = CapabilityNegativeCache.verdictRevision(control.map {
                .init(state: $0.state, reasonCode: $0.reasonCode, wireFamily: $0.wireFamily, sourceRefs: $0.sourceRefs)
            })
            return Rejection(
                capabilityKey: key, signatureId: signature.signatureId, wireFamily: family,
                verdictRevision: revision
            )
        }
        return evaluateParameter(attempt, status: status, body: body, signatures: signatures)
    }

    /// Parameter signature branch: a protocol-level `param_rejected` hit means that parameter was rejected.
    private static func evaluateParameter(
        _ attempt: Attempt, status: Int, body: Data, signatures: InputRejectionSignatures
    ) -> Rejection? {
        guard let wireProtocol = attempt.transport
                .flatMap(TransportKind.init(rawValue:))
                .flatMap(CapabilityEvidenceFacade.protocolKey),
              let signature = signatures.match(status: status, body: body, protocol: wireProtocol),
              signature.kind == "param_rejected",
              let parameter = signature.parameter, !parameter.isEmpty else { return nil }
        return Rejection(
            capabilityKey: parameterCapabilityKey(parameter), signatureId: signature.signatureId,
            wireFamily: wireProtocol,
            verdictRevision: OfficialParameterGate.verdictRevision(
                parameterSupport: attempt.parameterSupport, name: parameter
            )
        )
    }

    /// On a hit, records a v2 negative-cache entry and returns the result; on a miss does nothing.
    @discardableResult
    static func record(
        _ attempt: Attempt,
        signatures: InputRejectionSignatures = .shared,
        negativeCache: CapabilityNegativeCache = .shared
    ) -> Rejection? {
        guard let rejection = evaluate(attempt, signatures: signatures) else { return nil }
        negativeCache.record(
            connectionId: attempt.connectionId, modelId: attempt.modelId, wireFamily: rejection.wireFamily,
            capabilityKey: rejection.capabilityKey, signatureId: rejection.signatureId,
            verdictRevision: rejection.verdictRevision
        )
        return rejection
    }
}
