import Foundation

public enum ProviderTextWireRequestError: Error, Equatable, Sendable {
    case unsupportedTransport(ProviderWireTransport)
    case missingMessages
    case missingMaxOutputTokens
    case invalidMaxOutputTokens
    case invalidMessage
    case encodingFailed
}

