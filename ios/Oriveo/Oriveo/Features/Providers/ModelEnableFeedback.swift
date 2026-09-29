import Foundation

/// User feedback after tapping "+" on a model catalog row. The Home picker and the provider
/// detail screen share one copy and style so neither surface adds a model silently.
enum ModelEnableFeedback {
    struct Feedback: Equatable {
        let message: String
        let style: ToastStyle
    }

    static func feedback(for result: ProviderManager.EnableModelResult) -> Feedback? {
        switch result {
        case .added(let modelName):
            return Feedback(
                message: String(format: L10n.tr("Added %@", table: .providers), modelName),
                style: .success
            )
        case .alreadyEnabled:
            return nil
        case .notFound:
            return Feedback(
                message: L10n.tr("We couldn't enable that model. Please try again.", table: .providers),
                style: .error
            )
        }
    }

    @MainActor
    static func announce(_ result: ProviderManager.EnableModelResult) {
        guard let feedback = feedback(for: result) else { return }
        ToastManager.shared.show(feedback.message, style: feedback.style)
    }
}
