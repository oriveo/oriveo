import Foundation

/// Everything one BYOK image round needs. `params.n` 0 / nil means one image;
/// `maxPromptChars` comes from the profile (default 32000).
nonisolated struct StudioByokInput: Sendable {
    nonisolated struct Image: Equatable, Sendable {
        var slot: Int
        var role: String
        var mime: String
        var bytes: Data
    }

    var roundId: String
    var providerKind: String
    var apiKey: String
    var baseURL: String
    var modelId: String
    var profile: ImageProfile
    var operation: ImageProfile.Operation
    var prompt: String
    /// Style and effect fragments, passed to the prompt composer as they are.
    var styleFragment: String? = nil
    var effectFragments: [String] = []
    var params: ImageParamNormalizer.Request
    var advanced: ImageRequestBuilder.Advanced
    var images: [Image]
    /// Image library partition the delivered images are written to (nil = current session).
    var partitionUID: String?
}

/// Outcome of one round. `images` are already in the image library under their `id`.
nonisolated struct StudioByokResult: Equatable, Sendable {
    nonisolated struct Adjustments: Equatable, Sendable {
        var prompt: [StudioPromptComposer.Adjustment]
        var params: [ImageParamNormalizer.Adjustment]
    }

    nonisolated struct Image: Equatable, Sendable {
        var id: String
        var mime: String
        var width: Int
        var height: Int
        var revisedPrompt: String?
    }

    var status: StudioByokTasks.RoundStatus
    var errorKind: StudioImageErrorKind?
    var message: String?
    var mayBeBilled: Bool
    var retried: Bool
    var nRequested: Int
    var delivered: Int
    var composedPrompt: String?
    var adjustments: Adjustments
    var usage: StudioImageResponse.Usage?
    var images: [Image]
}

/// What one HTTP attempt produced: a reply (any status), a reply whose body exceeded the cap
/// and was not read (`byteCount` is its size), or an `NSURLErrorDomain` failure.
nonisolated enum StudioByokReply: Equatable, Sendable {
    case response(status: Int, body: Data)
    case oversized(status: Int, byteCount: Int)
    case failure(urlErrorCode: Int)
}

/// Sends built requests and downloads URL images. `jobId` is `<roundId>-b<batch>-a<attempt>`
/// (0-based); `timeoutSeconds` bounds the whole attempt; a reply body over `maxResponseBytes`
/// is not read into memory and comes back as `oversized`.
nonisolated protocol StudioByokTransport: Sendable {
    func send(
        _ request: ImageRequestBuilder.Request, jobId: String, timeoutSeconds: Int, maxResponseBytes: Int
    ) async -> StudioByokReply
    func fetchImage(_ url: URL, jobId: String, index: Int) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure>
}

/// Image library writes of delivered images. Never called on the main actor by the executor.
nonisolated protocol StudioByokImageSink: Sendable {
    func save(_ data: Data, id: String, partitionUID: String?) async throws
    func delete(id: String, partitionUID: String?) async
}

/// `ImageStore` backed sink: a save counts only when the file exists afterwards.
nonisolated struct StudioByokImageStoreSink: StudioByokImageSink {
    nonisolated struct SaveFailed: Error {}

    @concurrent
    func save(_ data: Data, id: String, partitionUID: String?) async throws {
        ImageStore.save(imageData: data, for: id, partitionUID: partitionUID)
        guard ImageStore.imageExists(for: id, partitionUID: partitionUID) else { throw SaveFailed() }
    }

    @concurrent
    func delete(id: String, partitionUID: String?) async {
        ImageStore.deleteImage(for: id, partitionUID: partitionUID)
    }
}

/// Runs one BYOK image round end to end: local checks, prompt composition, normalization,
/// reference budget, request build, send, classify, parse, URL fetch, assemble, aggregate,
/// then writes the images to the library. The cheap pure steps run on the main actor (the profile,
/// normalizer and builder types are main-actor isolated); reply decoding, reference shrinking and
/// library writes run off it.
struct StudioByokExecutor: Sendable {
    let transport: any StudioByokTransport
    let sink: any StudioByokImageSink

    init(transport: any StudioByokTransport, sink: any StudioByokImageSink = StudioByokImageStoreSink()) {
        self.transport = transport
        self.sink = sink
    }

    nonisolated static let defaultMaxPromptChars = 32000
    nonisolated static let messageLimit = 1000
    nonisolated static let referencesTooLarge = "references_too_large"
    nonisolated static let responseTooLarge = "response_too_large"
    /// Reply body cap of one batch: `batch` x 40 MiB + 1 MiB.
    nonisolated static let responseBytesPerImage = 41_943_040
    nonisolated static let responseBytesOverhead = 1_048_576

    nonisolated static func maxResponseBytes(batch: Int) -> Int {
        max(batch, 0) * responseBytesPerImage + responseBytesOverhead
    }

    /// Order: profile check → compose → normalize → reference fit (real shrink) → build every
    /// batch (its own n) → cancelled check → send the batches concurrently (one pre-connect
    /// retry each) → classify → parse → URL fetch → assemble → aggregate in batch order → store.
    /// Usage adds up across batches; cancelling the task drops every image.
    func run(_ input: StudioByokInput) async -> StudioByokResult {
        let profile = input.profile
        // 0 until normalization succeeds, then the sum of the batches.
        var nRequested = 0
        var adjustments = StudioByokResult.Adjustments(prompt: [], params: [])
        var composedPrompt: String?

        func finish(
            status: StudioByokTasks.RoundStatus,
            errorKind: StudioImageErrorKind?,
            message: String? = nil,
            mayBeBilled: Bool = false,
            retried: Bool = false,
            usage: StudioImageResponse.Usage? = nil,
            images: [StudioByokResult.Image] = []
        ) -> StudioByokResult {
            StudioByokResult(
                status: status, errorKind: errorKind, message: message, mayBeBilled: mayBeBilled,
                retried: retried, nRequested: nRequested, delivered: images.count,
                composedPrompt: composedPrompt, adjustments: adjustments, usage: usage, images: images
            )
        }
        func reject(_ message: String) -> StudioByokResult {
            finish(status: .failed, errorKind: .invalidParam, message: message)
        }

        guard profile.operations.contains(input.operation) else {
            return reject(ImageParamNormalizer.Failure.invalidProfile.rawValue)
        }

        let references = Self.sendOrder(input.images).enumerated().compactMap { offset, image in
            StudioPromptComposer.Role(rawValue: image.role).map { StudioPromptComposer.Reference(n: offset + 1, role: $0) }
        }
        let composition = StudioPromptComposer.compose(.v1, .init(
            userPrompt: input.prompt,
            references: references,
            styleFragment: input.styleFragment,
            effectFragments: input.effectFragments,
            maxPromptChars: profile.maxPromptChars ?? Self.defaultMaxPromptChars
        ))
        adjustments.prompt = composition.adjustments
        guard let composed = composition.composed else {
            return reject((composition.error ?? .promptTooLong).rawValue)
        }
        composedPrompt = composed

        let normalized: ImageParamNormalizer.Normalized
        switch ImageParamNormalizer.normalize(profile, request: input.params) {
        case .failure(let failure): return reject(failure.rawValue)
        case .success(let value): normalized = value
        }
        adjustments.params = normalized.adjustments
        nRequested = normalized.batches.reduce(0, +)

        let fit = await StudioReferenceBudget.fit(
            route: profile.route.rawValue,
            editTransport: profile.editTransport?.rawValue,
            prompt: composed,
            images: input.images,
            describe: { StudioReferenceBudget.Item(slot: $0.slot, role: $0.role, mime: $0.mime, byteCount: $0.bytes.count) },
            shrink: { image in
                guard let shrunk = await StudioReferenceShrinker.shrink(image.bytes, mime: image.mime) else { return nil }
                var copy = image
                copy.bytes = shrunk.data
                copy.mime = shrunk.mime
                return copy
            }
        )
        guard fit.status == .fits else { return reject(Self.referencesTooLarge) }

        let batches = normalized.batches
        var requests: [ImageRequestBuilder.Request] = []
        for batch in batches {
            var wire = normalized.wire
            if let nKey = profile.route.nBodyKey, wire[nKey] != nil {
                wire[nKey] = .integer(batch)
            }
            let built = ImageRequestBuilder.build(profile, input: .init(
                operation: input.operation,
                modelId: input.modelId,
                prompt: composed,
                wire: wire,
                images: fit.images.map { ImageRequestBuilder.Image(slot: $0.slot, role: $0.role, mime: $0.mime, data: $0.bytes) },
                advanced: input.advanced,
                baseUrl: input.baseURL,
                apiKey: input.apiKey
            ))
            switch built {
            case .failure(let failure): return reject(failure.rawValue)
            case .success(let value): requests.append(value)
            }
        }

        if Task.isCancelled { return finish(status: .cancelled, errorKind: nil) }

        let transport = self.transport
        let roundId = input.roundId
        let timeoutSeconds = StudioByokTasks.effectiveTimeoutSeconds(profile.timeoutSeconds)
        let outcomes: [BatchOutcome] = await withTaskGroup(of: (Int, BatchOutcome).self) { group in
            for (index, request) in requests.enumerated() {
                let batch = batches[index]
                group.addTask {
                    let outcome = await Self.runBatch(
                        request, index: index, batch: batch, roundId: roundId,
                        timeoutSeconds: timeoutSeconds, transport: transport
                    )
                    return (index, outcome)
                }
            }
            var collected = [BatchOutcome?](repeating: nil, count: requests.count)
            for await (index, outcome) in group {
                collected[index] = outcome
            }
            return collected.map { $0 ?? BatchOutcome(cancelled: true) }
        }

        let sent = outcomes.contains(where: \.sent)
        let billed = outcomes.contains(where: \.billed)
        let retried = outcomes.contains(where: \.retried)
        let usage = Self.sum(outcomes.map(\.decoded.usage))
        if Task.isCancelled {
            return finish(status: .cancelled, errorKind: nil, mayBeBilled: billed || sent, retried: retried, usage: usage)
        }

        let aggregate = StudioByokTasks.aggregate(
            n: nRequested, batches: batches, results: outcomes.map(\.decoded.batchResult), cancelled: false
        )
        let kept = zip(batches, outcomes).flatMap { batch, outcome in
            outcome.decoded.images.prefix(max(0, min(batch, outcome.decoded.batchResult.images)))
        }
        // The message belongs to the batch whose errorKind the aggregate picked (the first one
        // with an errorKind), never to a later batch.
        let message: String? = aggregate.status == .completed
            ? nil
            : outcomes.first(where: { $0.decoded.batchResult.errorKind != nil })
                .flatMap(\.decoded.message)
                .flatMap { $0.isEmpty ? nil : $0 }
        switch await Self.persist(kept, sink: sink, partitionUID: input.partitionUID) {
        case .cancelled:
            return finish(status: .cancelled, errorKind: nil, mayBeBilled: billed || sent, retried: retried, usage: usage)
        case .failed:
            // Every image is rolled back: no reply message, nothing delivered.
            return finish(status: .failed, errorKind: .storageFull, message: nil, mayBeBilled: billed, retried: retried, usage: usage)
        case .stored(let images):
            return finish(
                status: aggregate.status,
                errorKind: aggregate.errorKind,
                message: message,
                mayBeBilled: billed,
                retried: retried,
                usage: usage,
                images: images
            )
        }
    }

    /// What one batch's attempts produced. `sent`: a request may have left the device;
    /// `billed`: a 2xx reply or a failure the retry decision counts as possibly billed.
    nonisolated struct BatchOutcome: Sendable {
        var decoded = Decoded(batchResult: .init(images: 0, errorKind: .network))
        var sent = false
        var billed = false
        var retried = false
        var cancelled = false
    }

    /// Sends one batch; a pre-connect failure of the first attempt is retried once under the
    /// next attempt's job id. Only the task being cancelled ends the batch as cancelled; a transfer
    /// cancelled while the task is not fails the batch as network. A reply body over
    /// `maxResponseBytes(batch:)` fails the batch as upstream_error (`response_too_large`), sent and
    /// possibly billed whatever its status.
    @concurrent
    nonisolated private static func runBatch(
        _ request: ImageRequestBuilder.Request, index: Int, batch: Int, roundId: String,
        timeoutSeconds: Int, transport: any StudioByokTransport
    ) async -> BatchOutcome {
        var outcome = BatchOutcome()
        var attempt = 0
        let maxBytes = maxResponseBytes(batch: batch)
        func tooLarge() -> BatchOutcome {
            outcome.sent = true
            outcome.billed = true
            if attempt > 0 { outcome.retried = true }
            outcome.decoded = Decoded(batchResult: .init(images: 0, errorKind: .upstreamError), message: responseTooLarge)
            return outcome
        }
        while true {
            let jobId = "\(roundId)-b\(index)-a\(attempt)"
            let reply = await transport.send(request, jobId: jobId, timeoutSeconds: timeoutSeconds, maxResponseBytes: maxBytes)
            switch reply {
            case .oversized:
                return tooLarge()
            case .response(_, let body) where body.count > maxBytes:
                return tooLarge()
            case .failure(let urlErrorCode):
                let phase = StudioByokTasks.transportPhase(urlErrorCode: urlErrorCode)
                let decision = StudioByokTasks.retryDecision(phase: phase, attempt: attempt)
                if phase != .preConnect { outcome.sent = true }
                outcome.billed = outcome.billed || decision.mayBeBilled
                outcome.retried = outcome.retried || decision.retried
                if Task.isCancelled {
                    outcome.cancelled = true
                    return outcome
                }
                if phase == .cancelled {
                    // Cancelled by the system, not by the user: this batch fails, the request
                    // already left the device and may be billed, and it is not retried.
                    outcome.sent = true
                    outcome.billed = true
                    outcome.decoded.batchResult = .init(images: 0, errorKind: .network)
                    return outcome
                }
                if decision.retry {
                    attempt += 1
                    continue
                }
                outcome.decoded.batchResult = .init(images: 0, errorKind: decision.errorKind ?? .network)
                return outcome
            case .response(let status, let body):
                outcome.sent = true
                if (200...299).contains(status) { outcome.billed = true }
                if attempt > 0 { outcome.retried = true }
                outcome.decoded = await decode(status: status, body: body, batch: batch, jobId: jobId, transport: transport)
                return outcome
            }
        }
    }

    /// Field-by-field sum; a field stays nil when no batch reported it, nil when all are empty.
    nonisolated private static func sum(_ usages: [StudioImageResponse.Usage?]) -> StudioImageResponse.Usage? {
        func add(_ field: KeyPath<StudioImageResponse.Usage, Int?>) -> Int? {
            let values = usages.compactMap { $0?[keyPath: field] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let total = StudioImageResponse.Usage(
            inputTokens: add(\.inputTokens), outputTokens: add(\.outputTokens), totalTokens: add(\.totalTokens)
        )
        if total.inputTokens == nil, total.outputTokens == nil, total.totalTokens == nil { return nil }
        return total
    }

    /// What one reply of one batch turned into.
    nonisolated struct Decoded: Sendable {
        var batchResult: StudioByokTasks.BatchResult
        var message: String?
        var usage: StudioImageResponse.Usage?
        var images: [DecodedImage] = []
    }

    nonisolated struct DecodedImage: Sendable {
        var image: StudioImageResponse.Materialized
        var revisedPrompt: String?
    }

    /// classify → parse → materialize / fetch → assemble, off the main actor. Not ok / partial:
    /// 0 images and the reply text (first `messageLimit` characters) as the message.
    @concurrent
    nonisolated private static func decode(
        status: Int, body: Data, batch: Int, jobId: String, transport: any StudioByokTransport
    ) async -> Decoded {
        let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        let classifyBody: Any? = json ?? (body.isEmpty ? nil : String(decoding: body, as: UTF8.self))
        let kind = StudioImageErrorKind.classify(http: status, body: classifyBody, nRequested: batch)
        if let kind, kind != .partial {
            return Decoded(
                batchResult: .init(images: 0, errorKind: kind),
                message: String(String(decoding: body, as: UTF8.self).prefix(messageLimit))
            )
        }
        let parsed = StudioImageResponse.parse(json)
        var images: [DecodedImage] = []
        var outcomes: [StudioImageResponse.Outcome] = []
        for (index, image) in parsed.images.enumerated() {
            let result: Result<StudioImageResponse.Materialized, StudioImageResponse.Failure>
            if image.kind == .url {
                if let url = URL(string: image.value) {
                    result = await transport.fetchImage(url, jobId: jobId, index: index)
                } else {
                    result = .failure(.decodeFailed)
                }
            } else {
                result = await StudioImageResponse.materialize(image)
            }
            switch result {
            case .success(let materialized):
                images.append(DecodedImage(image: materialized, revisedPrompt: image.revisedPrompt))
                outcomes.append(.ok)
            case .failure(let failure):
                outcomes.append(.failed(failure))
            }
        }
        let assembly = StudioImageResponse.assemble(nRequested: batch, outcomes: outcomes)
        var errorKind = kind
        switch assembly.result {
        case .none:
            errorKind = .decodeFailed
        case .failed(let failure)?:
            errorKind = StudioImageErrorKind(rawValue: failure.rawValue) ?? .decodeFailed
        case .ok?, .partial?:
            break
        }
        return Decoded(
            batchResult: .init(images: assembly.delivered, errorKind: errorKind),
            usage: parsed.usage,
            images: images
        )
    }

    nonisolated enum Persisted: Sendable {
        case stored([StudioByokResult.Image])
        case failed
        case cancelled
    }

    /// Each image under a fresh UUID; a failed write, or the task being cancelled while
    /// writing, deletes every id written so far. Runs off the main actor.
    @concurrent
    nonisolated private static func persist(
        _ decoded: [DecodedImage], sink: any StudioByokImageSink, partitionUID: String?
    ) async -> Persisted {
        var images: [StudioByokResult.Image] = []
        var written: [String] = []
        func rollBack() async {
            for id in written {
                await sink.delete(id: id, partitionUID: partitionUID)
            }
        }
        for item in decoded {
            let id = UUID().uuidString
            written.append(id)
            do {
                try await sink.save(item.image.bytes, id: id, partitionUID: partitionUID)
            } catch {
                await rollBack()
                return Task.isCancelled ? .cancelled : .failed
            }
            if Task.isCancelled {
                await rollBack()
                return .cancelled
            }
            images.append(.init(
                id: id, mime: item.image.mime, width: item.image.width, height: item.image.height,
                revisedPrompt: item.revisedPrompt
            ))
        }
        return .stored(images)
    }

    /// The order `ImageRequestBuilder` sends images in: base first, then ascending slot; the
    /// prompt numbers references by this position.
    private static func sendOrder(_ images: [StudioByokInput.Image]) -> [StudioByokInput.Image] {
        images.enumerated().sorted { lhs, rhs in
            let lhsBase = lhs.element.role == StudioReferenceBudget.baseRole
            let rhsBase = rhs.element.role == StudioReferenceBudget.baseRole
            if lhsBase != rhsBase { return lhsBase }
            if lhs.element.slot != rhs.element.slot { return lhs.element.slot < rhs.element.slot }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
