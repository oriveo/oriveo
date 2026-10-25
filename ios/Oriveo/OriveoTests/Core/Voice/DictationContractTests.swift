import AVFoundation
import Foundation
import Testing
@testable import Oriveo

/// The production DictationRules reproduce every expected value in shared/voice-contracts/dictation.v1.json.
/// Entry references are looked up by {providerKind, direction, model} in the data object of voice_catalog_contract.v2.json and decoded with VoiceCatalogDecoder.
@Suite("Dictation contract")
struct DictationContractTests {

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

    private static func dictation() throws -> [String: Any] {
        try fixture("shared/voice-contracts/dictation.v1.json")
    }

    private static func cases(_ group: String) throws -> [[String: Any]] {
        let items = try #require(try dictation()[group] as? [[String: Any]], "Missing case group \(group)")
        #expect(!items.isEmpty, "Case group is empty: \(group)")
        return items
    }

    private static func catalog() throws -> VoiceCatalog {
        let data = try #require(try fixture("shared/model-contracts/voice_catalog_contract.v2.json")["data"])
        return VoiceCatalogDecoder.decode(data)
    }

    /// {providerKind, direction: "stt", model} -> the matching dictation entry in the decoded catalog.
    private static func sttEntry(_ raw: Any?, in catalog: VoiceCatalog) throws -> VoiceSTTEntry {
        let reference = try #require(raw as? [String: Any])
        #expect(reference["direction"] as? String == "stt")
        let rawKind = try #require(reference["providerKind"] as? String)
        let kind = try #require(ProviderKind(rawValue: rawKind))
        let model = try #require(reference["model"] as? String)
        return try #require(catalog.sttEntries(kind).first { $0.model == model }, "Catalog has no \(kind.rawValue)/\(model)")
    }

    private static func number(_ raw: Any?) throws -> Double {
        try #require(raw as? NSNumber).doubleValue
    }

    private static func envelope(_ raw: Any?) throws -> [Double?] {
        let items = try #require(raw as? [Any])
        return try items.map { item in item is NSNull ? nil : try number(item) }
    }

    private static func spans(_ raw: Any?) throws -> [DictationSpan] {
        let items = try #require(raw as? [[Any]])
        return try items.map { pair in
            try #require(pair.count == 2)
            return DictationSpan(start: try number(pair[0]), end: try number(pair[1]))
        }
    }

    private static func sameSpans(_ actual: [DictationSpan], _ expected: [DictationSpan]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy {
            abs($0.start - $1.start) < 1e-9 && abs($0.end - $1.end) < 1e-9
        }
    }

    private static func scalarValue(_ hex: Substring) throws -> UInt32 {
        let digits = try #require(hex.hasPrefix("U+") ? hex.dropFirst(2) : nil, "Bad code point format: \(hex)")
        return try #require(UInt32(digits, radix: 16))
    }

    // MARK: Constants

    @Test("constants match the fixture constants")
    func constantsMatchFixture() throws {
        let constants = try #require(try Self.dictation()["constants"] as? [String: Any])
        let envelope = try #require(constants["envelope"] as? [String: Any])
        #expect(try Self.number(envelope["windowSec"]) == DictationRules.windowSec)
        #expect(try Self.number(envelope["speechThresholdDbfs"]) == DictationRules.speechThresholdDbfs)
        let precheck = try #require(constants["precheck"] as? [String: Any])
        #expect(try Self.number(precheck["minDurationSec"]) == DictationRules.minDurationSec)
        #expect(try Self.number(precheck["minVoicedSec"]) == DictationRules.minVoicedSec)
        #expect(try Self.number(precheck["minVoicedWindows"]) == Double(DictationRules.minVoicedWindows))
        let segmentation = try #require(constants["segmentation"] as? [String: Any])
        #expect(try Self.number(segmentation["minSilenceRunSec"]) == DictationRules.minSilenceRunSec)
        #expect(try Self.number(segmentation["minSilenceRunWindows"]) == Double(DictationRules.minSilenceRunWindows))
        #expect(try Self.number(segmentation["byteSafetyFactor"]) == DictationRules.byteSafetyFactor)
        #expect(try Self.number(segmentation["secondsDecimals"]) == Double(DictationRules.secondsDecimals))
        #expect(try Self.number(segmentation["compareTolerance"]) == DictationRules.compareTolerance)
        #expect(try Self.number(constants["discardUndoAboveSec"]) == DictationRules.discardUndoAboveSec)
        #expect(try Self.number(constants["pendingRetentionSec"]) == DictationRules.pendingRetentionSec)
        let retry = try #require(constants["retry"] as? [String: Any])
        #expect(try Self.number(retry["maxAutoRetries"]) == Double(DictationRules.maxAutoRetries))
        #expect(try Self.number(retry["defaultDelaySec"]) == DictationRules.defaultRetryDelaySec)
        #expect(try Self.number(retry["maxRetryAfterSec"]) == DictationRules.maxRetryAfterSec)
        #expect(Set(try #require(retry["transientHttpStatuses"] as? [Int])) == DictationRules.transientHTTPStatuses)
        #expect(try Self.number(retry["transientHttpFrom"]) == Double(DictationRules.transientHTTPFrom))
        #expect(Set(try #require(retry["authHttpStatuses"] as? [Int])) == DictationRules.authHTTPStatuses)
        let text = try #require(constants["text"] as? [String: Any])
        let whitespace = try #require(text["whitespace"] as? [String]).map { try Self.scalarValue(Substring($0)) }
        #expect(Set(whitespace) == DictationRules.whitespace)
        let ranges = try #require(text["noSpaceScripts"] as? [String]).map { raw -> ClosedRange<UInt32> in
            let bounds = raw.split(separator: ".", omittingEmptySubsequences: true)
            try #require(bounds.count == 2, "Bad range format: \(raw)")
            return try Self.scalarValue(bounds[0])...Self.scalarValue(bounds[1])
        }
        #expect(ranges == DictationRules.noSpaceScripts)
        let before = try #require(text["noSpaceBefore"] as? [String]).compactMap { $0.unicodeScalars.first }
        #expect(Set(before) == DictationRules.noSpaceBefore)
        let after = try #require(text["noSpaceAfter"] as? [String]).compactMap { $0.unicodeScalars.first }
        #expect(Set(after) == DictationRules.noSpaceAfter)
        let multipart = try #require(constants["multipart"] as? [String: Any])
        #expect(multipart["fileName"] as? String == DictationRules.uploadFileName)
        #expect(multipart["contentType"] as? String == DictationRules.uploadContentType)
        #expect(multipart["legacyLanguageCodes"] as? [String: String] == DictationRules.legacyLanguageCodes)
    }

    @Test("Retry-After is trimmed of surrounding whitespace before being parsed as decimal seconds")
    func retryAfterTrimsWhitespace() {
        #expect(DictationRules.retryAfterSeconds(" 2 ") == 2)
        #expect(DictationRules.retryAfterSeconds(" 1.5") == 1.5)
        #expect(DictationRules.retryAfterSeconds(".5") == nil)
        #expect(DictationRules.retryAfterSeconds("  ") == nil)
        #expect(DictationRules.retryAfterSeconds("2\r\n") == 2)
        #expect(DictationRules.retryAfterSeconds("\t3\n") == 3)
    }

    // MARK: The nine case groups

    @Test("precheckCases match one by one")
    func precheckCases() throws {
        for item in try Self.cases("precheckCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let actual = DictationRules.precheck(
                durationSec: try Self.number(input["durationSec"]),
                envelope: try Self.envelope(input["envelope"])
            )
            #expect(actual.rawValue == item["expected"] as? String, "\(id)")
        }
    }

    @Test("silenceRunCases match one by one")
    func silenceRunCases() throws {
        for item in try Self.cases("silenceRunCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let actual = DictationRules.silenceRuns(envelope: try Self.envelope(input["envelope"]))
            let expected = try Self.spans(item["expected"])
            #expect(Self.sameSpans(actual, expected), "\(id): \(actual) != \(expected)")
        }
    }

    @Test("segmentPlanCases match one by one")
    func segmentPlanCases() throws {
        let catalog = try Self.catalog()
        for item in try Self.cases("segmentPlanCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let recording = try #require(input["recording"] as? [String: Any])
            let durationSec = try Self.number(recording["durationSec"])
            let uploadBytes = Int(try Self.number(recording["uploadBytes"]))
            let silences = try Self.spans(recording["silences"])
            let actual: [DictationSpan]
            if let limits = input["limits"] as? [String: Any] {
                actual = DictationRules.segmentPlan(
                    durationSec: durationSec,
                    uploadBytes: uploadBytes,
                    silences: silences,
                    maxBytes: Int(try Self.number(limits["maxBytes"])),
                    maxDurationSec: Int(try Self.number(limits["maxDurationSec"]))
                )
            } else {
                actual = DictationRules.segmentPlan(
                    durationSec: durationSec,
                    uploadBytes: uploadBytes,
                    silences: silences,
                    entry: try Self.sttEntry(input["entry"], in: catalog)
                )
            }
            let expected = try Self.spans(item["expected"])
            #expect(Self.sameSpans(actual, expected), "\(id): \(actual) != \(expected)")
        }
    }

    @Test("joinCases match one by one")
    func joinCases() throws {
        for item in try Self.cases("joinCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let texts = try #require(input["texts"] as? [String])
            let expected = try #require(item["expected"] as? String)
            let actual = DictationRules.join(texts)
            // Compare by scalar so String equality (canonical equivalence) cannot hide a difference.
            #expect(Array(actual.unicodeScalars) == Array(expected.unicodeScalars), "\(id): \(actual.debugDescription)")
        }
    }

    @Test("insertCases match one by one")
    func insertCases() throws {
        for item in try Self.cases("insertCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let expected = try #require(item["expected"] as? [String: Any])
            let actual = DictationRules.insert(
                transcript: try #require(input["transcript"] as? String),
                into: try #require(input["text"] as? String),
                selectionStart: Int(try Self.number(input["selectionStart"])),
                selectionEnd: Int(try Self.number(input["selectionEnd"]))
            )
            let expectedText = try #require(expected["text"] as? String)
            #expect(Array(actual.text.unicodeScalars) == Array(expectedText.unicodeScalars), "\(id): \(actual.text.debugDescription)")
            #expect(Double(actual.cursor) == (try Self.number(expected["cursor"])), "\(id) cursor \(actual.cursor)")
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
            let decision = DictationRules.decide(failure, attempt: Int(try Self.number(input["attempt"])))
            let expected = try #require(item["expected"] as? [String: Any])
            let autoRetry = try #require(expected["autoRetry"] as? Bool)
            switch decision {
            case .autoRetry(let delaySec):
                #expect(autoRetry, "\(id): should not auto-retry")
                #expect(delaySec == (try Self.number(expected["delaySec"])), "\(id) delay \(delaySec)")
            case .stop(let action):
                #expect(!autoRetry, "\(id): should auto-retry")
                #expect(action.rawValue == expected["primaryAction"] as? String, "\(id) action \(action.rawValue)")
            }
        }
    }

    /// inlineEntry -> VoiceSTTEntry; transport defaults to openai_transcriptions and the limits default to large values.
    private static func inlineEntry(_ inline: [String: Any]) throws -> VoiceSTTEntry {
        let rawTransport = inline["transport"] as? String ?? VoiceSTTTransport.openAITranscriptions.rawValue
        return VoiceSTTEntry(
            model: try #require(inline["model"] as? String),
            transport: try #require(VoiceSTTTransport(rawValue: rawTransport), "Unknown transport \(rawTransport)"),
            path: try #require(inline["path"] as? String),
            maxBytes: (inline["maxBytes"] as? NSNumber)?.intValue ?? 25_000_000,
            maxDurationSec: (inline["maxDurationSec"] as? NSNumber)?.intValue ?? 600,
            languageField: inline["languageField"] as? String,
            isDefault: inline["isDefault"] as? Bool ?? true
        )
    }

    @Test("requestCases match one by one")
    func requestCases() throws {
        let catalog = try Self.catalog()
        for item in try Self.cases("requestCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let language = input["language"] as? String
            let expected = try #require(item["expected"] as? [String: Any])
            #expect(expected["method"] as? String == "POST", "\(id)")
            if let inline = input["inlineEntry"] as? [String: Any], expected["parts"] != nil, inline["maxBytes"] == nil {
                // Legacy multipart case: inlineEntry only gives model / path / languageField, so go through the original requestParts entry point.
                let path = try #require(inline["path"] as? String)
                let parts = DictationRules.requestParts(
                    model: try #require(inline["model"] as? String),
                    languageField: inline["languageField"] as? String,
                    language: language,
                    audio: Data()
                )
                #expect(path == expected["path"] as? String, "\(id) path \(path)")
                #expect(Self.render(parts) == (try #require(expected["parts"] as? [[String: String]])), "\(id): \(Self.render(parts))")
                continue
            }
            let entry: VoiceSTTEntry
            if let inline = input["inlineEntry"] as? [String: Any] {
                entry = try Self.inlineEntry(inline)
            } else {
                entry = try Self.sttEntry(input["entry"], in: catalog)
            }
            #expect(entry.path == expected["path"] as? String, "\(id) path \(entry.path)")
            if let expectedParts = expected["parts"] as? [[String: String]] {
                #expect([.openAITranscriptions, .xaiSTT].contains(entry.transport), "\(id)")
                let parts = DictationRules.requestParts(entry: entry, language: language, audio: Data())
                #expect(Self.render(parts) == expectedParts, "\(id): \(Self.render(parts))")
                continue
            }
            // JSON transports: go through the production makeRequest and compare headers and the parsed body.
            let audioBase64 = try #require(input["audioBase64"] as? String)
            let audio = try #require(Data(base64Encoded: audioBase64))
            let apiKey = try #require(input["apiKey"] as? String)
            let baseURL = try #require(URL(string: "https://voice.example.test/base"))
            let request = try #require(DictationRules.makeRequest(
                baseURL: baseURL, entry: entry, language: language, apiKey: apiKey, audio: audio
            ), "\(id)")
            #expect(request.httpMethod == "POST", "\(id)")
            #expect(request.url?.path == expected["path"] as? String, "\(id) url \(String(describing: request.url))")
            let headers = try #require(expected["headers"] as? [String: String])
            for (field, value) in headers {
                #expect(request.value(forHTTPHeaderField: field) == value, "\(id) header \(field)")
            }
            let allHeaders = request.allHTTPHeaderFields ?? [:]
            #expect(Set(allHeaders.keys.map { $0.lowercased() }) == Set(headers.keys.map { $0.lowercased() }), "\(id) header set \(allHeaders.keys)")
            let body = try #require(request.httpBody)
            let actualJSON = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
            let expectedJSON = try #require(expected["json"] as? NSDictionary)
            #expect(actualJSON == expectedJSON, "\(id): \(String(decoding: body, as: UTF8.self))")
        }
    }

    private static func render(_ parts: [MultipartBody.Part]) -> [[String: String]] {
        parts.map { part in
            switch part {
            case .field(let name, let value):
                return ["name": name, "value": value]
            case .file(let name, let fileName, let contentType, _):
                return ["name": name, "filename": fileName, "contentType": contentType]
            }
        }
    }

    @Test("responseCases match one by one")
    func responseCases() throws {
        for item in try Self.cases("responseCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let rawTransport = input["transport"] as? String ?? VoiceSTTTransport.openAITranscriptions.rawValue
            let transport = try #require(VoiceSTTTransport(rawValue: rawTransport), "\(id): unknown transport \(rawTransport)")
            let actual = DictationRules.transcript(fromResponseObject: input["body"], transport: transport)
            if item["expected"] is NSNull {
                #expect(actual == nil, "\(id): should be an invalid response, got \(String(describing: actual))")
            } else {
                #expect(actual == (try #require(item["expected"] as? String)), "\(id): \(String(describing: actual))")
            }
        }
    }

    private static func tempStoreRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "DictationContractTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
    }

    /// Opens a slot, writes 0.1 s of silence, closes the file, and marks the sidecar ready with the given duration.
    private static func readySlot(_ store: RecordingStore, key: String, durationSec: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let writer = try store.open(slotKey: key, inputFormat: format, engine: "system")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        try writer.append(buffer)
        let result = try writer.close()
        try store.markReady(slotKey: key, result: RecordingResult(url: result.url, durationSec: durationSec,
                                                                  envelope: result.envelope))
    }

    @Test("thresholdCases match one by one (rules and RecordingStore layers)")
    func thresholdCases() throws {
        for item in try Self.cases("thresholdCases") {
            let id = item["id"] as? String ?? "?"
            let input = try #require(item["input"] as? [String: Any])
            let value = try Self.number(input["value"])
            let expected = try #require(item["expected"] as? Bool)
            switch input["kind"] as? String {
            case "discard_undo":
                #expect(DictationRules.showsDiscardUndo(durationSec: value) == expected, "\(id)")
                // Replayed through the production RecordingStore: above the threshold goes to the recycle area and can be undone, otherwise it is deleted outright.
                let store = try RecordingStore(root: Self.tempStoreRoot())
                let key = RecordingStore.homeDraftKey
                try Self.readySlot(store, key: key, durationSec: value)
                #expect(try store.discard(slotKey: key) == (expected ? .undoable : .deleted), "\(id)")
            case "retention_age":
                #expect(DictationRules.isPendingExpired(ageSec: value) == expected, "\(id)")
                // Replayed through the production RecordingStore: read when the slot age reaches value; an expired slot is cleared.
                let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
                var now = start
                var expiredCalls: [Int] = []
                let store = try RecordingStore(root: Self.tempStoreRoot(), now: { now },
                                               onExpired: { expiredCalls.append($0) })
                let key = RecordingStore.homeDraftKey
                try Self.readySlot(store, key: key, durationSec: 1)
                now = start.addingTimeInterval(value)
                #expect((try store.slot(for: key) == nil) == expected, "\(id)")
                #expect(expiredCalls == (expected ? [1] : []), "\(id)")
            default:
                Issue.record("\(id): unknown kind \(String(describing: input["kind"]))")
            }
        }
    }

    // MARK: Request URL and body

    @Test("the URL drops the path of the connection base URL and appends the catalog path")
    func requestURLReplacesBasePath() throws {
        let catalog = try Self.catalog()
        let entry = try #require(catalog.sttEntries(.groq).first)
        #expect(entry.path == "/openai/v1/audio/transcriptions")
        let audio = Data([0x00, 0x01, 0x02])
        let baseURL = try #require(URL(string: "https://api.groq.com/openai/v1"))
        let request = try #require(DictationRules.makeRequest(
            baseURL: baseURL,
            entry: entry,
            language: "ja",
            apiKey: "test-key",
            audio: audio,
            boundary: "B"
        ))
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        var expectedBody = Data()
        expectedBody.append(Data("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n".utf8))
        expectedBody.append(Data("--B\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nja\r\n".utf8))
        expectedBody.append(Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        expectedBody.append(audio)
        expectedBody.append(Data("\r\n--B--\r\n".utf8))
        #expect(request.httpBody == expectedBody)
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("response_format"))
    }

    @Test("the URL keeps the port of the connection base URL")
    func requestURLKeepsPort() throws {
        let url = DictationRules.requestURL(
            baseURL: try #require(URL(string: "http://localhost:8080/v1")),
            path: "/v1/audio/transcriptions"
        )
        #expect(url?.absoluteString == "http://localhost:8080/v1/audio/transcriptions")
    }
}
