import Testing
import UIKit
@testable import Oriveo

@MainActor
@Suite("UIKitRecoveryCard")
struct UIKitRecoveryCardTests {

    @Test("primary and secondary buttons use non-required fixed height constraints")
    func actionButtonsUseNonRequiredFixedHeightConstraints() throws {
        let card = UIKitRecoveryCard(
            config: .init(
                title: "Request did not complete",
                message: "Try again or edit the message before retrying.",
                primaryTitle: "Retry",
                secondaryTitle: "Edit message",
                tertiaryTitle: nil,
                tone: .danger,
                technicalDetail: "The provider chat completion finished without assistant content.",
                actionsEnabled: true,
                primaryAction: {},
                secondaryAction: {},
                tertiaryAction: nil,
                onDismiss: nil
            )
        )

        let buttons = collectButtons(in: card)
        let primaryButton = try #require(buttons.first(where: { $0.configuration?.title == "Retry" }))
        let secondaryButton = try #require(buttons.first(where: { $0.configuration?.title == "Edit message" }))

        #expect(hasExpectedHeightConstraint(primaryButton))
        #expect(hasExpectedHeightConstraint(secondaryButton))
    }

    @Test("technical detail expansion state is restored from config")
    func technicalDetailExpansionStateIsRestoredFromConfig() throws {
        let technicalDetail = "HTTP 429: provider rate limited"
        let hideTechnicalDetailsTitle = L10n.tr("Hide technical details")
        let card = UIKitRecoveryCard(
            config: .init(
                title: "Request did not complete",
                message: "Try again or edit the message before retrying.",
                primaryTitle: "Retry",
                secondaryTitle: "Edit message",
                tertiaryTitle: nil,
                tone: .danger,
                technicalDetail: technicalDetail,
                actionsEnabled: true,
                primaryAction: {},
                secondaryAction: {},
                tertiaryAction: nil,
                onDismiss: nil,
                showsTechnicalDetail: true
            )
        )

        let buttons = collectButtons(in: card)
        let hideButton = try #require(buttons.first(where: { $0.configuration?.title == hideTechnicalDetailsTitle }))
        let detailLabel = try #require(collectLabels(in: card).first(where: { $0.text == technicalDetail }))

        #expect(hideButton.configuration?.title == hideTechnicalDetailsTitle)
        #expect(detailLabel.isHidden == false)
    }

    @Test("technical detail toggle reports the new visibility state")
    func technicalDetailToggleReportsTheNewVisibilityState() throws {
        var reportedStates: [Bool] = []
        let technicalDetailsTitle = L10n.tr("Technical details")
        let card = UIKitRecoveryCard(
            config: .init(
                title: "Request did not complete",
                message: "Try again or edit the message before retrying.",
                primaryTitle: "Retry",
                secondaryTitle: "Edit message",
                tertiaryTitle: nil,
                tone: .danger,
                technicalDetail: "HTTP 429: provider rate limited",
                actionsEnabled: true,
                primaryAction: {},
                secondaryAction: {},
                tertiaryAction: nil,
                onDismiss: nil,
                onTechnicalDetailVisibilityChanged: { reportedStates.append($0) }
            )
        )

        let buttons = collectButtons(in: card)
        let detailButton = try #require(buttons.first(where: { $0.configuration?.title == technicalDetailsTitle }))
        detailButton.sendActions(for: UIControl.Event.touchUpInside)

        #expect(reportedStates == [true])
    }

    @Test("primary action can reveal technical detail instead of invoking the normal action")
    func primaryActionCanRevealTechnicalDetail() throws {
        var didRunPrimaryAction = false
        var reportedStates: [Bool] = []
        let card = UIKitRecoveryCard(
            config: .init(
                title: "Request did not complete",
                message: "Try again or edit the message before retrying.",
                primaryTitle: "View summary",
                secondaryTitle: nil,
                tertiaryTitle: nil,
                tone: .danger,
                technicalDetail: "Replay deltas expired",
                actionsEnabled: true,
                primaryAction: { didRunPrimaryAction = true },
                secondaryAction: nil,
                tertiaryAction: nil,
                onDismiss: nil,
                primaryRevealsTechnicalDetail: true,
                onTechnicalDetailVisibilityChanged: { reportedStates.append($0) }
            )
        )

        let primaryButton = try #require(collectButtons(in: card).first(where: { $0.configuration?.title == "View summary" }))
        primaryButton.sendActions(for: UIControl.Event.touchUpInside)

        #expect(reportedStates == [true])
        #expect(!didRunPrimaryAction)
    }

    private func collectButtons(in root: UIView) -> [UIButton] {
        var buttons: [UIButton] = []
        if let button = root as? UIButton {
            buttons.append(button)
        }
        for subview in root.subviews {
            buttons.append(contentsOf: collectButtons(in: subview))
        }
        return buttons
    }

    private func collectLabels(in root: UIView) -> [UILabel] {
        var labels: [UILabel] = []
        if let label = root as? UILabel {
            labels.append(label)
        }
        for subview in root.subviews {
            labels.append(contentsOf: collectLabels(in: subview))
        }
        return labels
    }

    private func hasExpectedHeightConstraint(_ button: UIButton) -> Bool {
        button.constraints.contains(where: { constraint in
            constraint.firstAttribute == .height &&
                constraint.constant == UIKitRecoveryCard.fixedButtonHeight &&
                constraint.priority == UIKitRecoveryCard.fixedButtonHeightPriority
        })
    }
}
