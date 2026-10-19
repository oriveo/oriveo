import Foundation
import OriveoProviderKit

/// tool_choice for client tools (such as propose_memory) in a normal chat request.
/// `.none` is for "the tail leg after tool results are fed back": the tool definitions still go out with the request, but the model is forbidden from issuing another call.
nonisolated enum ClientToolChoice: String, Hashable, Sendable {
    case auto
    case none
}

/// `ChatRequestOptions` is Hashable; equality of tool definitions is already given by Equatable,
/// so the hash only takes type + function name (two equal definitions necessarily hash the same, which satisfies the Hashable contract).
extension ToolLoopToolDefinition: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(type)
        hasher.combine(function.name)
    }
}

/// Writes `ChatRequestOptions.clientTools` into the chat request body using this client's ToolAdapter projection.
///
/// - With no client tools it writes nothing: the request body is byte-for-byte identical to before.
/// - When the request body already has tools (server tools such as web search / image generation, function tools of the library leg) the existing ones are kept
///   and client tools are appended after them (same as Web / Android).
/// - The call site runs before generation parameters and the extra request body, so a user's extra request body can still override the tools / tool_choice written here.
nonisolated enum ClientToolsInjector {
    static func apply(
        to body: inout [String: Any],
        protocol transport: TransportKind,
        options: ChatRequestOptions
    ) throws {
        guard !options.clientTools.isEmpty,
              let adapter = ToolProtocolAdapters.adapter(for: transport.rawValue) else { return }
        let projected = try adapter.encodeTools(options.clientTools)
        var tools = body["tools"] as? [Any] ?? []
        tools.append(contentsOf: projected)
        body["tools"] = tools

        let choice = options.clientToolChoice
        switch transport {
        case .anthropicMessages:
            body["tool_choice"] = ["type": choice.rawValue]
        case .geminiGenerate:
            var toolConfig = body["toolConfig"] as? [String: Any] ?? [:]
            var callingConfig = toolConfig["functionCallingConfig"] as? [String: Any] ?? [:]
            callingConfig["mode"] = choice.rawValue.uppercased()
            toolConfig["functionCallingConfig"] = callingConfig
            body["toolConfig"] = toolConfig
        default:
            body["tool_choice"] = choice.rawValue
        }
    }

    /// Host memory tools (propose_memory / search_memory) are moved to the end of tools: relay web-search snippets are merged in only
    /// after `apply`, and the memory tools must come after the snippets (web search and other server tools). Only host memory tools move;
    /// the relative order of MCP / library tools and snippets is unchanged; Gemini's functionDeclarations group moves as a whole only if it consists entirely of host memory tools.
    static func moveHostMemoryToolsLast(in body: inout [String: Any]) {
        guard let tools = body["tools"] as? [Any] else { return }
        let hostNames: Set<String> = [MemoryPropose.toolName, MemorySearch.toolName]
        func isHostMemoryTool(_ tool: Any) -> Bool {
            guard let object = tool as? [String: Any] else { return false }
            if let declarations = object["functionDeclarations"] as? [[String: Any]] {
                let names = declarations.compactMap { $0["name"] as? String }
                return !names.isEmpty && names.count == declarations.count && names.allSatisfy(hostNames.contains)
            }
            let name = (object["function"] as? [String: Any])?["name"] as? String ?? object["name"] as? String
            return name.map(hostNames.contains) ?? false
        }
        let host = tools.filter(isHostMemoryTool)
        guard !host.isEmpty else { return }
        body["tools"] = tools.filter { !isHostMemoryTool($0) } + host
    }
}
