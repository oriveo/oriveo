import Foundation
import Testing

@testable import Oriveo

// MARK: - Shared fixtures (shared/test-fixtures/provider-toolcall, read-only)
//
// Requests: each case in gemini_interactions.request-golden.v1.json has a test of the same name that feeds the production builder;
// Streams: each recorded/gemini_interactions_*.sse has a test of the same name that feeds the production stream parser, and the expectation is read from
// recorded/gemini_interactions.expected.json. The cases are named identically on all three platforms.

private enum GIFixtures {
    static let directory = ["shared", "test-fixtures", "provider-toolcall"]

    static func url(_ components: [String]) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = components.reduce(cursor) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func object(_ components: [String]) throws -> [String: Any] {
        let data = try Data(contentsOf: url(components))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func golden() throws -> [String: Any] {
        try object(directory + ["gemini_interactions.request-golden.v1.json"])
    }

    static func goldenCase(_ id: String) throws -> [String: Any] {
        let cases = try #require(try golden()["cases"] as? [[String: Any]])
        return try #require(cases.first { $0["id"] as? String == id }, "golden is missing case \(id)")
    }

    static func recipe(_ raw: Any) throws -> MetadataClient.CapabilityRecipe {
        try JSONDecoder().decode(
            MetadataClient.CapabilityRecipe.self,
            from: JSONSerialization.data(withJSONObject: raw)
        )
    }

    /// The web recipe and route take the production recipe from the server registry (not hand-copied in tests).
    static func webRecipe() throws -> MetadataClient.CapabilityRecipe {
        let registry = try object([
            "shared", "capabilityrecipe",
            "capability_runtime.v1.json",
        ])
        let recipes = try #require(registry["recipes"] as? [String: Any])
        return try recipe(try #require(recipes["gemini.interactions.web.v1"]))
    }

    static func reasoningRecipe() throws -> (MetadataClient.CapabilityRecipe, [String]) {
        let raw = try #require(try golden()["reasoning_recipe"] as? [String: Any])
        return (try recipe(raw), (raw["availableIntents"] as? [String]) ?? [])
    }

    static func sse(_ name: String) throws -> String {
        let data = try Data(contentsOf: url(directory + ["recorded", "\(name).sse"]))
        return String(decoding: data, as: UTF8.self)
    }

    static func expected(_ name: String) throws -> [String: Any] {
        let manifest = try object(directory + ["recorded", "gemini_interactions.expected.json"])
        let fixtures = try #require(manifest["fixtures"] as? [[String: Any]])
        let entry = try #require(fixtures.first { $0["file"] as? String == "\(name).sse" }, "expected is missing \(name)")
        return try #require(entry["expected"] as? [String: Any])
    }

    /// Real samples: entries in `recorded_samples` with `kind == "c4_sample"`; `expected` has the same shape as `fixtures[].expected`.
    static func liveSamples() throws -> [[String: Any]] {
        let manifest = try object(directory + ["recorded", "gemini_interactions.expected.json"])
        let samples = try #require(manifest["recorded_samples"] as? [[String: Any]])
        return samples.filter { $0["kind"] as? String == "c4_sample" }
    }

    static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "<invalid>"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Request golden (GI-01 to 05)

@Suite("Gemini Interactions golden (same-name cases for the shared fixtures)", .sharedProcessState)
struct GeminiInteractionsGoldenTests {

    private static func messages(from input: [String: Any], activated: Bool) throws -> [ChatMessage] {
        let raw = try #require(input["messages"] as? [[String: Any]])
        return try raw.map { item in
            let role: ChatRole = item["role"] as? String == "assistant" ? .assistant : .user
            let parts = try #require(item["parts"] as? [[String: Any]])
            let text = parts.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            let attachments: [Oriveo.Attachment] = parts.compactMap { part in
                let mime = part["mime_type"] as? String ?? ""
                let data = part["data"] as? String ?? ""
                switch part["type"] as? String {
                case "image":
                    return Oriveo.Attachment(id: UUID(), kind: .image, fileName: "image.png", mimeType: mime, base64Data: data)
                case "document":
                    // pre_activation: the file stores the extracted body (base64) in this platform's attachment model, with the original base64 stored separately;
                    // activated: the original is the data to send.
                    if !activated, let extracted = part["extracted_text"] as? String {
                        return Oriveo.Attachment(
                            id: UUID(), kind: .file, fileName: part["name"] as? String ?? "document",
                            mimeType: mime, base64Data: Data(extracted.utf8).base64EncodedString(),
                            extractedSizeBytes: extracted.utf8.count, originalBase64Data: data
                        )
                    }
                    return Oriveo.Attachment(
                        id: UUID(), kind: .file, fileName: part["name"] as? String ?? "document",
                        mimeType: mime, base64Data: data
                    )
                default:
                    return nil
                }
            }
            var message = ChatMessage(
                id: UUID(), role: role, text: text, providerKind: .gemini,
                providerName: "Gemini", modelName: input["model"] as? String ?? "", state: .delivered
            )
            message.attachments = attachments.isEmpty ? nil : attachments
            return message
        }
    }

    /// Call the production builder with the golden input and return the outbound body.
    private static func build(_ id: String) throws -> (body: [String: Any], raw: String, item: [String: Any]) {
        let item = try GIFixtures.goldenCase(id)
        let input = try #require(item["input"] as? [String: Any])
        let activated = input["attachment_profile"] as? String == "activated"
        let web = try GIFixtures.webRecipe()
        let route = try #require(web.route)
        let reasoning = input["reasoning_recipe"] as? Bool == true ? try GIFixtures.reasoningRecipe() : nil
        let request = try GeminiService().buildInteractionsRequest(
            modelID: try #require(input["model"] as? String),
            messages: try messages(from: input, activated: activated),
            apiKey: "fixture-key",
            stream: true,
            route: route,
            webRecipe: input["web"] as? Bool == true ? web : nil,
            reasoningRecipe: reasoning?.0,
            reasoningIntent: input["reasoning"] as? String,
            reasoningAvailableIntents: reasoning?.1,
            attachmentProfile: activated ? .activated : .preActivation,
            systemPrompt: input["system"] as? String ?? ""
        )
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (body, String(decoding: data, as: UTF8.self), item)
    }

    private static func keys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.keys).union(object.values.flatMap { keys(in: $0) })
        }
        if let array = value as? [Any] { return Set(array.flatMap { keys(in: $0) }) }
        return []
    }

    private static func value(at pointer: String, in body: [String: Any]) -> Any? {
        var current: Any? = body
        for segment in pointer.split(separator: "/").map(String.init) {
            current = (current as? [String: Any])?[segment]
        }
        return current
    }

    private static func verify(_ id: String) throws {
        let (body, raw, item) = try build(id)
        // Each case also asserts: store:false and no continuation ID (every turn sends the full Step[]).
        #expect(body["store"] as? Bool == false, "\(id): store must always be false")
        #expect(!keys(in: body).contains("previous_interaction_id"), "\(id): previous_interaction_id must not be sent")
        if let expectedBody = item["expected_body"] {
            #expect(GIFixtures.canonical(body) == GIFixtures.canonical(expectedBody), "\(id): body differs from golden\n\(raw)")
        }
        guard let assertions = item["assertions"] as? [String: Any] else { return }
        let steps = (body["input"] as? [[String: Any]]) ?? []
        let contents = steps.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
        if let pointers = assertions["absent_pointers"] as? [String] {
            for pointer in pointers {
                #expect(value(at: pointer, in: body) == nil, "\(id): \(pointer) should not appear")
            }
        }
        if let types = assertions["input_step_types"] as? [String] {
            #expect(steps.map { $0["type"] as? String ?? "" } == types, "\(id): step types \(raw)")
        }
        if let only = assertions["content_types_only"] as? [String] {
            #expect(contents.allSatisfy { only.contains($0["type"] as? String ?? "") }, "\(id): content type out of range \(raw)")
        }
        if let needles = assertions["user_text_contains"] as? [String] {
            let userText = steps.filter { $0["type"] as? String == "user_input" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            for needle in needles {
                #expect(userText.contains(needle), "\(id): user text is missing \(needle)\n\(userText)")
            }
        }
        if let absentKeys = assertions["absent_keys_anywhere"] as? [String] {
            let present = keys(in: body)
            for key in absentKeys {
                #expect(!present.contains(key), "\(id): key \(key) appeared")
            }
        }
        if let substrings = assertions["absent_substrings"] as? [String] {
            for substring in substrings {
                #expect(!raw.contains(substring), "\(id): the outbound request carried \(substring)")
            }
        }
        if let store = assertions["store"] as? Bool {
            #expect(body["store"] as? Bool == store)
        }
    }

    @Test func GI_TEXT_SINGLE() throws { try Self.verify("GI_TEXT_SINGLE") }
    @Test func GI_MULTI_TURN_SYSTEM() throws { try Self.verify("GI_MULTI_TURN_SYSTEM") }
    @Test func GI_WEB_ON() throws { try Self.verify("GI_WEB_ON") }
    @Test func GI_THINKING_AUTOMATIC() throws { try Self.verify("GI_THINKING_AUTOMATIC") }
    @Test func GI_THINKING_OFF() throws { try Self.verify("GI_THINKING_OFF") }
    @Test func GI_THINKING_LOW() throws { try Self.verify("GI_THINKING_LOW") }
    @Test func GI_THINKING_BALANCED() throws { try Self.verify("GI_THINKING_BALANCED") }
    @Test func GI_THINKING_DEEP_WEB_MULTI_TURN() throws { try Self.verify("GI_THINKING_DEEP_WEB_MULTI_TURN") }
    @Test func GI_IMAGE_PRE_ACTIVATION() throws { try Self.verify("GI_IMAGE_PRE_ACTIVATION") }
    @Test func GI_IMAGE_ACTIVATED() throws { try Self.verify("GI_IMAGE_ACTIVATED") }
    @Test func GI_DOCUMENT_ACTIVATED() throws { try Self.verify("GI_DOCUMENT_ACTIVATED") }
    @Test func GI_DOCUMENT_PRE_ACTIVATION() throws { try Self.verify("GI_DOCUMENT_PRE_ACTIVATION") }
    @Test func GI_EMPTY_ASSISTANT_SKIPPED() throws { try Self.verify("GI_EMPTY_ASSISTANT_SKIPPED") }

    @Test func GI_PATH_FROM_RECIPE() throws {
        let web = try GIFixtures.webRecipe()
        func route(_ path: String) throws -> MetadataClient.CapabilityRecipeRoute {
            let raw: [String: Any] = [
                "protocol": "gemini_interactions", "endpointClass": "interactions",
                "path": path, "requestMapper": "gemini_interactions_v1",
            ]
            return try JSONDecoder().decode(
                MetadataClient.CapabilityRecipeRoute.self,
                from: JSONSerialization.data(withJSONObject: raw)
            )
        }
        let message = ChatMessage(
            id: UUID(), role: .user, text: "Hello", providerKind: .gemini,
            providerName: "Gemini", modelName: "gemini-3.1-flash-lite", state: .delivered
        )
        let beta = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3.1-flash-lite", messages: [message], apiKey: "fixture-key", stream: true,
            route: try route("/v1beta/interactions"), webRecipe: web
        )
        #expect(beta.url?.absoluteString.hasSuffix("/v1beta/interactions") == true, "\(beta.url?.absoluteString ?? "")")
        #expect(beta.url?.absoluteString.contains("/v1beta/v1beta") == false)
        let ga = try GeminiService().buildInteractionsRequest(
            modelID: "gemini-3.1-flash-lite", messages: [message], apiKey: "fixture-key", stream: true,
            route: try route("/v1/interactions"), webRecipe: web
        )
        #expect(ga.url?.absoluteString == "https://generativelanguage.googleapis.com/v1/interactions")
        for path in ["/v1beta/models/gemini:generateContent", "/v2/interactions", "/interactions"] {
            #expect(throws: ProviderServiceError.self, "A path outside the allowlist, \(path), must be a configuration error") {
                _ = try GeminiService().buildInteractionsRequest(
                    modelID: "gemini-3.1-flash-lite", messages: [message], apiKey: "fixture-key", stream: true,
                    route: try route(path), webRecipe: web
                )
            }
        }
    }
}

// MARK: - Stream replay (GI-06 to 08)

@Suite("Gemini Interactions SSE replay (same-name cases for the shared fixtures)", .sharedProcessState)
struct GeminiInteractionsStreamReplayTests {

    private struct Replay {
        var text = ""
        var thinking = ""
        var citations: [Citation] = []
        var error: ProviderServiceError?
        var parser: GeminiService.InteractionsStreamParser
        var done = false
    }

    /// Feed the production parser line by line: split on LF, the same as `bytes.utf8Lines`.
    private static func replay(_ name: String) throws -> Replay {
        var out = Replay(parser: GeminiService.InteractionsStreamParser(redacting: ["fixture-key"]))
        do {
            for line in try GIFixtures.sse(name).split(separator: "\n", omittingEmptySubsequences: false) {
                for event in try out.parser.consume(line: String(line)) {
                    switch event {
                    case let .delta(text): out.text += text
                    case let .reasoning(text): out.thinking += text
                    case let .citations(citations): out.citations = citations
                    default: break
                    }
                }
            }
            try out.parser.finish()
            out.done = true
        } catch let error as ProviderServiceError {
            out.error = error
        }
        return out
    }

    private static func verify(_ name: String) throws {
        try verify(name, expected: try GIFixtures.expected(name))
    }

    /// `dedupeCitations`: for real samples only (conventions.citations_dedupe): both sides first dedupe by url (keeping the first occurrence and its range) and then compare.
    private static func verify(_ name: String, expected: [String: Any], dedupeCitations: Bool = false) throws {
        var got = try replay(name)
        #expect(got.text == expected["text"] as? String, "\(name): body text")
        #expect(got.thinking == expected["thinking"] as? String, "\(name): thinking")

        var citations = (expected["citations"] as? [[String: Any]]) ?? []
        if dedupeCitations {
            var seen = Set<String>()
            citations = citations.filter { seen.insert($0["url"] as? String ?? "").inserted }
            var seenGot = Set<String>()
            got.citations = got.citations.filter { seenGot.insert($0.url).inserted }
        }
        #expect(got.citations.map(\.url) == citations.map { $0["url"] as? String ?? "" }, "\(name): citation url")
        #expect(got.citations.map(\.title) == citations.map { $0["title"] as? String }, "\(name): citation title")
        #expect(got.citations.map(\.startIndex) == citations.map { $0["start_index"] as? Int }, "\(name): start_index")
        #expect(got.citations.map(\.endIndex) == citations.map { $0["end_index"] as? Int }, "\(name): end_index")
        #expect(got.parser.searchEvidenceCount == ((expected["search_evidence"] as? [Any]) ?? []).count, "\(name): web evidence count")

        if let usage = expected["usage"] as? [String: Any] {
            let parsed = try #require(got.parser.usage, "\(name): usage was not parsed")
            #expect(parsed.inputTokens == usage["input_total"] as? Int)
            #expect(parsed.outputTokens == usage["output_total"] as? Int)
            #expect(parsed.thoughtTokens == usage["reasoning"] as? Int)
        } else {
            #expect(got.parser.usage == nil, "\(name): there should be no usage")
        }

        let terminal = try #require(expected["terminal"] as? String)
        switch terminal {
        case "completed", "incomplete":
            // incomplete is handled like generateContent's MAX_TOKENS: it completes normally and keeps the content.
            #expect(got.done, "\(name): should complete normally, but threw \(String(describing: got.error))")
            #expect(got.error == nil)
        case "error":
            let error = try #require(got.error, "\(name): should throw the upstream error")
            let spec = try #require(expected["error"] as? [String: Any])
            let code = try #require(spec["code"] as? String)
            #expect(error.technicalDetail.contains(code), "\(name): the error did not carry code \(code): \(error.technicalDetail)")
            if let message = spec["message"] as? String {
                #expect(error.technicalDetail.contains(message), "\(name): the error did not carry the upstream text")
            }
            #expect(!got.done)
        case "interrupted":
            // interrupted is handled as an error: cancelled -> interaction_cancelled; a missing completed -> interaction_stream_closed.
            let error = try #require(got.error, "\(name): an interruption should be thrown as an error")
            let code = name.hasSuffix("_cancelled") ? "interaction_cancelled" : "interaction_stream_closed"
            #expect(error.technicalDetail.contains(code), "\(name): the error did not carry code \(code): \(error.technicalDetail)")
            #expect(!got.done)
        default:
            Issue.record("\(name): unknown terminal \(terminal)")
        }
    }

    @Test func gemini_interactions_text() throws { try Self.verify("gemini_interactions_text") }
    @Test func gemini_interactions_thought_summary() throws { try Self.verify("gemini_interactions_thought_summary") }
    @Test func gemini_interactions_search_citation() throws { try Self.verify("gemini_interactions_search_citation") }
    @Test func gemini_interactions_error() throws { try Self.verify("gemini_interactions_error") }
    @Test func gemini_interactions_error_after_text() throws { try Self.verify("gemini_interactions_error_after_text") }
    @Test func gemini_interactions_truncated() throws { try Self.verify("gemini_interactions_truncated") }
    @Test func gemini_interactions_incomplete() throws { try Self.verify("gemini_interactions_incomplete") }
    @Test func gemini_interactions_failed() throws { try Self.verify("gemini_interactions_failed") }
    @Test func gemini_interactions_cancelled() throws { try Self.verify("gemini_interactions_cancelled") }

    /// Five SSE recordings from real providers (2026-10-13), using the same parser and the same comparison as the official fixtures.
    @Test func GI_LIVE_RECORDED_SAMPLES() throws {
        let samples = try GIFixtures.liveSamples()
        #expect(samples.count == 5, "c4_sample should be exactly 5, actually \(samples.count)")
        for sample in samples {
            let file = try #require(sample["file"] as? String)
            let name = String(file.dropLast(".sse".count))
            let expected = try #require(sample["expected"] as? [String: Any], "\(file) is missing expected")
            try Self.verify(name, expected: expected, dedupeCitations: true)
            #expect(!(try Self.replay(name).text.isEmpty), "\(name): the real sample's body text should not be empty")
        }
    }
}
