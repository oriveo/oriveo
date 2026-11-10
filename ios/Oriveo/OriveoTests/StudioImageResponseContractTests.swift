import Foundation
import Testing
@testable import Oriveo

/// Image response normalization cases shared by all three clients: reads
/// `shared/model-contracts/image_response_samples.v1/index.json` (contractId
/// "image_response_samples.v1") and runs realSamples, parserCases, metaExpect, metaCases,
/// decodeCases, materializeCases and assembleCases against `StudioImageResponse`.
@Suite("StudioImageResponseContractTests")
struct StudioImageResponseContractTests {
    static let contractId = "image_response_samples.v1"

    static func repoFile(_ components: [String]) throws -> URL {
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

    static func fixtureFile(_ name: String) throws -> URL {
        try repoFile(["shared", "model-contracts", contractId, name])
    }

    static func index() throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureFile("index.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// The captured provider body of one real sample (the `response` member of its file).
    static func sampleResponse(_ file: String) throws -> Any? {
        let data = try Data(contentsOf: fixtureFile(file))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object["response"]
    }

    static func group(_ name: String) throws -> [[String: Any]] {
        let index = try index()
        #expect(index["contractId"] as? String == contractId)
        guard let group = index[name] as? [[String: Any]], !group.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return group
    }

    /// JSON null and missing both read as nil.
    static func string(_ value: Any?) -> String? { value as? String }

    /// Fixture `usage` object; JSON null reads as nil, per field too.
    static func usage(_ value: Any?) -> StudioImageResponse.Usage? {
        (value as? [String: Any]).map {
            StudioImageResponse.Usage(
                inputTokens: $0["inputTokens"] as? Int,
                outputTokens: $0["outputTokens"] as? Int,
                totalTokens: $0["totalTokens"] as? Int
            )
        }
    }

    /// Fixture `declaredSize` object; JSON null reads as nil.
    static func size(_ value: Any?) throws -> StudioImageResponse.Size? {
        guard let raw = value as? [String: Any] else { return nil }
        return StudioImageResponse.Size(
            width: try #require(raw["width"] as? Int), height: try #require(raw["height"] as? Int)
        )
    }

    @Test("realSamples: shapes, deduped and image kind + mime per captured response")
    func realSamples() throws {
        for sample in try Self.group("samples") {
            let file = try #require(sample["file"] as? String)
            let expect = try #require(sample["expect"] as? [String: Any])
            let nRequested = try #require(sample["nRequested"] as? Int)
            let parsed = StudioImageResponse.parse(try Self.sampleResponse(file))

            #expect(parsed.shapes == (expect["shapes"] as? [String]), "\(file) shapes")
            #expect(parsed.deduped == (expect["deduped"] as? [String]), "\(file) deduped")
            let images = try #require(expect["images"] as? [[String: Any]])
            #expect(parsed.images.map(\.kind.rawValue) == images.map { Self.string($0["kind"]) ?? "?" }, "\(file) kinds")
            #expect(parsed.images.map(\.mime) == images.map { Self.string($0["mime"]) }, "\(file) mimes")

            let assembled = StudioImageResponse.assemble(
                nRequested: nRequested,
                outcomes: parsed.images.map { _ in .ok }
            )
            if Self.string(expect["result"]) == "ok" {
                #expect(assembled.result == .ok, "\(file) all images delivered must be ok")
            } else {
                #expect(assembled.result == nil, "\(file) is left to the error classifier")
            }
        }
    }

    @Test("parserCases: synthetic bodies through parse(_:) and parse(data:)")
    func parserCases() throws {
        for testCase in try Self.group("parserCases") {
            let name = try #require(testCase["name"] as? String)
            let expect = try #require(testCase["expect"] as? [String: Any])
            let body = testCase["body"]
            let parsed = StudioImageResponse.parse(body)

            #expect(parsed.shapes == (expect["shapes"] as? [String]), "\(name) shapes")
            #expect(parsed.deduped == (expect["deduped"] as? [String]), "\(name) deduped")
            let images = try #require(expect["images"] as? [[String: Any]])
            #expect(parsed.images.count == images.count, "\(name) image count")
            for (actual, wanted) in zip(parsed.images, images) {
                #expect(actual.kind.rawValue == Self.string(wanted["kind"]), "\(name) kind")
                #expect(actual.mime == Self.string(wanted["mime"]), "\(name) mime")
                #expect(actual.value == Self.string(wanted["value"]), "\(name) value")
                #expect(actual.revisedPrompt == Self.string(wanted["revisedPrompt"]), "\(name) revisedPrompt")
            }

            let raw = try JSONSerialization.data(withJSONObject: body ?? NSNull(), options: [.fragmentsAllowed])
            #expect(StudioImageResponse.parse(data: raw) == parsed, "\(name) parse(data:) matches parse(_:)")
        }
        #expect(StudioImageResponse.parse(data: Data("not json".utf8)).images.isEmpty)
    }

    @Test("metaExpect: usage and declaredSize per real sample")
    func metaExpect() throws {
        let entries = try Self.group("metaExpect")
        let sampleFiles = try Self.group("samples").map { try #require($0["file"] as? String) }
        #expect(entries.count == sampleFiles.count, "one metaExpect entry per real sample")
        #expect(entries.compactMap { $0["file"] as? String } == sampleFiles, "metaExpect files follow samples")
        for entry in entries {
            let file = try #require(entry["file"] as? String)
            let parsed = StudioImageResponse.parse(try Self.sampleResponse(file))
            #expect(parsed.usage == Self.usage(entry["usage"]), "\(file) usage")
            #expect(parsed.declaredSize == (try Self.size(entry["declaredSize"])), "\(file) declaredSize")
        }
    }

    @Test("metaCases: synthetic usage and declaredSize bodies")
    func metaCases() throws {
        for testCase in try Self.group("metaCases") {
            let name = try #require(testCase["name"] as? String)
            let parsed = StudioImageResponse.parse(testCase["body"])
            #expect(parsed.usage == Self.usage(testCase["usage"]), "\(name) usage")
            #expect(parsed.declaredSize == (try Self.size(testCase["declaredSize"])), "\(name) declaredSize")
        }
    }

    @Test("materializeCases: base64 tolerance, data URL marker, decoded mime wins")
    func materializeCases() async throws {
        for testCase in try Self.group("materializeCases") {
            let name = try #require(testCase["name"] as? String)
            let image = try #require(testCase["image"] as? [String: Any])
            let kind = try #require(StudioImageResponse.Kind(rawValue: image["kind"] as? String ?? ""), "\(name) kind")
            let value = try #require(image["value"] as? String)
            let expect = try #require(testCase["expect"] as? [String: Any])
            let result = await StudioImageResponse.materialize(.init(kind: kind, mime: nil, value: value, revisedPrompt: nil))
            if expect["ok"] as? Bool == true {
                let materialized = try #require(try? result.get(), "\(name) should succeed, got \(result)")
                #expect(materialized.mime == expect["mime"] as? String, "\(name) mime")
                #expect(materialized.width == expect["width"] as? Int, "\(name) width")
                #expect(materialized.height == expect["height"] as? Int, "\(name) height")
                #expect(StudioImageResponse.decodeImageInfo(materialized.bytes)?.mime == materialized.mime, "\(name) bytes")
            } else {
                let wanted = try #require(StudioImageResponse.Failure(rawValue: expect["failure"] as? String ?? ""))
                #expect(result == .failure(wanted), "\(name) failure")
            }
        }
    }

    @Test("decodeCases: header decode, and materialize of b64 / data URL follows it")
    func decodeCases() async throws {
        for testCase in try Self.group("decodeCases") {
            let name = try #require(testCase["name"] as? String)
            let b64 = try #require(testCase["b64"] as? String)
            let bytes = try #require(Data(base64Encoded: b64), "\(name) fixture base64")
            let expected = (testCase["expect"] as? [String: Any]).flatMap { raw -> StudioImageResponse.ImageInfo? in
                guard let mime = raw["mime"] as? String, let width = raw["width"] as? Int,
                      let height = raw["height"] as? Int else { return nil }
                return StudioImageResponse.ImageInfo(mime: mime, width: width, height: height)
            }
            if testCase["expect"] is [String: Any] {
                #expect(expected != nil, "\(name) fixture expect")
            }
            #expect(StudioImageResponse.decodeImageInfo(bytes) == expected, "\(name) decodeImageInfo")

            let wanted: Result<StudioImageResponse.Materialized, StudioImageResponse.Failure> = expected.map {
                .success(.init(bytes: bytes, mime: $0.mime, width: $0.width, height: $0.height))
            } ?? .failure(.decodeFailed)
            let fromB64 = await StudioImageResponse.materialize(
                .init(kind: .b64, mime: nil, value: b64, revisedPrompt: nil)
            )
            #expect(fromB64 == wanted, "\(name) materialize b64")
            let fromDataURL = await StudioImageResponse.materialize(
                .init(kind: .dataURL, mime: "image/png", value: "data:image/png;base64,\(b64)", revisedPrompt: nil)
            )
            #expect(fromDataURL == wanted, "\(name) materialize data URL (decoded mime wins)")
        }
        let garbage = await StudioImageResponse.materialize(
            .init(kind: .b64, mime: nil, value: "%%%not base64%%%", revisedPrompt: nil)
        )
        #expect(garbage == .failure(.decodeFailed))
    }

    @Test("assembleCases: per-image outcomes to result")
    func assembleCases() throws {
        for testCase in try Self.group("assembleCases") {
            let name = try #require(testCase["name"] as? String)
            let nRequested = try #require(testCase["nRequested"] as? Int)
            let raw = try #require(testCase["outcomes"] as? [String])
            let expect = try #require(testCase["expect"] as? [String: Any])
            let outcomes: [StudioImageResponse.Outcome] = try raw.map { value in
                if value == "ok" { return .ok }
                return .failed(try #require(StudioImageResponse.Failure(rawValue: value), "\(name) outcome \(value)"))
            }

            let assembled = StudioImageResponse.assemble(nRequested: nRequested, outcomes: outcomes)
            #expect(assembled.result?.name == Self.string(expect["result"]), "\(name) result")
            #expect(assembled.delivered == expect["delivered"] as? Int, "\(name) delivered")
            #expect(assembled.failures.map(\.rawValue) == (expect["failures"] as? [String]), "\(name) failures")
        }
    }
}
