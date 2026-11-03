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
    /// Host opens voice settings (the recognition language is changed there)
    case changeLanguage
    /// Host opens voice settings (the dictation engine is switched there)
    case switchEngine
    /// download(): installs the recognition language pack in the background
    case download
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
        case .changeLanguage: return L10n.tr("Change Language", table: .voice)
        case .switchEngine: return L10n.tr("Change Dictation Engine", table: .voice)
        case .download: return L10n.tr("Download", table: .voice)
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
    /// Transcribing; cloud engines carry the connection display name, the system engine passes nil.
    case transcribing(engineName: String?)
}

@MainActor
extension DictationBusyActivity {
    var localizedCaption: String {
        switch self {
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
    /// Withdraws realtime text already written into the input field.
    case restoreLive
    /// The host does nothing.
    case ignore
}

// MARK: - Presentation rules

/// Presentation rules for the dictation recording state, shared by the chat page and the home page; pure functions that never call the controller.
enum DictationPresentation {

    /// Card mapping.
    /// - Parameter savedDuration: slot recording duration in seconds; when nil the subtitle is "Recording saved".
    /// - Parameter recognitionLanguageName: display name of the current recognition language, used only for the "language not supported" card title and the "no text recognized" card body.
    /// - Parameter languagePack: the controller's language-pack hint; when no other card applies (including recording and transcribing), the language-pack card is shown; no card while downloading.
    static func card(
        for state: DictationState, savedDuration: TimeInterval?, recognitionLanguageName: String,
        languagePack: DictationLanguagePackPrompt? = nil
    ) -> DictationCard? {
        switch state {
        case .failed(.system(.network)):
            return DictationCard(
                title: L10n.tr("No network connection", table: .voice),
                subtitle: L10n.tr("Connect to the internet, then retry. Your recording is saved.", table: .voice),
                secondary: .discard,
                primary: .retry
            )
        case .failed(.system(.busy)):
            return DictationCard(
                title: L10n.tr("Speech recognition is busy", table: .voice),
                subtitle: L10n.tr(
                    "The system speech recognition service is busy (already retried once). Your recording is saved, so you can retry later.",
                    table: .voice
                ),
                secondary: .discard,
                primary: .retry
            )
        case .failed(.system(.languageUnsupported)):
            return DictationCard(
                title: L10n.format(
                    L10n.tr("Speech recognition on this device doesn’t support %1$@", table: .voice),
                    recognitionLanguageName
                ),
                subtitle: L10n.tr(
                    "Choose another recognition language or a different dictation engine. Your recording is saved.",
                    table: .voice
                ),
                secondary: .discard,
                primary: .changeLanguage
            )
        case .failed(.system(.noService)):
            return DictationCard(
                title: L10n.tr("No speech recognition service on this device", table: .voice),
                subtitle: L10n.tr(
                    "You can switch to the dictation engine of a provider you’ve connected. Your recording is saved.",
                    table: .voice
                ),
                secondary: .discard,
                primary: .switchEngine
            )
        case .failed(.retry), .failed(.system(.other)):
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
                subtitle: L10n.format(
                    L10n.tr(
                        "The recognition language is %1$@. If you spoke another language, change it and try again. Your recording is saved.",
                        table: .voice
                    ),
                    recognitionLanguageName
                ),
                secondary: .retry,
                primary: .changeLanguage
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
        case .idle, .recording, .transcribing:
            guard let languagePack, !languagePack.downloading else { return nil }
            return DictationCard(
                title: L10n.format(
                    L10n.tr("Download the %1$@ speech pack for faster recognition that also works offline.", table: .voice),
                    languagePack.displayName
                ),
                subtitle: "",
                secondary: .notNow,
                primary: .download
            )
        }
    }

    /// Input row mode.
    static func inputRow(for state: DictationState, engineInfo: DictationEngineInfo?) -> DictationInputRowMode {
        switch state {
        case .recording(let startedAt):
            return .recording(startedAt: startedAt)
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
        case .liveDiscarded:
            return .restoreLive
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

    /// One-time hint after tapping Download on the language-pack card: downloading in the background; recognition uses the network meanwhile.
    static func languagePackDownloadingToast(displayName: String) -> DictationToast {
        DictationToast(
            message: L10n.format(
                L10n.tr("Downloading the %1$@ speech pack. Until it finishes, recognition uses the internet.", table: .voice),
                displayName
            ),
            undoTitle: nil,
            duration: nil
        )
    }

    /// Duration: rounded down to whole seconds, m:ss; h:mm:ss for one hour or more.
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
