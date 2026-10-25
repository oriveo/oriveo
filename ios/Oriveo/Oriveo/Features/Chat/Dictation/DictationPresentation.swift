import Foundation

// MARK: - Value types

/// Button actions on the card and the recording bar; the view layer maps them to controller methods.
nonisolated enum DictationCardAction: Sendable, Hashable, CaseIterable {
    /// discard()
    case discard
    /// finish(.insert)
    case retry
    /// finish(.insert)
    case transcribeRecording
    /// transcribeOccupied()
    case transcribeFirst
    /// discardAndRerecord()
    case discardAndRerecord
    /// dismissDenied()
    case notNow
    /// Opens UIApplication.openSettingsURLString
    case openSettings
    /// The host opens the connection details for engineInfo.providerID, or the provider list when there is no id
    case checkConnection
}

@MainActor
extension DictationCardAction {
    var localizedTitle: String {
        switch self {
        case .discard: return L10n.tr("Discard", table: .voice)
        case .retry: return L10n.tr("Retry", table: .voice)
        case .transcribeRecording: return L10n.tr("Transcribe Recording", table: .voice)
        case .transcribeFirst: return L10n.tr("Transcribe First", table: .voice)
        case .discardAndRerecord: return L10n.tr("Discard and Re-record", table: .voice)
        case .notNow: return L10n.tr("Not Now", table: .voice)
        case .openSettings: return L10n.tr("Open Settings", table: .voice)
        case .checkConnection: return L10n.tr("Check Connection", table: .voice)
        }
    }
}

/// Inline card above the input field: title / subtitle are already localized; secondary / primary are actions.
nonisolated struct DictationCard: Sendable, Equatable {
    let title: String
    let subtitle: String
    let secondary: DictationCardAction
    let primary: DictationCardAction
}

/// Activity carried by the busy input row.
nonisolated enum DictationBusyActivity: Sendable, Equatable {
    /// The on-device model for the system engine is downloading; progress is 0...1.
    case preparing(progress: Double)
    /// Transcribing; cloud engines carry the connection display name, the system engine passes nil.
    case transcribing(engineName: String?)
}

@MainActor
extension DictationBusyActivity {
    var localizedCaption: String {
        switch self {
        case .preparing:
            return L10n.tr("Preparing speech recognition", table: .voice)
        case .transcribing(let engineName?):
            return L10n.format(L10n.tr("Transcribing · %@", table: .voice), engineName)
        case .transcribing(nil):
            return L10n.tr("Transcribing", table: .voice)
        }
    }
}

/// Input row mode.
nonisolated enum DictationInputRowMode: Sendable, Equatable {
    /// The normal input row.
    case normal
    /// Recording bar: ✕, timer, waveform, Transcribe, outer ↑.
    case recording(startedAt: Date)
    /// Busy: caption + progress, only ✕ remains.
    case busy(DictationBusyActivity)
}

/// One-off toast: the message is already localized; with undo it carries the undo button title and display duration.
nonisolated struct DictationToast: Sendable, Equatable {
    let message: String
    let undoTitle: String?
    /// nil uses the host default duration.
    let duration: Duration?
}

/// UI reaction to a controller event; inserting at the selection, sending and showing toasts are done by the host.
nonisolated enum DictationEventReaction: Sendable, Equatable {
    case insert(String)
    case insertAndSend(String)
    case toast(DictationToast)
}

// MARK: - Presentation rules

/// Presentation rules for the dictation recording state, shared by the chat page and the home page; pure functions that never call the controller.
enum DictationPresentation {

    /// Card mapping.
    /// - Parameter savedDuration: duration of the slot recording in seconds; when nil the subtitle is "Recording saved".
    static func card(for state: DictationState, savedDuration: TimeInterval?) -> DictationCard? {
        switch state {
        case .failed(.retry):
            return DictationCard(
                title: L10n.tr("Transcription failed", table: .voice),
                subtitle: L10n.tr("Recording saved", table: .voice),
                secondary: .discard,
                primary: .retry
            )
        case .failed(.checkConnection):
            return DictationCard(
                title: L10n.tr("Transcription failed", table: .voice),
                subtitle: L10n.tr("Connection unavailable. Recording saved", table: .voice),
                secondary: .discard,
                primary: .checkConnection
            )
        case .failed(.noTranscript):
            return DictationCard(
                title: L10n.tr("No text recognized", table: .voice),
                subtitle: L10n.tr("Recording saved", table: .voice),
                secondary: .discard,
                primary: .retry
            )
        case .interrupted:
            return DictationCard(
                title: L10n.tr("Recording interrupted", table: .voice),
                subtitle: savedSubtitle(savedDuration),
                secondary: .discard,
                primary: .transcribeRecording
            )
        case .slotOccupied:
            return DictationCard(
                title: L10n.tr("Previous recording not transcribed yet", table: .voice),
                subtitle: savedSubtitle(savedDuration),
                secondary: .discardAndRerecord,
                primary: .transcribeFirst
            )
        case .denied(let permission):
            let title = switch permission {
            case .microphone: L10n.tr("Microphone access is off", table: .voice)
            case .speechRecognition: L10n.tr("Speech recognition access is off", table: .voice)
            }
            return DictationCard(
                title: title,
                subtitle: L10n.tr("Turn it on in Settings to dictate", table: .voice),
                secondary: .notNow,
                primary: .openSettings
            )
        case .idle, .preparing, .recording, .transcribing:
            return nil
        }
    }

    /// Input row mode.
    static func inputRow(for state: DictationState, engineInfo: DictationEngineInfo?) -> DictationInputRowMode {
        switch state {
        case .recording(let startedAt):
            return .recording(startedAt: startedAt)
        case .preparing(let progress):
            return .busy(.preparing(progress: progress))
        case .transcribing:
            return .busy(.transcribing(engineName: engineInfo?.displayName))
        case .idle, .denied, .slotOccupied, .interrupted, .failed:
            return .normal
        }
    }

    /// Event reaction: when the host cannot send right now, a send event only inserts.
    static func reaction(to event: DictationEvent, canSend: Bool) -> DictationEventReaction {
        switch event {
        case .insert(let text):
            return .insert(text)
        case .send(let text):
            return canSend ? .insertAndSend(text) : .insert(text)
        case .noSpeechHeard:
            return .toast(DictationToast(
                message: L10n.tr("Didn't hear anything", table: .voice), undoTitle: nil, duration: nil
            ))
        case .engineFallback:
            return .toast(DictationToast(
                message: L10n.tr("The selected dictation engine is unavailable. Using system dictation.", table: .voice),
                undoTitle: nil,
                duration: nil
            ))
        }
    }

    /// Result of discard(): only undoable shows "discarded + Undo", with the same duration as the controller's undo window.
    static func toast(forDiscard outcome: RecordingDiscardOutcome?) -> DictationToast? {
        guard outcome == .undoable else { return nil }
        return DictationToast(
            message: L10n.tr("Recording discarded", table: .voice),
            undoTitle: L10n.tr("Undo", table: .voice),
            duration: DictationController.discardUndoWindow
        )
    }

    /// Duration: rounded down to the second, m:ss; h:mm:ss from one hour up.
    nonisolated static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, secs)
        }
        return String(format: "%ld:%02ld", minutes, secs)
    }

    private static func savedSubtitle(_ duration: TimeInterval?) -> String {
        guard let duration else { return L10n.tr("Recording saved", table: .voice) }
        return L10n.format(L10n.tr("Saved %@", table: .voice), formattedDuration(duration))
    }
}
