import Foundation

/// Text fallback after the upstream rejects a native file block (only for routes whose mode is `.alwaysWithTextFallback`).
///
/// Subscription and Relay routes use the same native routing as official direct routes, but there is no
/// guarantee the other end accepts file blocks. When a request carried native file blocks and the upstream
/// answered 400 / 404 / 413 / 415 / 422 before producing any output, the route is temporarily treated as
/// having no native file blocks, the delivery decision is run again, and the request is resent once. If the
/// resend is accepted, the app remembers that this protocol on this connection does not take file blocks
/// (subscriptions keep it in memory for the process; a Relay records it in the local negative cache per
/// connection x model x protocol for 7 days, and only when the upstream refusal is classified as rejected)
/// and goes straight to text from then on, saving a round trip. If the resend also fails (including text that
/// does not fit), or none of the native files in the rejected request has extracted text (scanned documents),
/// there is no fallback and the first error is thrown. Only the status code is inspected, never the error message.
nonisolated enum NativeFileFallback {

    /// The connection and route of one send. With a nil `connectionID` (a call without connection context) the fallback still happens, it is just not remembered.
    struct Scope: Sendable {
        let transport: AttachmentTransport
        let connectionID: UUID?
        let providerKind: ProviderKind
        /// The protocol name used as part of the Relay negative cache key.
        let protocolName: String
        /// The model in the Relay negative cache key; other forms do not use it.
        var modelID: String? = nil
        /// Relay model-level file override: when `true` the `file` negative cache is not read and the native block is sent first as usual.
        var fileOverride: Bool? = nil

        /// The three protocols on a Relay that carry native file blocks.
        static func relayScope(
            _ transport: RelayTransport,
            connectionID: UUID?,
            modelID: String?,
            fileOverride: Bool? = nil
        ) -> Scope {
            Scope(
                transport: AttachmentTransportResolver.relay(transport),
                connectionID: connectionID,
                providerKind: .relay,
                protocolName: transport.rawValue,
                modelID: modelID,
                fileOverride: fileOverride
            )
        }

        static func codexSubscriptionScope(connectionID: UUID?) -> Scope {
            Scope(
                transport: .codexSubscription,
                connectionID: connectionID,
                providerKind: .openAI,
                protocolName: TransportKind.openaiResponses.rawValue
            )
        }

        static func grokSubscriptionScope(connectionID: UUID?) -> Scope {
            Scope(
                transport: .grokSubscription,
                connectionID: connectionID,
                providerKind: .grok,
                protocolName: TransportKind.openaiResponses.rawValue
            )
        }
    }

    static let fallbackStatusCodes: Set<Int> = [400, 404, 413, 415, 422]

    /// Record of one request attempt: which native files were carried, registered at build time, and the status code if the upstream rejects it.
    final class Attempt: @unchecked Sendable {
        let sendsTextOnly: Bool
        private let lock = NSLock()
        private var nativeFileCount = 0
        private var nativeFilesWithTextCount = 0
        private var rejectedStatusCode: Int?

        init(sendsTextOnly: Bool) { self.sendsTextOnly = sendsTextOnly }

        func recordNativeFiles(_ files: [Attachment]) {
            lock.lock(); defer { lock.unlock() }
            nativeFileCount += files.count
            nativeFilesWithTextCount += files.filter(NativeFileFallback.hasExtractedText).count
        }

        func recordRejection(statusCode: Int) {
            lock.lock(); defer { lock.unlock() }
            if rejectedStatusCode == nil { rejectedStatusCode = statusCode }
        }

        var firstRejectedStatusCode: Int? {
            lock.lock(); defer { lock.unlock() }
            return rejectedStatusCode
        }

        /// Whether the request of this attempt carried any native file block.
        var carriesNativeFiles: Bool {
            lock.lock(); defer { lock.unlock() }
            return nativeFileCount > 0
        }

        /// Whether this rejection is worth resending as text: the status code is in the fallback set and at least one of the native files sent has extracted text.
        var shouldRetryAsText: Bool {
            lock.lock(); defer { lock.unlock() }
            guard !sendsTextOnly, let rejectedStatusCode else { return false }
            return NativeFileFallback.fallbackStatusCodes.contains(rejectedStatusCode)
                && nativeFilesWithTextCount > 0
        }
    }

    @TaskLocal static var currentAttempt: Attempt?

    // MARK: - File rejection notice card

    /// Whether the first attempt of a message carried native file blocks. When the outer protocol fallback resends over another protocol this is not overwritten: the criterion looks only at the first attempt.
    final class FirstAttemptProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var carried: Bool?

        func record(carriedNativeFiles: Bool) {
            lock.lock(); defer { lock.unlock() }
            if carried == nil { carried = carriedNativeFiles }
        }

        var firstAttemptCarriedNativeFiles: Bool {
            lock.lock(); defer { lock.unlock() }
            return carried == true
        }
    }

    @TaskLocal static var firstAttemptProbe: FirstAttemptProbe?

    /// Whether a failed message should get the "these files are not supported" mark: only on the Relay form, when
    /// the first attempt carried native file blocks and the first refusal is a rejection signal (a 400 / 404 / 415 / 422
    /// before output). The caller asks only when the fallback chain finally fails; 413 is not a rejection signal,
    /// so it still falls back to text but gets no mark.
    static func marksRelayFileUnsupported(
        isRelay: Bool, firstAttemptCarriedNativeFiles: Bool, firstRejection: RelayPreOutputRejection?
    ) -> Bool {
        isRelay && firstAttemptCarriedNativeFiles && RelayRejectionRecording.isRejected(firstRejection)
    }

    // MARK: - Memory (in process)

    private struct ConnectionKey: Hashable {
        let connectionID: UUID
        let transport: AttachmentTransport
    }

    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var textOnlyConnections: Set<ConnectionKey> = []

    static func isKnownTextOnly(connectionID: UUID?, transport: AttachmentTransport) -> Bool {
        guard let connectionID else { return false }
        memoryLock.lock(); defer { memoryLock.unlock() }
        return textOnlyConnections.contains(ConnectionKey(connectionID: connectionID, transport: transport))
    }

    /// Relay form: the memory lives in the local negative cache (connection x model x protocol x `file`, 7 days) instead of the in-process connection x protocol memory.
    static func isKnownTextOnly(_ scope: Scope, negativeCache: RelayNegativeCache = .shared) -> Bool {
        guard scope.providerKind == .relay else {
            return isKnownTextOnly(connectionID: scope.connectionID, transport: scope.transport)
        }
        guard scope.fileOverride != true,
              let connectionID = scope.connectionID, let modelID = scope.modelID else { return false }
        return negativeCache.isRejected(
            connectionID: connectionID.uuidString, modelID: modelID,
            transport: scope.protocolName, kind: .file
        )
    }

    /// Only a refusal that "Test capabilities" classifies as rejected is written to the Relay negative cache; the fallback resend itself is unaffected.
    static func rememberTextOnly(
        _ scope: Scope,
        rejectedStatusCode: Int?,
        negativeCache: RelayNegativeCache = .shared,
        capabilityNegativeCache: CapabilityNegativeCache = .shared
    ) {
        if scope.providerKind == .relay {
            guard let connectionID = scope.connectionID, let modelID = scope.modelID,
                  let rejectedStatusCode,
                  RelayRejectionRecording.isRejected(RelayPreOutputRejection(
                      status: rejectedStatusCode, contentType: "application/json", body: Data()
                  )) else { return }
            negativeCache.record(
                connectionID: connectionID.uuidString, modelID: modelID,
                transport: scope.protocolName, kind: .file
            )
            // The v2 negative cache is written alongside: the read side (the facade's file_input projection) only looks at this one.
            if let transport = RelayTransport(rawValue: scope.protocolName),
               let family = CapabilityEvidenceProductionAdapter.relayWireFamily(
                   transport: transport, key: CapabilityEvidenceFacade.fileInputKey
               ) {
                capabilityNegativeCache.record(
                    connectionId: connectionID.uuidString, modelId: modelID, wireFamily: family,
                    capabilityKey: CapabilityEvidenceFacade.fileInputKey,
                    signatureId: "relay.classified_rejected",
                    verdictRevision: CapabilityNegativeCache.verdictRevision(
                        CapabilityEvidenceProductionAdapter.relayInputVerdict(
                            key: CapabilityEvidenceFacade.fileInputKey, visionEvidence: nil, wireFamily: family
                        )
                    )
                )
            }
            return
        }
        rememberTextOnly(scope)
    }

    private static func rememberTextOnly(_ scope: Scope) {
        guard let connectionID = scope.connectionID else { return }
        memoryLock.lock(); defer { memoryLock.unlock() }
        textOnlyConnections.insert(ConnectionKey(connectionID: connectionID, transport: scope.transport))
    }

    #if DEBUG
    static func resetMemoryForTesting() {
        memoryLock.lock(); defer { memoryLock.unlock() }
        textOnlyConnections.removeAll()
    }
    #endif

    /// For the pre-send check: when this connection is known not to accept file blocks, make the delivery decision as a text route.
    static func withKnownConnectionState<T>(
        connectionID: UUID?, transport: AttachmentTransport, relay: Scope? = nil, _ body: () -> T
    ) -> T {
        let known = relay.map { isKnownTextOnly($0) }
            ?? isKnownTextOnly(connectionID: connectionID, transport: transport)
        guard known else { return body() }
        return $currentAttempt.withValue(Attempt(sendsTextOnly: true), operation: body)
    }

    // MARK: - Delivery decision side

    /// The mode actually in effect for this route right now: `.off` while a text resend is under way or when this connection is known not to accept file blocks.
    static func effectiveMode(of profile: AttachmentTransportProfile) -> NativeFileMode {
        let mode = profile.effectiveNativeFiles
        guard mode == .alwaysWithTextFallback else { return mode }
        return currentAttempt?.sendsTextOnly == true ? .off : mode
    }

    static func hasExtractedText(_ attachment: Attachment) -> Bool {
        attachment.hasUsableExtractedText
    }

    // MARK: - Sending side

    /// Wraps the "build the request, send it and get the response headers" step. `send` may be called twice and must rebuild the request each time.
    static func run<T>(_ scope: Scope, send: () async throws -> T) async throws -> T {
        guard scope.transport.profile.effectiveNativeFiles == .alwaysWithTextFallback,
              currentAttempt == nil else {
            return try await send()
        }
        if isKnownTextOnly(scope) {
            firstAttemptProbe?.record(carriedNativeFiles: false)
            return try await $currentAttempt.withValue(Attempt(sendsTextOnly: true)) { try await send() }
        }
        let first = Attempt(sendsTextOnly: false)
        do {
            defer { firstAttemptProbe?.record(carriedNativeFiles: first.carriesNativeFiles) }
            return try await $currentAttempt.withValue(first) { try await send() }
        } catch let firstError {
            // The relay classified this as "this key has no access to the model": the problem is not the file block, so there is no text-fallback resend.
            let keyAccessDenied = scope.providerKind == .relay
                && RelayKeyAccess.classify(RelayPreOutputRejection.current?.rejection) == .modelAccessDenied
            guard first.shouldRetryAsText, !keyAccessDenied, !Task.isCancelled else { throw firstError }
            let result: T
            do {
                result = try await $currentAttempt.withValue(Attempt(sendsTextOnly: true)) { try await send() }
            } catch {
                // Even as text it did not go out (the upstream still refuses, or the text does not fit): the problem is not the file block, so show the first error.
                throw firstError
            }
            rememberTextOnly(scope, rejectedStatusCode: first.firstRejectedStatusCode)
            return result
        }
    }
}
