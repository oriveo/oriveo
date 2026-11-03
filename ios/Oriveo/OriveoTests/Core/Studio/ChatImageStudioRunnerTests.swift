import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Oriveo

/// Chat image runner: the wire cases of `shared/studio-contracts/chat_image_dispatch.v1.json` go
/// through the runner and the real BYOK executor into a fake transport; edit references keep the
/// attachment order; failures map onto chat errors; the default transport stays enabled with the
/// Studio build flag off.
@Suite("ChatImageStudioRunnerTests")
@MainActor
struct ChatImageStudioRunnerTests {
    typealias JSONValue = MetadataClient.JSONValue
    typealias Slice = ImageProfileResolver.Slice

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

    private static func fixtureURL() throws -> URL {
        try repoFile(["\u{5171}\u{4EAB}", "studio-contracts", "chat_image_dispatch.v1.json"])
    }

    private static func fixture() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any] else {
            throw BadFixture(description: "chat_image_dispatch.v1.json is not a JSON object")
        }
        return object
    }

    /// The raw `profiles` table of the fixture, served as `profiles.image` of the slice.
    private static func profileTable() throws -> [String: JSONValue] {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL())),
              case .object(let profiles)? = root["profiles"]
        else { throw BadFixture(description: "profiles missing") }
        return profiles
    }

    /// A slice with one catalog model under its server provider key.
    private static func slice(serverKey: String, modelId: String, profileRef: String) throws -> Slice {
        Slice(
            profiles: .init(image: try profileTable()),
            providers: [
                serverKey: Slice.Provider(
                    models: [modelId: Slice.ModelEntry(displayName: nil, imageProfile: profileRef, imageProfileOverride: nil)],
                    imageModels: nil
                ),
            ]
        )
    }

    /// Fixture provider kinds are server catalog keys (`togetherAI`); map them back through the
    /// production wrapper.
    private static func providerKind(serverKey: String) throws -> ProviderKind {
        guard let kind = ProviderKind.allCases.first(where: { MetadataClient.catalogKey(for: $0) == serverKey }) else {
            throw BadFixture(description: "no provider kind for server key \(serverKey)")
        }
        return kind
    }

    private static func runner(_ transport: FakeTransport, slice: Slice?) -> ChatImageStudioRunner {
        ChatImageStudioRunner(executor: StudioByokExecutor(transport: transport), slice: { slice })
    }

    private static func request(
        _ provider: ProviderKind,
        modelId: String,
        prompt: String = "a cup of coffee on a table",
        attachments: [Oriveo.Attachment] = [],
        baseURL: String? = "https://api.example.com/v1",
        partitionUID: String? = nil
    ) -> ChatImageStudioRunner.Request {
        ChatImageStudioRunner.Request(
            provider: provider,
            modelId: modelId,
            apiKey: "test-key",
            baseURL: baseURL,
            prompt: prompt,
            attachments: attachments,
            partitionUID: partitionUID
        )
    }

    private static func jsonBody(_ request: ImageRequestBuilder.Request) throws -> [String: Any] {
        guard case .json(let body) = request.body else { throw BadFixture(description: "expected a JSON body") }
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any] else {
            throw BadFixture(description: "body is not a JSON object")
        }
        return object
    }

    /// Dotted path lookup (`parameters.size`).
    private static func value(_ object: [String: Any], path: String) -> Any? {
        var current: Any? = object
        for key in path.split(separator: ".") {
            current = (current as? [String: Any])?[String(key)]
        }
        return current
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// JSON equality that keeps booleans apart from numbers.
    private static func same(_ actual: Any?, _ expected: Any) -> Bool {
        guard let actual = actual as? NSObject, let expected = expected as? NSObject else { return false }
        return isBoolean(actual) == isBoolean(expected) && actual.isEqual(expected)
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
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
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

    private static func imageAttachment(localImageID: String, mime: String) -> Oriveo.Attachment {
        Oriveo.Attachment(id: UUID(), kind: .image, fileName: "photo", mimeType: mime, localImageID: localImageID)
    }

    // MARK: - wire

    @Test("wireMatchesLegacy: every wire case goes through the runner and the real executor as the expected request")
    func wireMatchesLegacy() async throws {
        let cases = try #require(Self.fixture()["wire"] as? [[String: Any]])
        #expect(cases.count == 7)
        var ran = 0
        for item in cases {
            let caseId = try #require(item["caseId"] as? String)
            let input = try #require(item["input"] as? [String: Any], "\(caseId) input")
            let expect = try #require(item["expect"] as? [String: Any], "\(caseId) expect")
            let serverKey = try #require(input["providerKind"] as? String, "\(caseId) providerKind")
            let modelId = try #require(input["modelId"] as? String, "\(caseId) modelId")
            let profileRef = try #require(input["profileRef"] as? String, "\(caseId) profileRef")
            let prompt = try #require(input["prompt"] as? String, "\(caseId) prompt")
            let pathSuffix = try #require(expect["pathSuffix"] as? String, "\(caseId) pathSuffix")
            let includes = try #require(expect["bodyIncludes"] as? [String: Any], "\(caseId) bodyIncludes")
            let excludes = try #require(expect["bodyExcludes"] as? [String], "\(caseId) bodyExcludes")

            let transport = FakeTransport(reply: .response(status: 500, body: Data("{}".utf8)))
            let runner = Self.runner(transport, slice: try Self.slice(serverKey: serverKey, modelId: modelId, profileRef: profileRef))
            do {
                _ = try await runner.run(Self.request(try Self.providerKind(serverKey: serverKey), modelId: modelId, prompt: prompt))
                Issue.record("\(caseId) a 500 reply must fail the send")
            } catch {}

            let requests = transport.requests
            #expect(requests.count == 1, "\(caseId) exactly one request")
            guard let sent = requests.first else { continue }
            #expect(sent.method == expect["method"] as? String, "\(caseId) method")
            #expect(sent.url.hasSuffix(pathSuffix), "\(caseId) url \(sent.url)")
            let body = try Self.jsonBody(sent)
            for (path, want) in includes {
                let got = Self.value(body, path: path)
                #expect(Self.same(got, want), "\(caseId) \(path) = \(String(describing: got))")
            }
            for key in excludes {
                #expect(body[key] == nil, "\(caseId) must not send \(key)")
            }
            ran += 1
        }
        #expect(ran == cases.count, "every wire case must actually send")
    }

    // MARK: - edit

    @Test("editSendsAttachmentsInOrder: images with local bytes go out in attachment order and the result becomes chat image attachments")
    func editSendsAttachmentsInOrder() async throws {
        let partition = "chat-image-runner-tests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: AppSessionStore.imagesDir(for: partition).deletingLastPathComponent()) }
        let first = try Self.makeImage(width: 40, height: 40, mime: "image/png")
        let third = try Self.makeImage(width: 24, height: 48, mime: "image/jpeg")
        let output = try Self.makeImage(width: 64, height: 64, mime: "image/png")
        let ids = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
        ImageStore.save(imageData: first, for: ids[0], partitionUID: partition)
        ImageStore.save(imageData: third, for: ids[2], partitionUID: partition)
        let attachments = [
            Self.imageAttachment(localImageID: ids[0], mime: "image/png"),
            // No bytes on this device: skipped.
            Self.imageAttachment(localImageID: ids[1], mime: "image/png"),
            Oriveo.Attachment(id: UUID(), kind: .file, fileName: "notes.txt", mimeType: "text/plain", base64Data: Data("hi".utf8).base64EncodedString()),
            Self.imageAttachment(localImageID: ids[2], mime: "image/jpeg"),
        ]
        let reply = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": output.base64EncodedString()]]])
        let transport = FakeTransport(reply: .response(status: 200, body: reply))
        let runner = Self.runner(transport, slice: try Self.slice(serverKey: "openAI", modelId: "gpt-image-2", profileRef: "openai_gpt_image"))

        let result = try #require(
            try await runner.run(Self.request(.openAI, modelId: "gpt-image-2", attachments: attachments, partitionUID: partition))
        )

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.url.hasSuffix("/images/edits"), "edit endpoint, got \(sent.url)")
        guard case .multipart(_, let files) = sent.body else {
            Issue.record("edit must send multipart")
            return
        }
        #expect(files.map(\.data) == [first, third], "attachment order, the image without bytes skipped")
        #expect(files.map(\.mime) == ["image/png", "image/jpeg"])

        #expect(result.text == "")
        #expect(result.promptTokens == 0)
        #expect(result.completionTokens == 0)
        #expect(result.estimatedCost == 0)
        #expect(result.usageReported == false)
        let images = try #require(result.attachments)
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.kind == .image)
        #expect(image.mimeType == "image/png")
        #expect(image.base64Data == nil)
        let id = try #require(image.localImageID)
        #expect(ImageStore.loadImageData(for: id, partitionUID: partition) == output, "result stored under the attachment id")
        let thumbnail = try #require(image.thumbnailBase64, "thumbnail is required")
        #expect(!thumbnail.isEmpty)
        #expect(ImageStore.loadThumbnailData(for: id, partitionUID: partition)?.base64EncodedString() == thumbnail, "thumbnail written")
    }

    // MARK: - failures

    @Test("failureMapsToChatError: failed rounds throw the mapped chat error with the result message; legacy sends return nil")
    func failureMapsToChatError() async throws {
        let slice = try Self.slice(serverKey: "openAI", modelId: "gpt-image-1", profileRef: "openai_images_square")
        let cases: [(status: Int, body: String, category: String)] = [
            (401, #"{"error":{"message":"bad key"}}"#, "invalid_key"),
            (429, #"{"error":{"message":"slow down"}}"#, "rate_limited"),
            (402, #"{"error":{"message":"pay up"}}"#, "quota_exceeded"),
            (404, #"{"error":{"message":"gone"}}"#, "model_unavailable"),
            (400, #"{"error":{"code":"moderation_blocked"}}"#, "upstream_400"),
            (503, #"{"error":{"message":"busy"}}"#, "upstream_502"),
        ]
        for testCase in cases {
            let transport = FakeTransport(reply: .response(status: testCase.status, body: Data(testCase.body.utf8)))
            do {
                _ = try await Self.runner(transport, slice: slice).run(Self.request(.openAI, modelId: "gpt-image-1"))
                Issue.record("\(testCase.status) must fail")
            } catch let error as ProviderServiceError {
                let message = testCase.body
                let matches: Bool
                switch (testCase.category, error) {
                case ("invalid_key", .invalidAPIKey(let detail)): matches = detail == message
                case ("rate_limited", .rateLimited(let detail)): matches = detail == message
                case ("quota_exceeded", .quotaExceeded(let detail)): matches = detail == message
                case ("model_unavailable", .modelUnavailable(let detail)): matches = detail == message
                case ("upstream_400", .upstream(let code, let detail)): matches = code == 400 && detail == message
                case ("upstream_502", .upstream(let code, let detail)): matches = code == 502 && detail == message
                default: matches = false
                }
                #expect(matches, "\(testCase.status) -> \(testCase.category) got \(error)")
            } catch {
                Issue.record("\(testCase.status) threw \(error)")
            }
            #expect(transport.requests.count == 1, "\(testCase.status) one request")
        }

        let network = FakeTransport(reply: .failure(urlErrorCode: URLError.Code.networkConnectionLost.rawValue))
        do {
            _ = try await Self.runner(network, slice: slice).run(Self.request(.openAI, modelId: "gpt-image-1"))
            Issue.record("a lost connection must fail")
        } catch let error as ProviderServiceError {
            if case .network = error {} else { Issue.record("lost connection got \(error)") }
        }

        // Legacy sends never touch the transport and leave the old path to run.
        let legacyCases: [(String, ProviderKind, String, Slice?)] = [
            ("relay", .relay, "gpt-image-1", slice),
            ("not in catalog", .openAI, "gpt-image-unknown", slice),
            ("no snapshot", .openAI, "gpt-image-1", nil),
        ]
        for (name, provider, modelId, legacySlice) in legacyCases {
            let transport = FakeTransport(reply: .response(status: 200, body: Data("{}".utf8)))
            let result = try await Self.runner(transport, slice: legacySlice).run(Self.request(provider, modelId: modelId))
            #expect(result == nil, "\(name) stays legacy")
            #expect(transport.requests.isEmpty, "\(name) must not send")
        }
    }

    // MARK: - base URL

    @Test("missingBaseURLStaysLegacy: without a base URL the runner returns nil and sends nothing")
    func missingBaseURLStaysLegacy() async throws {
        let slice = try Self.slice(serverKey: "openAI", modelId: "gpt-image-1", profileRef: "openai_images_square")
        for baseURL in [nil, "", "   "] as [String?] {
            let transport = FakeTransport(reply: .response(status: 200, body: Data("{}".utf8)))
            let result = try await Self.runner(transport, slice: slice)
                .run(Self.request(.openAI, modelId: "gpt-image-1", baseURL: baseURL))
            #expect(result == nil, "base URL \(String(describing: baseURL)) stays legacy")
            #expect(transport.requests.isEmpty, "base URL \(String(describing: baseURL)) must not send")
        }
    }

    // MARK: - build flag

    @Test("worksWithStudioCompiledOut: the default runner sends through the shared background transfer, enabled whatever the build flag")
    func worksWithStudioCompiledOut() throws {
        let runner = ChatImageStudioRunner()
        let transport = try #require(runner.executor.transport as? StudioBackgroundByokTransport)
        #expect(transport.transfer === StudioBackgroundTransfer.shared)
        #expect(StudioBackgroundTransfer.shared.isEnabled, "compiledIn = \(StudioAvailability.compiledIn)")
    }

    // MARK: - Fakes

    nonisolated final class FakeTransport: StudioByokTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let reply: StudioByokReply
        private var _requests: [ImageRequestBuilder.Request] = []

        init(reply: StudioByokReply) {
            self.reply = reply
        }

        var requests: [ImageRequestBuilder.Request] { lock.withLock { _requests } }

        func send(
            _ request: ImageRequestBuilder.Request, jobId: String, timeoutSeconds: Int, maxResponseBytes: Int
        ) async -> StudioByokReply {
            lock.withLock { _requests.append(request) }
            return reply
        }

        func fetchImage(_ url: URL, jobId: String, index: Int) async -> Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> {
            .failure(.network)
        }
    }
}
