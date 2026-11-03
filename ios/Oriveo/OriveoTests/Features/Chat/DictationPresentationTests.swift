import Foundation
import Testing

@testable import Oriveo

/// Presentation rules for the dictation recording state, locked one by one.
@MainActor
@Suite("Dictation recording state - presentation rules")
struct DictationPresentationTests {

    private func voice(_ key: String) -> String { L10n.tr(key, table: .voice) }

    // MARK: Card

    @Test("card: the mapping for failed / interrupted / slot busy / rejected, and no card for the other states")
    func cardMapping() {
        let language = "Klingon"
        let card = { (state: DictationState, duration: TimeInterval?) in
            DictationPresentation.card(for: state, savedDuration: duration, recognitionLanguageName: language)
        }
        #expect(card(.failed(.retry), 12) == DictationCard(
            title: voice("Transcription failed"), subtitle: voice("Recording saved"),
            secondary: .discard, primary: .retry))
        #expect(card(.failed(.checkConnection), 12) == DictationCard(
            title: voice("Transcription failed"), subtitle: voice("Connection unavailable. Recording saved"),
            secondary: .discard, primary: .checkConnection))
        #expect(card(.failed(.noTranscript), nil) == DictationCard(
            title: voice("No text recognized"),
            subtitle: L10n.format(voice("The recognition language is %1$@. If you spoke another language, change it and try again. Your recording is saved."), language),
            secondary: .retry, primary: .changeLanguage))
        #expect(card(.failed(.system(.network)), 12) == DictationCard(
            title: voice("No network connection"),
            subtitle: voice("Connect to the internet, then retry. Your recording is saved."),
            secondary: .discard, primary: .retry))
        #expect(card(.failed(.system(.busy)), 12) == DictationCard(
            title: voice("Speech recognition is busy"),
            subtitle: voice("The system speech recognition service is busy (already retried once). Your recording is saved, so you can retry later."),
            secondary: .discard, primary: .retry))
        #expect(card(.failed(.system(.languageUnsupported)), 12) == DictationCard(
            title: L10n.format(voice("Speech recognition on this device doesn’t support %1$@"), language),
            subtitle: voice("Choose another recognition language or a different dictation engine. Your recording is saved."),
            secondary: .discard, primary: .changeLanguage))
        #expect(card(.failed(.system(.noService)), 12) == DictationCard(
            title: voice("No speech recognition service on this device"),
            subtitle: voice("You can switch to the dictation engine of a provider you’ve connected. Your recording is saved."),
            secondary: .discard, primary: .switchEngine))
        #expect(card(.failed(.system(.other)), 12) == DictationCard(
            title: voice("Transcription failed"), subtitle: voice("Recording saved"),
            secondary: .discard, primary: .retry))
        #expect(DictationCardAction.changeLanguage.localizedTitle == voice("Change Language"))
        #expect(DictationCardAction.switchEngine.localizedTitle == voice("Change Dictation Engine"))
        #expect(card(.interrupted, 65.9) == DictationCard(
            title: voice("Recording interrupted"),
            subtitle: L10n.format(voice("Saved %@"), "1:05"),
            secondary: .discard, primary: .transcribeRecording))
        #expect(card(.slotOccupied, 3_725) == DictationCard(
            title: voice("Previous recording not transcribed yet"),
            subtitle: L10n.format(voice("Saved %@"), "1:02:05"),
            secondary: .discardAndRerecord, primary: .transcribeFirst))
        #expect(card(.denied(.microphone), nil) == DictationCard(
            title: voice("Microphone access is off"), subtitle: voice("Turn it on in Settings to dictate"),
            secondary: .notNow, primary: .openSettings))
        #expect(card(.denied(.speechRecognition), nil)?.title == voice("Speech recognition access is off"))

        for state: DictationState in [.idle, .recording(startedAt: .now),
                                      .transcribing(.insert), .transcribing(.send)] {
            #expect(card(state, 10) == nil)
        }
    }

    @Test("card: when the duration is missing the subtitle is Recording saved")
    func missingDurationFallsBackToRecordingSaved() {
        #expect(DictationPresentation.card(for: .interrupted, savedDuration: nil, recognitionLanguageName: "English")?.subtitle == voice("Recording saved"))
        #expect(DictationPresentation.card(for: .slotOccupied, savedDuration: nil, recognitionLanguageName: "English")?.subtitle == voice("Recording saved"))
    }

    // MARK: Language pack hint card

    @Test("Language pack hint: shows a card when no other card is present (including while recording); the title contains the language name; secondary / primary are Not Now / Download")
    func languagePackCard() {
        let prompt = DictationLanguagePackPrompt(localeID: "tlh", displayName: "Klingon", downloading: false)
        let expected = DictationCard(
            title: L10n.format(voice("Download the %1$@ speech pack for faster recognition that also works offline."), "Klingon"),
            subtitle: "",
            secondary: .notNow,
            primary: .download
        )
        for state: DictationState in [.idle, .recording(startedAt: .now), .transcribing(.insert)] {
            #expect(DictationPresentation.card(
                for: state, savedDuration: nil, recognitionLanguageName: "English", languagePack: prompt
            ) == expected, "\(state)")
        }
        #expect(expected.title.contains("Klingon"))
        #expect(DictationCardAction.download.localizedTitle == voice("Download"))
        #expect(DictationCardAction.notNow.localizedTitle == voice("Not Now"))
    }

    @Test("The language pack hint ranks below the failure / interruption / slot-occupied / permission cards; no card is shown while downloading")
    func languagePackCardYieldsToOtherCards() {
        let prompt = DictationLanguagePackPrompt(localeID: "tlh", displayName: "Klingon", downloading: false)
        for state: DictationState in [.failed(.retry), .failed(.system(.network)), .interrupted, .slotOccupied,
                                      .denied(.microphone)] {
            let plain = DictationPresentation.card(for: state, savedDuration: 5, recognitionLanguageName: "English")
            #expect(plain != nil)
            #expect(DictationPresentation.card(
                for: state, savedDuration: 5, recognitionLanguageName: "English", languagePack: prompt
            ) == plain, "\(state)")
        }
        var downloading = prompt
        downloading.downloading = true
        #expect(DictationPresentation.card(
            for: .recording(startedAt: .now), savedDuration: nil, recognitionLanguageName: "English", languagePack: downloading
        ) == nil)
    }

    @Test("Downloading toast: the recognition pack for this language is downloading; no undo")
    func languagePackDownloadingToast() {
        let toast = DictationPresentation.languagePackDownloadingToast(displayName: "Klingon")
        #expect(toast == DictationToast(
            message: L10n.format(voice("Downloading the %1$@ speech pack. Until it finishes, recognition uses the internet."), "Klingon"),
            undoTitle: nil, duration: nil
        ))
    }

    // MARK: Composer row

    @Test("composer row: recording bar / busy (preparing, cloud with the connection name, system) / everything else normal")
    func inputRowMode() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let cloud = DictationEngineInfo(displayName: "My Groq", providerID: UUID())
        #expect(DictationPresentation.inputRow(for: .recording(startedAt: startedAt), engineInfo: nil)
            == .recording(startedAt: startedAt))

        let cloudBusy = DictationPresentation.inputRow(for: .transcribing(.send), engineInfo: cloud)
        #expect(cloudBusy == .busy(.transcribing(engineName: "My Groq")))
        if case .busy(let activity) = cloudBusy {
            #expect(activity.localizedCaption == L10n.format(voice("Transcribing · %@"), "My Groq"))
        }

        let systemBusy = DictationPresentation.inputRow(for: .transcribing(.insert), engineInfo: nil)
        #expect(systemBusy == .busy(.transcribing(engineName: nil)))
        if case .busy(let activity) = systemBusy {
            #expect(activity.localizedCaption == voice("Transcribing"))
        }

        for state: DictationState in [.idle, .denied(.microphone), .slotOccupied, .interrupted,
                                      .failed(.retry), .failed(.checkConnection), .failed(.noTranscript)] {
            #expect(DictationPresentation.inputRow(for: state, engineInfo: cloud) == .normal)
        }
    }

    // MARK: Duration

    @Test("duration: rounded down to the second, m:ss; h:mm:ss from 1 hour")
    func durationFormat() {
        #expect(DictationPresentation.formattedDuration(0) == "0:00")
        #expect(DictationPresentation.formattedDuration(9.99) == "0:09")
        #expect(DictationPresentation.formattedDuration(59.999) == "0:59")
        #expect(DictationPresentation.formattedDuration(600) == "10:00")
        #expect(DictationPresentation.formattedDuration(3_599.9) == "59:59")
        #expect(DictationPresentation.formattedDuration(3_600) == "1:00:00")
        #expect(DictationPresentation.formattedDuration(36_061.5) == "10:01:01")
    }

    // MARK: Events

    @Test("events: insert inserts; send inserts and sends when sendable, and only inserts when not")
    func insertAndSendReactions() {
        #expect(DictationPresentation.reaction(to: .insert("hi"), canSend: true) == .insert("hi"))
        #expect(DictationPresentation.reaction(to: .insert("hi"), canSend: false) == .insert("hi"))
        #expect(DictationPresentation.reaction(to: .send("go"), canSend: true) == .insertAndSend("go"))
        #expect(DictationPresentation.reaction(to: .send("go"), canSend: false) == .insert("go"))
    }

    @Test("events: nothing heard / engine fallback show a toast; an undoable discard shows \"Discarded + Undo\" for 4 seconds")
    func liveDiscardedRestores() {
        #expect(DictationPresentation.reaction(to: .liveDiscarded, canSend: true) == .restoreLive)
        #expect(DictationPresentation.reaction(to: .liveDiscarded, canSend: false) == .restoreLive)
    }

    @Test("events: nothing heard / engine fallback show a toast; an undoable discard shows \"Discarded + Undo\" for 4 seconds")
    func toastReactions() {
        #expect(DictationPresentation.reaction(to: .noSpeechHeard, canSend: true) == .toast(DictationToast(
            message: voice("Didn't hear anything"), undoTitle: nil, duration: nil)))
        for reason: VoiceFallbackReason in [.connectionMissing, .keyMissing, .entryRemoved] {
            #expect(DictationPresentation.reaction(to: .engineFallback(reason), canSend: false) == .toast(DictationToast(
                message: voice("The selected dictation engine is unavailable. Using system dictation."),
                undoTitle: nil, duration: nil)))
        }
        #expect(DictationPresentation.toast(forDiscard: .undoable) == DictationToast(
            message: voice("Recording discarded"), undoTitle: voice("Undo"), duration: .seconds(4)))
        #expect(DictationPresentation.toast(forDiscard: .deleted) == nil)
        #expect(DictationPresentation.toast(forDiscard: nil) == nil)
    }

    @Test("each of the 8 card actions has its own button label")
    func actionTitles() {
        #expect(DictationCardAction.allCases.count == 11)
        #expect(DictationCardAction.transcribeRecording.localizedTitle == voice("Transcribe Recording"))
        #expect(DictationCardAction.discardAndRerecord.localizedTitle == voice("Discard and Re-record"))
    }
}
