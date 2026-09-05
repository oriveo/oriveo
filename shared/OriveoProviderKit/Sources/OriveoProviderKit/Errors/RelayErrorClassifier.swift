import Foundation

/// An upstream error body in the OpenAI shape, `{ error: { code, message, param } }`.
///
/// Relay endpoints vary in how much of it they fill in, so every field is optional and the
/// classifiers below fail closed: an error they cannot read is not treated as a known cause.
public struct RelayUpstreamErrorPayload: Sendable {
    public let code: String?
    public let message: String?
    public let param: String?

    public init(code: String?, message: String?, param: String?) {
        self.code = code
        self.message = message
        self.param = param
    }
}

public enum RelayErrorClassifier {

    /// Parses a 4xx body as an OpenAI-shaped error. Returns nil when the body is not one.
    public static func parseUpstreamErrorPayload(_ data: Data) -> RelayUpstreamErrorPayload? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let err = json["error"] as? [String: Any] {
            return RelayUpstreamErrorPayload(
                code: err["code"] as? String,
                message: err["message"] as? String,
                param: err["param"] as? String
            )
        }
        if let str = json["error"] as? String {
            return RelayUpstreamErrorPayload(code: nil, message: str, param: nil)
        }
        return nil
    }

    /// Whether the endpoint rejected the request because it does not support the built-in tool
    /// that was attached, which the caller answers by retrying once without tools.
    ///
    /// Endpoints disagree about how they say this, so several shapes are accepted:
    /// - `param` points at `tools[*]` and the message names the tool or the code says the
    ///   parameter is unknown or unsupported
    /// - `code` is `tool_not_supported`
    /// - the message names `image_generation` or `web_search` outright
    /// - the endpoint says the model is not valid for its image route
    ///
    /// The bare word "image" is deliberately not enough: it also appears in ordinary vision
    /// errors, where dropping the tools would not help.
    public static func isImageGenerationToolUnsupportedError(
        payload: RelayUpstreamErrorPayload?,
        statusCode: Int
    ) -> Bool {
        guard (400 ..< 500).contains(statusCode), let payload else { return false }

        let code = payload.code?.lowercased() ?? ""
        let message = payload.message ?? ""
        let messageLower = message.lowercased()
        let param = payload.param ?? ""

        if code == "tool_not_supported" { return true }

        let paramTargetsTools = paramMatchesTools(param)
        let codeWhitelist = ["unknown_parameter", "unsupported_parameter", "invalid_parameter"]
        if paramTargetsTools && (messageLower.contains("image_generation") || codeWhitelist.contains(code)) {
            return true
        }

        // Some endpoints report the offending tool only in the message, with no usable `param`
        // or `code`. Matching the exact tool names is safe here; matching the bare word "image"
        // would not be, because vision errors use it too.
        if messageLower.contains("image_generation") { return true }
        if messageLower.contains("web_search") { return true }
        if isImageEndpointModelMismatch(messageLower) { return true }

        return false
    }

    /// Whether the endpoint rejected the requested reasoning effort, so the caller can retry
    /// with a level the endpoint accepts.
    public static func isReasoningEffortXHighError(
        payload: RelayUpstreamErrorPayload?,
        statusCode: Int
    ) -> Bool {
        guard (400 ..< 500).contains(statusCode), let payload else { return false }
        let message = (payload.message ?? "").lowercased()
        return message.contains("xhigh")
            || (message.contains("reasoning") && message.contains("effort"))
    }

    private static func paramMatchesTools(_ param: String) -> Bool {
        let lower = param.lowercased()
        if lower == "tools" { return true }
        // Also accept indexed forms such as `tools[0]` and `tools[12].type`.
        let regex = #"^tools(\[\d+\](\.[a-z_]+)?)?$"#
        return param.range(of: regex, options: .regularExpression) != nil
    }

    private static func isImageEndpointModelMismatch(_ messageLower: String) -> Bool {
        messageLower.contains("unsupported model:")
            && messageLower.contains("only gpt-image")
            && messageLower.contains("supported on this endpoint")
    }
}

/// Adjustments the caller applies when rebuilding a request for a retry after one of the
/// classifications above.
public struct RelayRetryHints: Equatable, Sendable {
    public var reasoningEffortOverride: String?
    public var removeTools: Bool

    public init(reasoningEffortOverride: String? = nil, removeTools: Bool = false) {
        self.reasoningEffortOverride = reasoningEffortOverride
        self.removeTools = removeTools
    }
}
