import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Oriveo

/// BYOK executor main path, one attempt of the first batch: captured response samples of
/// `shared/model-contracts/image_response_samples.v1` run through a fake transport with real
/// images in place of the redacted base64; local rejects never send; a failed library write
/// rolls every image back.
@Suite("StudioByokExecutorTests")
struct StudioByokExecutorTests {
    typealias JSONValue = MetadataClient.JSONValue

    private struct BadFixture: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Fixtures

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func sampleFile(_ name: String) throws -> URL {
        try repoFile(["\u{5171}\u{4EAB}", "model-contracts", "image_response_samples.v1", name])
    }

    private static func jsonObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw BadFixture(description: "\(url.lastPathComponent) is not a JSON object")
        }
        return object
    }

    /// Profiles of image_param_normalization.v1.json, by name.
    private static func profileObjects() throws -> [String: [String: JSONValue]] {
        let url = try repoFile(["\u{5171}\u{4EAB}", "model-contracts", "image_param_normalization.v1.json"])
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)),
              case .object(let profiles)? = root["profiles"]
        else { throw BadFixture(description: "profiles missing") }
        return profiles.compactMapValues { value in
            if case .object(let object) = value { return object }
            return nil
        }
    }

    /// First profile (by name) on `route` that offers `operation`.
    private static func profile(route: String, operation: String) throws -> ImageProfile {
        let objects = try profileObjects()
        for name in objects.keys.sorted() {
            guard let object = objects[name], case .string(route)? = object["route"],
                  case .array(let operations)? = object["operations"],
                  operations.contains(where: { value in
                      if case .string(operation) = value { return true }
                      return false
                  })
            else { continue }
            guard case .success(let profile) = ImageProfileResolver.validate(object) else {
                throw BadFixture(description: "profile \(name) must validate")
            }
            return profile
        }
        throw BadFixture(description: "no profile for \(route) / \(operation)")
    }

    /// A real, decodable image of the given size and mime.
    private static func makeImage(width: Int, height: Int, mime: String) throws -> Data {
        let type: UTType
        switch mime {
        case "image/png": type = .png
        case "image/jpeg": type = .jpeg
        default: throw BadFixture(description: "cannot encode \(mime)")
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw BadFixture(description: "no bitmap context") }
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw BadFixture(description: "no image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw BadFixture(description: "no destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BadFixture(description: "encode failed") }
        return output as Data
    }

    /// The captured response with every `<base64 bytes=N ...>` placeholder of an observed image
    /// replaced by the base64 of `pictures[i]` (matched on N); other placeholders stay as captured.
    private static func patchedBody(_ response: Any, observed: [[String: Any]], pictures: [Data]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed])
        var text = String(decoding: data, as: UTF8.self)
        var byBytes: [Int: Int] = [:]
        for (index, image) in observed.enumerated() {
            if let bytes = image["bytes"] as? Int, byBytes[bytes] == nil { byBytes[bytes] = index }
        }
        let pattern = try NSRegularExpression(pattern: "<base64 bytes=([0-9]+) sha256=[0-9a-f]+>")
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text),
                  let bytes = Int(text[digits]), let index = byBytes[bytes]
            else { continue }
            text.replaceSubrange(whole, with: pictures[index].base64EncodedString())
        }
        return Data(text.utf8)
    }

    private static func reference(slot: Int = 1, role: String = "base") throws -> StudioByokInput.Image {
        StudioByokInput.Image(slot: slot, role: role, mime: "image/png", bytes: try makeImage(width: 64, height: 64, mime: "image/png"))
    }

    private static func input(
        _ profile: ImageProfile,
        operation: ImageProfile.Operation,
        n: Int = 1,
        prompt: String = "a red fox in fresh snow",
        aspect: String? = nil,
        modelId: String = "test-model",
        images: [StudioByokInput.Image] = []
    ) -> StudioByokInput {
        StudioByokInput(
            roundId: "round-1",
            providerKind: "openai",
            apiKey: "test-key",
            baseURL: "https://api.example.com/v1",
            modelId: modelId,
            profile: profile,
            operation: operation,
            prompt: prompt,
            params: ImageParamNormalizer.Request(aspect: aspect, n: n),
            advanced: ImageRequestBuilder.Advanced(),
            images: images,
            partitionUID: "test-partition"
        )
    }

    // MARK: - Fakes

    nonisolated final class FakeTransport: StudioByokTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let reply: StudioByokReply
        private let pictures: [Data]
        private var _jobIds: [String] = []
        private var _timeouts: [Int] = []
        private var _fetchIndices: [Int] = []
        private var _maxResponseBytes: [Int] = []

        init(reply: StudioByokReply, pictures: [Data] = []) {
            self.reply = reply
            self.pictures = pictures
        }

        var jobIds: [String] { lock.withLock { _jobIds } }
        var timeouts: [Int] { lock.withLock { _timeouts } }
        var fetchIndices: [Int] { lock.withLock { _fetchIndices } }
        var maxResponseBytes: [Int] { lock.withLock { _maxResponseBytes } }

        func send(
            _ request: ImageRequestBuilder.Request, jobId: String, timeoutSeconds: Int, maxResponseBytes: Int
        ) async -> StudioByokReply {
            lock.withLock {
                _jobIds.append(jobId)
                _timeouts.append(timeoutSeconds)
                _maxResponseBytes.append(maxResponseBytes)
            }
            return reply
        }

        func fetchImage(_ url: URL, jobId: String, index: Int) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
            lock.withLock { _fetchIndices.append(index) }
            guard pictures.indices.contains(index) else { return .failure(.network) }
            return StudioImageResponse.materialized(pictures[index])
        }
    }

    nonisolated final class FakeSink: StudioByokImageSink, @unchecked Sendable {
        nonisolated struct Full: Error {}

        private let lock = NSLock()
        private let failAt: Int?
        private let cancelAt: Int?
        private var _saves: [String] = []
        private var _deletes: [String] = []
        private var _stored: [String: Data] = [:]
        private var _savedOnMain = false

        /// `cancelAt`: the save at that index succeeds and then cancels the calling task.
        init(failAt: Int? = nil, cancelAt: Int? = nil) {
            self.failAt = failAt
            self.cancelAt = cancelAt
        }

        var saves: [String] { lock.withLock { _saves } }
        var deletes: [String] { lock.withLock { _deletes } }
        var stored: [String: Data] { lock.withLock { _stored } }
        var savedOnMain: Bool { lock.withLock { _savedOnMain } }

        func save(_ data: Data, id: String, partitionUID: String?) async throws {
            let onMain = pthread_main_np() != 0
            let (failed, cancel): (Bool, Bool) = lock.withLock {
                _savedOnMain = _savedOnMain || onMain
                let index = _saves.count
                _saves.append(id)
                if index == failAt { return (true, false) }
                _stored[id] = data
                return (false, index == cancelAt)
            }
            if failed { throw Full() }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        }

        func delete(id: String, partitionUID: String?) async {
            lock.withLock {
                _deletes.append(id)
                _stored[id] = nil
            }
        }
    }

    /// Replies per (batch, attempt) parsed from the job id; records every request and announces
    /// each job id on `started` as it is sent.
    nonisolated final class ScriptedTransport: StudioByokTransport, @unchecked Sendable {
        typealias Script = @Sendable (_ batch: Int, _ attempt: Int) async -> StudioByokReply

        private let lock = NSLock()
        private let script: Script
        private var _jobIds: [String] = []
        private var _requests: [String: ImageRequestBuilder.Request] = [:]
        private let started: AsyncStream<String>
        private let startedContinuation: AsyncStream<String>.Continuation

        init(_ script: @escaping Script) {
            self.script = script
            (started, startedContinuation) = AsyncStream.makeStream(of: String.self)
        }

        var jobIds: [String] { lock.withLock { _jobIds } }
        var requests: [String: ImageRequestBuilder.Request] { lock.withLock { _requests } }

        func send(
            _ request: ImageRequestBuilder.Request, jobId: String, timeoutSeconds: Int, maxResponseBytes: Int
        ) async -> StudioByokReply {
            let parts = jobId.split(separator: "-")
            let batch = parts.count >= 2 ? Int(parts[parts.count - 2].dropFirst()) ?? -1 : -1
            let attempt = parts.last.flatMap { Int($0.dropFirst()) } ?? -1
            lock.withLock {
                _jobIds.append(jobId)
                _requests[jobId] = request
            }
            startedContinuation.yield(jobId)
            return await script(batch, attempt)
        }

        func fetchImage(_ url: URL, jobId: String, index: Int) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
            .failure(.network)
        }

        /// True once `jobId` was sent, false after `seconds` without it. Call once per transport.
        func waitStarted(_ jobId: String, seconds: Double) async -> Bool {
            let stream = started
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await job in stream where job == jobId { return true }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(seconds))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }
    }

    /// A 2xx `data[].b64_json` reply with the given images and an optional `usage` object.
    private static func okBody(_ pictures: [Data], usage: [String: Int]? = nil) throws -> Data {
        var reply: [String: Any] = ["data": pictures.map { ["b64_json": $0.base64EncodedString()] }]
        if let usage { reply["usage"] = usage }
        return try JSONSerialization.data(withJSONObject: reply)
    }

    /// The `n` (or `parameters.n`) a built JSON request carries.
    private static func wireN(_ request: ImageRequestBuilder.Request?) -> Int? {
        guard let request, case .json(let body) = request.body else { return nil }
        if case .number(let value)? = body["n"] { return Int(value) }
        if case .object(let parameters)? = body["parameters"], case .number(let value)? = parameters["n"] {
            return Int(value)
        }
        return nil
    }

    private static func withMaxPerCall(_ profile: ImageProfile, _ maxNPerCall: Int) -> ImageProfile {
        var copy = profile
        copy.maxNPerCall = maxNPerCall
        return copy
    }

    private static let preConnectCode = URLError.Code.cannotConnectToHost.rawValue
    private static let afterSendCode = URLError.Code.networkConnectionLost.rawValue
    private static let timeoutCode = URLError.Code.timedOut.rawValue
    private static let cancelledCode = URLError.Code.cancelled.rawValue

    // MARK: - Tests

    @Test("goldenSamplesDeliverDecodedImages: every captured sample runs the whole chain and stores the decoded images")
    func goldenSamplesDeliverDecodedImages() async throws {
        let index = try Self.jsonObject(Self.sampleFile("index.json"))
        let samples = try #require(index["samples"] as? [[String: Any]])
        #expect(!samples.isEmpty)
        var ran = 0
        for sample in samples {
            let file = try #require(sample["file"] as? String)
            let route = try #require(sample["route"] as? String)
            let operationName = try #require(sample["operation"] as? String)
            let operation = try #require(ImageProfile.Operation(rawValue: operationName), "\(file) operation")
            let nRequested = try #require(sample["nRequested"] as? Int)
            let expect = try #require(sample["expect"] as? [String: Any])
            let expectedResult = try #require(expect["result"] as? String)
            let expectedKinds = (expect["images"] as? [[String: Any]] ?? []).map { $0["kind"] as? String }

            let raw = try Self.jsonObject(Self.sampleFile(file))
            let http = try #require((raw["meta"] as? [String: Any])?["http"] as? Int, "\(file) meta.http")
            let observed = try #require((raw["observed"] as? [String: Any])?["images"] as? [[String: Any]])
            let pictures = try observed.map { image in
                try Self.makeImage(
                    width: try #require(image["width"] as? Int),
                    height: try #require(image["height"] as? Int),
                    mime: try #require(image["mime"] as? String)
                )
            }
            let body = try Self.patchedBody(try #require(raw["response"]), observed: observed, pictures: pictures)
            let profile = try Self.profile(route: route, operation: operationName)
            let references = operation == .edit ? [try Self.reference()] : []

            let transport = FakeTransport(reply: .response(status: http, body: body), pictures: pictures)
            let sink = FakeSink()
            let result = await StudioByokExecutor(transport: transport, sink: sink)
                .run(Self.input(profile, operation: operation, n: nRequested, images: references))

            #expect(transport.jobIds == ["round-1-b0-a0"], "\(file) one request for the first batch")
            #expect(transport.timeouts == [StudioByokTasks.effectiveTimeoutSeconds(profile.timeoutSeconds)], "\(file) timeout")
            #expect(result.nRequested == nRequested, "\(file) nRequested")
            #expect(result.retried == false, "\(file) retried")
            #expect(result.composedPrompt?.hasPrefix("a red fox in fresh snow") == true, "\(file) composed prompt")
            let urlIndices = expectedKinds.enumerated().compactMap { $0.element == "url" ? $0.offset : nil }
            #expect(transport.fetchIndices == urlIndices, "\(file) URL images go through fetchImage")

            if expectedResult == "ok" {
                #expect(result.status == .completed, "\(file) status")
                #expect(result.errorKind == nil, "\(file) errorKind")
                #expect(result.message == nil, "\(file) message")
                #expect(result.mayBeBilled, "\(file) a 2xx reply may be billed")
                #expect(result.delivered == nRequested, "\(file) delivered")
                #expect(result.images.count == nRequested, "\(file) image count")
                for (offset, image) in result.images.enumerated() {
                    let want = observed[offset]
                    #expect(image.width == want["width"] as? Int, "\(file) width")
                    #expect(image.height == want["height"] as? Int, "\(file) height")
                    #expect(image.mime == want["mime"] as? String, "\(file) mime")
                    let stored = try #require(sink.stored[image.id], "\(file) image stored under its id")
                    #expect(StudioImageResponse.decodeImageInfo(stored)?.mime == image.mime, "\(file) stored bytes")
                    #expect(UUID(uuidString: image.id) != nil, "\(file) id is a UUID")
                }
                #expect(sink.saves == result.images.map(\.id), "\(file) sink got every image once")
                #expect(sink.deletes.isEmpty, "\(file) nothing rolled back")
            } else {
                #expect(result.status == .failed, "\(file) status")
                #expect(result.errorKind?.rawValue == expectedResult, "\(file) errorKind")
                #expect(result.delivered == 0, "\(file) delivered")
                #expect(result.images.isEmpty, "\(file) images")
                #expect(result.mayBeBilled == (200...299).contains(http), "\(file) mayBeBilled")
                #expect(result.message == String(String(decoding: body, as: UTF8.self).prefix(1000)), "\(file) message")
                #expect(sink.saves.isEmpty, "\(file) nothing stored")
            }
            ran += 1
        }
        #expect(ran == samples.count, "every sample must actually run")
    }

    @Test("localRejectsDoNotSend: local checks fail as invalid_param with the reason name and never send")
    func localRejectsDoNotSend() async throws {
        let minimax = try Self.profile(route: "minimax_image_generation", operation: "generate")
        let openai = try Self.profile(route: "openai_images", operation: "generate")
        var shortPrompt = openai
        shortPrompt.maxPromptChars = 10
        let dashscope = try Self.profile(route: "dashscope_multimodal", operation: "edit")
        let oversized = StudioByokInput.Image(slot: 1, role: "base", mime: "image/png", bytes: Data(count: 10_000_001))

        // nRequested stays 0 for rejects before normalization and is the batch sum after it.
        let cases: [(name: String, input: StudioByokInput, message: String, nRequested: Int)] = [
            ("operation outside the profile", Self.input(minimax, operation: .edit, images: [try Self.reference()]), "invalid_profile", 0),
            ("prompt over maxPromptChars", Self.input(shortPrompt, operation: .generate), "prompt_too_long", 0),
            ("aspect outside its closed set", Self.input(openai, operation: .generate, aspect: "wide"), "invalid_request", 0),
            ("reference that cannot shrink under the limit", Self.input(dashscope, operation: .edit, images: [oversized]), "references_too_large", 1),
            ("blank model id", Self.input(openai, operation: .generate, modelId: "   "), "invalid_request", 1),
        ]
        for testCase in cases {
            let transport = FakeTransport(reply: .response(status: 200, body: Data("{}".utf8)))
            let sink = FakeSink()
            let result = await StudioByokExecutor(transport: transport, sink: sink).run(testCase.input)
            #expect(result.status == .failed, "\(testCase.name) status")
            #expect(result.errorKind == .invalidParam, "\(testCase.name) errorKind")
            #expect(result.message == testCase.message, "\(testCase.name) message")
            #expect(result.mayBeBilled == false, "\(testCase.name) mayBeBilled")
            #expect(result.retried == false, "\(testCase.name) retried")
            #expect(result.delivered == 0, "\(testCase.name) delivered")
            #expect(result.nRequested == testCase.nRequested, "\(testCase.name) nRequested")
            #expect(result.images.isEmpty, "\(testCase.name) images")
            #expect(transport.jobIds.isEmpty, "\(testCase.name) must not send")
            #expect(sink.saves.isEmpty, "\(testCase.name) must not store")
        }
    }

    @Test("persistFailureRollsBack: one failed library write deletes every image and fails as storage_full")
    func persistFailureRollsBack() async throws {
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let first = try Self.makeImage(width: 32, height: 16, mime: "image/png")
        let second = try Self.makeImage(width: 16, height: 32, mime: "image/jpeg")
        let reply: [String: Any] = ["data": [["b64_json": first.base64EncodedString()], ["b64_json": second.base64EncodedString()]]]
        let body = try JSONSerialization.data(withJSONObject: reply)

        let healthySink = FakeSink()
        let healthy = await StudioByokExecutor(
            transport: FakeTransport(reply: .response(status: 200, body: body)), sink: healthySink
        ).run(Self.input(profile, operation: .generate, n: 2))
        #expect(healthy.status == .completed)
        #expect(healthy.images.map(\.mime) == ["image/png", "image/jpeg"])
        #expect(Set(healthy.images.map(\.id)).count == 2, "every image gets its own id")
        #expect(Set(healthySink.stored.keys) == Set(healthy.images.map(\.id)))
        #expect(healthySink.savedOnMain == false, "library writes stay off the main thread")

        let sink = FakeSink(failAt: 1)
        let result = await StudioByokExecutor(
            transport: FakeTransport(reply: .response(status: 200, body: body)), sink: sink
        ).run(Self.input(profile, operation: .generate, n: 2))
        #expect(result.status == .failed)
        #expect(result.errorKind == .storageFull)
        #expect(result.message == nil, "a storage failure carries no reply message")
        #expect(result.images.isEmpty)
        #expect(result.delivered == 0)
        #expect(result.mayBeBilled, "the reply was 2xx")
        #expect(sink.saves.count == 2)
        #expect(sink.saves.first.map(sink.deletes.contains) == true, "the image already written is rolled back")
        #expect(sink.stored.isEmpty, "nothing stays in the library")
    }

    @Test("batchesRewriteN: every batch sends its own n, runs concurrently and keeps batch order")
    func batchesRewriteN() async throws {
        let openai = Self.withMaxPerCall(try Self.profile(route: "openai_images", operation: "generate"), 2)
        var bodies: [Int: Data] = [:]
        for batch in 0..<3 {
            bodies[batch] = try Self.okBody(try (0..<3).map { offset in
                try Self.makeImage(width: 16 + batch, height: 8 + offset, mime: "image/png")
            })
        }
        let replies = bodies
        let transport = ScriptedTransport { batch, _ in
            // The first batch answers last; the result must still list it first.
            if batch == 0 { try? await Task.sleep(for: .milliseconds(200)) }
            return .response(status: 200, body: replies[batch] ?? Data())
        }
        let sink = FakeSink()
        var input = Self.input(openai, operation: .generate, n: 5)
        input.styleFragment = "watercolor wash"
        input.effectFragments = ["soft rim light"]
        let result = await StudioByokExecutor(transport: transport, sink: sink).run(input)

        #expect(transport.jobIds.sorted() == ["round-1-b0-a0", "round-1-b1-a0", "round-1-b2-a0"])
        let requests = transport.requests
        #expect(["round-1-b0-a0", "round-1-b1-a0", "round-1-b2-a0"].map { Self.wireN(requests[$0]) } == [2, 2, 1])
        #expect(result.status == .completed)
        #expect(result.errorKind == nil)
        #expect(result.nRequested == 5)
        #expect(result.delivered == 5)
        #expect(result.images.map(\.width) == [16, 16, 17, 17, 18], "each batch cut to its size, in batch order")
        #expect(result.images.map(\.height) == [8, 9, 8, 9, 8])
        #expect(sink.saves == result.images.map(\.id))
        #expect(result.composedPrompt?.contains("watercolor wash") == true, "style fragment reaches the composer")
        #expect(result.composedPrompt?.contains("soft rim light") == true, "effect fragments reach the composer")

        let dashscope = Self.withMaxPerCall(try Self.profile(route: "dashscope_multimodal", operation: "edit"), 2)
        let nested = ScriptedTransport { _, _ in .response(status: 200, body: replies[0] ?? Data()) }
        _ = await StudioByokExecutor(transport: nested, sink: FakeSink())
            .run(Self.input(dashscope, operation: .edit, n: 3, images: [try Self.reference()]))
        let nestedRequests = nested.requests
        #expect(nested.jobIds.sorted() == ["round-1-b0-a0", "round-1-b1-a0"])
        #expect(["round-1-b0-a0", "round-1-b1-a0"].map { Self.wireN(nestedRequests[$0]) } == [2, 1], "parameters.n per batch")
    }

    @Test("preConnectRetriedOnce: a pre-connect failure of the first attempt retries once under a new job id")
    func preConnectRetriedOnce() async throws {
        #expect(StudioByokTasks.transportPhase(urlErrorCode: Self.preConnectCode) == .preConnect)
        #expect(StudioByokTasks.transportPhase(urlErrorCode: Self.afterSendCode) == .afterSend)
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let body = try Self.okBody([try Self.makeImage(width: 24, height: 12, mime: "image/png")])
        let preConnect = Self.preConnectCode
        let afterSend = Self.afterSendCode

        let recovering = ScriptedTransport { _, attempt in
            attempt == 0 ? .failure(urlErrorCode: preConnect) : .response(status: 200, body: body)
        }
        let sink = FakeSink()
        let recovered = await StudioByokExecutor(transport: recovering, sink: sink).run(Self.input(profile, operation: .generate))
        #expect(recovering.jobIds == ["round-1-b0-a0", "round-1-b0-a1"])
        #expect(recovered.status == .completed)
        #expect(recovered.errorKind == nil)
        #expect(recovered.delivered == 1)
        #expect(recovered.retried, "the second attempt got a reply")
        #expect(recovered.mayBeBilled, "the second attempt was 2xx")
        #expect(sink.saves == recovered.images.map(\.id))

        let offline = ScriptedTransport { _, _ in .failure(urlErrorCode: preConnect) }
        let offlineSink = FakeSink()
        let failed = await StudioByokExecutor(transport: offline, sink: offlineSink).run(Self.input(profile, operation: .generate))
        #expect(offline.jobIds == ["round-1-b0-a0", "round-1-b0-a1"], "only the first attempt is retried")
        #expect(failed.status == .failed)
        #expect(failed.errorKind == .network)
        #expect(failed.mayBeBilled == false, "nothing left the device")
        #expect(failed.retried)
        #expect(failed.delivered == 0)
        #expect(offlineSink.saves.isEmpty)

        let lost = ScriptedTransport { _, attempt in .failure(urlErrorCode: attempt == 0 ? preConnect : afterSend) }
        let lostResult = await StudioByokExecutor(transport: lost, sink: FakeSink()).run(Self.input(profile, operation: .generate))
        #expect(lost.jobIds == ["round-1-b0-a0", "round-1-b0-a1"])
        #expect(lostResult.status == .failed)
        #expect(lostResult.errorKind == .network)
        #expect(lostResult.mayBeBilled, "the retry failed after sending")
        #expect(lostResult.retried)
    }

    @Test("afterSendNotRetried: after-send and timeout failures are not retried and may be billed")
    func afterSendNotRetried() async throws {
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        for (code, kind) in [(Self.afterSendCode, StudioImageErrorKind.network), (Self.timeoutCode, .timeout)] {
            let transport = ScriptedTransport { _, _ in .failure(urlErrorCode: code) }
            let sink = FakeSink()
            let result = await StudioByokExecutor(transport: transport, sink: sink).run(Self.input(profile, operation: .generate))
            #expect(transport.jobIds == ["round-1-b0-a0"], "code \(code) is not retried")
            #expect(result.status == .failed, "code \(code) status")
            #expect(result.errorKind == kind, "code \(code) errorKind")
            #expect(result.mayBeBilled, "code \(code) may be billed")
            #expect(result.retried == false, "code \(code) retried")
            #expect(result.images.isEmpty, "code \(code) images")
            #expect(sink.saves.isEmpty, "code \(code) nothing stored")
        }

        let single = Self.withMaxPerCall(profile, 1)
        let body = try Self.okBody([try Self.makeImage(width: 20, height: 10, mime: "image/png")])
        let afterSend = Self.afterSendCode
        let transport = ScriptedTransport { batch, _ in
            batch == 0 ? .response(status: 200, body: body) : .failure(urlErrorCode: afterSend)
        }
        let sink = FakeSink()
        let result = await StudioByokExecutor(transport: transport, sink: sink).run(Self.input(single, operation: .generate, n: 2))
        #expect(transport.jobIds.sorted() == ["round-1-b0-a0", "round-1-b1-a0"])
        #expect(result.status == .partial)
        #expect(result.errorKind == .network)
        #expect(result.delivered == 1)
        #expect(result.nRequested == 2)
        #expect(result.mayBeBilled)
        #expect(result.retried == false)
        #expect(result.images.map(\.width) == [20])
        #expect(sink.saves == result.images.map(\.id))
    }

    @Test("cancelDropsImages: cancelling the round sends nothing when early, stops the transport when running and rolls back written images")
    func cancelDropsImages() async throws {
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let body = try Self.okBody([try Self.makeImage(width: 20, height: 10, mime: "image/png")])

        let early = ScriptedTransport { _, _ in .response(status: 200, body: body) }
        let earlySink = FakeSink()
        let earlyExecutor = StudioByokExecutor(transport: early, sink: earlySink)
        let earlyInput = Self.input(profile, operation: .generate)
        let earlyResult = await Task { () -> StudioByokResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await earlyExecutor.run(earlyInput)
        }.value
        #expect(earlyResult.status == .cancelled)
        #expect(earlyResult.errorKind == nil)
        #expect(earlyResult.mayBeBilled == false)
        #expect(earlyResult.delivered == 0)
        #expect(earlyResult.images.isEmpty)
        #expect(early.jobIds.isEmpty, "a round cancelled before sending sends nothing")
        #expect(earlySink.saves.isEmpty)

        let cancelled = Self.cancelledCode
        let running = ScriptedTransport { batch, _ in
            if batch == 0 { return .response(status: 200, body: body) }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .failure(urlErrorCode: cancelled)
            }
            return .response(status: 500, body: Data())
        }
        let runningSink = FakeSink()
        let runningExecutor = StudioByokExecutor(transport: running, sink: runningSink)
        let runningInput = Self.input(Self.withMaxPerCall(profile, 1), operation: .generate, n: 2)
        let task = Task { await runningExecutor.run(runningInput) }
        let started = await running.waitStarted("round-1-b1-a0", seconds: 10)
        #expect(started, "the second batch must be in flight before cancelling")
        task.cancel()
        let runningResult = await task.value
        #expect(runningResult.status == .cancelled)
        #expect(runningResult.errorKind == nil)
        #expect(runningResult.mayBeBilled, "the requests already left the device")
        #expect(runningResult.delivered == 0)
        #expect(runningResult.images.isEmpty)
        #expect(runningSink.saves.isEmpty, "a cancelled round stores nothing")

        let two = try Self.okBody([
            try Self.makeImage(width: 20, height: 10, mime: "image/png"),
            try Self.makeImage(width: 10, height: 20, mime: "image/png"),
        ])
        let writing = ScriptedTransport { _, _ in .response(status: 200, body: two) }
        let writingSink = FakeSink(cancelAt: 0)
        let writingExecutor = StudioByokExecutor(transport: writing, sink: writingSink)
        let writingInput = Self.input(profile, operation: .generate, n: 2)
        let writingResult = await Task { await writingExecutor.run(writingInput) }.value
        #expect(writingResult.status == .cancelled)
        #expect(writingResult.errorKind == nil)
        #expect(writingResult.mayBeBilled)
        #expect(writingResult.delivered == 0)
        #expect(writingResult.images.isEmpty)
        #expect(!writingSink.saves.isEmpty)
        #expect(writingSink.saves.allSatisfy(writingSink.deletes.contains), "every written image is rolled back")
        #expect(writingSink.stored.isEmpty, "nothing stays in the library")
    }

    @Test("transportCancelWithoutUserCancelFailsBatch: a transfer cancelled while the round is not fails only that batch as network")
    func transportCancelWithoutUserCancelFailsBatch() async throws {
        #expect(StudioByokTasks.transportPhase(urlErrorCode: Self.cancelledCode) == .cancelled)
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let cancelled = Self.cancelledCode

        let lone = ScriptedTransport { _, _ in .failure(urlErrorCode: cancelled) }
        let loneSink = FakeSink()
        let loneResult = await StudioByokExecutor(transport: lone, sink: loneSink).run(Self.input(profile, operation: .generate))
        #expect(lone.jobIds == ["round-1-b0-a0"], "a system-cancelled transfer is not retried")
        #expect(loneResult.status == .failed)
        #expect(loneResult.errorKind == .network)
        #expect(loneResult.mayBeBilled, "the request already left the device")
        #expect(loneResult.retried == false)
        #expect(loneResult.delivered == 0)
        #expect(loneSink.saves.isEmpty)

        let body = try Self.okBody([try Self.makeImage(width: 20, height: 10, mime: "image/png")])
        let mixed = ScriptedTransport { batch, _ in
            batch == 0 ? .response(status: 200, body: body) : .failure(urlErrorCode: cancelled)
        }
        let sink = FakeSink()
        let result = await StudioByokExecutor(transport: mixed, sink: sink)
            .run(Self.input(Self.withMaxPerCall(profile, 1), operation: .generate, n: 2))
        #expect(mixed.jobIds.sorted() == ["round-1-b0-a0", "round-1-b1-a0"])
        #expect(result.status == .partial, "the other batches still count")
        #expect(result.errorKind == .network)
        #expect(result.delivered == 1)
        #expect(result.mayBeBilled)
        #expect(result.retried == false)
        #expect(result.images.map(\.width) == [20])
        #expect(sink.saves == result.images.map(\.id))
    }

    @Test("usageSummed: usage adds up field by field across batches and the first batch message explains a partial round")
    func usageSummed() async throws {
        let single = Self.withMaxPerCall(try Self.profile(route: "openai_images", operation: "generate"), 1)
        let picture = try Self.makeImage(width: 20, height: 10, mime: "image/png")
        let errorText = #"{"error":{"message":"bad size","type":"invalid_request_error"}}"#
        let errorBody = Data(errorText.utf8)
        let replies: [Int: StudioByokReply] = [
            0: .response(status: 200, body: try Self.okBody([picture], usage: ["input_tokens": 10, "output_tokens": 20, "total_tokens": 30])),
            1: .response(status: 200, body: try Self.okBody([picture], usage: ["prompt_tokens": 1, "total_tokens": 4])),
            2: .response(status: 400, body: errorBody),
        ]
        let transport = ScriptedTransport { batch, _ in replies[batch] ?? .failure(urlErrorCode: -1) }
        let result = await StudioByokExecutor(transport: transport, sink: FakeSink()).run(Self.input(single, operation: .generate, n: 3))
        let expectedKind = StudioImageErrorKind.classify(
            http: 400, body: try JSONSerialization.jsonObject(with: errorBody), nRequested: 1
        )
        #expect(result.status == .partial)
        #expect(result.delivered == 2)
        #expect(result.errorKind == expectedKind)
        #expect(result.usage == StudioImageResponse.Usage(inputTokens: 11, outputTokens: 20, totalTokens: 34))
        #expect(result.message == errorText, "first non-empty batch message")

        let plain = try Self.okBody([picture])
        let withOutput = try Self.okBody([picture], usage: ["output_tokens": 5])
        let late = ScriptedTransport { batch, _ in .response(status: 200, body: batch == 1 ? withOutput : plain) }
        let lateResult = await StudioByokExecutor(transport: late, sink: FakeSink()).run(Self.input(single, operation: .generate, n: 2))
        #expect(lateResult.status == .completed)
        #expect(lateResult.usage == StudioImageResponse.Usage(inputTokens: nil, outputTokens: 5, totalTokens: nil))
        #expect(lateResult.message == nil)

        let none = ScriptedTransport { _, _ in .response(status: 200, body: plain) }
        let noneResult = await StudioByokExecutor(transport: none, sink: FakeSink()).run(Self.input(single, operation: .generate, n: 2))
        #expect(noneResult.status == .completed)
        #expect(noneResult.usage == nil, "no batch reported usage")
    }

    @Test("messageFromErrorKindBatch: the message comes from the batch whose errorKind the aggregate picked")
    func messageFromErrorKindBatch() async throws {
        let single = Self.withMaxPerCall(try Self.profile(route: "openai_images", operation: "generate"), 1)
        // Batch 0: a 2xx reply whose only image does not decode (decode_failed, no message).
        let undecodable = Data(#"{"data":[{"b64_json":"AAAA"}]}"#.utf8)
        // Batch 1: an HTTP 400 with a reply text.
        let errorBody = Data(#"{"error":{"message":"bad size","type":"invalid_request_error"}}"#.utf8)
        let transport = ScriptedTransport { batch, _ in
            batch == 0 ? .response(status: 200, body: undecodable) : .response(status: 400, body: errorBody)
        }
        let result = await StudioByokExecutor(transport: transport, sink: FakeSink())
            .run(Self.input(single, operation: .generate, n: 2))
        #expect(transport.jobIds.sorted() == ["round-1-b0-a0", "round-1-b1-a0"])
        #expect(result.status == .failed)
        #expect(result.errorKind == .decodeFailed, "the first batch with an errorKind wins")
        #expect(result.message == nil, "batch 0 has no message; batch 1's text must not leak in")
        #expect(result.nRequested == 2)
        #expect(result.delivered == 0)
    }

    @Test("responseTooLargeIsUpstreamError: a reply over batch x 40 MiB + 1 MiB fails that batch as upstream_error and may be billed")
    func responseTooLargeIsUpstreamError() async throws {
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let cap = 1 * 41_943_040 + 1_048_576
        for status in [200, 400] {
            let transport = FakeTransport(reply: .response(status: status, body: Data(count: cap + 1)))
            let sink = FakeSink()
            let result = await StudioByokExecutor(transport: transport, sink: sink).run(Self.input(profile, operation: .generate))
            #expect(transport.jobIds == ["round-1-b0-a0"], "HTTP \(status) not retried")
            #expect(transport.maxResponseBytes == [cap], "HTTP \(status) the cap reaches the transport")
            #expect(result.status == .failed, "HTTP \(status) status")
            #expect(result.errorKind == .upstreamError, "HTTP \(status) errorKind")
            #expect(result.message == "response_too_large", "HTTP \(status) message")
            #expect(result.mayBeBilled, "HTTP \(status) the request was sent")
            #expect(result.delivered == 0, "HTTP \(status) delivered")
            #expect(sink.saves.isEmpty, "HTTP \(status) nothing stored")
        }

        let atCap = await StudioByokExecutor(
            transport: FakeTransport(reply: .response(status: 200, body: Data(count: cap))), sink: FakeSink()
        ).run(Self.input(profile, operation: .generate))
        #expect(atCap.message != "response_too_large", "a reply of exactly the cap is decoded")

        let oversized = await StudioByokExecutor(
            transport: FakeTransport(reply: .oversized(status: 200, byteCount: cap + 1)), sink: FakeSink()
        ).run(Self.input(profile, operation: .generate))
        #expect(oversized.status == .failed)
        #expect(oversized.errorKind == .upstreamError)
        #expect(oversized.message == "response_too_large")
        #expect(oversized.mayBeBilled)
    }
}
