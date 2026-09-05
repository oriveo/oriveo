import Foundation
import OriveoProviderKit

nonisolated struct ToolCallLoop: Sendable {
    struct Limits: Sendable, Equatable {
        static let hardCap = 8
        static let defaultMaxSteps = 6

        var maxSteps: Int
        var maxSelfCorrections: Int
        var maxConsecutiveToolFailures: Int
        var tokenBudget: Int?

        init(
            maxSteps: Int,
            maxSelfCorrections: Int = 3,
            maxConsecutiveToolFailures: Int = 3,
            tokenBudget: Int? = nil
        ) {
            self.maxSteps = max(0, maxSteps)
            self.maxSelfCorrections = maxSelfCorrections
            self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
            self.tokenBudget = tokenBudget
        }

        static func effectiveMaxSteps(serverValue: Int?) -> Int {
            guard let serverValue, serverValue > 0 else { return defaultMaxSteps }
            return min(serverValue, hardCap)
        }
    }

    struct Prompts: Sendable, Equatable {
        var stepLimitReached = "The tool call limit was reached. Synthesize the answer now from existing tool results. Do not call another tool and cite sources as [n]."
        var tokenBudgetReached = "The research token budget was reached. Synthesize the answer now from existing tool results, do not call another tool, and cite sources as [n]. If there is not enough evidence, say so clearly."
        var stoppedByStepLimit = "The tool call step limit was reached."
        var stoppedByTokenBudget = "The research token budget was reached."

        init() {}
    }

    enum ProgressEvent: Sendable, Equatable {
        case legStarted(Int)
        case textDelta(String)
        case reasoningDelta(String)
        case usage(ToolLoopUsage)
        case toolCallsAccepted([ToolLoopToolCall])
    }

    struct LegRecord: Sendable, Equatable {
        var legIndex: Int
        var assistantMessage: ToolLoopMessage
        var toolResultMessages: [ToolLoopMessage]
    }

    struct Result: Sendable, Equatable {
        var text: String
        var legTexts: [String]
        var usage: ToolLoopUsage?
        var endedWithoutToolCall: Bool
        var stepLimitReached: Bool
        var receivedStructuredToolCalls: Bool
        var executedToolSteps: Int
    }

    typealias ProgressHandler = @Sendable (ProgressEvent) async -> Void
    typealias UnhandledHandler = @Sendable ([ProviderToolCall]) async -> Void
    typealias LegCompletedHandler = @Sendable (LegRecord) async throws -> Void

    let registry: ToolRegistry
    let legRunner: any ToolLoopLegRunning
    let adapter: any ToolProtocolAdapter
    let limits: Limits
    let prompts: Prompts
    let onUnhandledToolCalls: UnhandledHandler
    let onLegCompleted: LegCompletedHandler?
    let includesReasoningInAssistantMessage: Bool

    init(
        registry: ToolRegistry,
        legRunner: any ToolLoopLegRunning,
        adapter: any ToolProtocolAdapter = OpenAIChatToolAdapter(),
        limits: Limits,
        prompts: Prompts = Prompts(),
        includesReasoningInAssistantMessage: Bool = false,
        onUnhandledToolCalls: @escaping UnhandledHandler = { _ in },
        onLegCompleted: LegCompletedHandler? = nil
    ) {
        self.registry = registry
        self.legRunner = legRunner
        self.adapter = adapter
        self.limits = limits
        self.prompts = prompts
        self.includesReasoningInAssistantMessage = includesReasoningInAssistantMessage
        self.onUnhandledToolCalls = onUnhandledToolCalls
        self.onLegCompleted = onLegCompleted
    }

    func run(
        messages initialMessages: [ToolLoopMessage],
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> Result {
        let tools = registry.definitions
        var history = initialMessages
        var usage: ToolLoopUsage?
        var legTexts: [String] = []
        var selfCorrections = 0
        var consecutiveToolFailures = 0
        var executedToolSteps = 0
        var receivedStructuredToolCalls = false
        var forceSynthesis = false
        var stepLimitReached = false

        for legIndex in 0..<limits.maxSteps {
            try Task.checkCancellation()
            await onProgress(.legStarted(legIndex))
            let leg = try await consumeLeg(
                request: ToolLoopLegRequest(messages: history, tools: tools, toolChoice: .auto),
                legIndex: legIndex,
                receivedStructuredToolCalls: receivedStructuredToolCalls,
                onProgress: onProgress
            )
            legTexts.append(leg.text)
            usage = ToolLoopUsage.merge(usage, leg.usage)
            if let usage { await onProgress(.usage(usage)) }

            if leg.toolCalls.isEmpty {
                return Result(
                    text: leg.text, legTexts: legTexts, usage: usage,
                    endedWithoutToolCall: legIndex == 0,
                    stepLimitReached: false,
                    receivedStructuredToolCalls: receivedStructuredToolCalls,
                    executedToolSteps: executedToolSteps
                )
            }
            receivedStructuredToolCalls = true

            let (typedCalls, accepted, unhandled) = partition(leg.toolCalls)
            if !unhandled.isEmpty {
                await onUnhandledToolCalls(unhandled.map {
                    ProviderToolCall(providerCallID: $0.id, name: $0.function.name, rawArguments: $0.function.arguments)
                })
            }
            if accepted.isEmpty {
                return Result(
                    text: leg.text, legTexts: legTexts, usage: usage,
                    endedWithoutToolCall: legIndex == 0,
                    stepLimitReached: false,
                    receivedStructuredToolCalls: true,
                    executedToolSteps: executedToolSteps
                )
            }
            await onProgress(.toolCallsAccepted(accepted))

            let assistantMessage = adapter.encodeAssistantToolCalls(
                text: leg.text,
                reasoning: includesReasoningInAssistantMessage ? leg.reasoning : nil,
                toolCalls: typedCalls,
                replayBlocks: leg.replayBlocks,
                assistantReplay: leg.assistantReplay
            )
            history.append(assistantMessage)
            var resultsByCallID: [String: ToolLoopMessage] = [:]
            var trailingSystemMessages: [ToolLoopMessage] = []
            func feed(_ message: ToolLoopMessage) {
                if let id = message.toolCallID { resultsByCallID[id] = message }
            }
            func appendSystem(_ content: String) {
                trailingSystemMessages.append(ToolLoopMessage(role: "system", content: content))
            }
            func commitLeg() async throws {
                let ordered = typedCalls.compactMap { resultsByCallID[$0.id] }
                history.append(contentsOf: ordered)
                history.append(contentsOf: trailingSystemMessages)
                try await onLegCompleted?(LegRecord(legIndex: legIndex, assistantMessage: assistantMessage, toolResultMessages: ordered))
            }
            for call in unhandled {
                feed(adapter.encodeToolResult(
                    callID: call.id, toolName: call.function.name,
                    content: Self.errorContent(code: "unknown_tool", message: "Unsupported tool: \(call.function.name)")
                ))
            }

            if let tokenBudget = limits.tokenBudget, (usage?.resolvedTotalTokens ?? 0) >= tokenBudget {
                for call in accepted {
                    feed(adapter.encodeToolResult(
                        callID: call.id, toolName: call.function.name,
                        content: Self.errorContent(code: "research_stopped", message: prompts.stoppedByTokenBudget)
                    ))
                }
                appendSystem(prompts.tokenBudgetReached)
                forceSynthesis = true
                try await commitLeg()
                break
            }

            toolCallsLoop: for (callIndex, call) in accepted.enumerated() {
                guard let entry = registry.entry(named: call.function.name) else { continue }
                let stepNumber = executedToolSteps + 1
                let context = ToolExecutionContext(callID: call.id, stepNumber: stepNumber, legIndex: legIndex)
                do {
                    let outcome = try await entry.execute(call, context: context)
                    executedToolSteps = stepNumber
                    consecutiveToolFailures = 0
                    feed(adapter.encodeToolResult(callID: call.id, toolName: call.function.name, content: outcome.content))
                    if let stopReason = outcome.stopReason {
                        appendSystem(stopReason)
                        for skipped in accepted.dropFirst(callIndex + 1) {
                            feed(adapter.encodeToolResult(
                                callID: skipped.id, toolName: skipped.function.name,
                                content: Self.errorContent(code: "research_stopped", message: stopReason)
                            ))
                        }
                        forceSynthesis = true
                        break toolCallsLoop
                    }
                } catch let rejection as ToolCallRejection {
                    selfCorrections += 1
                    feed(adapter.encodeToolResult(
                        callID: call.id, toolName: call.function.name,
                        content: Self.errorContent(code: rejection.code, message: rejection.message)
                    ))
                    if selfCorrections > limits.maxSelfCorrections { throw rejection }
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    switch entry.failureDisposition(for: error) {
                    case .fatal:
                        throw error
                    case let .degrade(code, message):
                        executedToolSteps = stepNumber
                        consecutiveToolFailures += 1
                        feed(adapter.encodeToolResult(
                            callID: call.id, toolName: call.function.name,
                            content: Self.errorContent(code: code, message: message)
                        ))
                        if consecutiveToolFailures >= limits.maxConsecutiveToolFailures { throw error }
                    }
                }

                if executedToolSteps >= limits.maxSteps {
                    for skipped in accepted.dropFirst(callIndex + 1) {
                        feed(adapter.encodeToolResult(
                            callID: skipped.id, toolName: skipped.function.name,
                            content: Self.errorContent(code: "research_stopped", message: prompts.stoppedByStepLimit)
                        ))
                    }
                    appendSystem(prompts.stepLimitReached)
                    forceSynthesis = true
                    stepLimitReached = true
                    break toolCallsLoop
                }
            }
            try await commitLeg()
            if forceSynthesis { break }
        }

        if !forceSynthesis {
            history.append(ToolLoopMessage(role: "system", content: prompts.stepLimitReached))
            stepLimitReached = true
        }
        let finalIndex = max(0, limits.maxSteps)
        await onProgress(.legStarted(finalIndex))
        let finalLeg = try await consumeLeg(
            request: ToolLoopLegRequest(messages: history, tools: tools, toolChoice: .none),
            legIndex: finalIndex,
            receivedStructuredToolCalls: receivedStructuredToolCalls,
            onProgress: onProgress
        )
        legTexts.append(finalLeg.text)
        usage = ToolLoopUsage.merge(usage, finalLeg.usage)
        if let usage { await onProgress(.usage(usage)) }
        if !finalLeg.toolCalls.isEmpty {
            await onUnhandledToolCalls(finalLeg.toolCalls.map {
                ProviderToolCall(providerCallID: $0.id, name: $0.function.name, rawArguments: $0.function.arguments)
            })
        }
        return Result(
            text: finalLeg.text, legTexts: legTexts, usage: usage,
            endedWithoutToolCall: false,
            stepLimitReached: stepLimitReached,
            receivedStructuredToolCalls: receivedStructuredToolCalls,
            executedToolSteps: executedToolSteps
        )
    }
}

nonisolated extension ToolCallLoop {
    struct ConsumedLeg: Sendable, Equatable {
        var text: String
        var reasoning: String
        var toolCalls: [ToolLoopToolCall]
        var usage: ToolLoopUsage?
        var replayBlocks: [ToolJSONValue] = []
        var assistantReplay: ToolJSONValue?
    }

    private func partition(
        _ calls: [ToolLoopToolCall]
    ) -> (typed: [ToolLoopToolCall], accepted: [ToolLoopToolCall], unhandled: [ToolLoopToolCall]) {
        var typed: [ToolLoopToolCall] = []
        var accepted: [ToolLoopToolCall] = []
        var unhandled: [ToolLoopToolCall] = []
        for var call in calls {
            if let entry = registry.entry(named: call.function.name) {
                call.type = entry.wireType
                accepted.append(call)
            } else {
                unhandled.append(call)
            }
            typed.append(call)
        }
        return (typed, accepted, unhandled)
    }

    func consumeLeg(
        request: ToolLoopLegRequest,
        legIndex: Int,
        receivedStructuredToolCalls: Bool = false,
        onProgress: @escaping ProgressHandler
    ) async throws -> ConsumedLeg {
        var text = ""
        var reasoning = ""
        var usage: ToolLoopUsage?
        var replayBlocks: [ToolJSONValue] = []
        var assistantReplay: ToolJSONValue?
        var accumulated: [Int: ToolLoopToolCallDelta] = [:]
        func consume(_ event: ToolLoopLegEvent) async {
            switch event {
            case let .textDelta(delta):
                text += delta
                await onProgress(.textDelta(delta))
            case let .reasoningDelta(delta):
                reasoning += delta
                await onProgress(.reasoningDelta(delta))
            case let .toolCallDeltas(deltas):
                Self.mergeToolCallDeltas(&accumulated, deltas: deltas)
            case let .usage(value):
                usage = value
            case let .providerReplayBlocks(blocks):
                replayBlocks.append(contentsOf: blocks)
            case let .providerAssistantReplay(value):
                assistantReplay = value
            }
        }
        do {
            for try await event in legRunner.run(request: request) {
                try Task.checkCancellation()
                await consume(event)
            }
        } catch var rejected as ToolsRejectedByUpstreamError {
            rejected.legIndex = legIndex
            rejected.receivedStructuredToolCalls = receivedStructuredToolCalls
            throw rejected
        } catch let error where ToolUnsupportedErrorMatcher.matches(error) {
            guard case let ProviderServiceError.upstream(statusCode, _) = error,
                  let mapped = error as? ProviderServiceError else { throw error }
            throw ToolsRejectedByUpstreamError(
                statusCode: statusCode, underlying: mapped,
                legIndex: legIndex, receivedStructuredToolCalls: receivedStructuredToolCalls
            )
        }
        return ConsumedLeg(
            text: text,
            reasoning: reasoning,
            toolCalls: Self.finalizeToolCalls(accumulated, legIndex: legIndex),
            usage: usage,
            replayBlocks: replayBlocks,
            assistantReplay: assistantReplay
        )
    }

    static func mergeToolCallDeltas(
        _ target: inout [Int: ToolLoopToolCallDelta],
        deltas: [ToolLoopToolCallDelta]
    ) {
        for delta in deltas {
            let previous = target[delta.index]
            target[delta.index] = ToolLoopToolCallDelta(
                index: delta.index,
                id: delta.id ?? previous?.id,
                type: delta.type ?? previous?.type,
                name: previous?.name ?? delta.name,
                arguments: (previous?.arguments ?? "") + (delta.arguments ?? ""),
                providerSignature: delta.providerSignature ?? previous?.providerSignature
            )
        }
    }

    static let fallbackCallIDPrefix = "tool_call_"

    static func finalizeToolCalls(
        _ target: [Int: ToolLoopToolCallDelta],
        legIndex: Int
    ) -> [ToolLoopToolCall] {
        target.sorted { $0.key < $1.key }.enumerated().map { offset, entry in
            let call = entry.value
            let providedID = call.id.flatMap { id in
                id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : id
            }
            return ToolLoopToolCall(
                id: providedID ?? "\(fallbackCallIDPrefix)\(legIndex + 1)_\(offset + 1)",
                function: .init(name: call.name ?? "", arguments: call.arguments ?? ""),
                providerSignature: call.providerSignature
            )
        }
    }

    static func errorContent(code: String, message: String) -> String {
        jsonContent(["ok": false, "error": ["code": code, "message": message]])
    }

    static func jsonContent(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
    }
}
