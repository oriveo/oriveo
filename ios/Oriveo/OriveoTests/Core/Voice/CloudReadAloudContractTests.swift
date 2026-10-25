import Foundation
import Testing
@testable import Oriveo

/// The production CloudReadAloudRules reproduce every expected value in shared/voice-contracts/cloud-read-aloud.v1.json.
/// bodyCases entries reference {providerKind, direction, model} into the data object of voice_catalog_contract.v2.json;
/// method / path / json are parsed from the production URLRequest.
@Suite("Cloud read-aloud contract")
struct CloudReadAloudContractTests {

    // MARK: Fixtures

    private static func fixture(_ relativePath: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func contract() throws -> [String: Any] {
        try fixture("shared/voice-contracts/cloud-read-aloud.v1.json")
    }

    private static func cases(_ group: String) throws -> [[String: Any]] {
        let items = try #require(try contract()[group] as? [[String: Any]], "Missing case group \(group)")
        #expect(!items.isEmpty, "Case group is empty: \(group)")
        return items
    }

    private static func catalog() throws -> VoiceCatalog {
        let data = try #require(try fixture("shared/model-contracts/voice_catalog_contract.v2.json")["data"])
        return VoiceCatalogDecoder.decode(data)
    }

    /// {providerKind, direction: "tts", model} -> the matching read-aloud entry in the decoded catalog.
    private static func ttsEntry(_ raw: Any?, in catalog: VoiceCatalog) throws -> VoiceTTSEntry {
        let reference = try #require(raw as? [String: Any])
        #expect(reference["direction"] as? String == "tts")
        let rawKind = try #require(reference["providerKind"] as? String)
        let kind = try #require(ProviderKind(rawValue: rawKind))
        let model = try #require(reference["model"] as? String)
        return try #require(catalog.ttsEntries(kind).first { $0.model == model }, "Catalog has no \(kind.rawValue)/\(model)")
    }

    private static func number(_ raw: Any?) throws -> Double {
        try #require(raw as? NSNumber).doubleValue
    }

    private static func describe(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Constants

    @Test("constants match production constants")
    func constantsMatchProduction() throws {
        let constants = try #require(try Self.contract()["constants"] as? [String: Any])
        #expect(constants["unit"] as? String == "unicode_scalar")
        #expect(constants["firstChunkMaxCodePoints"] as? Int == CloudReadAloudRules.firstChunkMaxCodePoints)
        #expect(constants["firstChunkMaxSentences"] as? Int == CloudReadAloudRules.firstChunkMaxSentences)
        #expect(constants["laterChunkCapCodePoints"] as? Int == CloudReadAloudRules.laterChunkCapCodePoints)
        #expect(constants["sentenceJoiner"] as? String == CloudReadAloudRules.sentenceJoiner)
        #expect(constants["prefetchChunks"] as? Int == CloudReadAloudRules.prefetchChunks)
        #expect(try Self.number(constants["languageMinConfidence"]) == CloudReadAloudRules.languageMinConfidence)
        #expect(constants["xaiTtsLanguages"] as? [String] == CloudReadAloudRules.xaiTtsLanguages)
        #expect(constants["xaiDefaultRegion"] as? [String: String] == CloudReadAloudRules.xaiDefaultRegion)
        let slider = try #require(constants["speedSlider"] as? [String: Any])
        #expect(try Self.number(slider["min"]) == CloudReadAloudRules.speedSliderMin)
        #expect(try Self.number(slider["max"]) == CloudReadAloudRules.speedSliderMax)
        #expect(try Self.number(slider["step"]) == CloudReadAloudRules.speedSliderStep)
        #expect(try Self.number(slider["default"]) == CloudReadAloudRules.speedSliderDefault)
        #expect(constants["speedDecimals"] as? Int == CloudReadAloudRules.speedDecimals)

        let cache = try #require(constants["cache"] as? [String: Any])
        #expect(cache["maxBytes"] as? Int == SpeechAudioCache.defaultMaxBytes)
        #expect(cache["keyFields"] as? [String] == SpeechAudioCacheKey.fieldNames)
        #expect(cache["eviction"] as? String == "lru")
        #expect(cache["backup"] as? Bool == false)
    }

    // MARK: Cases

    @Test("chunkCases match one by one")
    func chunkCases() throws {
        for item in try Self.cases("chunkCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let sentences = try #require(input["sentences"] as? [String])
            let maxChars = Int(try Self.number(input["maxChars"]))
            let expected = try #require(item["expected"] as? [String])
            let actual = CloudReadAloudRules.chunks(sentences: sentences, maxChars: maxChars)
            #expect(actual == expected, "\(id)\nactual \(actual.map { $0.unicodeScalars.count })\nexpected \(expected.map { $0.unicodeScalars.count })")
        }
    }

    @Test("readingLanguageCases match one by one")
    func readingLanguageCases() throws {
        for item in try Self.cases("readingLanguageCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let rawHypotheses = try #require(input["hypotheses"] as? [[String: Any]])
            var hypotheses: [String: Double] = [:]
            for hypothesis in rawHypotheses {
                hypotheses[try #require(hypothesis["language"] as? String)] = try Self.number(hypothesis["confidence"])
            }
            let uiLocale = try #require(input["uiLocale"] as? String)
            let actual = CloudReadAloudRules.readingLanguage(hypotheses: hypotheses, uiLocale: uiLocale)
            #expect(actual == item["expected"] as? String, "\(id) actual \(actual)")
        }
    }

    @Test("xaiLanguageCases match one by one")
    func xaiLanguageCases() throws {
        for item in try Self.cases("xaiLanguageCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let actual = CloudReadAloudRules.xaiLanguage(try #require(input["language"] as? String))
            #expect(actual == item["expected"] as? String, "\(id) actual \(actual)")
        }
    }

    @Test("bodyCases match one by one (taken from the production URLRequest)")
    func bodyCases() throws {
        let catalog = try Self.catalog()
        let baseURL = try #require(URL(string: "https://api.example.test/some/base?x=1"))
        for item in try Self.cases("bodyCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let entry = try Self.ttsEntry(input["entry"], in: catalog)
            let text = try #require(input["text"] as? String)
            let voice = try #require(input["voice"] as? String)
            let language = try #require(input["language"] as? String)
            let built = CloudReadAloudRules.makeRequest(
                baseURL: baseURL,
                entry: entry,
                text: text,
                voice: voice,
                speed: (input["speed"] as? NSNumber)?.doubleValue,
                language: language,
                apiKey: "test-key"
            )
            let request = try #require(built, "\(id) no request")
            let expected = try #require(item["expected"] as? [String: Any])
            #expect(request.httpMethod == expected["method"] as? String, "\(id) method")
            #expect(request.url?.host == "api.example.test", "\(id) host")
            #expect(request.url?.query == nil, "\(id) query")
            #expect(request.url?.path == expected["path"] as? String, "\(id) path \(request.url?.path ?? "nil")")
            // Auth headers follow expected.headers; the default is Bearer + JSON.
            let headers = expected["headers"] as? [String: String]
                ?? ["Authorization": "Bearer test-key", "Content-Type": "application/json"]
            for (field, value) in headers {
                #expect(request.value(forHTTPHeaderField: field) == value, "\(id) header \(field)")
            }
            // On the wire only the auth header and Content-Type are sent (no Accept).
            #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == Set(headers.keys), "\(id) headers \(request.allHTTPHeaderFields ?? [:])")
            let authFields = ["Authorization", "x-goog-api-key"]
            for field in authFields where !headers.keys.contains(field) {
                #expect(request.value(forHTTPHeaderField: field) == nil, "\(id) sent unexpected \(field)")
            }
            #expect(request.timeoutInterval == 30, "\(id) timeout")
            let body = try #require(request.httpBody, "\(id) no request body")
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any], "\(id) request body is not an object")
            let expectedJSON = try #require(expected["json"] as? [String: Any])
            #expect(
                NSDictionary(dictionary: json).isEqual(to: expectedJSON),
                "\(id)\nactual \(Self.describe(json))\nexpected \(Self.describe(expectedJSON))"
            )
        }
    }

    @Test("mistral_speech always sends response_format mp3 and ignores the catalog outputFormat")
    func mistralSpeechAlwaysMP3() throws {
        let entry = VoiceTTSEntry(
            model: "voxtral-mini-tts-3-0", transport: .mistralSpeech, path: "/v1/audio/speech", outputFormat: "wav",
            maxChars: 1000, voices: [VoiceCatalogVoice(id: "v1", isDefault: true)],
            speedRange: nil, isDefault: true
        )
        let body = CloudReadAloudRules.requestBody(entry: entry, text: "Hi.", voice: "v1", speed: nil, language: "en")
        #expect(body["response_format"] as? String == "mp3")
    }

    @Test("audioResponseCases match one by one")
    func audioResponseCases() throws {
        for item in try Self.cases("audioResponseCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let transport = try #require(
                (input["transport"] as? String).flatMap(VoiceTTSTransport.init(rawValue:)), "\(id) transport"
            )
            let body = try JSONSerialization.data(withJSONObject: try #require(input["body"]))
            let actual = CloudReadAloudRules.audioResponse(transport: transport, data: body)
            let expected = item["expected"] as? [String: Any]
            if let encoded = expected?["audioBase64"] as? String {
                #expect(actual == .audio(try #require(Data(base64Encoded: encoded))), "\(id) actual \(String(describing: actual))")
            } else if let url = expected?["downloadUrl"] as? String {
                #expect(actual == .download(try #require(URL(string: url))), "\(id) actual \(String(describing: actual))")
            } else {
                #expect(actual == nil, "\(id) should be an invalid response, actual \(String(describing: actual))")
            }
        }
    }

    @Test("failureCases match one by one")
    func failureCases() throws {
        for item in try Self.cases("failureCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let raw = try #require(input["failure"] as? [String: Any])
            let failure: DictationFailure
            switch raw["kind"] as? String {
            case "network": failure = .network
            case "timeout": failure = .timeout
            case "http":
                failure = .http(status: Int(try Self.number(raw["status"])), retryAfter: raw["retryAfter"] as? String)
            default:
                Issue.record("\(id): unknown failure.kind \(String(describing: raw["kind"]))")
                continue
            }
            let decision = CloudReadAloudRules.decide(failure, attempt: Int(try Self.number(input["attempt"])))
            let expected = try #require(item["expected"] as? [String: Any])
            let autoRetry = try #require(expected["autoRetry"] as? Bool)
            switch decision {
            case .autoRetry(let delaySec):
                #expect(autoRetry, "\(id): should not auto-retry")
                #expect(delaySec == (try Self.number(expected["delaySec"])), "\(id) delay \(delaySec)")
            case .fallbackSystemFromFailedChunk:
                #expect(!autoRetry, "\(id): should auto-retry")
                #expect(expected["then"] as? String == "fallback_system_from_failed_chunk", "\(id) then")
            }
        }
    }
}
