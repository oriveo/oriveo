import Foundation
import Testing
@testable import Oriveo

/// How a subscription failure and an unavailable model land on the chat page.
///
/// Every error object comes out of the production mapping (`BaseAPIService.mapHTTPError`) fed with a real
/// upstream body; no `ProviderServiceError` is assembled by hand here.
@MainActor
@Suite("Chat failure presentation · subscription 426 and model switch")
struct ChatFailurePresentationTests {
    /// The body xAI returns when it rejects the client version.
    static let grok426Body = Data(#"{"code":"ClientVersionRejected","error":"Your Grok CLI version (1.0.4) is outdated. Please update to the latest version via `grok update`."}"#.utf8)

    private final class ProbeService: BaseAPIService {}

    // MARK: - Subscription 426

    @Test("A Grok / ChatGPT subscription rejected with 426 persists the user-facing sentence, not the upstream text, and offers Switch model",
          arguments: [ProviderServiceError.SubscriptionLane.grok, .openAI])
    func subscriptionRejectionPersistsActionableCopy(lane: ProviderServiceError.SubscriptionLane) {
        let error = ProbeService().mapHTTPError(statusCode: 426, data: Self.grok426Body, subscriptionLane: lane)
        #expect(error.subscriptionClientVersionRejectionLane == lane, "426 should map to a client version rejection on the subscription lane")
        #expect(error.technicalDetail.contains("grok update"), "Precondition: the upstream text really carries the instruction a user cannot follow")

        let detail = ChatFailurePresentation.persistedDetail(for: error)
        #expect(detail == error.message)
        #expect(!detail.contains("grok update") && !detail.contains("CLI"), "The card's collapsed section must not show the upstream text: \(detail)")
        #expect(!error.message.contains("grok update"))
        #expect(ChatFailurePresentation.offersModelSwitch(errorTitle: error.titleKey, errorDetail: detail, bodyText: error.message))
    }

    @Test("Subscription 401 / 403 / 429 also offer Switch model; a 401 in API key mode does not")
    func subscriptionFailuresOfferModelSwitch() {
        for status in [401, 403, 429] {
            let error = ProbeService().mapHTTPError(statusCode: status, data: Data("{}".utf8), subscriptionLane: .grok)
            #expect(error.subscriptionClientVersionRejectionLane == nil)
            // The body is deliberately not English: the decision must not depend on the translated text.
            #expect(ChatFailurePresentation.offersModelSwitch(
                errorTitle: error.titleKey,
                errorDetail: ChatFailurePresentation.persistedDetail(for: error),
                bodyText: "Abonnement abgelaufen"
            ), "A subscription \(status) should keep the Switch model way out")
        }
        let keyMode = ProbeService().mapHTTPError(statusCode: 401, data: Data("{}".utf8))
        #expect(!ChatFailurePresentation.offersModelSwitch(
            errorTitle: keyMode.titleKey,
            errorDetail: ChatFailurePresentation.persistedDetail(for: keyMode),
            bodyText: "Ungültiger Schlüssel"
        ))
        #expect(ChatFailurePresentation.persistedDetail(for: keyMode) == keyMode.technicalDetail, "A failure with the user's own key keeps its technical detail")
    }

    // MARK: - Model unavailable

    @Test("Model Unavailable offers Switch model in a non-English interface too; an ordinary upstream error does not")
    func modelUnavailableOffersSwitchRegardlessOfLanguage() {
        #expect(ChatFailurePresentation.offersModelSwitch(errorTitle: "Model Unavailable", errorDetail: "x", bodyText: "Modell derzeit nicht verfügbar"))
        #expect(!ChatFailurePresentation.offersModelSwitch(errorTitle: "Provider Request Failed", errorDetail: "Upstream HTTP 500: boom", bodyText: "Anfrage fehlgeschlagen"))
        #expect(ChatFailurePresentation.offersModelSwitch(errorTitle: "Provider Rate Limited", errorDetail: nil, bodyText: ""))
    }
}
