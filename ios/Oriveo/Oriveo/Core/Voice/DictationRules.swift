import Foundation

/// A span of seconds: a silent run or an upload segment; endpoints are rounded to secondsDecimals.
nonisolated struct DictationSpan: Sendable, Hashable {
    let start: Double
    let end: Double
}

/// Result of the pre-upload check; tooShort / noSpeech show "no sound heard" and nothing is uploaded.
nonisolated enum DictationPrecheck: String, Sendable, Hashable {
    case ok
    case tooShort = "too_short"
    case noSpeech = "no_speech"
}

/// Failure of one recognition request. retryAfter is the raw Retry-After response header.
nonisolated enum DictationFailure: Sendable, Hashable {
    case network
    case timeout
    case http(status: Int, retryAfter: String?)
    /// The response lacks text or text is not a string: treated as a permanent failure.
    case invalidResponse
}

nonisolated enum DictationPrimaryAction: String, Sendable, Hashable {
    case retry
    case checkConnection = "check_connection"
}

/// What to do after a failure: retry silently, or stop and offer a primary action (the recording stays in its slot).
nonisolated enum DictationFailureDecision: Sendable, Hashable {
    case autoRetry(delaySec: Double)
    case stop(DictationPrimaryAction)
}

/// Text and cursor (UTF-16 offset) after a transcript is inserted into the input field.
nonisolated struct DictationInsertion: Sendable, Hashable {
    let text: String
    let cursor: Int
}

/// Pure dictation rules, aligned one by one with the shared dictation contract fixture; the constants
/// match the fixture's constants.
/// Text is handled per Unicode scalar; only the insertion offset is in UTF-16.
nonisolated enum DictationRules {

    // MARK: - Constants

    static let recordingFileExtension = "aac"
    static let recordingSampleRateHz = 16000
    static let recordingChannels = 1

    static let windowSec = 0.05
    static let speechThresholdDbfs = -45.0

    static let minDurationSec = 0.5
    static let minVoicedSec = 0.3
    static let minVoicedWindows = 6

    static let minSilenceRunSec = 0.4
    static let minSilenceRunWindows = 8
    static let byteSafetyFactor = 0.9
    static let secondsDecimals = 3
    static let compareTolerance = 1e-9

    static let discardUndoAboveSec = 5.0
    static let pendingRetentionSec = 604_800.0

    static let maxAutoRetries = 1
    static let defaultRetryDelaySec = 1.0
    static let maxRetryAfterSec = 10.0
    static let transientHTTPStatuses: Set<Int> = [408, 409, 429]
    static let transientHTTPFrom = 500
    static let authHTTPStatuses: Set<Int> = [401, 403]

    static let whitespace: Set<UInt32> = [
        0x0020, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
        0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// Code point ranges that never get a space inserted (Thai, Lao, Burmese, Khmer, CJK, kana, fullwidth, etc.); the Script property is not used.
    static let noSpaceScripts: [ClosedRange<UInt32>] = [
        0x0E00...0x0E7F,
        0x0E80...0x0EFF,
        0x1000...0x109F,
        0x1780...0x17FF,
        0x2E80...0x2FFF,
        0x3000...0x303F,
        0x3040...0x309F,
        0x30A0...0x30FF,
        0x31F0...0x31FF,
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF,
        0xFF00...0xFFEF,
        0x20000...0x3FFFF,
    ]

    static let noSpaceBefore: Set<Unicode.Scalar> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "%", "…"]
    static let noSpaceAfter: Set<Unicode.Scalar> = ["(", "[", "{", "¿", "¡"]

    static let uploadFileName = "audio.m4a"
    static let uploadContentType = "audio/mp4"
    static let fileFieldName = "file"
    static let modelFieldName = "model"
    static let legacyLanguageCodes: [String: String] = ["in": "id", "iw": "he", "ji": "yi"]

    // MARK: - Precheck and silence

    /// A window that is nil (digital silence) or below the threshold is not voiced.
    static func isVoiced(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value >= speechThresholdDbfs
    }

    /// Check duration first, then count voiced windows (count windows, do not convert to seconds).
    static func precheck(durationSec: Double, envelope: [Double?]) -> DictationPrecheck {
        if durationSec < minDurationSec { return .tooShort }
        let voiced = envelope.reduce(0) { $0 + (isVoiced($1) ? 1 : 0) }
        return voiced < minVoicedWindows ? .noSpeech : .ok
    }

    /// Maximal runs of non-voiced windows, kept only when at least minSilenceRunWindows long; endpoints = window index * windowSec.
    static func silenceRuns(envelope: [Double?]) -> [DictationSpan] {
        var runs: [DictationSpan] = []
        var runStart: Int?
        for index in 0...envelope.count {
            let silent = index < envelope.count && !isVoiced(envelope[index])
            if silent {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= minSilenceRunWindows {
                    runs.append(DictationSpan(
                        start: roundSeconds(Double(start) * windowSec),
                        end: roundSeconds(Double(index) * windowSec)
                    ))
                }
                runStart = nil
            }
        }
        return runs
    }

    // MARK: - Segmentation

    static func segmentPlan(durationSec: Double, uploadBytes: Int, silences: [DictationSpan], entry: VoiceSTTEntry) -> [DictationSpan] {
        segmentPlan(
            durationSec: durationSec,
            uploadBytes: uploadBytes,
            silences: silences,
            maxBytes: entry.maxBytes,
            maxDurationSec: entry.maxDurationSec
        )
    }

    /// Lmax = min(maxDurationSec, maxBytes * byteSafetyFactor / bytesPerSec).
    /// Starting from 0, while the remainder exceeds Lmax, cut at the latest silence midpoint within
    /// [s + Lmax/2, s + Lmax], or hard-cut at s + Lmax when there is none.
    static func segmentPlan(durationSec: Double, uploadBytes: Int, silences: [DictationSpan], maxBytes: Int, maxDurationSec: Int) -> [DictationSpan] {
        guard durationSec > 0 else { return [] }
        let bytesPerSec = Double(uploadBytes) / durationSec
        let byBytes = bytesPerSec > 0 ? Double(maxBytes) * byteSafetyFactor / bytesPerSec : Double.infinity
        let limit = min(Double(maxDurationSec), byBytes)
        let end = roundSeconds(durationSec)
        guard limit > 0 else { return [DictationSpan(start: 0, end: end)] }
        let midpoints = silences.map { roundSeconds(($0.start + $0.end) / 2) }
        var segments: [DictationSpan] = []
        var start = 0.0
        while durationSec - start > limit + compareTolerance {
            let low = start + limit / 2
            let high = start + limit
            let candidates = midpoints.filter { $0 >= low - compareTolerance && $0 <= high + compareTolerance }
            let cut = candidates.max() ?? roundSeconds(high)
            // Stop if rounding makes no progress, to avoid an endless loop with a tiny Lmax
            guard cut > start else { break }
            segments.append(DictationSpan(start: start, end: cut))
            start = cut
        }
        segments.append(DictationSpan(start: start, end: end))
        return segments
    }

    static func roundSeconds(_ value: Double) -> Double {
        let scale = pow(10.0, Double(secondsDecimals))
        return (value * scale).rounded() / scale
    }

    // MARK: - Text

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        whitespace.contains(scalar.value)
    }

    static func isNoSpaceScript(_ scalar: Unicode.Scalar) -> Bool {
        noSpaceScripts.contains { $0.contains(scalar.value) }
    }

    /// Whether a U+0020 is inserted between the two sides.
    static func needsSpace(_ left: Unicode.Scalar?, _ right: Unicode.Scalar?) -> Bool {
        guard let left, let right else { return false }
        if isWhitespace(left) || isWhitespace(right) { return false }
        if isNoSpaceScript(left) || isNoSpaceScript(right) { return false }
        if noSpaceBefore.contains(right) || noSpaceAfter.contains(left) { return false }
        return true
    }

    /// Strips only the code points in constants.text.whitespace (U+0085 / U+FEFF are kept); the platform trim is not used.
    static func trimmedScalars(_ text: String) -> [Unicode.Scalar] {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isWhitespace($0) }) else {
            return []
        }
        return Array(scalars[first...last])
    }

    static func trim(_ text: String) -> String {
        string(trimmedScalars(text))
    }

    /// Trims each piece, drops empty ones, and joins them according to needsSpace.
    static func join(_ texts: [String]) -> String {
        var joined: [Unicode.Scalar] = []
        for text in texts {
            let scalars = trimmedScalars(text)
            guard let head = scalars.first else { continue }
            if needsSpace(joined.last, head) { joined.append(" ") }
            joined.append(contentsOf: scalars)
        }
        return string(joined)
    }

    /// Inserts at max(selectionStart, selectionEnd) (UTF-16 offset), keeping the selected text;
    /// the cursor lands after the transcript (after the leading space, before the trailing one).
    /// An empty transcript returns the text unchanged with the cursor at selectionEnd.
    static func insert(transcript: String, into text: String, selectionStart: Int, selectionEnd: Int) -> DictationInsertion {
        let units = Array(text.utf16)
        let scalars = trimmedScalars(transcript)
        guard let head = scalars.first, let tail = scalars.last else {
            return DictationInsertion(text: text, cursor: clamp(selectionEnd, units.count))
        }
        let offset = clamp(max(selectionStart, selectionEnd), units.count)
        var result = Array(units[..<offset])
        if needsSpace(scalarBefore(units, offset), head) { result.append(0x20) }
        result.append(contentsOf: string(scalars).utf16)
        let cursor = result.count
        if needsSpace(tail, scalarAt(units, offset)) { result.append(0x20) }
        result.append(contentsOf: units[offset...])
        return DictationInsertion(text: String(decoding: result, as: UTF16.self), cursor: cursor)
    }

    private static func clamp(_ offset: Int, _ count: Int) -> Int {
        min(max(offset, 0), count)
    }

    /// Same as codePointBefore: when the previous unit is a trail surrogate and the one before it a lead surrogate, combine them into one code point.
    private static func scalarBefore(_ units: [UInt16], _ offset: Int) -> Unicode.Scalar? {
        guard offset > 0 else { return nil }
        let low = units[offset - 1]
        if UTF16.isTrailSurrogate(low), offset >= 2, UTF16.isLeadSurrogate(units[offset - 2]) {
            return surrogatePair(units[offset - 2], low)
        }
        return Unicode.Scalar(low)
    }

    /// Same as codePointAt.
    private static func scalarAt(_ units: [UInt16], _ offset: Int) -> Unicode.Scalar? {
        guard offset < units.count else { return nil }
        let high = units[offset]
        if UTF16.isLeadSurrogate(high), offset + 1 < units.count, UTF16.isTrailSurrogate(units[offset + 1]) {
            return surrogatePair(high, units[offset + 1])
        }
        return Unicode.Scalar(high)
    }

    private static func surrogatePair(_ lead: UInt16, _ trail: UInt16) -> Unicode.Scalar? {
        Unicode.Scalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: - Failures

    nonisolated enum FailureClass: Sendable, Hashable {
        case transient
        case auth
        case permanent
    }

    static func classify(_ failure: DictationFailure) -> FailureClass {
        switch failure {
        case .network, .timeout:
            return .transient
        case .http(let status, _):
            if authHTTPStatuses.contains(status) { return .auth }
            if transientHTTPStatuses.contains(status) || status >= transientHTTPFrom { return .transient }
            return .permanent
        case .invalidResponse:
            return .permanent
        }
    }

    /// Accepts only non-negative decimal seconds (surrounding whitespace is stripped first); an HTTP-date or anything unparseable counts as missing.
    static func retryAfterSeconds(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              pieces.allSatisfy({ piece in !piece.isEmpty && piece.allSatisfy { $0.isASCII && $0.isWholeNumber } }) else {
            return nil
        }
        return Double(raw)
    }

    /// attempt starts at 1 and is the ordinal of the request that just failed.
    static func decide(_ failure: DictationFailure, attempt: Int) -> DictationFailureDecision {
        switch classify(failure) {
        case .auth:
            return .stop(.checkConnection)
        case .permanent:
            return .stop(.retry)
        case .transient:
            guard attempt <= maxAutoRetries else { return .stop(.retry) }
            var retryAfter: String?
            if case .http(_, let header) = failure { retryAfter = header }
            let delay = retryAfterSeconds(retryAfter) ?? defaultRetryDelaySec
            guard delay <= maxRetryAfterSec else { return .stop(.retry) }
            return .autoRetry(delaySec: delay)
        }
    }

    // MARK: - Requests

    /// Recognition language -> ISO-639-1 primary subtag: _ becomes -, in / iw / ji become id / he / yi; nil = automatic, not sent.
    static func languageValue(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let primary = (normalized.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? "").lowercased()
        guard !primary.isEmpty else { return nil }
        return legacyLanguageCodes[primary] ?? primary
    }

    /// Order: model, language hint (the entry has a languageField and the user picked a language), file always last; response_format is not sent.
    static func requestParts(model: String, languageField: String?, language: String?, audio: Data) -> [MultipartBody.Part] {
        var parts: [MultipartBody.Part] = [.field(name: modelFieldName, value: model)]
        if let languageField, let value = languageValue(language) {
            parts.append(.field(name: languageField, value: value))
        }
        parts.append(.file(name: fileFieldName, fileName: uploadFileName, contentType: uploadContentType, data: audio))
        return parts
    }

    static func requestParts(entry: VoiceSTTEntry, language: String?, audio: Data) -> [MultipartBody.Part] {
        requestParts(model: entry.model, languageField: entry.languageField, language: language, audio: audio)
    }

    /// The connection base URL's scheme://host[:port] (its path / query / user info dropped) plus the catalog path.
    static func requestURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = path
        return components.url
    }

    /// The auth header depends only on the transport: gemini_* uses `x-goog-api-key: <key>`, the rest `Authorization: Bearer <key>`. Read-aloud shares it.
    static func authHeader(usesGoogAPIKey: Bool, apiKey: String) -> (field: String, value: String) {
        usesGoogAPIKey ? ("x-goog-api-key", apiKey) : ("Authorization", "Bearer \(apiKey)")
    }

    static func authHeader(transport: VoiceSTTTransport, apiKey: String) -> (field: String, value: String) {
        authHeader(usesGoogAPIKey: transport.usesGoogAPIKey, apiKey: apiKey)
    }

    static let geminiAudioMimeType = "audio/m4a"
    static let dashscopeAudioDataPrefix = "data:audio/mp4;base64,"
    static let dashscopeAudioFormat = "m4a"

    /// Request body for JSON-style dictation; multipart transports return nil.
    /// gemini_transcribe sends no language; dashscope_asr sends parameters.language_hints when languageField == language_hints and a language is picked.
    static func requestJSON(entry: VoiceSTTEntry, language: String?, audio: Data) -> [String: Any]? {
        let encoded = audio.base64EncodedString()
        switch entry.transport {
        case .openAITranscriptions, .xaiSTT:
            return nil
        case .geminiTranscribe:
            return [
                "model": entry.model,
                "store": false,
                "input": [["type": "audio", "mime_type": geminiAudioMimeType, "data": encoded]],
            ]
        case .dashscopeASR:
            var parameters: [String: Any] = ["format": dashscopeAudioFormat]
            if entry.languageField == "language_hints", let value = languageValue(language) {
                parameters["language_hints"] = [value]
            }
            let content: [[String: Any]] = [
                ["type": "input_audio", "input_audio": ["data": dashscopeAudioDataPrefix + encoded]],
            ]
            return [
                "model": entry.model,
                "input": ["messages": [["role": "user", "content": content]]],
                "parameters": parameters,
            ]
        }
    }

    /// POST request: multipart transports send multipart, JSON transports send application/json; the auth header follows the transport.
    static func makeRequest(
        baseURL: URL,
        entry: VoiceSTTEntry,
        language: String?,
        apiKey: String,
        audio: Data,
        boundary: String = "Boundary-\(UUID().uuidString)"
    ) -> URLRequest? {
        guard let url = requestURL(baseURL: baseURL, path: entry.path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let auth = authHeader(transport: entry.transport, apiKey: apiKey)
        request.setValue(auth.value, forHTTPHeaderField: auth.field)
        if let json = requestJSON(entry: entry, language: language, audio: audio) {
            guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]) else {
                return nil
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            let body = MultipartBody(boundary: boundary, parts: requestParts(entry: entry, language: language, audio: audio))
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encoded()
        }
        return request
    }

    // MARK: - Responses

    /// The top-level string text, trimmed; missing or not a string -> nil (invalid response).
    static func transcript(fromResponseObject object: Any?) -> String? {
        guard let body = object as? [String: Any], let text = body["text"] as? String else { return nil }
        return trim(text)
    }

    static func transcript(fromResponseData data: Data) -> String? {
        transcript(fromResponseObject: try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Extracts the transcript per transport: gemini_transcribe concatenates the text of steps[].content[] items with type == text, then trims (empty -> nil);
    /// dashscope_asr takes output.text trimmed; multipart transports use the top-level text above.
    static func transcript(fromResponseObject object: Any?, transport: VoiceSTTTransport) -> String? {
        switch transport {
        case .openAITranscriptions, .xaiSTT:
            return transcript(fromResponseObject: object)
        case .geminiTranscribe:
            guard let body = object as? [String: Any], let steps = body["steps"] as? [Any] else { return nil }
            var joined = ""
            for step in steps {
                guard let contents = (step as? [String: Any])?["content"] as? [Any] else { continue }
                for content in contents {
                    guard let item = content as? [String: Any], item["type"] as? String == "text",
                          let text = item["text"] as? String else { continue }
                    joined += text
                }
            }
            let text = trim(joined)
            return text.isEmpty ? nil : text
        case .dashscopeASR:
            guard let body = object as? [String: Any], let output = body["output"] as? [String: Any],
                  let text = output["text"] as? String else { return nil }
            return trim(text)
        }
    }

    static func transcript(fromResponseData data: Data, transport: VoiceSTTTransport) -> String? {
        transcript(
            fromResponseObject: try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            transport: transport
        )
    }

    // MARK: - Thresholds

    /// Only discarding a recording longer than 5 seconds offers undo; exactly 5 seconds does not.
    static func showsDiscardUndo(durationSec: Double) -> Bool {
        durationSec > discardUndoAboveSec
    }

    /// A pending file is deleted only when older than 7 days; exactly 7 days is kept.
    static func isPendingExpired(ageSec: Double) -> Bool {
        ageSec - pendingRetentionSec > compareTolerance
    }
}
