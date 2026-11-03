import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Oriveo

/// URLProtocol stub of the BYOK transport tests: a nil reply never answers (the task hangs
/// until it is cancelled).
nonisolated final class StudioByokTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> (HTTPURLResponse, Data)?)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var stops = 0

    static func reset(_ newHandler: ((URLRequest) -> (HTTPURLResponse, Data)?)?) {
        lock.withLock {
            handler = newHandler
            requests = []
            stops = 0
        }
    }

    static var capturedRequests: [URLRequest] { lock.withLock { requests } }
    static var stopCount: Int { lock.withLock { stops } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current: ((URLRequest) -> (HTTPURLResponse, Data)?)? = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler
        }
        guard let current else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let (response, data) = current(request) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stops += 1 }
    }
}

/// Production BYOK transport over the background transfer: upload, wait by job id, timeout and
/// task cancellation cancel the job, URL images download with the 30 MB cap, and the executor
/// runs a captured URL sample end to end through it.
@Suite("StudioBackgroundByokTransportTests", .serialized)
struct StudioBackgroundByokTransportTests {
    typealias JSONValue = MetadataClient.JSONValue

    private struct BadFixture: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Fixtures

    private static let endpoint = "https://api.example.com/v1/images/generations"
    private static let imageURL = URL(string: "https://cdn.example.test/image-0.png")!

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioBackgroundByokTransportTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeTransfer(root: URL) -> StudioBackgroundTransfer {
        StudioBackgroundTransfer(
            store: StudioTransferStore(root: root),
            isEnabled: true,
            sessionFactory: { delegate in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StudioByokTransportURLProtocol.self]
                return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            }
        )
    }

    private static func response(_ status: Int, url: URL?) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? imageURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private static func jsonRequest() -> ImageRequestBuilder.Request {
        ImageRequestBuilder.Request(
            method: "POST",
            url: endpoint,
            headers: ["Authorization": "Bearer test-key", "Content-Type": "application/json"],
            body: .json(["model": .string("test-model"), "prompt": .string("a red fox"), "n": .number(1)])
        )
    }

    /// Shared contract directory name, built at run time so the source stays ASCII.
    private static let sharedDirectory = String(decoding: [0xE5, 0x85, 0xB1, 0xE4, 0xBA, 0xAB] as [UInt8], as: UTF8.self)

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

    private static func jsonObject(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw BadFixture(description: "\(url.lastPathComponent) is not a JSON object")
        }
        return object
    }

    /// First profile (by name) of image_param_normalization.v1.json on `route` offering `operation`.
    private static func profile(route: String, operation: String) throws -> ImageProfile {
        let url = try repoFile([sharedDirectory, "model-contracts", "image_param_normalization.v1.json"])
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)),
              case .object(let profiles)? = root["profiles"]
        else { throw BadFixture(description: "profiles missing") }
        for name in profiles.keys.sorted() {
            guard case .object(let object)? = profiles[name], case .string(route)? = object["route"],
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

    nonisolated final class FakeSink: StudioByokImageSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _stored: [String: Data] = [:]

        var stored: [String: Data] { lock.withLock { _stored } }

        func save(_ data: Data, id: String, partitionUID: String?) async throws {
            lock.withLock { _stored[id] = data }
        }

        func delete(id: String, partitionUID: String?) async {
            lock.withLock { _stored[id] = nil }
        }
    }

    // MARK: - Send

    @Test("sendReturnsStatusAndBody: the reply carries the upload status and response.body, then the job directory is gone")
    func sendReturnsStatusAndBody() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        StudioByokTransportURLProtocol.reset { request in (Self.response(429, url: request.url), body) }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)

        let encoded = try #require(StudioBackgroundByokTransport.encode(Self.jsonRequest()))
        let decoded = try #require(JSONSerialization.jsonObject(with: encoded.body) as? NSDictionary)
        #expect(decoded == ["model": "test-model", "prompt": "a red fox", "n": 1] as NSDictionary)
        #expect(encoded.request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let reply = await transport.send(Self.jsonRequest(), jobId: "job-send", timeoutSeconds: 180)

        #expect(reply == .response(status: 429, body: body))
        let sent = try #require(StudioByokTransportURLProtocol.capturedRequests.first)
        #expect(sent.url?.absoluteString == Self.endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-send").path))
    }

    @Test("enqueueFailureRemovesJobDir: an upload that cannot be enqueued replies not sent and leaves no job directory")
    func enqueueFailureRemovesJobDir() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StudioByokTransportURLProtocol.reset { request in (Self.response(200, url: request.url), Data("{}".utf8)) }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)
        // A directory where the request body file goes makes writing the body fail after the
        // job directory already exists.
        let blocker = store.requestBodyURL(jobId: "job-enqueue")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))

        let reply = await transport.send(Self.jsonRequest(), jobId: "job-enqueue", timeoutSeconds: 180)

        #expect(reply == .failure(urlErrorCode: StudioBackgroundByokTransport.notSentCode))
        #expect(StudioByokTransportURLProtocol.capturedRequests.isEmpty, "nothing was sent")
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-enqueue").path))
    }

    @Test("sendOverCapRepliesOversized: a response.body larger than the cap is reported by size, not read, and the job directory is gone")
    func sendOverCapRepliesOversized() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(#"{"error":{"message":"rate limited"}}"#.utf8)
        StudioByokTransportURLProtocol.reset { request in (Self.response(429, url: request.url), body) }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)

        let over = await transport.send(Self.jsonRequest(), jobId: "job-over", timeoutSeconds: 180, maxResponseBytes: body.count - 1)
        #expect(over == .oversized(status: 429, byteCount: body.count))
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-over").path))

        let exact = await transport.send(Self.jsonRequest(), jobId: "job-exact", timeoutSeconds: 180, maxResponseBytes: body.count)
        #expect(exact == .response(status: 429, body: body))
    }

    @Test("multipartEncodedWithBoundary: fields and files are encoded in order and the boundary lands in Content-Type")
    func multipartEncodedWithBoundary() throws {
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0xFF])
        let request = ImageRequestBuilder.Request(
            method: "POST",
            url: "https://api.example.com/v1/images/edits",
            headers: ["Authorization": "Bearer test-key", "Content-Type": "multipart/form-data"],
            body: .multipart(
                fields: [
                    ImageRequestBuilder.MultipartField(name: "model", value: "test-model"),
                    ImageRequestBuilder.MultipartField(name: "prompt", value: "line one\r\nline two"),
                ],
                files: [ImageRequestBuilder.MultipartFile(name: "image[]", filename: "image-1.png", mime: "image/png", data: picture)]
            )
        )

        let encoded = try #require(StudioBackgroundByokTransport.encode(request, boundary: "test-boundary"))

        var expected = Data()
        expected.append(Data("--test-boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ntest-model\r\n".utf8))
        expected.append(Data("--test-boundary\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nline one\r\nline two\r\n".utf8))
        expected.append(Data("--test-boundary\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"image-1.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        expected.append(picture)
        expected.append(Data("\r\n--test-boundary--\r\n".utf8))
        #expect(encoded.body == expected)
        #expect(encoded.request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary")
        #expect(encoded.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(encoded.request.httpMethod == "POST")
        #expect(encoded.request.url?.absoluteString == "https://api.example.com/v1/images/edits")
        #expect(encoded.request.httpBody == nil)
    }

    @Test("shortTimeoutCancelsAsTimeout: a deadline under 180 s cancels the job and replies timed out")
    func shortTimeoutCancelsAsTimeout() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StudioByokTransportURLProtocol.reset { _ in nil }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)
        let started = Date()

        let reply = await transport.send(Self.jsonRequest(), jobId: "job-timeout", timeoutSeconds: 1)

        #expect(reply == .failure(urlErrorCode: NSURLErrorTimedOut))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(StudioByokTransportURLProtocol.capturedRequests.count == 1)
        #expect(StudioByokTransportURLProtocol.stopCount >= 1)
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-timeout").path))
    }

    @Test("taskCancelCancelsJob: cancelling the calling task cancels the job and replies cancelled")
    func taskCancelCancelsJob() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StudioByokTransportURLProtocol.reset { _ in nil }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)
        let request = Self.jsonRequest()

        let task = Task { await transport.send(request, jobId: "job-cancel", timeoutSeconds: 180) }
        for _ in 0..<250 where StudioByokTransportURLProtocol.capturedRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(StudioByokTransportURLProtocol.capturedRequests.count == 1)
        task.cancel()
        let reply = await task.value

        #expect(reply == .failure(urlErrorCode: NSURLErrorCancelled))
        #expect(StudioByokTransportURLProtocol.stopCount >= 1)
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-cancel").path))
    }

    // MARK: - Fetch

    @Test("downloadOverCapFails: a download over 31_457_280 bytes fails like the foreground fetcher's size cap")
    func downloadOverCapFails() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A valid png header so only the size cap can reject it.
        var oversized = try Self.makeImage(width: 8, height: 8, mime: "image/png")
        #expect(StudioImageResponse.decodeImageInfo(oversized) != nil)
        oversized.append(Data(count: 31_457_281 - oversized.count))
        StudioByokTransportURLProtocol.reset { request in (Self.response(200, url: request.url), oversized) }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)

        let result = await transport.fetchImage(Self.imageURL, jobId: "job-cap", index: 0)

        #expect(StudioImageFetcher.Policy.maxBytes == 31_457_280)
        #expect(transport.maxImageBytes == StudioImageFetcher.Policy.maxBytes)
        #expect(result == .failure(.decodeFailed))
        #expect(StudioByokTransportURLProtocol.capturedRequests.first?.url == Self.imageURL)
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-cap").path))
    }

    @Test("downloadDecodesImage: a downloaded image decodes to its bytes, mime and size")
    func downloadDecodesImage() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = try Self.makeImage(width: 48, height: 32, mime: "image/png")
        StudioByokTransportURLProtocol.reset { request in (Self.response(200, url: request.url), picture) }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer)
        let store = StudioTransferStore(root: root)

        let result = await transport.fetchImage(Self.imageURL, jobId: "job-image", index: 2)

        #expect(result == .success(StudioImageResponse.Materialized(bytes: picture, mime: "image/png", width: 48, height: 32)))
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-image").path))
    }

    @Test("downloadTimesOutAt60s: a download unfinished at the image deadline is cancelled and fails as timeout")
    func downloadTimesOutAt60s() async throws {
        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StudioByokTransportURLProtocol.reset { _ in nil }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let transport = StudioBackgroundByokTransport(transfer: transfer, imageTimeoutSeconds: 0.5)
        let store = StudioTransferStore(root: root)
        let started = Date()

        let result = await transport.fetchImage(Self.imageURL, jobId: "job-slow", index: 0)

        #expect(StudioImageFetcher.Policy.timeoutSeconds == 60)
        #expect(StudioBackgroundByokTransport(transfer: transfer).imageTimeoutSeconds == StudioImageFetcher.Policy.timeoutSeconds)
        #expect(result == .failure(.timeout))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(StudioByokTransportURLProtocol.capturedRequests.count == 1)
        #expect(StudioByokTransportURLProtocol.stopCount >= 1)
        #expect(!FileManager.default.fileExists(atPath: store.directory(jobId: "job-slow").path))
    }

    // MARK: - Golden chain

    @Test("goldenChainThroughRealTransport: a captured URL sample runs through the executor and this transport and is delivered")
    func goldenChainThroughRealTransport() async throws {
        let file = "openai_images.zhipu.glm-image.generate.json"
        let samples = try #require(
            try Self.jsonObject(Self.repoFile([Self.sharedDirectory, "model-contracts", "image_response_samples.v1", "index.json"]))["samples"]
                as? [[String: Any]]
        )
        let sample = try #require(samples.first { $0["file"] as? String == file })
        let kinds = ((sample["expect"] as? [String: Any])?["images"] as? [[String: Any]] ?? []).map { $0["kind"] as? String }
        #expect(kinds == ["url"])
        let raw = try Self.jsonObject(Self.repoFile([Self.sharedDirectory, "model-contracts", "image_response_samples.v1", file]))
        let observed = try #require(((raw["observed"] as? [String: Any])?["images"] as? [[String: Any]])?.first)
        let width = try #require(observed["width"] as? Int)
        let height = try #require(observed["height"] as? Int)
        let mime = try #require(observed["mime"] as? String)
        let picture = try Self.makeImage(width: width, height: height, mime: mime)
        let body = try JSONSerialization.data(withJSONObject: try #require(raw["response"]))

        let root = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        StudioByokTransportURLProtocol.reset { request in
            if request.url?.host == "api.example.com" { return (Self.response(200, url: request.url), body) }
            return (Self.response(200, url: request.url), picture)
        }
        defer { StudioByokTransportURLProtocol.reset(nil) }
        let transfer = Self.makeTransfer(root: root)
        let sink = FakeSink()
        let executor = StudioByokExecutor(transport: StudioBackgroundByokTransport(transfer: transfer), sink: sink)
        let profile = try Self.profile(route: "openai_images", operation: "generate")
        let input = StudioByokInput(
            roundId: "round-1",
            providerKind: "openai",
            apiKey: "test-key",
            baseURL: "https://api.example.com/v1",
            modelId: "test-model",
            profile: profile,
            operation: .generate,
            prompt: "a red fox in fresh snow",
            params: ImageParamNormalizer.Request(aspect: nil, n: 1),
            advanced: ImageRequestBuilder.Advanced(),
            images: [],
            partitionUID: "test-partition"
        )

        let result = await executor.run(input)

        #expect(result.status == .completed)
        #expect(result.errorKind == nil)
        #expect(result.delivered == 1)
        let image = try #require(result.images.first)
        #expect(image.width == width)
        #expect(image.height == height)
        #expect(image.mime == mime)
        #expect(sink.stored[image.id] == picture)
        let urls = StudioByokTransportURLProtocol.capturedRequests.compactMap(\.url)
        #expect(urls.count == 2)
        #expect(urls.first?.host == "api.example.com")
        #expect(urls.last?.host == "maas-watermark-prod-new.cn-wlcb.ufileos.com")
        #expect(StudioTransferStore(root: root).jobIds().isEmpty)
    }
}
