import Foundation

/// What to do after a cloud read-aloud synthesis request fails: retry silently, or switch to the system engine from the failed chunk (with a one-time notice).
nonisolated enum CloudReadAloudFailureDecision: Sendable, Hashable {
    case autoRetry(delaySec: Double)
    case fallbackSystemFromFailedChunk
}

/// Pure rules for cloud read-aloud, aligned item by item with shared/voice-contracts/cloud-read-aloud.v1.json; constants match the fixture's constants.
/// Lengths are counted in Unicode scalars.
nonisolated enum CloudReadAloudRules {

    // MARK: - Constants

    static let firstChunkMaxCodePoints = 200
    static let firstChunkMaxSentences = 2
    static let laterChunkCapCodePoints = 1000
    static let sentenceJoiner = " "
    static let prefetchChunks = 1
    static let languageMinConfidence = 0.5

    static let xaiTtsLanguages = [
        "en", "ar-EG", "ar-SA", "ar-AE", "bn", "zh", "fr", "de", "hi", "id",
        "it", "ja", "ko", "pt-BR", "pt-PT", "ru", "es-MX", "es-ES", "tr", "vi",
    ]
    static let xaiDefaultRegion: [String: String] = ["ar": "ar-SA", "es": "es-MX", "pt": "pt-BR"]
    static let xaiAutoLanguage = "auto"

    static let speedSliderMin = 0.5
    static let speedSliderMax = 2.0
    static let speedSliderStep = 0.1
    static let speedSliderDefault = 1.0
    static let speedDecimals = 2

    static let requestTimeoutSec: TimeInterval = 30

    // MARK: - Chunking

    /// Sentences are trimmed first (dictation whitespace set) and empty ones dropped. Chunk 1 = sentence 1, plus sentence 2 when "s1 s2" fits within min(200, maxChars);
    /// chunk k (k >= 2) joins whole sentences with a single space up to min(maxChars, 1000, 200 × 2^(k−1)); sentences are never split.
    static func chunks(sentences: [String], maxChars: Int) -> [String] {
        let items = sentences.map(DictationRules.trim).filter { !$0.isEmpty }
        guard !items.isEmpty else { return [] }
        let joinerLength = sentenceJoiner.unicodeScalars.count
        var result: [String] = []
        var index = 0
        while index < items.count {
            let chunkNumber = result.count + 1
            let limit: Int
            let maxSentences: Int
            if chunkNumber == 1 {
                limit = min(firstChunkMaxCodePoints, maxChars)
                maxSentences = firstChunkMaxSentences
            } else {
                limit = min(maxChars, laterChunkCapCodePoints, growthLimit(chunkNumber))
                maxSentences = Int.max
            }
            var parts = [items[index]]
            var length = items[index].unicodeScalars.count
            index += 1
            while index < items.count, parts.count < maxSentences {
                let next = length + joinerLength + items[index].unicodeScalars.count
                guard next <= limit else { break }
                parts.append(items[index])
                length = next
                index += 1
            }
            result.append(parts.joined(separator: sentenceJoiner))
        }
        return result
    }

    /// 200 × 2^(k−1); stops doubling once past the cap to avoid overflow.
    private static func growthLimit(_ chunkNumber: Int) -> Int {
        var limit = firstChunkMaxCodePoints
        var step = 1
        while step < chunkNumber, limit < laterChunkCapCodePoints {
            limit *= 2
            step += 1
        }
        return limit
    }

    // MARK: - Reading language

    /// The hypothesis with the highest confidence (ties go to the lexicographically smallest tag); none or below 0.5 gives nil. The tag is kept as is.
    static func confidentLanguage(_ hypotheses: [String: Double]) -> String? {
        let top = hypotheses.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }
        guard let top, top.value >= languageMinConfidence else { return nil }
        return top.key
    }

    /// Reading language: a trusted detection result, otherwise the app UI language.
    static func readingLanguage(hypotheses: [String: Double], uiLocale: String) -> String {
        readingLanguage(detected: confidentLanguage(hypotheses), uiLocale: uiLocale)
    }

    static func readingLanguage(detected: String?, uiLocale: String) -> String {
        detected ?? uiLocale
    }

    // MARK: - xAI language

    /// Normalize first (_ → -, in / iw / ji → id / he / yi); a case-insensitive exact match returns the list spelling;
    /// otherwise the primary subtag if it is in the list; otherwise the primary subtag's default region; otherwise auto.
    static func xaiLanguage(_ language: String) -> String {
        var subtags = language.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = subtags.first, !first.isEmpty else { return xaiAutoLanguage }
        let primary = DictationRules.legacyLanguageCodes[first.lowercased()] ?? first.lowercased()
        subtags[0] = primary
        let normalized = subtags.joined(separator: "-").lowercased()
        if let exact = xaiTtsLanguages.first(where: { $0.lowercased() == normalized }) { return exact }
        if let byPrimary = xaiTtsLanguages.first(where: { $0.lowercased() == primary }) { return byPrimary }
        return xaiDefaultRegion[primary] ?? xaiAutoLanguage
    }

    // MARK: - Speed

    /// An entry without speedRange gives 1 (speed not supported); otherwise the slider value is clamped into speedRange,
    /// then rounded to two decimals with floor(x × 100 + 0.5) / 100 (round half up, not banker's rounding). The slider default is 1.
    static func effectiveSpeed(slider: Double?, entry: VoiceTTSEntry) -> Double {
        guard let range = entry.speedRange else { return 1 }
        let clamped = min(max(slider ?? speedSliderDefault, range.min), range.max)
        let scale = pow(10.0, Double(speedDecimals))
        return (clamped * scale + 0.5).rounded(.down) / scale
    }

    // MARK: - Request

    static let geminiAudioMimeType = "audio/wav"
    static let dashscopeAutoLanguageType = "Auto"
    /// dashscope_tts language_type: primary subtag of the reading language to name; everything else is Auto.
    static let dashscopeLanguageTypes: [String: String] = [
        "zh": "Chinese", "en": "English", "de": "German", "it": "Italian", "pt": "Portuguese",
        "es": "Spanish", "ja": "Japanese", "ko": "Korean", "fr": "French", "ru": "Russian",
    ]

    /// The primary subtag reuses dictation's language normalization (_ → -, in / iw / ji → id / he / yi).
    static func dashscopeLanguageType(_ language: String) -> String {
        DictationRules.languageValue(language).flatMap { dashscopeLanguageTypes[$0] } ?? dashscopeAutoLanguageType
    }

    /// mistral_speech response_format is fixed and does not read the catalog outputFormat.
    static let mistralResponseFormat = "mp3"

    /// openai_speech: {model, input, voice, response_format, speed?};
    /// xai_tts: {text, voice_id, language, output_format: {codec}, speed?}, no model. speed is omitted when the effective speed is 1.
    /// gemini_tts / mistral_speech / dashscope_tts never send speed.
    static func requestBody(entry: VoiceTTSEntry, text: String, voice: String, speed: Double?, language: String) -> [String: Any] {
        let effective = effectiveSpeed(slider: speed, entry: entry)
        var body: [String: Any]
        switch entry.transport {
        case .openAISpeech:
            body = [
                "model": entry.model,
                "input": text,
                "voice": voice,
                "response_format": entry.outputFormat,
            ]
        case .xaiTTS:
            body = [
                "text": text,
                "voice_id": voice,
                "language": xaiLanguage(language),
                "output_format": ["codec": entry.outputFormat],
            ]
        case .geminiTTS:
            return [
                "model": entry.model,
                "store": false,
                "input": [["type": "user_input", "content": [["type": "text", "text": text]]]],
                "response_format": ["type": "audio", "mime_type": geminiAudioMimeType],
                "generation_config": ["speech_config": [["voice": voice]]],
            ]
        case .mistralSpeech:
            return [
                "model": entry.model,
                "input": text,
                "voice_id": voice,
                "response_format": mistralResponseFormat,
            ]
        case .dashscopeTTS:
            return [
                "model": entry.model,
                "input": ["text": text, "voice": voice, "language_type": dashscopeLanguageType(language)],
            ]
        }
        if effective != 1 { body["speed"] = effective }
        return body
    }

    /// POSTs JSON to the connection origin + entry path; the auth header depends on the transport (gemini_tts uses x-goog-api-key, the rest Bearer); timeout 30 s.
    static func makeRequest(
        baseURL: URL,
        entry: VoiceTTSEntry,
        text: String,
        voice: String,
        speed: Double?,
        language: String,
        apiKey: String
    ) -> URLRequest? {
        guard let url = DictationRules.requestURL(baseURL: baseURL, path: entry.path) else { return nil }
        let body = requestBody(entry: entry, text: text, voice: voice, speed: speed, language: language)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: requestTimeoutSec)
        request.httpMethod = "POST"
        let auth = DictationRules.authHeader(usesGoogAPIKey: entry.transport.usesGoogAPIKey, apiKey: apiKey)
        request.setValue(auth.value, forHTTPHeaderField: auth.field)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// dashscope_tts second hop: GET to download the audio, no auth header, same timeout as the synthesis request.
    static func downloadRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeoutSec)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Response

    /// Result decoded from a 2xx body: either the audio bytes directly, or an https address to download from.
    enum AudioResponse: Equatable {
        case audio(Data)
        case download(URL)
    }

    /// openai_speech / xai_tts: the body is the audio; gemini_tts: base64-decode `data` of the first type == audio entry in steps[].content[];
    /// mistral_speech: base64-decode audio_data; dashscope_tts: only output.audio.url counts (scheme https case-insensitively, non-empty host).
    /// gemini_tts looks only at the first audio part; if its data is empty the response is invalid and later parts are not searched.
    /// Empty audio / missing fields / non-strict base64 (length not a multiple of 4, missing padding, non-standard alphabet) / non-https gives nil (invalid response).
    /// Includes JSON and base64 decoding, so callers should not call it on the main thread.
    static func audioResponse(transport: VoiceTTSTransport, data: Data) -> AudioResponse? {
        switch transport {
        case .openAISpeech, .xaiTTS:
            return data.isEmpty ? nil : .audio(data)
        case .geminiTTS:
            let steps = (jsonObject(data)?["steps"] as? [Any]) ?? []
            let audioPart = steps.lazy
                .compactMap { ($0 as? [String: Any])?["content"] as? [Any] }
                .flatMap { $0 }
                .compactMap { $0 as? [String: Any] }
                .first { $0["type"] as? String == "audio" }
            return decodedAudio(audioPart?["data"])
        case .mistralSpeech:
            return decodedAudio(jsonObject(data)?["audio_data"])
        case .dashscopeTTS:
            let output = jsonObject(data)?["output"] as? [String: Any]
            let audio = output?["audio"] as? [String: Any]
            // Object-storage addresses often come back as http (the same address works over https), so http is always rewritten to https before downloading; any other scheme is still invalid.
            guard let raw = audio?["url"] as? String, var url = URL(string: raw) else { return nil }
            if url.scheme?.lowercased() == "http" {
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
                components.scheme = "https"
                guard let upgraded = components.url else { return nil }
                url = upgraded
            }
            guard url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false else { return nil }
            return .download(url)
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Strict standard base64: length a multiple of 4, padded (= only at the end and at most 2), using only A–Z a–z 0–9 + /.
    static func isStrictBase64(_ encoded: String) -> Bool {
        let bytes = Array(encoded.utf8)
        guard !bytes.isEmpty, bytes.count % 4 == 0 else { return false }
        let padding = bytes.reversed().prefix { $0 == UInt8(ascii: "=") }.count
        guard padding <= 2 else { return false }
        return bytes.dropLast(padding).allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                return true
            default:
                return false
            }
        }
    }

    private static func decodedAudio(_ raw: Any?) -> AudioResponse? {
        guard let encoded = raw as? String,
              isStrictBase64(encoded),
              let audio = Data(base64Encoded: encoded),
              !audio.isEmpty else { return nil }
        return .audio(audio)
    }

    // MARK: - Failure

    /// Per-chunk automatic retries follow the same failure matrix as dictation; no retry (including 401 / 403) falls back to the system engine from the failed chunk.
    static func decide(_ failure: DictationFailure, attempt: Int) -> CloudReadAloudFailureDecision {
        switch DictationRules.decide(failure, attempt: attempt) {
        case .autoRetry(let delaySec):
            return .autoRetry(delaySec: delaySec)
        case .stop:
            return .fallbackSystemFromFailedChunk
        }
    }
}
