import Foundation

// MARK: - Wiring remote MCP tools into the generic tool loop
//
// This layer turns "the servers enabled for this conversation" into registry entries for the generic loop: it
// assembles the usable tools, produces the names sent to the model along with the lookup table, runs the
// confirmation gate, makes the call and feeds the result back.
// UI (the confirmation sheet, the step block) does not live here: the confirmation gate is an injectable
// protocol, and step changes are handed out through a callback.

// MARK: - Confirmation gate

/// What the user picked on the confirmation sheet.
nonisolated enum McpConfirmationChoice: String, Sendable, Equatable {
    /// Allow once.
    case once
    /// Allow for the rest of this conversation (same tool on the same server only, kept in memory only).
    case conversation
    /// Deny: no `tools/call` is sent and `user_denied` is fed back.
    case deny
}

/// What the confirmation sheet shows. The arguments are the raw top-level object from the model (keys verbatim);
/// the sheet itself takes the first 4 and clamps each to two lines.
nonisolated struct McpConfirmationRequest: Sendable, Equatable {
    var conversationId: UUID
    var serverId: UUID
    var serverName: String
    /// Host name of the server address (for display; the full address of a localOnly server never appears here).
    var serverHost: String
    var toolName: String
    var toolTitle: String
    var arguments: JSONValue
    var inputSchema: JSONValue
    /// The tool does not declare itself read-only (anything undeclared is treated as modifying data). The sheet
    /// uses this to decide whether to say "this will change your content".
    var changesData: Bool = true
}

/// The confirmation gate: a suspension point in the loop whose waiting time does not count toward the call
/// timeout. Several tools needing confirmation in one leg are executed serially by the loop, so they are asked
/// one at a time, in proposal order. When the user taps Stop the implementation should throw `CancellationError`.
nonisolated protocol McpConfirmationGate: Sendable {
    func requestConfirmation(_ request: McpConfirmationRequest) async throws -> McpConfirmationChoice
}

/// The gate used when there is no UI to ask: it always denies (fail closed).
nonisolated struct McpDenyingConfirmationGate: McpConfirmationGate {
    func requestConfirmation(_ request: McpConfirmationRequest) async throws -> McpConfirmationChoice { .deny }
}

// MARK: - Authorization expiring mid-run

/// What is handed to the UI when a step in the loop hits "sign in again".
nonisolated struct McpReauthorizationRequest: Sendable, Equatable {
    var conversationId: UUID
    var serverId: UUID
    var serverName: String
    /// The step that stopped here (its `toolSteps` id): the UI hangs the two buttons under this row.
    var stepId: String
}

nonisolated enum McpReauthorizationChoice: String, Sendable, Equatable {
    /// The user signed in again; carry on from this step.
    case reauthorized
    /// Skip this step (`auth_skipped` is fed back).
    case skip
}

/// The reauthorization gate: the loop stops at the step and waits for the user to sign in again or skip, and
/// the wait does not count toward the call timeout. Signing in again (opening the browser) is a UI flow and is
/// not done inside the loop. Without a gate the loop does not pause and the step degrades with `needs_auth`.
/// When the user taps Stop the implementation should throw `CancellationError`.
nonisolated protocol McpReauthorizationGate: Sendable {
    func requestReauthorization(_ request: McpReauthorizationRequest) async throws -> McpReauthorizationChoice
}

/// "Allow for this conversation": remembered in memory only, keyed by conversation + server + original tool
/// name, and gone once the app restarts.
nonisolated final class McpConversationGrants: @unchecked Sendable {
    static let shared = McpConversationGrants()

    private struct Key: Hashable {
        var conversationId: UUID
        var serverId: UUID
        var toolName: String
    }

    private let lock = NSLock()
    private var granted: Set<Key> = []

    func grant(conversationId: UUID, serverId: UUID, toolName: String) {
        lock.withLock { _ = granted.insert(Key(conversationId: conversationId, serverId: serverId, toolName: toolName)) }
    }

    func isGranted(conversationId: UUID, serverId: UUID, toolName: String) -> Bool {
        lock.withLock { granted.contains(Key(conversationId: conversationId, serverId: serverId, toolName: toolName)) }
    }

    func revokeAll() {
        lock.withLock { granted.removeAll() }
    }

    /// Revokes a server's "allow for this conversation" grants in every conversation (optionally only for some of
    /// its tools). After a permission is edited, a tool definition changes or is confirmed, or the server is
    /// removed, an earlier tap must not keep working across that change.
    func revoke(serverId: UUID, toolNames: Set<String>? = nil) {
        lock.withLock {
            granted = granted.filter { key in
                guard key.serverId == serverId else { return true }
                if let toolNames { return !toolNames.contains(key.toolName) }
                return false
            }
        }
    }
}

// MARK: - Assembly

/// The input for one enabled server in this request, read from local storage by
/// `McpToolBridge.plan(conversationId:...)`.
nonisolated struct McpBridgeServerInput: Sendable {
    var record: McpServerRecord
    var endpoint: McpServerEndpointResolution
    var connectionStatus: McpConnectionStatus?
    var snapshots: [McpToolSnapshot]
    var permissions: [String: McpToolPermission]
}

/// One entry of the lookup table: the name sent to the model -> the server and the original tool name.
nonisolated struct McpToolBinding: Sendable, Equatable {
    var outboundName: String
    var serverId: UUID
    var toolName: String
}

/// One usable MCP tool in this request.
nonisolated struct McpPlannedTool: Sendable {
    var binding: McpToolBinding
    var server: McpServerRecord
    /// The full address requests go to (the result of `McpServerEndpoint.resolve`; for localOnly servers it comes
    /// from the credential store).
    var endpoint: URL
    var snapshot: McpToolSnapshot
    /// Only ever `auto` or `ask`: `off` is excluded during assembly.
    var permission: McpToolPermission
    var definition: ToolLoopToolDefinition
}

/// The MCP tools and lookup table for this request. Empty means the request carries no MCP tools.
nonisolated struct McpToolPlan: Sendable {
    var tools: [McpPlannedTool]
    /// More tools were usable than `maxToolsPerRequest`; the tail was cut off in server-enable order.
    var truncated: Bool

    static let empty = McpToolPlan(tools: [], truncated: false)

    var isEmpty: Bool { tools.isEmpty }

    /// The lookup table. A name coming back from the model is resolved here and nowhere else; a miss means the
    /// call does not match the registry.
    var nameTable: [String: McpToolBinding] {
        Dictionary(tools.map { ($0.binding.outboundName, $0.binding) }, uniquingKeysWith: { first, _ in first })
    }
}

nonisolated enum McpToolBridge {
    /// Error code for calls that were skipped once the loop stopped.
    static let stoppedErrorCode = "tool_loop_stopped"

    /// Whether this connection and model can carry MCP tools: the same check as the outbound tool gate.
    static func connectionSupportsTools(provider: Provider, model: AIModel, memory: ToolCallMemoryStore) -> Bool {
        ToolCallCapabilityPolicy.permitsToolsOutbound(provider: provider, model: model, memory: memory)
    }

    /// Assembles the tools usable right now: the enabled servers (in the order they were enabled) that have a
    /// usable connection, minus tools that are set to "off", quarantined or oversized; truncated past
    /// `maxToolsPerRequest`.
    ///
    /// A whole server is excluded in two cases: it needs a new sign-in (`needsAuth`), or the full address of a
    /// localOnly server is not on this device (`needsAddress`). In the latter case a request is never sent to the
    /// display address stored in the database.
    static func plan(servers: [McpBridgeServerInput], runtimeConfig: McpRuntimeConfig) -> McpToolPlan {
        guard runtimeConfig.enabled else { return .empty }
        var tools: [McpPlannedTool] = []
        var taken = Set<String>()
        var truncated = false
        serverLoop: for server in servers {
            guard case .ready(let endpoint) = server.endpoint, server.connectionStatus != .needsAuth else { continue }
            let outbound = McpToolCatalog.outboundSnapshots(
                server.snapshots, permissions: server.permissions, runtimeConfig: runtimeConfig
            )
            let names = outbound.map(\.toolName)
            for snapshot in outbound {
                let others = names.filter { $0 != snapshot.toolName }
                let name = McpToolNaming.outboundName(
                    slug: server.record.slug,
                    serverId: server.record.id.uuidString,
                    toolName: snapshot.toolName,
                    collidesWith: others
                ).name
                // Slugs are unique across servers, so this should not collide. If it does, only the first-enabled tool
                // is kept: one name must never point at two places.
                guard taken.insert(name).inserted else { continue }
                if tools.count >= runtimeConfig.maxToolsPerRequest {
                    truncated = true
                    break serverLoop
                }
                let permission = server.permissions[snapshot.toolName]
                    ?? McpToolPermission.defaultFor(readOnly: snapshot.readOnly)
                tools.append(McpPlannedTool(
                    binding: McpToolBinding(outboundName: name, serverId: server.record.id, toolName: snapshot.toolName),
                    server: server.record,
                    endpoint: endpoint,
                    snapshot: snapshot,
                    permission: permission,
                    definition: ToolLoopToolDefinition(function: .init(
                        name: name,
                        // The description is sent verbatim, with nothing of ours prepended.
                        description: snapshot.description ?? "",
                        parameters: toolJSON(snapshot.inputSchema)
                    ))
                ))
            }
        }
        return McpToolPlan(tools: tools, truncated: truncated)
    }

    /// Reads the servers enabled for this conversation from local storage and assembles them (switches are per
    /// conversation and stored on this device only). Empty when the conversation has no server enabled.
    static func plan(
        conversationId: UUID,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String,
        runtimeConfig: McpRuntimeConfig
    ) throws -> McpToolPlan {
        let enabled = try store.fetchEnabledServerIds(conversationId: conversationId)
        guard !enabled.isEmpty, runtimeConfig.enabled else { return .empty }
        var inputs: [McpBridgeServerInput] = []
        for serverId in enabled {
            guard let record = try store.fetchServer(id: serverId) else { continue }
            inputs.append(McpBridgeServerInput(
                record: record,
                endpoint: McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore),
                connectionStatus: try store.fetchConnectionState(serverId: serverId)?.status,
                snapshots: try store.fetchToolSnapshots(serverId: serverId),
                permissions: try store.fetchToolPermissions(serverId: serverId)
            ))
        }
        return plan(servers: inputs, runtimeConfig: runtimeConfig)
    }

    /// Re-reads local state before executing. The assembled plan is only a snapshot from the moment the request was
    /// sent: one answer can run for a long time, and meanwhile the user may have changed a permission or removed
    /// the server, or a new sign-in may have changed a tool definition and quarantined it. All of that must take
    /// effect before the next `tools/call`. State that cannot be read counts as unavailable.
    static func liveState(
        of tool: McpPlannedTool,
        store: McpServerStore,
        credentialStore: McpCredentialStore,
        uid: String,
        runtimeConfig: McpRuntimeConfig
    ) -> McpLiveToolState {
        let toolName = tool.snapshot.toolName
        guard runtimeConfig.enabled,
              let record = try? store.fetchServer(id: tool.server.id),
              case .ready(let endpoint) = McpServerEndpoint.resolve(record, uid: uid, credentialStore: credentialStore),
              let snapshot = (try? store.fetchToolSnapshots(serverId: record.id))?.first(where: { $0.toolName == toolName }),
              !snapshot.pendingReview,
              !McpToolCatalog.isOversized(snapshot, runtimeConfig: runtimeConfig),
              // The model holds the definition from assembly time; if the stored one is no longer the same, the tool
              // must not be called under the old definition.
              snapshot.contentHash == tool.snapshot.contentHash,
              snapshot.title == tool.snapshot.title,
              let permissions = try? store.fetchToolPermissions(serverId: record.id)
        else { return .unavailable }
        let permission = permissions[toolName] ?? McpToolPermission.defaultFor(readOnly: snapshot.readOnly)
        guard permission != .off else { return .unavailable }
        return .usable(permission: permission, endpoint: endpoint)
    }

    /// Registry entries (registration order = the order sent to the model).
    static func entries(for plan: McpToolPlan, executor: McpToolExecutor) -> [any ToolRegistryEntry] {
        plan.tools.map { McpToolEntry(tool: $0, executor: executor) }
    }

    /// The loop used when only MCP is enabled (production and tests build it here).
    static func makeLoop(
        plan: McpToolPlan,
        executor: McpToolExecutor,
        legRunner: any ToolLoopLegRunning,
        adapter: any ToolProtocolAdapter,
        runtimeConfig: McpRuntimeConfig,
        onUnhandledToolCalls: @escaping ToolCallLoop.UnhandledHandler
    ) -> ToolCallLoop {
        ToolCallLoop(
            registry: ToolRegistry(entries: entries(for: plan, executor: executor)),
            legRunner: legRunner,
            adapter: adapter,
            limits: limits(runtimeConfig: runtimeConfig),
            prompts: prompts,
            onUnhandledToolCalls: onUnhandledToolCalls
        )
    }

    /// Messages for the first leg: the system prompt (the user's plus the safety prompt) first, then the
    /// conversation history.
    static func initialMessages(history: [ToolLoopMessage], systemPrompt: String) -> [ToolLoopMessage] {
        [ToolLoopMessage(role: "system", content: Self.systemPrompt(appendingTo: systemPrompt))] + history
    }

    /// The fixed text appended to the system prompt when MCP tools are enabled (shared fixture `safety-prompt.txt`).
    static func systemPrompt(appendingTo base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? McpSafetyPrompt.text : trimmed + "\n\n" + McpSafetyPrompt.text
    }

    /// Loop limits when MCP tools are attached. The consecutive-failure breaker is switched off: one failing
    /// third-party server should not blow up the whole answer, and the only thing that aborts the whole run is the
    /// user tapping Stop. The step count is still bounded by `maxSteps`, so errors are not fed back forever.
    static func limits(runtimeConfig: McpRuntimeConfig) -> ToolCallLoop.Limits {
        ToolCallLoop.Limits(
            maxSteps: ToolCallLoop.Limits.effectiveMaxSteps(serverValue: runtimeConfig.effectiveMaxSteps),
            maxConsecutiveToolFailures: Int.max
        )
    }

    /// The fixed phrases the loop feeds back to the model. Tool results are not citable sources, so nothing
    /// here asks the model to cite them.
    static var prompts: ToolCallLoop.Prompts {
        var prompts = ToolCallLoop.Prompts()
        prompts.stepLimitReached = "The tool call limit was reached. Answer now from the tool results you already have. Do not call another tool."
        prompts.tokenBudgetReached = "The token budget for tool use was reached. Answer now from the tool results you already have. Do not call another tool."
        prompts.stoppedByStepLimit = "The tool call limit was reached."
        prompts.stoppedByTokenBudget = "The token budget for tool use was reached."
        prompts.stoppedErrorCode = stoppedErrorCode
        return prompts
    }

    /// MCP's order-preserving `JSONValue` -> the loop's `ToolJSONValue`.
    static func toolJSON(_ value: JSONValue) -> ToolJSONValue {
        switch value {
        case .object(let object):
            var dict: [String: ToolJSONValue] = [:]
            for key in object.keys { if let child = object[key] { dict[key] = toolJSON(child) } }
            return .object(dict)
        case .array(let array): return .array(array.map(toolJSON))
        case .string(let string): return .string(string)
        case .number(let number): return .number(number)
        case .bool(let bool): return .bool(bool)
        case .null: return .null
        }
    }
}

// MARK: - Execution

/// A call that did not succeed. `code` comes from a closed set; the model only ever gets that code and one
/// fixed sentence, never the server's own text.
nonisolated struct McpToolFailure: Error, Sendable, Equatable {
    var code: McpErrorCode
}

/// A state change of one step (the fields of `toolSteps`). `McpToolStep(update:)` takes the summary that is
/// stored with the message. `payload` does not go into the message: it has its own table.
nonisolated struct McpToolStepUpdate: Sendable, Equatable {
    enum Status: String, Sendable, Equatable, Codable {
        case running
        case done
        case failed
        case denied
        case needsAuth
        case interrupted
    }

    var id: String
    var serverId: UUID
    var serverName: String
    var toolName: String
    var title: String
    var argsSummary: String
    var status: Status
    var errorCode: McpErrorCode?
    var step: Int
    var durationMs: Int?
    /// The raw arguments arrive with the first callback, the result or failure text with the terminal state.
    var payload: McpToolStepPayload?
}

/// A step payload: the raw arguments and the start of the result. **Never part of the message.**
nonisolated struct McpToolStepPayload: Sendable, Equatable {
    /// The raw arguments from the model (canonical JSON). The storage layer truncates them to 16 KB.
    var arguments: String?
    /// The start of the result (the storage layer truncates it to 2 KB); on failure it is the error text from the
    /// server, truncated to 200 characters.
    var resultPrefix: String?

    static let maxFailureTextLength = 200
}

/// The MCP executor for one answer: it owns this run's clients (one connection per server), the confirmation
/// gate and the in-memory grants.
actor McpToolExecutor {
    typealias TokenProvider = @Sendable (UUID) async throws -> String?
    typealias StepHandler = @Sendable (McpToolStepUpdate) async -> Void
    typealias LiveStateProvider = @Sendable (McpPlannedTool) async -> McpLiveToolState

    private let conversationId: UUID
    private let runtimeConfig: McpRuntimeConfig
    private let gate: any McpConfirmationGate
    private let reauthGate: (any McpReauthorizationGate)?
    private let grants: McpConversationGrants
    private let tokenProvider: TokenProvider
    private let liveState: LiveStateProvider
    private let makeClient: @Sendable (URL) -> McpClient
    private let onStep: StepHandler
    private var clients: [UUID: (endpoint: URL, client: McpClient)] = [:]

    init(
        conversationId: UUID,
        runtimeConfig: McpRuntimeConfig = .fallback,
        gate: any McpConfirmationGate,
        reauthGate: (any McpReauthorizationGate)? = nil,
        grants: McpConversationGrants = .shared,
        tokenProvider: @escaping TokenProvider,
        liveState: @escaping LiveStateProvider,
        makeClient: (@Sendable (URL) -> McpClient)? = nil,
        onStep: @escaping StepHandler = { _ in }
    ) {
        self.conversationId = conversationId
        self.runtimeConfig = runtimeConfig
        self.gate = gate
        self.reauthGate = reauthGate
        self.grants = grants
        self.tokenProvider = tokenProvider
        self.liveState = liveState
        self.makeClient = makeClient ?? { McpClient(endpoint: $0, runtimeConfig: runtimeConfig) }
        self.onStep = onStep
    }

    func execute(
        _ tool: McpPlannedTool,
        call: ToolLoopToolCall,
        context: ToolExecutionContext
    ) async throws -> ToolExecutionOutcome {
        let arguments = try Self.validatedArguments(call.function.arguments, schema: tool.snapshot.inputSchema)
        var step = McpToolStepUpdate(
            id: "\(context.stepNumber):\(call.id)",
            serverId: tool.server.id,
            serverName: tool.server.name,
            toolName: tool.snapshot.toolName,
            title: tool.snapshot.title,
            argsSummary: McpArgsSummary.summary(inputSchema: tool.snapshot.inputSchema, arguments: arguments),
            status: .running,
            step: context.stepNumber,
            payload: McpToolStepPayload(arguments: arguments.canonicalJSONString, resultPrefix: nil)
        )

        // The step is `running` from the moment it is proposed: while waiting for the user to confirm, the step block
        // and the activity line are both shown (the app is waiting for a person, it is not idle).
        // The raw arguments are handed out with this first callback only.
        await onStep(step)
        step.payload = nil

        // Once the user has tapped "Allow" for this call, resuming the same step does not ask a second time.
        var confirmed = false
        var endpoint = tool.endpoint
        // When authorization has expired the loop parks at this step and waits for the user: after signing in again
        // it carries on from this step, and a skip feeds back `auth_skipped`.
        // Needing a new sign-in means this tools/call was not executed, so sending it again after the user signs in
        // does not repeat a call that already ran.
        while true {
            // Re-read local state before every request: since assembly, or while waiting for a confirmation or a new
            // sign-in, the permission, the quarantine flag and the tool definition may all have changed.
            guard case .usable(let permission, let liveEndpoint) = await liveState(tool) else {
                throw await unavailable(&step)
            }
            endpoint = liveEndpoint
            // With "ask every time", no tools/call is sent without the user's approval.
            if permission != .auto, !confirmed,
               !grants.isGranted(conversationId: conversationId, serverId: tool.server.id, toolName: tool.snapshot.toolName) {
                if let denied = try await confirm(tool, arguments: arguments, endpoint: endpoint, step: &step) {
                    return denied
                }
                confirmed = true
                // State can change while the sheet is open too: go round and read it again, and send only if still usable.
                continue
            }
            do {
                return try await callOnce(tool, endpoint: endpoint, arguments: arguments, step: &step)
            } catch let failure as McpToolFailure where failure.code == .needsAuth {
                guard let reauthGate else { throw failure }
                let choice: McpReauthorizationChoice
                do {
                    choice = try await reauthGate.requestReauthorization(McpReauthorizationRequest(
                        conversationId: conversationId,
                        serverId: tool.server.id,
                        serverName: tool.server.name,
                        stepId: step.id
                    ))
                    try Task.checkCancellation()
                } catch {
                    // The user tapped Stop while waiting for the new sign-in.
                    step.status = .interrupted
                    step.errorCode = .cancelled
                    await onStep(step)
                    throw error
                }
                guard choice == .reauthorized else {
                    step.errorCode = .authSkipped
                    await onStep(step)
                    throw McpToolFailure(code: .authSkipped)
                }
                // The old connection carries the expired token: drop it so the next attempt fetches a token and reconnects.
                clients[tool.server.id] = nil
                step.status = .running
                step.errorCode = nil
                step.durationMs = nil
                await onStep(step)
            }
        }
    }

    /// The tool cannot be called right now: no request is sent, the step is marked failed and `tool_unavailable`
    /// is fed back.
    private func unavailable(_ step: inout McpToolStepUpdate) async -> McpToolFailure {
        step.status = .failed
        step.errorCode = .toolUnavailable
        step.durationMs = nil
        await onStep(step)
        return McpToolFailure(code: .toolUnavailable)
    }

    /// Runs the confirmation gate. A non-nil return means the user denied, and it is fed back as this step's
    /// result; `nil` means allowed.
    private func confirm(
        _ tool: McpPlannedTool,
        arguments: JSONValue,
        endpoint: URL,
        step: inout McpToolStepUpdate
    ) async throws -> ToolExecutionOutcome? {
        let choice: McpConfirmationChoice
        do {
            choice = try await gate.requestConfirmation(McpConfirmationRequest(
                conversationId: conversationId,
                serverId: tool.server.id,
                serverName: tool.server.name,
                serverHost: endpoint.host ?? "",
                toolName: tool.snapshot.toolName,
                toolTitle: tool.snapshot.title,
                arguments: arguments,
                inputSchema: tool.snapshot.inputSchema,
                changesData: !tool.snapshot.readOnly
            ))
            try Task.checkCancellation()
        } catch {
            // The user tapped Stop while waiting for confirmation: the step did not run, so it is marked interrupted.
            step.status = .interrupted
            step.errorCode = .cancelled
            await onStep(step)
            throw error
        }
        switch choice {
        case .deny:
            step.status = .denied
            step.errorCode = .userDenied
            await onStep(step)
            // A denial is not a server failure: it is fed back as a normal result and does not advance the
            // consecutive-failure counter.
            return ToolExecutionOutcome(content: ToolCallLoop.errorContent(
                code: McpErrorCode.userDenied.rawValue,
                message: "The user declined this tool call. Do not call it again for this request; continue without it."
            ))
        case .conversation:
            grants.grant(conversationId: conversationId, serverId: tool.server.id, toolName: tool.snapshot.toolName)
            return nil
        case .once:
            return nil
        }
    }

    /// Connects and calls once; terminal states (done / failed / needsAuth / interrupted) are emitted here.
    private func callOnce(
        _ tool: McpPlannedTool,
        endpoint: URL,
        arguments: JSONValue,
        step: inout McpToolStepUpdate
    ) async throws -> ToolExecutionOutcome {
        let started = Date()
        do {
            let client = try await connectedClient(for: tool, endpoint: endpoint)
            let result: McpToolCallResult
            do {
                result = try await client.callTool(name: tool.snapshot.toolName, arguments: arguments)
            } catch let error as McpClientError {
                throw Self.failure(for: error)
            }
            step.durationMs = Self.elapsedMs(since: started)
            if let code = result.errorCode, code == .toolError || code == .needsInputUnsupported {
                // The failure text only goes into the local step payload, never into `toolSteps` or back to the model.
                let text = String(result.text.prefix(McpToolStepPayload.maxFailureTextLength))
                step.payload = text.isEmpty ? nil : McpToolStepPayload(arguments: nil, resultPrefix: text)
                throw McpToolFailure(code: code)
            }
            step.status = .done
            step.errorCode = result.errorCode
            step.payload = result.text.isEmpty ? nil : McpToolStepPayload(arguments: nil, resultPrefix: result.text)
            await onStep(step)
            step.payload = nil
            return ToolExecutionOutcome(content: ToolCallLoop.jsonContent([
                "ok": true,
                "result": result.text.isEmpty ? "The tool returned no content." : result.text,
            ]))
        } catch let failure as McpToolFailure {
            step.durationMs = step.durationMs ?? Self.elapsedMs(since: started)
            step.status = failure.code == .needsAuth ? .needsAuth : .failed
            step.errorCode = failure.code
            await onStep(step)
            step.payload = nil
            throw failure
        } catch {
            step.durationMs = Self.elapsedMs(since: started)
            step.status = .interrupted
            step.errorCode = .cancelled
            await onStep(step)
            throw error
        }
    }

    /// Each server is connected once per run; the token comes from the credential store. The address is the one
    /// re-read before executing: if it changed during this run (the address was re-entered) the old
    /// connection is no longer used.
    private func connectedClient(for tool: McpPlannedTool, endpoint: URL) async throws -> McpClient {
        if let cached = clients[tool.server.id], cached.endpoint == endpoint { return cached.client }
        clients[tool.server.id] = nil
        let token: String?
        do {
            token = try await tokenProvider(tool.server.id)
        } catch let error as McpAuthorizerError {
            throw McpToolFailure(code: error.isTransient ? .unreachable : .needsAuth)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw McpToolFailure(code: .unreachable)
        }
        let client = makeClient(endpoint)
        switch await client.connect(bearerToken: token) {
        case .connected:
            clients[tool.server.id] = (endpoint, client)
            return client
        case .needsAuth:
            throw McpToolFailure(code: .needsAuth)
        case .unreachable:
            try Task.checkCancellation()
            throw McpToolFailure(code: .unreachable)
        case .notMcp:
            throw McpToolFailure(code: .serverError)
        case .failed(let error):
            throw Self.failure(for: error)
        }
    }

    /// A cancellation is turned back into `CancellationError`, so the loop winds the whole run down as "the user
    /// tapped Stop" instead of feeding it back as a failed call.
    private static func failure(for error: McpClientError) -> Error {
        if error.code == .cancelled, Task.isCancelled { return CancellationError() }
        return McpToolFailure(code: error.code)
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(min(Date().timeIntervalSince(start) * 1_000, Double(Int32.max)).rounded())
    }

    /// The arguments must be a JSON object and include everything in `required`; otherwise the loop counts it as a
    /// model self-correction.
    static func validatedArguments(_ raw: String, schema: JSONValue) throws -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: JSONValue
        if trimmed.isEmpty {
            parsed = .object(JSONObject())
        } else if let value = try? JSONValue(parsing: trimmed) {
            parsed = value
        } else {
            throw ToolCallRejection(code: "invalid_arguments", message: "Tool arguments must be a JSON object.")
        }
        guard case .object(let object) = parsed else {
            throw ToolCallRejection(code: "invalid_arguments", message: "Tool arguments must be a JSON object.")
        }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            throw ToolCallRejection(
                code: "missing_required_arguments",
                message: "Missing required arguments: \(missing.joined(separator: ", "))."
            )
        }
        return parsed
    }
}

/// The state of one tool on this device right now (`McpToolBridge.liveState`).
nonisolated enum McpLiveToolState: Sendable, Equatable {
    /// Still callable. The permission and address are the current values, not the ones from assembly.
    case usable(permission: McpToolPermission, endpoint: URL)
    /// The record is gone, the tool is quarantined, set to "off" or oversized, its definition or title changed, or
    /// the full address is not on this device.
    case unavailable
}

/// One MCP tool = one registry entry.
nonisolated struct McpToolEntry: ToolRegistryEntry {
    let tool: McpPlannedTool
    let executor: McpToolExecutor

    var name: String { tool.binding.outboundName }
    var scope: ToolScope { .mcp }
    var definition: ToolLoopToolDefinition? { tool.definition }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        try await executor.execute(tool, call: call, context: context)
    }

    /// Always `.degrade`; only the user tapping Stop aborts the whole run.
    func failureDisposition(for error: any Error) -> ToolFailureDisposition {
        if error is CancellationError { return .fatal }
        let code = (error as? McpToolFailure)?.code ?? .serverError
        return .degrade(
            code: code.rawValue,
            message: "The tool call did not succeed. Do not invent its result; continue with what you have."
        )
    }
}

/// An authorizer used only for refreshing tokens needs no browser: actually opening one (signing in again) is a
/// UI flow and never happens inside the chat loop.
nonisolated struct McpNoBrowserSession: McpBrowserSession {
    func authorize(url: URL, callbackURLScheme: String) async throws -> URL {
        throw McpAuthorizerError.cancelled
    }
}
