import Foundation

/// Normalizes an image generation response body into a flat list of images, plus usage and
/// declared size, and turns per-image outcomes into one delivery result. Pure functions only;
/// URL images are downloaded by `StudioImageFetcher`.
///
/// Cases: `shared/model-contracts/image_response_samples.v1/index.json`, read by the
/// iOS / Android / Web contract tests alike. Parsers accept every shape and never assume a
/// shape per model or provider.
nonisolated enum StudioImageResponse {
    enum Kind: String, Equatable, Sendable {
        case b64
        case url
        case dataURL = "data_url"
    }

    /// One image as found in the body. `value` is the raw base64 string, the URL, or the
    /// full data URL; `mime` is the declared mime (nil = sniff from the bytes).
    struct Image: Equatable, Sendable {
        var kind: Kind
        var mime: String?
        var value: String
        var revisedPrompt: String?
    }

    struct Usage: Equatable, Sendable {
        var inputTokens: Int?
        var outputTokens: Int?
        var totalTokens: Int?
    }

    struct Size: Equatable, Sendable {
        var width: Int
        var height: Int
    }

    struct Parsed: Equatable, Sendable {
        /// Shape names in first-seen order, each once.
        var shapes: [String] = []
        /// Shapes skipped because they duplicate another one (SiliconFlow `images[]`).
        var deduped: [String] = []
        var images: [Image] = []
        var usage: Usage?
        /// Informational only: the real pixel size always comes from `decodeImageInfo`.
        var declaredSize: Size?
    }

    /// Pixel size as stored in the image header (EXIF orientation ignored).
    struct ImageInfo: Equatable, Sendable {
        var mime: String
        var width: Int
        var height: Int
    }

    /// Image bytes ready to store; `mime` comes from the decoded header, not the declaration.
    struct Materialized: Equatable, Sendable {
        var bytes: Data
        var mime: String
        var width: Int
        var height: Int
    }

    /// Per-image failure kinds, named as in image_error_samples.v1.
    enum Failure: String, Error, Equatable, Sendable {
        case network
        case timeout
        case decodeFailed = "decode_failed"
    }

    enum Outcome: Equatable, Sendable {
        case ok
        case failed(Failure)
    }

    enum Delivery: Equatable, Sendable {
        case ok
        case partial
        case failed(Failure)

        var name: String {
            switch self {
            case .ok: return "ok"
            case .partial: return "partial"
            case let .failed(failure): return failure.rawValue
            }
        }
    }

    struct Assembly: Equatable, Sendable {
        /// nil = no image at all; the error classifier decides.
        var result: Delivery?
        var delivered: Int
        var failures: [Failure]
    }

    // MARK: - parse

    /// Convenience over raw bytes; anything that is not JSON parses as an empty result.
    static func parse(data: Data) -> Parsed {
        parse(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// `body` is what `JSONSerialization` produced; non-objects give an empty result.
    static func parse(_ body: Any?) -> Parsed {
        var parsed = Parsed()
        guard let body = body as? [String: Any] else { return parsed }

        func add(_ shape: String, _ kind: Kind, _ mime: String?, _ value: String, _ revisedPrompt: String? = nil) {
            if !parsed.shapes.contains(shape) { parsed.shapes.append(shape) }
            parsed.images.append(Image(kind: kind, mime: mime, value: value, revisedPrompt: revisedPrompt))
        }
        func addURL(_ shape: String, _ url: String, _ revisedPrompt: String? = nil) {
            if isDataURL(url) {
                add(shape, .dataURL, mimeOfDataURL(url), url, revisedPrompt)
            } else {
                add(shape, .url, nil, url, revisedPrompt)
            }
        }

        // data[]: b64_json wins over url inside one item.
        let dataArray = body["data"] as? [Any]
        for case let item as [String: Any] in dataArray ?? [] {
            let revisedPrompt = item["revised_prompt"] as? String
            if let b64 = item["b64_json"] as? String {
                let mime = (item["mime_type"] as? String) ?? (item["media_type"] as? String)
                add("data[].b64_json", .b64, mime, b64, revisedPrompt)
            } else if let url = item["url"] as? String {
                addURL("data[].url", url, revisedPrompt)
            }
        }
        // SiliconFlow sends images[] and data[] for the same picture: take data[] only.
        if let images = body["images"] as? [Any] {
            if let dataArray, !dataArray.isEmpty {
                parsed.deduped.append("images[].url")
            } else {
                for case let item as [String: Any] in images {
                    if let url = item["url"] as? String { addURL("images[].url", url) }
                }
            }
        }
        // MiniMax: data is an object holding image_base64[].
        if let dataObject = body["data"] as? [String: Any], let list = dataObject["image_base64"] as? [Any] {
            for case let b64 as String in list { add("data.image_base64[]", .b64, nil, b64) }
        }
        for case let choice as [String: Any] in body["choices"] as? [Any] ?? [] {
            guard let message = choice["message"] as? [String: Any] else { continue }
            for case let item as [String: Any] in message["images"] as? [Any] ?? [] {
                if let url = (item["image_url"] as? [String: Any])?["url"] as? String {
                    addURL("message.images[]", url)
                }
            }
            if let content = message["content"] as? String {
                for url in markdownDataURLs(content) {
                    add("markdown data URL", .dataURL, mimeOfDataURL(url), url)
                }
            }
        }
        for case let candidate as [String: Any] in body["candidates"] as? [Any] ?? [] {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [Any] ?? []
            for case let part as [String: Any] in parts {
                // A camelCase key holding a non-object (e.g. null) falls back to the snake_case one.
                guard let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any]),
                      let b64 = inline["data"] as? String else { continue }
                let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String)
                add("inlineData", .b64, mime, b64)
            }
        }
        let outputChoices = (body["output"] as? [String: Any])?["choices"] as? [Any] ?? []
        for case let choice as [String: Any] in outputChoices {
            let content = (choice["message"] as? [String: Any])?["content"] as? [Any] ?? []
            for case let part as [String: Any] in content {
                if let url = part["image"] as? String { addURL("output.choices[].message.content[].image", url) }
            }
        }

        parsed.usage = usage(of: body)
        parsed.declaredSize = declaredSize(of: body)
        return parsed
    }

    private static func isDataURL(_ value: String) -> Bool {
        value.prefix(5).lowercased() == "data:"
    }

    /// Lowercased mime of a `data:image/...;base64,` prefix, nil when there is none.
    private static func mimeOfDataURL(_ url: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "^data:(image/[a-z0-9.+-]+);base64,", options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range),
              let mime = Range(match.range(at: 1), in: url) else { return nil }
        return url[mime].lowercased()
    }

    /// Data URLs in markdown image syntax, in order; plain http links are ignored.
    private static func markdownDataURLs(_ content: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "!\\[[^\\]]*\\]\\((data:image/[a-z0-9.+-]+;base64,[^)]+)\\)", options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            Range(match.range(at: 1), in: content).map { String(content[$0]) }
        }
    }

    /// JSON integers only: not Bool, no fractional part.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if !CFNumberIsFloatType(number) { return number.intValue }
        return Int(exactly: number.doubleValue)
    }

    /// Per field: first positive integer among the sources, else the first integer present.
    private static func usage(of body: [String: Any]) -> Usage? {
        let usage = body["usage"] as? [String: Any] ?? [:]
        let metadata = body["usageMetadata"] as? [String: Any] ?? [:]
        func pick(_ values: [Any?]) -> Int? {
            let integers = values.compactMap(integer)
            return integers.first { $0 > 0 } ?? integers.first
        }
        let result = Usage(
            inputTokens: pick([usage["input_tokens"], usage["prompt_tokens"], metadata["promptTokenCount"]]),
            outputTokens: pick([usage["output_tokens"], usage["completion_tokens"], metadata["candidatesTokenCount"]]),
            totalTokens: pick([usage["total_tokens"], metadata["totalTokenCount"]])
        )
        if result.inputTokens == nil, result.outputTokens == nil, result.totalTokens == nil { return nil }
        return result
    }

    /// Top-level `size` "WxH" (ASCII digits only, both > 0), else `usage.width` + `usage.height`.
    private static func declaredSize(of body: [String: Any]) -> Size? {
        if let size = body["size"] as? String {
            let parts = size.split(separator: "x", omittingEmptySubsequences: false)
            if parts.count == 2, let width = digits(parts[0]), let height = digits(parts[1]), width > 0, height > 0 {
                return Size(width: width, height: height)
            }
        }
        let usage = body["usage"] as? [String: Any] ?? [:]
        if let width = integer(usage["width"]), let height = integer(usage["height"]), width > 0, height > 0 {
            return Size(width: width, height: height)
        }
        return nil
    }

    /// Non-empty run of ASCII digits; no sign, no spaces (unlike `Int(String)`).
    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(text)
    }

    // MARK: - decodeImageInfo

    /// Reads the stored pixel size from a png / jpeg / webp header; anything else, truncated
    /// or empty gives nil (= decode_failed).
    static func decodeImageInfo(_ bytes: Data) -> ImageInfo? {
        let b = [UInt8](bytes)
        return png(b) ?? jpeg(b) ?? webp(b)
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int { be16(b, i) << 16 | be16(b, i + 2) }
    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func le24(_ b: [UInt8], _ i: Int) -> Int { le16(b, i) | Int(b[i + 2]) << 16 }

    private static func info(_ mime: String, _ width: Int, _ height: Int) -> ImageInfo? {
        width > 0 && height > 0 ? ImageInfo(mime: mime, width: width, height: height) : nil
    }

    private static func png(_ b: [UInt8]) -> ImageInfo? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 24, Array(b[0..<8]) == signature, Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
        let width = be32(b, 16), height = be32(b, 20)
        guard width <= Int(Int32.max), height <= Int(Int32.max) else { return nil }
        return info("image/png", width, height)
    }

    /// Walks the marker segments up to the first SOF0–SOF15 (C4 DHT, C8 JPG, CC DAC are not frames).
    private static func jpeg(_ b: [UInt8]) -> ImageInfo? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i < b.count {
            guard b[i] == 0xFF else { return nil }
            while i < b.count, b[i] == 0xFF { i += 1 }
            guard i < b.count else { return nil }
            let marker = b[i]
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { i += 1; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }
            guard i + 2 < b.count else { return nil }
            let length = be16(b, i + 1)
            guard length >= 2 else { return nil }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard length >= 7, i + 7 < b.count else { return nil }
                return info("image/jpeg", be16(b, i + 6), be16(b, i + 4))
            }
            i += 1 + length
        }
        return nil
    }

    private static func webp(_ b: [UInt8]) -> ImageInfo? {
        guard b.count >= 20, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) else {
            return nil
        }
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8 ":
            guard b.count >= 30, b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A else { return nil }
            return info("image/webp", le16(b, 26) & 0x3FFF, le16(b, 28) & 0x3FFF)
        case "VP8L":
            guard b.count >= 25, b[20] == 0x2F else { return nil }
            let bits = le24(b, 21) | Int(b[24]) << 24
            return info("image/webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        case "VP8X":
            guard b.count >= 30 else { return nil }
            return info("image/webp", le24(b, 24) + 1, le24(b, 27) + 1)
        default:
            return nil
        }
    }

    // MARK: - materialize

    /// b64 / data URL: decode base64 then the header, any failure is decode_failed. A data URL
    /// must carry `;base64,` (any case). URL: handed to the fetcher.
    static func materialize(
        _ image: Image,
        fetcher: StudioImageFetcher = StudioImageFetcher()
    ) async -> Result<Materialized, Failure> {
        let encoded: Substring
        switch image.kind {
        case .url:
            guard let url = URL(string: image.value) else { return .failure(.decodeFailed) }
            return await fetcher.fetch(url)
        case .b64:
            encoded = Substring(image.value)
        case .dataURL:
            guard let marker = image.value.range(of: ";base64,", options: [.caseInsensitive]) else {
                return .failure(.decodeFailed)
            }
            encoded = image.value[marker.upperBound...]
        }
        guard let bytes = decodeBase64(encoded) else { return .failure(.decodeFailed) }
        return materialized(bytes)
    }

    /// Standard alphabet only: whitespace is dropped and missing `=` padding added; any other
    /// non-alphabet character (URL-safe `-` / `_` included) fails.
    private static func decodeBase64(_ encoded: Substring) -> Data? {
        var text = String(encoded.filter { !$0.isWhitespace })
        let remainder = text.utf8.count % 4
        if remainder != 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    /// Header-checked bytes, shared with the fetcher.
    static func materialized(_ bytes: Data) -> Result<Materialized, Failure> {
        guard let info = decodeImageInfo(bytes) else { return .failure(.decodeFailed) }
        return .success(Materialized(bytes: bytes, mime: info.mime, width: info.width, height: info.height))
    }

    // MARK: - assemble

    /// No outcome → nil; none delivered → the first failure; at least nRequested delivered → ok
    /// (extra images and failures of extra images do not matter); otherwise partial.
    static func assemble(nRequested: Int, outcomes: [Outcome]) -> Assembly {
        var delivered = 0
        var failures: [Failure] = []
        for outcome in outcomes {
            switch outcome {
            case .ok: delivered += 1
            case let .failed(failure): failures.append(failure)
            }
        }
        let result: Delivery?
        if outcomes.isEmpty {
            result = nil
        } else if delivered == 0 {
            result = .failed(failures[0])
        } else if delivered >= nRequested {
            result = .ok
        } else {
            result = .partial
        }
        return Assembly(result: result, delivered: delivered, failures: failures)
    }
}
