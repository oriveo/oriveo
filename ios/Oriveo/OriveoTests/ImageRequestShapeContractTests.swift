import Foundation
import Testing
@testable import Oriveo

/// Image request shapes shared by all three clients: reads `imageRequests` of
/// `shared/model-contracts/request_shape_contract.v2.json` (the vendor cases of every built route
/// plus every clientCase), shallow-merges each profile from
/// `image_param_normalization.v1.json#profiles` with the case's profileOverride, validates and
/// normalizes it, merges the case's wireOverride into the wire, builds the request with
/// ImageRequestBuilder and compares it with expect.
@Suite("ImageRequestShapeContractTests")
struct ImageRequestShapeContractTests {
    typealias JSONValue = MetadataClient.JSONValue

    private static let routes: Set<String> = [
        "openai_images", "xai_images", "openrouter_images", "minimax_image_generation",
        "gemini_generate_content", "chat_modalities", "dashscope_multimodal",
    ]
    private static let expectedVendorCases = 16
    private static let expectedClientCases = 97
    /// Error cases carry no baseUrlExample; a valid URL keeps the base URL rule out of their way.
    private static let fallbackBaseUrl = "https://api.example.com/v1"

    private struct BadFixture: Error, CustomStringConvertible {
        let description: String
    }

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

    private static func load(_ name: String) throws -> [String: JSONValue] {
        let url = try repoFile(["shared", "model-contracts", name])
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else {
            throw BadFixture(description: "\(name) is not a JSON object")
        }
        return object
    }

    // MARK: - JSON helpers

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func array(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let array)? = value else { return nil }
        return array
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        (array(value) ?? []).compactMap { string($0) }
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.rounded() == number, abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw BadFixture(description: "\(what) missing or malformed") }
        return value
    }

    /// Order-independent JSON text, so values compare by content.
    private static func canonical(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Dotted path lookup; a numeric segment indexes an array.
    private static func value(at path: String, in root: JSONValue) -> JSONValue? {
        var current: JSONValue? = root
        for segment in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch current {
            case .some(.object(let object)):
                current = object[segment]
            case .some(.array(let items)):
                guard let index = Int(segment), items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func nonEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return false
        case .string(let text): return !text.isEmpty
        case .array(let items): return !items.isEmpty
        case .object(let object): return !object.isEmpty
        case .number, .bool: return true
        }
    }

    /// Standard base64: non-empty, length a multiple of 4, alphabet A-Z a-z 0-9 + / with at most two
    /// trailing "=".
    private static func isStandardBase64(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count % 4 == 0 else { return false }
        return text.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
            && Data(base64Encoded: text) != nil
    }

    /// "*" = present and non-empty (empty string, array or object fail); "data:<mime>;base64,*" = same
    /// prefix followed by standard base64; anything else must be structurally equal.
    private static func matches(_ actual: JSONValue?, _ expected: JSONValue) throws -> Bool {
        guard let actual else { return false }
        if case .string(let pattern) = expected {
            if pattern == "*" { return nonEmpty(actual) }
            if pattern.hasPrefix("data:"), pattern.hasSuffix(";base64,*") {
                guard case .string(let text) = actual else { return false }
                let prefix = String(pattern.dropLast())
                guard text.hasPrefix(prefix) else { return false }
                let rest = String(text.dropFirst(prefix.count))
                return isStandardBase64(rest)
            }
        }
        return try canonical(actual) == canonical(expected)
    }

    private static func strippingTrailingSlashes(_ text: String) -> String {
        var result = text
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    // MARK: - Cases

    @Test("Every built-route vendor case and every clientCase builds the expected request or error")
    func everyCase() throws {
        let shapes = try Self.load("request_shape_contract.v2.json")
        let normalization = try Self.load("image_param_normalization.v1.json")
        let imageRequests = try #require(Self.object(shapes["imageRequests"]))
        let profiles = try #require(Self.object(normalization["profiles"]))
        let defaultAspect = Self.string(normalization["defaultAspect"]) ?? ImageParamNormalizer.defaultAspect
        let vendorCases = (Self.array(imageRequests["cases"]) ?? []).compactMap { Self.object($0) }.filter {
            Self.routes.contains(Self.string(Self.object($0["intent"])?["route"]) ?? "")
        }
        let clientCases = (Self.array(imageRequests["clientCases"]) ?? []).compactMap { Self.object($0) }

        var ran = 0
        for testCase in vendorCases + clientCases {
            let caseId = Self.string(testCase["caseId"]) ?? "<no caseId>"
            do {
                try Self.check(testCase, caseId: caseId, profiles: profiles, defaultAspect: defaultAspect)
                ran += 1
            } catch {
                Issue.record("\(caseId): \(error)")
            }
        }
        #expect(vendorCases.count == Self.expectedVendorCases)
        #expect(clientCases.count == Self.expectedClientCases)
        #expect(ran == Self.expectedVendorCases + Self.expectedClientCases, "every case must actually run")
    }

    private static func check(
        _ testCase: [String: JSONValue],
        caseId: String,
        profiles: [String: JSONValue],
        defaultAspect: String
    ) throws {
        let intent = try require(object(testCase["intent"]), "intent")
        let expect = try require(object(testCase["expect"]), "expect")
        let ref = try require(string(intent["profileRef"]), "intent.profileRef")
        var profileObject = try require(object(profiles[ref]), "profile \(ref)")
        if let override = object(testCase["profileOverride"]) {
            profileObject.merge(override) { _, overriding in overriding }
        }
        guard case .success(let profile) = ImageProfileResolver.validate(profileObject) else {
            throw BadFixture(description: "merged profile must validate")
        }
        if let route = string(intent["route"]), route != profile.route.rawValue {
            throw BadFixture(description: "intent.route \(route) differs from the profile route")
        }
        if let transport = string(intent["editTransport"]), transport != profile.editTransport?.rawValue {
            throw BadFixture(description: "intent.editTransport \(transport) differs from the profile")
        }

        let params = object(intent["params"]) ?? [:]
        let request = ImageParamNormalizer.Request(
            aspect: string(params["aspect"]),
            resolution: string(params["resolution"]),
            quality: string(params["quality"]),
            n: integer(params["n"])
        )
        guard case .success(let normalized) = ImageParamNormalizer.normalize(profile, request: request, defaultAspect: defaultAspect) else {
            throw BadFixture(description: "params must normalize")
        }
        // wireOverride: string values under dotted keys, merged after normalization.
        var wire = normalized.wire
        if let rawOverride = testCase["wireOverride"] {
            let override = try require(object(rawOverride), "wireOverride")
            for (key, raw) in override {
                wire[key] = .string(try require(string(raw), "wireOverride.\(key)"))
            }
        }

        let operation = try require(string(intent["operation"]).flatMap(ImageProfile.Operation.init(rawValue:)), "intent.operation")
        let images = try (array(intent["images"]) ?? []).map { raw -> ImageRequestBuilder.Image in
            let image = try require(object(raw), "intent.images[]")
            let slot = try require(integer(image["slot"]), "images[].slot")
            return ImageRequestBuilder.Image(
                slot: slot,
                role: try require(string(image["role"]), "images[].role"),
                mime: try require(string(image["mime"]), "images[].mime"),
                data: Data((string(image["data"]) ?? "image-\(slot)").utf8)
            )
        }
        let advancedRaw = object(intent["advanced"]) ?? [:]
        let advanced = ImageRequestBuilder.Advanced(
            negativePrompt: string(advancedRaw["negativePrompt"]),
            seed: integer(advancedRaw["seed"]),
            transparentBackground: bool(advancedRaw["transparentBackground"]),
            outputFormat: string(advancedRaw["outputFormat"])
        )
        let apiKey = string(intent["apiKey"]) ?? "test-key"
        let baseUrlExample = string(expect["baseUrlExample"])
        let input = ImageRequestBuilder.Input(
            operation: operation,
            modelId: try require(string(intent["modelId"]), "intent.modelId"),
            prompt: try require(string(intent["prompt"]), "intent.prompt"),
            wire: wire,
            images: images,
            advanced: advanced,
            baseUrl: string(intent["baseUrl"]) ?? baseUrlExample ?? fallbackBaseUrl,
            apiKey: apiKey
        )
        let result = ImageRequestBuilder.build(profile, input: input)

        if let expectedError = string(expect["error"]) {
            switch result {
            case .success:
                Issue.record("\(caseId): expected \(expectedError), built a request")
            case .failure(let failure):
                #expect(failure.rawValue == expectedError, "\(caseId)")
            }
            return
        }
        guard case .success(let built) = result else {
            Issue.record("\(caseId): expected a request, got \(result)")
            return
        }

        #expect(built.method == string(expect["method"]), "\(caseId) method")
        let endpointPath = try require(string(expect["endpointPath"]), "expect.endpointPath")
        let defaultUrl = strippingTrailingSlashes(try require(baseUrlExample, "expect.baseUrlExample")) + endpointPath
        #expect(built.url == (string(expect["url"]) ?? defaultUrl), "\(caseId) url")
        #expect(built.headers["Content-Type"] == string(expect["contentType"]), "\(caseId) Content-Type")
        switch expect["auth"] {
        case .none:
            break
        case .some(.null):
            #expect(built.headers["Authorization"] == nil, "\(caseId) no Authorization")
            #expect(built.headers["x-goog-api-key"] == nil, "\(caseId) no x-goog-api-key")
        case .some(.string("Authorization: Bearer")):
            let key = ImageRequestBuilder.asciiTrimmed(apiKey)
            #expect(built.headers["Authorization"] == "Bearer \(key)", "\(caseId) Authorization")
            #expect(built.headers["x-goog-api-key"] == nil, "\(caseId) no x-goog-api-key")
        case .some(.string("x-goog-api-key")):
            let key = ImageRequestBuilder.asciiTrimmed(apiKey)
            #expect(built.headers["x-goog-api-key"] == key, "\(caseId) x-goog-api-key")
            #expect(built.headers["Authorization"] == nil, "\(caseId) no Authorization")
        default:
            throw BadFixture(description: "unknown expect.auth")
        }
        // URLComponents rejects URLs the contract keeps (e.g. a U+00A0 in the path); fall back to a plain
        // split after "?" so queryExcludes never passes vacuously.
        let queryNames: Set<String>
        if let components = URLComponents(string: built.url) {
            queryNames = Set((components.queryItems ?? []).map(\.name))
        } else {
            let afterMark = built.url.firstIndex(of: "?").map { String(built.url[built.url.index(after: $0)...]) } ?? ""
            let query = afterMark.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            queryNames = Set(query.split(separator: "&").map { String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]) })
        }
        for key in strings(expect["queryExcludes"]) {
            #expect(!queryNames.contains(key), "\(caseId) query \(key)")
        }

        let bodyIncludes = object(expect["bodyIncludes"]) ?? [:]
        switch built.body {
        case .json(let body):
            let expectsMultipart = object(expect["multipartParts"]) != nil
            #expect(!expectsMultipart, "\(caseId) expected a multipart body")
            let root = JSONValue.object(body)
            for (path, expected) in bodyIncludes {
                #expect(try matches(value(at: path, in: root), expected), "\(caseId) body \(path)")
            }
            for path in strings(expect["bodyExcludes"]) {
                let absent = value(at: path, in: root) == nil
                #expect(absent, "\(caseId) body must not have \(path)")
            }
        case .multipart(let fields, let files):
            #expect(bodyIncludes.isEmpty, "\(caseId) expected a JSON body")
            guard let parts = object(expect["multipartParts"]) else {
                Issue.record("\(caseId): expected a JSON body, built multipart")
                return
            }
            let names = fields.map(\.name)
            #expect(Set(names).count == names.count, "\(caseId) multipart field names must be unique: \(names)")
            if let order = array(parts["fieldOrder"]) {
                #expect(names == order.compactMap { string($0) }, "\(caseId) multipart field order \(names)")
            }
            for (name, expected) in object(parts["fields"]) ?? [:] {
                let actual = fields.first { $0.name == name }.map { JSONValue.string($0.value) }
                #expect(try matches(actual, expected), "\(caseId) field \(name)")
            }
            let expectedFiles = (array(parts["files"]) ?? []).compactMap { object($0) }
            #expect(files.count == expectedFiles.count, "\(caseId) file count")
            for (index, (file, expectedFile)) in zip(files, expectedFiles).enumerated() {
                #expect(file.name == string(expectedFile["name"]), "\(caseId) file \(index) name")
                #expect(file.mime == string(expectedFile["mime"]), "\(caseId) file \(index) mime")
                if let filename = string(expectedFile["filename"]) {
                    #expect(file.filename == filename, "\(caseId) file \(index) filename")
                }
                if let data = string(expectedFile["data"]) {
                    #expect(String(decoding: file.data, as: UTF8.self) == data, "\(caseId) file \(index) data")
                }
            }
            for name in strings(parts["excludes"]) {
                #expect(!fields.contains { $0.name == name } && !files.contains { $0.name == name }, "\(caseId) part \(name)")
            }
        }
    }
}
