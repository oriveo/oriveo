import Foundation

/// Builds one BYOK Studio image request from a resolved ImageProfile and the normalized wire.
/// Cases: `imageRequests` of `shared/model-contracts/request_shape_contract.v2.json`, read by the
/// iOS / Android / Web contract tests alike. Pure function: nothing is encoded or sent here, the
/// multipart body has no boundary. Built routes: openai_images, xai_images, openrouter_images,
/// minimax_image_generation, gemini_generate_content, chat_modalities, dashscope_multimodal; the
/// others are not built yet.
enum ImageRequestBuilder {
    typealias JSONValue = MetadataClient.JSONValue

    enum Failure: String, CaseIterable, Error, Sendable {
        /// The input breaks a request rule (operation, prompt, images, advanced values, base URL).
        case invalidRequest = "invalid_request"
        /// The profile cannot be built on this route.
        case invalidProfile = "invalid_profile"
    }

    struct Image: Equatable, Sendable {
        var slot: Int
        var role: String
        var mime: String
        var data: Data

        init(slot: Int, role: String, mime: String, data: Data) {
            self.slot = slot
            self.role = role
            self.mime = mime
            self.data = data
        }
    }

    /// Advanced user options; nil means not set.
    struct Advanced: Equatable, Sendable {
        var negativePrompt: String?
        var seed: Int?
        var transparentBackground: Bool?
        var outputFormat: String?

        init(negativePrompt: String? = nil, seed: Int? = nil, transparentBackground: Bool? = nil, outputFormat: String? = nil) {
            self.negativePrompt = negativePrompt
            self.seed = seed
            self.transparentBackground = transparentBackground
            self.outputFormat = outputFormat
        }
    }

    struct Input: Equatable, Sendable {
        var operation: ImageProfile.Operation
        var modelId: String
        var prompt: String
        /// `ImageParamNormalizer.Normalized.wire`: dotted body keys.
        var wire: [String: ImageParamNormalizer.WireValue]
        var images: [Image]
        var advanced: Advanced
        var baseUrl: String
        var apiKey: String

        init(
            operation: ImageProfile.Operation,
            modelId: String,
            prompt: String,
            wire: [String: ImageParamNormalizer.WireValue],
            images: [Image] = [],
            advanced: Advanced = Advanced(),
            baseUrl: String,
            apiKey: String
        ) {
            self.operation = operation
            self.modelId = modelId
            self.prompt = prompt
            self.wire = wire
            self.images = images
            self.advanced = advanced
            self.baseUrl = baseUrl
            self.apiKey = apiKey
        }
    }

    struct MultipartField: Equatable, Sendable {
        var name: String
        var value: String
    }

    struct MultipartFile: Equatable, Sendable {
        var name: String
        var filename: String
        var mime: String
        var data: Data
    }

    enum Body: Sendable {
        case json([String: JSONValue])
        /// Fields and files in send order.
        case multipart(fields: [MultipartField], files: [MultipartFile])
    }

    struct Request: Sendable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Body
    }

    static let supportedMimes: Set<String> = ["image/png", "image/jpeg", "image/webp"]
    static let supportedOutputFormats: Set<String> = ["png", "jpeg", "webp"]
    static let seedRange = 0...2_147_483_647

    /// Route body keys of the advanced fields; a route without a key never sends that field.
    private struct AdvancedKeys {
        var negativePrompt: String?
        var seed: String?
        var background: String?
        var outputFormat: String?
    }

    private static func advancedKeys(_ route: ImageProfile.Route) -> AdvancedKeys {
        switch route {
        case .openaiImages:
            return AdvancedKeys(negativePrompt: "negative_prompt", seed: "seed", background: "background", outputFormat: "output_format")
        case .openrouterImages:
            return AdvancedKeys(seed: "seed", background: "background", outputFormat: "output_format")
        case .minimaxImageGeneration:
            return AdvancedKeys(seed: "seed")
        case .geminiGenerateContent:
            // Dotted: lands in the fixed generationConfig object.
            return AdvancedKeys(seed: "generationConfig.seed")
        case .chatModalities:
            return AdvancedKeys(seed: "seed")
        case .dashscopeMultimodal:
            // Dotted: lands in the fixed parameters object.
            return AdvancedKeys(negativePrompt: "parameters.negative_prompt", seed: "parameters.seed")
        default:
            return AdvancedKeys()
        }
    }

    /// Images one request of this edit transport can carry; nil = no transport limit.
    private static func transportLimit(_ transport: ImageProfile.EditTransport) -> Int? {
        switch transport {
        case .jsonImage, .jsonImageUrl: return 1
        case .jsonImageObject: return 5
        case .inputReferences, .inline: return nil
        default: return nil
        }
    }

    /// Validation runs in the contract order: route (invalid_profile), operation (invalid_request),
    /// edit transport (invalid_profile), then the other request rules (invalid_request). A wire or
    /// advanced key that collides with an existing key or a non-object value is invalid_profile; every
    /// fixed field of the route is written before them, so the check covers the fixed fields too.
    private static let builtRoutes: Set<ImageProfile.Route> = [
        .openaiImages, .xaiImages, .openrouterImages, .minimaxImageGeneration, .geminiGenerateContent, .chatModalities,
        .dashscopeMultimodal,
    ]

    static func build(_ profile: ImageProfile, input: Input) -> Result<Request, Failure> {
        guard builtRoutes.contains(profile.route) else { return .failure(.invalidProfile) }
        guard profile.operations.contains(input.operation) else { return .failure(.invalidRequest) }
        var transport: ImageProfile.EditTransport?
        if input.operation == .edit {
            guard let declared = profile.editTransport, profile.route.allowedEditTransports.contains(declared) else {
                return .failure(.invalidProfile)
            }
            transport = declared
        }

        let modelId = asciiTrimmed(input.modelId)
        // The prompt is checked for blankness but sent verbatim.
        guard !modelId.isEmpty, !asciiTrimmed(input.prompt).isEmpty else {
            return .failure(.invalidRequest)
        }
        // Gemini puts the model in the path: one leading "models/" is dropped, the rest must be non-blank.
        var modelSegment = modelId
        if profile.route == .geminiGenerateContent {
            if modelSegment.hasPrefix("models/") { modelSegment.removeFirst("models/".count) }
            guard !modelSegment.isEmpty else { return .failure(.invalidRequest) }
        }
        guard let images = orderedImages(input, transport: transport, profile: profile) else {
            return .failure(.invalidRequest)
        }
        let advanced = input.advanced
        if let seed = advanced.seed, !seedRange.contains(seed) { return .failure(.invalidRequest) }
        if let format = advanced.outputFormat, !supportedOutputFormats.contains(format) { return .failure(.invalidRequest) }
        guard let base = baseUrl(input.baseUrl) else { return .failure(.invalidRequest) }

        let advancedFields = advancedValues(profile, advanced: advanced)
        var headers: [String: String] = [:]
        let apiKey = asciiTrimmed(input.apiKey)
        if !apiKey.isEmpty {
            if profile.route == .geminiGenerateContent {
                headers["x-goog-api-key"] = apiKey
            } else {
                headers["Authorization"] = "Bearer \(apiKey)"
            }
        }

        if transport == .multipart {
            headers["Content-Type"] = "multipart/form-data"
            var fields = [MultipartField(name: "model", value: modelId), MultipartField(name: "prompt", value: input.prompt)]
            for key in input.wire.keys.sorted() {
                guard let value = input.wire[key] else { continue }
                fields.append(MultipartField(name: key, value: text(value)))
            }
            for (name, value) in advancedFields {
                fields.append(MultipartField(name: name, value: text(value)))
            }
            // A repeated field name would be a silent second value; same rule as the JSON key collision.
            guard Set(fields.map(\.name)).count == fields.count else { return .failure(.invalidProfile) }
            let files = images.enumerated().map { index, image in
                MultipartFile(
                    name: "image[]",
                    filename: "image-\(index + 1).\(fileExtension(image.mime))",
                    mime: image.mime,
                    data: image.data
                )
            }
            return .success(Request(method: "POST", url: base + "/images/edits", headers: headers, body: .multipart(fields: fields, files: files)))
        }

        headers["Content-Type"] = "application/json"
        var body = fixedBody(
            profile.route, transport: transport, modelId: modelId, prompt: input.prompt, images: images,
            promptExtend: promptExtend(profile)
        )
        let expanded = input.wire.map { ($0.key, $0.value) } + advancedFields
        for (key, value) in expanded {
            let path = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard insert(&body, path: path, value: json(value)) else { return .failure(.invalidProfile) }
        }
        let path: String
        switch profile.route {
        case .openrouterImages: path = "/images"
        case .minimaxImageGeneration: path = "/image_generation"
        case .geminiGenerateContent: path = "/models/\(percentEncoded(modelSegment)):generateContent"
        case .chatModalities: path = "/chat/completions"
        case .dashscopeMultimodal: path = "/services/aigc/multimodal-generation/generation"
        default: path = transport == .jsonImageObject ? "/images/edits" : "/images/generations"
        }
        return .success(Request(method: "POST", url: base + path, headers: headers, body: .json(body)))
    }

    /// Every fixed body field of a JSON route (including response_format and the image fields), written
    /// before the wire and the advanced keys.
    private static func fixedBody(
        _ route: ImageProfile.Route,
        transport: ImageProfile.EditTransport?,
        modelId: String,
        prompt: String,
        images: [Image],
        promptExtend: Bool?
    ) -> [String: JSONValue] {
        switch route {
        case .dashscopeMultimodal:
            // Images first (base, then ascending slot), then exactly one text item; generation sends text only.
            let content = images.map { JSONValue.object(["image": .string(dataUri($0))]) }
                + [JSONValue.object(["text": .string(prompt)])]
            // parameters is always an object; watermark is never written.
            var parameters: [String: JSONValue] = [:]
            if let promptExtend { parameters["prompt_extend"] = .bool(promptExtend) }
            return [
                "model": .string(modelId),
                "input": .object(["messages": .array([.object(["role": .string("user"), "content": .array(content)])])]),
                "parameters": .object(parameters),
            ]
        case .geminiGenerateContent:
            // Text part first, then the images; inline_data.data is plain base64.
            let parts = [JSONValue.object(["text": .string(prompt)])] + images.map {
                JSONValue.object(["inline_data": .object([
                    "mime_type": .string($0.mime),
                    "data": .string($0.data.base64EncodedString()),
                ])])
            }
            return [
                "contents": .array([.object(["role": .string("user"), "parts": .array(parts)])]),
                "generationConfig": .object(["responseModalities": .array([.string("TEXT"), .string("IMAGE")])]),
            ]
        case .chatModalities:
            let content: JSONValue
            if transport == nil {
                content = .string(prompt)
            } else {
                content = .array([JSONValue.object(["type": .string("text"), "text": .string(prompt)])] + images.map {
                    JSONValue.object(["type": .string("image_url"), "image_url": .object(["url": .string(dataUri($0))])])
                })
            }
            return [
                "model": .string(modelId),
                "messages": .array([.object(["role": .string("user"), "content": content])]),
                "modalities": .array([.string("image"), .string("text")]),
                "stream": .bool(false),
            ]
        default:
            break
        }
        var body: [String: JSONValue] = ["model": .string(modelId), "prompt": .string(prompt)]
        switch transport {
        case .jsonImage?:
            if let image = images.first { body["image"] = .string(dataUri(image)) }
        case .jsonImageUrl?:
            if let image = images.first { body["image_url"] = .string(dataUri(image)) }
        case .jsonImageObject?:
            let objects = images.map { JSONValue.object(["url": .string(dataUri($0))]) }
            if objects.count == 1 {
                body["image"] = objects[0]
            } else {
                body["images"] = .array(objects)
            }
        case .inputReferences?:
            // Always an array, even for one image.
            body["input_references"] = .array(images.map {
                JSONValue.object(["type": .string("image_url"), "image_url": .object(["url": .string(dataUri($0))])])
            })
        default:
            break
        }
        if route == .xaiImages { body["response_format"] = .string("b64_json") }
        if route == .minimaxImageGeneration { body["response_format"] = .string("base64") }
        return body
    }

    /// Percent-encodes every UTF-8 byte outside RFC 3986 unreserved (A-Z a-z 0-9 - . _ ~), upper-case hex.
    private static func percentEncoded(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// Checks the images against the operation and returns them base first, then by ascending slot;
    /// nil when any image rule is broken.
    private static func orderedImages(
        _ input: Input,
        transport: ImageProfile.EditTransport?,
        profile: ImageProfile
    ) -> [Image]? {
        let images = input.images
        guard let transport else { return images.isEmpty ? [] : nil }
        guard !images.isEmpty else { return nil }
        let slots = images.map(\.slot)
        guard slots.allSatisfy({ $0 >= 1 }), Set(slots).count == slots.count else { return nil }
        guard images.filter({ $0.role == "base" }).count <= 1 else { return nil }
        guard images.allSatisfy({ supportedMimes.contains($0.mime) && !$0.data.isEmpty }) else { return nil }
        var limit = profile.maxReferenceImages.flatMap { $0 >= 1 ? $0 : nil } ?? 1
        if let transportCap = transportLimit(transport) { limit = min(limit, transportCap) }
        guard images.count <= limit else { return nil }
        return images.sorted { lhs, rhs in
            let lhsBase = lhs.role == "base"
            let rhsBase = rhs.role == "base"
            if lhsBase != rhsBase { return lhsBase }
            return lhs.slot < rhs.slot
        }
    }

    /// Textual base URL rule shared by every client instead of a platform URL parser:
    /// http(s)://host[:port][/path], no userinfo / query / fragment. Whitespace classes spell out the
    /// ASCII set instead of \s / \v, whose meaning differs between engines; U+00A0 is a plain character.
    private static let baseUrlPattern =
        #"^[Hh][Tt][Tt][Pp][Ss]?://(\[[0-9A-Fa-f:.]+\]|[^/?# \t\n\x0B\f\r:@\[\]]+)(:[0-9]{1,5})?(/[^?# \t\n\x0B\f\r]*)?$"#

    /// The ASCII-trimmed base URL with trailing slashes dropped when it matches the rule; nil otherwise.
    private static func baseUrl(_ raw: String) -> String? {
        var trimmed = asciiTrimmed(raw)
        guard let regex = try? NSRegularExpression(pattern: baseUrlPattern),
              regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Only ASCII whitespace (space, \t, \n, \v, \f, \r) counts as blank, so every client trims alike;
    /// U+00A0 and other Unicode spaces are kept.
    static func asciiTrimmed(_ text: String) -> String {
        let blank: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        let bytes = Array(text.utf8)
        guard let first = bytes.firstIndex(where: { !blank.contains($0) }),
              let last = bytes.lastIndex(where: { !blank.contains($0) }) else { return "" }
        return String(decoding: bytes[first...last], as: UTF8.self)
    }

    /// Advanced body fields in send order: negative_prompt, seed, background, output_format. A field
    /// goes out only when `profile.params[field]` is literally true and the route has a key for it.
    private static func advancedValues(_ profile: ImageProfile, advanced: Advanced) -> [(String, ImageParamNormalizer.WireValue)] {
        let keys = advancedKeys(profile.route)
        func supported(_ field: String) -> Bool {
            guard case .some(.some(true)) = profile.params?[field] else { return false }
            return true
        }
        var values: [(String, ImageParamNormalizer.WireValue)] = []
        if let key = keys.negativePrompt, supported("negativePrompt"), let negative = advanced.negativePrompt,
           !asciiTrimmed(negative).isEmpty {
            values.append((key, .string(negative)))
        }
        if let key = keys.seed, supported("seed"), let seed = advanced.seed {
            values.append((key, .integer(seed)))
        }
        var transparent = false
        if let key = keys.background, supported("transparentBackground"), advanced.transparentBackground == true {
            values.append((key, .string("transparent")))
            transparent = true
        }
        if let key = keys.outputFormat, supported("outputFormat") {
            if transparent {
                values.append((key, .string("png")))
            } else if let format = advanced.outputFormat {
                values.append((key, .string(format)))
            }
        }
        return values
    }

    /// `profile.params.promptExtend` when it is a literal boolean (false included); nil when null or
    /// missing. Only dashscope_multimodal sends it.
    private static func promptExtend(_ profile: ImageProfile) -> Bool? {
        guard profile.route == .dashscopeMultimodal, case .some(.some(let flag)) = profile.params?["promptExtend"] else {
            return nil
        }
        return flag
    }

    /// Writes a dotted key; false when it lands on an existing key, passes through a non-object value
    /// (arrays included), or any segment is "__proto__".
    private static func insert(_ object: inout [String: JSONValue], path: [String], value: JSONValue) -> Bool {
        guard let head = path.first, head != "__proto__" else { return false }
        if path.count == 1 {
            guard object[head] == nil else { return false }
            object[head] = value
            return true
        }
        var child: [String: JSONValue] = [:]
        switch object[head] {
        case nil: break
        case .object(let existing)?: child = existing
        default: return false
        }
        guard insert(&child, path: Array(path.dropFirst()), value: value) else { return false }
        object[head] = .object(child)
        return true
    }

    private static func json(_ value: ImageParamNormalizer.WireValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(text)
        case .integer(let number): return .number(Double(number))
        }
    }

    private static func text(_ value: ImageParamNormalizer.WireValue) -> String {
        switch value {
        case .string(let text): return text
        case .integer(let number): return String(number)
        }
    }

    private static func dataUri(_ image: Image) -> String {
        "data:\(image.mime);base64,\(image.data.base64EncodedString())"
    }

    private static func fileExtension(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        default: return "png"
        }
    }
}
