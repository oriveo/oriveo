import Foundation
import OriveoProviderKit


nonisolated struct MoonshotWebSearchTool: ToolRegistryEntry {
    static let builtinToolName = "$web_search"

    let name: String
    let wireType: String
    let executeCall: @Sendable (ToolLoopToolCall) async throws -> String

    var scope: ToolScope { .web }
    var definition: ToolLoopToolDefinition? { nil }

    init(
        name: String = Self.builtinToolName,
        wireType: String = "builtin_function",
        executeCall: @escaping @Sendable (ToolLoopToolCall) async throws -> String
    ) {
        self.name = name
        self.wireType = wireType
        self.executeCall = executeCall
    }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        let content = try await executeCall(call)
        // A completed tool/fiber result is a real side effect. A later chat-leg failure cannot be
        // treated as a pre-token custom rejection.
        await MainActor.run { CapabilityExecutionRuntime.recordSideEffect() }
        return ToolExecutionOutcome(content: content)
    }

    static func builtinResultContent(for call: ToolLoopToolCall) -> String {
        call.function.arguments.isEmpty ? "{}" : call.function.arguments
    }
}

nonisolated final class MoonshotToolLoopLegRunner: ToolLoopLegRunning, @unchecked Sendable {
    typealias LegRequestPerformer = @Sendable (URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
    typealias CitationsSink = @Sendable ([Citation]) -> Void

    private let initialRequest: URLRequest
    private let perform: LegRequestPerformer
    private let citationsSink: CitationsSink
    private let kimiShape: MetadataClient.StreamShape?
    private let lock = NSLock()
    private var legUsages: [ProviderTokenUsage] = []

    init(
        initialRequest: URLRequest,
        kimiShape: MetadataClient.StreamShape?,
        perform: @escaping LegRequestPerformer,
        citationsSink: @escaping CitationsSink
    ) {
        self.initialRequest = initialRequest
        self.kimiShape = kimiShape
        self.perform = perform
        self.citationsSink = citationsSink
    }

    var collectedLegUsages: [ProviderTokenUsage] {
        lock.withLock { legUsages }
    }

    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let urlRequest = try Self.legRequest(base: initialRequest, leg: request)
                    let (bytes, response) = try await perform(urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderServiceError.network(detail: "Missing HTTPURLResponse.")
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        throw ProviderServiceError.upstream(statusCode: http.statusCode, detail: "Moonshot leg failed.")
                    }
                    var assembler = OpenAICompatibleStreamAssembler(profile: .moonshot)
                    var state = OpenAICompatibleStreamState()
                    var kimiCtx = StreamContext()
                    var lastCitationsCount = 0
                    let strategy = TransportRegistry.strategy(for: .openaiChat)
                    func forward(_ events: [StreamEvent]) {
                        for event in events {
                            switch event {
                            case let .delta(text): continuation.yield(.textDelta(text))
                            case let .reasoning(text): continuation.yield(.reasoningDelta(text))
                            case let .toolCallDeltas(calls):
                                continuation.yield(.toolCallDeltas(calls.enumerated().map { offset, call in
                                    ToolLoopToolCallDelta(
                                        index: offset, id: call.providerCallID, type: "function",
                                        name: call.name, arguments: call.rawArguments
                                    )
                                }))
                            default: break
                            }
                        }
                    }
                    for try await line in bytes.utf8Lines {
                        try Task.checkCancellation()
                        forward(state.consume(try assembler.ingest(line)))
                        let payload = line.hasPrefix("data:")
                            ? String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                            : line
                        _ = strategy.parseStreamLine(payload, ctx: &kimiCtx, shape: kimiShape)
                        let snapshot = kimiCtx.citationsAccumulator.citations
                        if snapshot.count > lastCitationsCount {
                            lastCitationsCount = snapshot.count
                            citationsSink(snapshot)
                        }
                        if assembler.isDone { break }
                    }
                    try Task.checkCancellation()
                    forward(state.consume(try assembler.finish()))
                    if let usage = state.usage {
                        continuation.yield(.usage(ToolLoopUsage(
                            promptTokens: Int(clamping: usage.inputTokens),
                            completionTokens: Int(clamping: usage.outputTokens),
                            totalTokens: Int(clamping: usage.inputTokens + usage.outputTokens)
                        )))
                    }
                    if let usage = state.usage {
                        lock.withLock { legUsages.append(usage) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func legRequest(base: URLRequest, leg: ToolLoopLegRequest) throws -> URLRequest {
        guard let body = base.httpBody,
              var json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Kimi request payload.")
        }
        var messages = json["messages"] as? [[String: Any]] ?? []
        if !leg.messages.isEmpty {
            let data = try JSONEncoder().encode(leg.messages)
            guard let appended = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ProviderServiceError.invalidConfiguration(detail: "Invalid Kimi tool-loop messages.")
            }
            messages.append(contentsOf: appended)
        }
        json["messages"] = messages
        if leg.toolChoice == .none, (json["tools"] as? [Any])?.isEmpty == false {
            json["tool_choice"] = "none"
        }
        var request = base
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }
}

actor MoonshotLoopProgress {
    private(set) var text = ""
    private(set) var reasoning = ""
    private var legSawReasoning = false

    func beginLeg() {
        legSawReasoning = false
    }

    func appendText(_ delta: String) {
        text += delta
    }

    func appendReasoning(_ delta: String) -> Bool {
        let needsSeparator = !legSawReasoning && !reasoning.isEmpty
        if needsSeparator { reasoning += "\n\n" }
        legSawReasoning = true
        reasoning += delta
        return needsSeparator
    }
}

/// pending calls never reach the local sidecar and cannot be auto-resumed on restart.
final class MoonshotContinuationPersistence {
    private let messageID: UUID?
    private let recipe: MetadataClient.CapabilityRecipe?
    private var completedMessages: [MetadataClient.JSONValue] = []

    init(messageID: UUID?, recipe: MetadataClient.CapabilityRecipe?) {
        self.messageID = messageID
        self.recipe = recipe
    }

    func save(_ record: ToolCallLoop.LegRecord) throws {
        guard let messageID else { return }
        let encoded = try ([record.assistantMessage] + record.toolResultMessages).map(Self.jsonValue)
        completedMessages.append(contentsOf: encoded)
        let state: [String: MetadataClient.JSONValue] = ["completedMessages": .array(completedMessages)]
        let validation = RequestPreferenceResolver.validateContinuation(.init(
            kind: "tool_loop", variant: recipe?.continuationVariant, step: 1,
            state: state.mapValues(Self.requestPreferenceValue)
        ))
        guard validation.accepted else {
            throw ProviderServiceError.invalidConfiguration(detail: "Invalid Moonshot tool-loop continuation state.")
        }
        try RecipeContinuationRuntime.save(messageID: messageID, recipe: recipe, state: state)
    }

    static func jsonValue(_ message: ToolLoopMessage) throws -> MetadataClient.JSONValue {
        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data)
        return jsonValue(object)
    }

    static func jsonValue(_ value: Any) -> MetadataClient.JSONValue {
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? NSNumber { return .number(value.doubleValue) }
        if let value = value as? [String: Any] { return .object(value.mapValues(jsonValue)) }
        if let value = value as? [Any] { return .array(value.map(jsonValue)) }
        return .null
    }

    static func requestPreferenceValue(_ value: MetadataClient.JSONValue) -> RequestPreferenceJSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .number(value): return .double(value)
        case let .string(value): return .string(value)
        case let .array(value): return .array(value.map(requestPreferenceValue))
        case let .object(value): return .object(value.mapValues(requestPreferenceValue))
        }
    }
}
