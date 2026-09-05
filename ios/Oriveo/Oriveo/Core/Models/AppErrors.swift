import Foundation

enum OriveoErrorSeverity: Hashable {
    case warning
    case critical
}

struct OriveoError: Identifiable, Hashable {
    let id: UUID
    var title: String
    var message: String
    var actionTitle: String
    var detail: String
    var severity: OriveoErrorSeverity
}

func makeProviderError(_ error: Error, actionTitle: String = L10n.tr("Try Again")) -> OriveoError {
    let providerError: ProviderServiceError
    if let typedError = error as? ProviderServiceError {
        providerError = typedError
    } else if let rejected = error as? ToolsRejectedByUpstreamError {
        providerError = rejected.underlying
    } else {
        providerError = .network(detail: error.localizedDescription)
    }

    let severity: OriveoErrorSeverity
    switch providerError {
    case .invalidAPIKey, .invalidConfiguration:
        severity = .critical
    default:
        severity = .warning
    }

    return OriveoError(
        id: UUID(),
        title: providerError.title,
        message: providerError.message,
        actionTitle: actionTitle,
        detail: providerError.technicalDetail,
        severity: severity
    )
}
