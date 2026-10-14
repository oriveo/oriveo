import Foundation
import OriveoProviderKit

// MARK: - Relay 2.0 user-initiated "Test capabilities"
//
// Runs only when the user taps the button: using the protocol currently in effect for the model, sends text -> image -> tool in turn, one streaming request per item,
// built by the same production builders as an ordinary chat send, and sent only once: no protocol fallback, no self-heal parameter stripping, no retry, no negative-cache write.
// Each item has a total deadline `perItemDeadline` (from dispatch to reading the last byte).
// text is the baseline: if it is not accepted we stop and write nothing; accepted writes `{true, tested}`, rejected writes `{false, tested}`,
// undetermined writes nothing (the old value is kept); items that already have a `user` override are neither sent nor changed.
// After an image / tool item is accepted, the production parser of this protocol must still find evidence: for image, whether the visible text contains the whole word
// `imageExpectedAnswer`; for tool, whether a function call named `toolName` is produced; no evidence = notObserved, nothing is written and the old value is kept.
// Request shape and verdicts follow `shared/test-fixtures/relay/capability-test.v1.json`.

enum RelayCapabilityTest {
    enum Kind: String, CaseIterable, Sendable {
        case text, image, tool
        /// Web search: goes through the manual web probe; the override for web is written back by the probe itself.
        case web

        /// The override key to write back; text has none.
        var overrideKey: RelayCapabilityOverrides.Key? {
            switch self {
            case .text: nil
            case .image: .image
            case .tool: .toolCall
            case .web: .web
            }
        }
    }

    nonisolated enum Verdict: String, Equatable, Sendable {
        case accepted, rejected, undetermined
        /// Accepted with 2xx, but no evidence in the response that image / tool actually took effect; nothing is written.
        case notObserved
        /// Web item (probe result): it really searched / it replied without searching.
        case searched, silent
    }

    /// Reason for the verdict (fixture `reason`); the panel shows one sentence based on it.
    nonisolated enum Reason: String, Equatable, Sendable {
        case ok
        case upstreamRejected = "upstream_rejected"
        case notFound = "not_found"
        case unauthorized, forbidden
        case rateLimited = "rate_limited"
        case html, server, http, network, timeout
        case notObserved = "not_observed"
    }

    nonisolated struct Judgement: Equatable, Sendable {
        let verdict: Verdict
        let reason: Reason
    }

    enum Outcome: String, Equatable, Sendable {
        case completed
        case textFailed = "text_failed"
        case stopped
    }

    /// Interruption reason: checked before each item is sent and before writing back.
    enum StopReason: String, Equatable, Sendable {
        case cancelled, connection
        case protocolChanged = "protocol"
        case unavailable
    }

    struct Response: Equatable, Sendable {
        let status: Int
        let contentType: String
        let body: Data
    }

    /// The verdict of one item: `status` is present only when an HTTP response was received.
    struct ItemResult: Equatable, Sendable {
        let verdict: Verdict
        let reason: Reason
        let status: Int?
        let elapsedMs: Int
    }

    struct Result: Equatable, Sendable {
        let outcome: Outcome
        /// Text baseline; nil when interrupted before it completes.
        let text: ItemResult?
        /// The `.image` / `.toolCall` items actually tested; empty when text did not pass.
        let itemResults: [RelayCapabilityOverrides.Key: ItemResult]
        let stopReason: StopReason?
        /// A write-back happened and at least one item was written (accepted / rejected).
        let written: Bool

        var items: [RelayCapabilityOverrides.Key: Verdict] { itemResults.mapValues(\.verdict) }
    }

    /// Reports progress to the UI item by item.
    enum Event: Equatable, Sendable {
        case started(Kind)
        case finished(Kind, ItemResult)
    }

    /// Sends one test request and reads the whole response; a throw = no HTTP response was received (network / security policy / cancelled).
    typealias Send = (_ kind: Kind, _ request: URLRequest) async throws -> Response

    // MARK: Built-in material (fixture `builtins` / `deadline`)

    static let maxOutputTokens = 16
    /// Total deadline per item (fixture `deadline.perItemSeconds`).
    static let perItemSeconds = 30
    static let perItemDeadline: Duration = .seconds(perItemSeconds)
    static let textPrompt = "Hi"
    static let imagePrompt = "What color is this image? Answer in one word."
    static let imageMimeType = "image/png"
    static let imagePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYII="
    static let toolPrompt = "What time is it? Use the tool."
    static let toolName = "get_current_time"
    static let toolDescription = "Returns the current time. Has no side effects."
    /// Expected answer for the image item (fixture `builtins.imageExpectedAnswer`): the image counts as recognized only if the visible text contains this whole word (case-insensitive).
    static let imageExpectedAnswer = "red"

    static var toolDefinition: ToolLoopToolDefinition {
        ToolLoopToolDefinition(function: .init(
            name: toolName,
            description: toolDescription,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "timezone": .object([
                        "type": .string("string"),
                        "description": .string("IANA time zone name, for example UTC."),
                    ]),
                ]),
            ])
        ))
    }

    /// A synthesized user message; the image item attaches the built-in PNG as an image attachment, going through the same attachment pipeline as chat.
    static func message(for kind: Kind, modelID: String) -> ChatMessage {
        var message = ChatMessage(
            id: UUID(),
            role: .user,
            text: kind == .text ? textPrompt : (kind == .image ? imagePrompt : toolPrompt),
            providerKind: .relay,
            providerName: "Relay",
            modelName: modelID,
            state: .delivered
        )
        if kind == .image {
            message.attachments = [Attachment(
                id: UUID(), kind: .image, fileName: "capability-test.png", mimeType: imageMimeType,
                base64Data: imagePNGBase64
            )]
        }
        return message
    }

    /// Only the four generation protocols are supported; the others (llama.cpp native, auto) are not tested.
    static func shortName(_ transport: RelayTransport) -> String? {
        switch transport {
        case .openaiChatCompletions: "chat"
        case .openaiResponses: "responses"
        case .anthropicMessages: "messages"
        case .geminiGenerateContent: "gemini"
        case .auto, .llamacppNative: nil
        }
    }

    /// Same scope as the per-model probe: Relay form, no `engineProfile`, and the model's first-send protocol is one of the four.
    static func isEligible(provider: Provider, model: AIModel) -> Bool {
        ProviderForm.of(provider) == .relay
            && provider.relayRequested?.engineProfile == nil
            && shortName(transport(provider: provider, model: model)) != nil
    }

    /// The protocol used for testing = the protocol of a chat's first send without attachments: the request, the negative-cache key cleared on write-back, the panel display and the eligibility check all read it,
    /// An unverified Claude-family model on an auto connection first sends Messages, so the test also sends Messages rather than the effective protocol Chat.
    static func transport(provider: Provider, model: AIModel) -> RelayTransport {
        RelayFirstSendTransport.current(provider: provider, model: model)
    }

    /// The "Test capabilities" entry: in scope, and image and tool do not both already have a `user` override (if both do, there is nothing to test);
    /// it is still shown when both are `user` but a web item can be listed (the first-send protocol has a stored fragment).
    static func showsEntry(provider: Provider, model: AIModel, fragments: RelayWebFragmentStore = .shared) -> Bool {
        isEligible(provider: provider, model: model)
            && (!(isUserSet(model.relayCapabilityOverrides, .image) && isUserSet(model.relayCapabilityOverrides, .toolCall))
                || listsWeb(provider: provider, model: model, fragments: fragments))
    }

    /// Items to be tested: text is always first; image / tool are tested only when there is no `user` override.
    static func plannedKinds(_ overrides: RelayCapabilityOverrides?) -> [Kind] {
        [.text] + [Kind.image, .tool].filter { kind in
            kind.overrideKey.map { !isUserSet(overrides, $0) } ?? true
        }
    }

    /// Items shared by the panel and execution: if the first-send protocol has a stored web fragment, web is then placed last.
    static func plannedKinds(provider: Provider, model: AIModel, fragments: RelayWebFragmentStore) -> [Kind] {
        plannedKinds(model.relayCapabilityOverrides) + (listsWeb(provider: provider, model: model, fragments: fragments) ? [.web] : [])
    }

    static func listsWeb(provider: Provider, model: AIModel, fragments: RelayWebFragmentStore) -> Bool {
        RelayWebProbe.isEligible(provider: provider, model: model)
            && fragments.hasEffectiveFragment(provider: provider, transport: RelayWebProbe.transport(provider: provider, model: model))
    }

    // MARK: T1 Verdict

    /// For callers that look only at the verdict (negative-cache write points).
    nonisolated static func classify(status: Int, contentType: String, body: Data) -> Verdict {
        judge(status: status, contentType: contentType, body: body).verdict
    }

    /// Rejection signals follow only these: HTTP 400 / 404 / 415 / 422, and 2xx whose response is an error (top-level JSON `error` non-null with no body text;
    /// SSE with an error event and no output event at all). A 2xx HTML fallback page and all other failures are undetermined.
    nonisolated static func judge(status: Int, contentType: String, body: Data) -> Judgement {
        if (200..<300).contains(status) {
            let probe = HTTPURLResponse(
                url: URL(string: "https://relay.invalid")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!
            guard RelaySuccessResponsePolicy.acceptsGenerationResponse(data: body, response: probe) else {
                return Judgement(verdict: .undetermined, reason: .html)
            }
            let rejected = contentType.lowercased().contains("text/event-stream")
                ? isRejectedEventStream(body)
                : isErrorBodyWithoutContent(body)
            return rejected
                ? Judgement(verdict: .rejected, reason: .upstreamRejected)
                : Judgement(verdict: .accepted, reason: .ok)
        }
        switch status {
        case 400, 415, 422: return Judgement(verdict: .rejected, reason: .upstreamRejected)
        case 404: return Judgement(verdict: .rejected, reason: .notFound)
        case 401: return Judgement(verdict: .undetermined, reason: .unauthorized)
        case 403: return Judgement(verdict: .undetermined, reason: .forbidden)
        case 429: return Judgement(verdict: .undetermined, reason: .rateLimited)
        case 500..<600: return Judgement(verdict: .undetermined, reason: .server)
        default: return Judgement(verdict: .undetermined, reason: .http)
        }
    }

    /// Body fields of the four protocols: Chat `choices`, Responses `output`, Messages `content`, Gemini `candidates`.
    nonisolated private static let contentKeys = ["choices", "output", "content", "candidates"]
    /// Top-level fields in an SSE event that count as "has output" (fixture $comment).
    nonisolated private static let eventOutputKeys = ["choices", "candidates", "delta", "output", "content", "content_block"]

    nonisolated private static func isErrorBodyWithoutContent(_ body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = object["error"], !(error is NSNull) else { return false }
        return !contentKeys.contains { key in
            guard let value = object[key] else { return false }
            return !(value is NSNull)
        }
    }

    /// Every `data:` that parses as a JSON object is an event; an error event with no output event -> rejected.
    nonisolated private static func isRejectedEventStream(_ body: Data) -> Bool {
        let signals = eventStreamSignals(body)
        return signals.sawError && !signals.sawOutput
    }

    /// Whether the SSE has an error event and whether it has an output event; the web probe uses this to judge an "error frame after output" as undetermined.
    nonisolated static func eventStreamSignals(_ body: Data) -> (sawError: Bool, sawOutput: Bool) {
        let text = String(decoding: body, as: UTF8.self)
        var sawError = false
        var sawOutput = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            let type = event["type"] as? String
            if let error = event["error"], !(error is NSNull) { sawError = true }
            if type == "error" || type == "response.failed" { sawError = true }
            if type?.hasPrefix("response.output") == true { sawOutput = true }
            if eventOutputKeys.contains(where: { key in event[key].map { !($0 is NSNull) } ?? false }) {
                sawOutput = true
            }
        }
        return (sawError, sawOutput)
    }

    // MARK: T1.5 Image / tool evidence

    /// After an image / tool item is judged accepted, the SSE is fed to this protocol's production parser (fed the same way as the web probe):
    /// for image take the body delta chat would display (thinking content does not count) and whole-word match the expected answer; for tool take the function-call name the parser produced.
    /// No evidence -> notObserved / not_observed; text items and non-accepted verdicts are returned as is.
    nonisolated static func withEvidence(_ judgement: Judgement, kind: Kind, transport: RelayTransport, body: Data) -> Judgement {
        guard judgement.verdict == .accepted, kind != .text else { return judgement }
        let events = RelayWebProbe.parseStream(transport: transport, fragment: nil, body: body).events
        let observed: Bool
        switch kind {
        case .text:
            observed = true
        case .image:
            let visible = events.reduce(into: "") { text, event in
                if case let .delta(chunk) = event { text += chunk }
            }
            observed = containsWord(visible, imageExpectedAnswer)
        case .tool:
            observed = events.contains { event in
                guard case let .toolCallDeltas(calls) = event else { return false }
                return calls.contains { $0.name == toolName }
            }
        case .web:
            // Web items do not go through here (the web probe judges them).
            observed = true
        }
        return observed ? judgement : Judgement(verdict: .notObserved, reason: .notObserved)
    }

    /// Whole word, case-insensitive: split into words on non-alphanumerics and compare each.
    nonisolated static func containsWord(_ text: String, _ word: String) -> Bool {
        let target = word.lowercased()
        return text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .contains { $0 == target }
    }

    // MARK: T2 Request (the same builders as chat)

    /// Builds the streaming request for one item with the chat builder for the effective protocol: same URL root, same headers (the key from the per-model key entry point), same options;
    /// the output cap goes through the builder's max-tokens parameter, and the tool item carries `tools` in this protocol's tool-leg shape.
    static func request(
        kind: Kind,
        provider: Provider,
        model: AIModel,
        services: ProviderServiceRouter.Services,
        partitionID: String
    ) throws -> URLRequest {
        // The evidence model, connection id and task-local identity are the same as an ordinary chat send (ChatManager); the builder reads them at construction time.
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partitionID, hasExplicitValue: false, effectiveTransport: nil
        )
        return try CapabilityEvidenceRequestContext.$current.withValue(identity) {
            try buildRequest(
                provider: provider, model: model, services: services,
                messages: [message(for: kind, modelID: model.id)], maxOutputTokens: maxOutputTokens,
                includesTool: kind == .tool, webFragments: nil
            )
        }
    }

    /// The web probe uses the same builder: one user message, its own output cap, plus the web fragment stored on the connection,
    /// merged into the request body by the builder with the same per-protocol merge function as chat (`RelayWebFragments.apply`).
    static func request(
        provider: Provider,
        model: AIModel,
        services: ProviderServiceRouter.Services,
        partitionID: String,
        messages: [ChatMessage],
        maxOutputTokens: Int,
        webFragments: RelayWebFragmentSet
    ) throws -> URLRequest {
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partitionID, hasExplicitValue: false, effectiveTransport: nil
        )
        return try CapabilityEvidenceRequestContext.$current.withValue(identity) {
            try buildRequest(
                provider: provider, model: model, services: services,
                messages: messages, maxOutputTokens: maxOutputTokens, includesTool: false, webFragments: webFragments
            )
        }
    }

    private static func buildRequest(
        provider: Provider,
        model: AIModel,
        services: ProviderServiceRouter.Services,
        messages: [ChatMessage],
        maxOutputTokens: Int,
        includesTool: Bool,
        webFragments: RelayWebFragmentSet?
    ) throws -> URLRequest {
        // Same injection as the first send in chat (ChatManager first send): when the first-send protocol differs from the effective protocol, re-route the model copy by it.
        var routedModel = model
        let first = transport(provider: provider, model: model)
        if first != RelayEndpointResolver.effectiveTransport(provider: provider, model: model) {
            routedModel.relayTransport = first
        }
        guard case let .byProtocol(route) = ProviderServiceRouter.route(provider: provider, model: routedModel) else {
            throw ProviderServiceError.invalidConfiguration(detail: "Missing relay address.")
        }
        let apiKey = ProviderCredentialResolver.apiKey(provider: provider, modelID: model.id)
        var options = ChatRequestOptions()
        options.relayRequested = route.requested
        options.capabilityEvidenceModel = AttachmentTransportResolver.evidenceModel(provider: provider, model: model)
        options.attachmentConnectionID = provider.id
        options.relayWebFragments = webFragments
        let tools = includesTool ? try functionTools(for: route.transport) : nil
        switch route.transport {
        case .anthropicMessages:
            return try services.anthropic.relayCapabilityTestRequest(
                apiKey: apiKey, modelID: model.id, messages: messages, baseURL: route.baseURL,
                requestOptions: options, relayRequested: route.requested,
                maxOutputTokens: maxOutputTokens, functionTools: tools
            )
        case .geminiGenerateContent:
            return try services.gemini.relayCapabilityTestRequest(
                apiKey: apiKey, modelID: model.id, messages: messages, baseURL: route.baseURL,
                requestOptions: options, relayRequested: route.requested,
                maxOutputTokens: maxOutputTokens, functionTools: tools
            )
        case .openaiChatCompletions, .openaiResponses, .auto, .llamacppNative:
            return try services.openAI.relayCapabilityTestRequest(
                apiKey: apiKey, modelID: model.id, messages: messages, baseURL: route.baseURL,
                requestOptions: options, relayRequested: route.requested,
                maxOutputTokens: maxOutputTokens, functionTools: tools
            )
        }
    }

    /// `tools` of the tool item: the shape produced by the same protocol adapter as the chat tool leg.
    static func functionTools(for transport: RelayTransport) throws -> [Any] {
        let kind: TransportKind = switch transport {
        case .openaiResponses: .openaiResponses
        case .anthropicMessages: .anthropicMessages
        case .geminiGenerateContent: .geminiGenerate
        case .openaiChatCompletions, .auto, .llamacppNative: .openaiChat
        }
        guard let adapter = ToolProtocolAdapters.adapter(for: kind.rawValue) else {
            throw ProviderServiceError.invalidConfiguration(detail: "No tool adapter for \(transport.rawValue).")
        }
        return try adapter.encodeTools([toolDefinition])
    }

    // MARK: T3 Send and total deadline

    /// Production send: `relayBytes` of the same chat session, read to the end of the stream; once an HTTP response is received it is returned as is and no error is thrown for the status code.
    nonisolated static func perform(_ request: URLRequest, session: URLSession) async throws -> Response {
        let (bytes, response) = try await session.relayBytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderServiceError.network(detail: "No HTTP response")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return Response(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            body: data
        )
    }

    private final class DeadlineFlag {
        var fired = false
    }

    /// Sends one item and judges it. When the total deadline hits, the request is cancelled and judged timeout; `CancellationError` is thrown only if the outer task is cancelled.
    static func execute(
        kind: Kind,
        transport: RelayTransport,
        request: URLRequest,
        deadline: Duration,
        send: @escaping Send
    ) async throws -> ItemResult {
        let clock = ContinuousClock()
        let start = clock.now
        let flag = DeadlineFlag()
        let work = Task { try await send(kind, request) }
        let watchdog = Task {
            do { try await Task.sleep(for: deadline) } catch { return }
            flag.fired = true
            work.cancel()
        }
        let outcome: Swift.Result<Response, Error> = await withTaskCancellationHandler {
            do { return .success(try await work.value) } catch { return .failure(error) }
        } onCancel: {
            work.cancel()
        }
        watchdog.cancel()
        let elapsed = clock.now - start
        let elapsedMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        if Task.isCancelled, !flag.fired { throw CancellationError() }
        switch outcome {
        case let .success(response):
            let judgement = withEvidence(
                judge(status: response.status, contentType: response.contentType, body: response.body),
                kind: kind, transport: transport, body: response.body
            )
            return ItemResult(verdict: judgement.verdict, reason: judgement.reason, status: response.status, elapsedMs: elapsedMs)
        case .failure:
            return ItemResult(verdict: .undetermined, reason: flag.fired ? .timeout : .network, status: nil, elapsedMs: elapsedMs)
        }
    }

    static func isUserSet(_ overrides: RelayCapabilityOverrides?, _ key: RelayCapabilityOverrides.Key) -> Bool {
        guard let overrides, value(of: overrides, key) != nil else { return false }
        return (overrides.sources[key] ?? .user) == .user
    }

    private static func value(of overrides: RelayCapabilityOverrides, _ key: RelayCapabilityOverrides.Key) -> Bool? {
        switch key {
        case .image: overrides.image
        case .toolCall: overrides.toolCall
        case .file: overrides.file
        case .imageGeneration: overrides.imageGeneration
        case .web: overrides.web
        case .reasoningLevels: nil
        }
    }

    /// Merge the results into one override: accepted -> true, rejected -> false (both recorded as tested); undetermined / notObserved and `user` items are left alone, and other keys are untouched.
    static func merged(_ existing: RelayCapabilityOverrides?, with result: Result) -> RelayCapabilityOverrides? {
        var overrides = existing ?? RelayCapabilityOverrides()
        for (key, verdict) in result.items where !isUserSet(existing, key) {
            let value: Bool
            switch verdict {
            case .accepted: value = true
            case .rejected: value = false
            // The override for web items (searched / silent) is written back by the probe itself; not touched here.
            case .undetermined, .notObserved, .searched, .silent: continue
            }
            switch key {
            case .image: overrides.image = value
            case .toolCall: overrides.toolCall = value
            default: continue
            }
            overrides.sources[key] = .tested
        }
        return overrides.isEmpty ? nil : overrides
    }

    /// Write-back: the model with the same id is written in both the enabled list and the catalog, each merged with its own current override. Not written when text did not pass.
    static func apply(_ result: Result, modelID: String, to provider: inout Provider) {
        guard result.outcome == .completed else { return }
        func write(_ models: inout [AIModel]) {
            for index in models.indices where models[index].id == modelID {
                models[index].relayCapabilityOverrides = merged(models[index].relayCapabilityOverrides, with: result)
            }
        }
        write(&provider.models)
        write(&provider.catalogModels)
    }

    // MARK: T4 Restore automatic

    static func hasTestedEntries(_ overrides: RelayCapabilityOverrides?) -> Bool {
        guard let overrides else { return false }
        return RelayCapabilityOverrides.Key.allCases.contains { key in
            overrides.sources[key] == .tested && hasValue(overrides, key)
        }
    }

    /// Clear only `tested` items and keep `user` items; return nil (field omitted) when nothing is left.
    static func restoreAutomatic(_ overrides: RelayCapabilityOverrides?) -> RelayCapabilityOverrides? {
        guard var overrides else { return nil }
        for key in RelayCapabilityOverrides.Key.allCases where overrides.sources[key] == .tested {
            switch key {
            case .image: overrides.image = nil
            case .file: overrides.file = nil
            case .imageGeneration: overrides.imageGeneration = nil
            case .toolCall: overrides.toolCall = nil
            case .reasoningLevels: overrides.reasoningLevels = nil
            case .web: overrides.web = nil
            }
            overrides.sources[key] = nil
        }
        return overrides.isEmpty ? nil : overrides
    }

    private static func hasValue(_ overrides: RelayCapabilityOverrides, _ key: RelayCapabilityOverrides.Key) -> Bool {
        key == .reasoningLevels ? overrides.reasoningLevels != nil : value(of: overrides, key) != nil
    }
}
