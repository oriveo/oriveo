import Foundation

/// Localized copy for input capability states, keyed by disabled reason × medium.
/// Keys are the English source strings in `Chat.xcstrings`; UI call sites only go through here.
enum InputCapabilityCopy {
    enum Medium: String, Sendable, CaseIterable {
        case image
        case file
        case video

        /// Input capability key (`vision_input` / `file_input` / `video_input`) → medium; other keys are nil.
        init?(capabilityKey: String) {
            switch capabilityKey {
            case CapabilityEvidenceFacade.visionInputKey: self = .image
            case CapabilityEvidenceFacade.fileInputKey: self = .file
            case CapabilityEvidenceFacade.videoInputKey: self = .video
            default: return nil
            }
        }
    }

    typealias Reason = CapabilityEvidenceFacade.InputDisabledReason

    /// Why the attach entry for `medium` is disabled.
    static func disabled(_ reason: Reason, _ medium: Medium) -> String {
        L10n.tr(disabledKey(reason, medium), table: .chat)
    }

    /// One-time hint shown on the first attach while the capability is still unconfirmed.
    static func hintFirstAttach(_ medium: Medium) -> String {
        L10n.tr(hintFirstAttachKey(medium), table: .chat)
    }

    /// Recovery action label: resend the message with this medium stripped.
    static func resendWithout(_ medium: Medium) -> String {
        L10n.tr(resendWithoutKey(medium), table: .chat)
    }

    /// Bubble marker on an attachment that was not sent to the model (not medium-specific).
    static var bubbleNotSentToModel: String {
        L10n.tr(bubbleNotSentToModelKey, table: .chat)
    }

    // MARK: - Copy ids (cross-platform identifiers, not display text)

    /// Copy id of the disabled reason for one medium, e.g. `disabled.kill_switch.image`.
    /// Each medium has its own id; the display string still comes from `disabledKey`.
    static func disabledCopyId(_ reason: Reason, _ medium: Medium) -> String {
        "\(reason.rawValue).\(medium.rawValue)"
    }

    // MARK: - Keys (English source strings)

    static func disabledKey(_ reason: Reason, _ medium: Medium) -> String {
        switch (reason, medium) {
        case (.modelAbsent, .image): "This model doesn't support image input"
        case (.modelAbsent, .file): "This model doesn't support file input"
        case (.modelAbsent, .video): "This model doesn't support video input"
        case (.wireNotImplemented, .image): "This connection can't send images yet"
        case (.wireNotImplemented, .file): "This connection can't send files yet"
        case (.wireNotImplemented, .video): "This connection can't send videos yet"
        case (.killSwitch, .image): "Image input is temporarily off for this provider"
        case (.killSwitch, .file): "File input is temporarily off for this provider"
        case (.killSwitch, .video): "Video input is temporarily off for this provider"
        case (.rejectedRecently, .image): "This model just rejected an image"
        case (.rejectedRecently, .file): "This model just rejected a file"
        case (.rejectedRecently, .video): "This model just rejected a video"
        case (.userRemoved, .image): "You turned off image input for this model"
        case (.userRemoved, .file): "You turned off file input for this model"
        case (.userRemoved, .video): "You turned off video input for this model"
        }
    }

    static func hintFirstAttachKey(_ medium: Medium) -> String {
        switch medium {
        case .image: "We haven't confirmed this model can see images yet. If it can't, we'll let you know"
        case .file: "We haven't confirmed this model can read files yet. If it can't, we'll let you know"
        case .video: "We haven't confirmed this model can watch videos yet. If it can't, we'll let you know"
        }
    }

    static func resendWithoutKey(_ medium: Medium) -> String {
        switch medium {
        case .image: "Resend without images"
        case .file: "Resend without files"
        case .video: "Resend without videos"
        }
    }

    static let bubbleNotSentToModelKey = "Not sent to this model"
}
