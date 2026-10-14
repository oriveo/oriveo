import Foundation

// MARK: - The two add-page boards (Setup / LocalSetup; relay two-step flow)
//
// The view renders only the copy keys, slot order, check card states and button states produced here; structural tests assert on this model instead of image snapshots.
// All three platforms give the same answer: changing a branch here changes the contract, so change the contract first.

enum SetupInputSlot: String, Equatable, Sendable {
    case address
    case apiKey
    /// Relay step 1: key name (optional).
    case keyName
    /// Relay step 1: "Add another key".
    case addKey
}

/// The four values of the check card; "tri-state" = the last three.
enum SetupDetectionCardState: Equatable, Sendable {
    case hidden
    case detecting
    case succeeded
    case failed
}

/// Primary button: the three copy keys are unchanged; while checking it shows loading and is not tappable.
enum SetupPrimaryButton: Equatable, Sendable {
    case detect
    case detecting
    case connectAndSave
    case saveAndContinue

    var titleKey: String {
        switch self {
        case .detect: "Detect connection settings"
        case .detecting: "Detecting..."
        case .connectAndSave: "Connect and save"
        case .saveAndContinue: "Save and continue"
        }
    }

    var showsProgress: Bool { self == .detecting }
}

// MARK: - Relay

struct RelayProtocolShare: Equatable, Sendable {
    let transport: RelayTransport
    let count: Int
}

/// Protocol ratio bar of the check card: each detected model is grouped by the first item of the same candidate function used by probe orchestration (`RelayProbeCandidates`);
/// the default model uses the verified protocol. It reads only responses already received: the family lookup is a closure over a read-only cache supplied by the caller, and no request is sent for the ratio bar.
enum RelayProtocolMix {
    /// Fixed order of the legend and color segments (the same on all three platforms, not reordered by count).
    static let legendOrder: [RelayTransport] = [
        .openaiChatCompletions,
        .openaiResponses,
        .anthropicMessages,
        .geminiGenerateContent,
    ]

    static func shares(
        modelIDs: [String],
        endpointTypesByModel: [String: [String]],
        verifiedDefault: (modelID: String, transport: RelayTransport)?,
        family: (String) async -> String?
    ) async -> [RelayProtocolShare] {
        var counts: [RelayTransport: Int] = [:]
        var seen = Set<String>()
        for modelID in modelIDs where seen.insert(modelID).inserted {
            let transport = await protocolOf(
                modelID: modelID,
                endpointTypes: endpointTypesByModel[modelID],
                verifiedDefault: verifiedDefault,
                family: family
            )
            if let transport { counts[transport, default: 0] += 1 }
        }
        return legendOrder.compactMap { transport in
            counts[transport].map { RelayProtocolShare(transport: transport, count: $0) }
        }
    }

    /// Protocol of a single model: the verified one uses the verified protocol, otherwise the first candidate (the ratio bar and the default model row use the same criterion).
    static func protocolOf(
        modelID: String,
        endpointTypes: [String]?,
        verifiedDefault: (modelID: String, transport: RelayTransport)?,
        family: (String) async -> String?
    ) async -> RelayTransport? {
        if let verifiedDefault, verifiedDefault.modelID == modelID { return verifiedDefault.transport }
        return await RelayProbeCandidates.candidates(
            supportedEndpointTypes: endpointTypes,
            family: { await family(modelID) }
        ).first
    }

    /// Protocol names on the legend are the names of the protocols themselves (the same as the short names in `ProviderSettingsSection`) and are not translated.
    static func legendName(_ transport: RelayTransport) -> String {
        switch transport {
        case .openaiChatCompletions: "Chat"
        case .openaiResponses: "Responses"
        case .anthropicMessages: "Messages"
        case .geminiGenerateContent: "Gemini"
        case .auto, .llamacppNative: transport.rawValue
        }
    }
}

/// Relay add step 1 (Setup board): address -> key -> key name -> add another; three check items; the primary button is always Next.
struct RelaySetupBoardModel: Equatable {
    static let heroLabelKey = "Custom LLM · Custom Relay"
    static let heroTitleKey = "Connect a Custom Relay"
    static let heroSubtitleKey = "Enter the address and key, then choose models in the next step. Protocol and capabilities are checked per model."
    /// With a single key the name is not shown: a single key does not store `relayKeys`, so the name could not be stored; once a second key is added every key (including the primary one) has a name.
    static func slots(keyCount: Int) -> [SetupInputSlot] {
        keyCount >= 2 ? [.address, .apiKey, .keyName, .addKey] : [.address, .apiKey, .addKey]
    }
    static let willRequestKey = "Will request %@"
    static let keyNameKey = "Name (optional)"
    static let addKeyKey = "Add another key"
    static let removeKeyKey = "Remove key"
    static let keysLocalKey = "Keys stay on this device and aren’t uploaded by cloud sync."
    static let detectionTitleKey = "Detection"
    static let detectionSubtitleKey = "Doesn’t lock the screen. Cancel anytime."
    static let detectionNoteKey = "No chat requests are sent in this step. It only ranks protocol candidates for each model."
    static let connectionCheckKey = "relay_setup_check_connection"
    static let catalogCheckKey = "Model list"
    static let protocolsCheckKey = "Protocols"
    static let reachableKey = "%@ reachable"
    static let catalogCountKey = "%lld models"
    static let protocolsRunningKey = "Reading gateway fields and model facts…"
    static let protocolsDoneKey = "Candidates ready"
    static let skippedKey = "Skipped"
    static let cancelDetectionKey = "Cancel detection"
    static let nextKey = "Next"
    static let stepOfKey = "Step %1$lld of %2$lld"
    static let secondaryActionKey = "Set up protocol manually"

    enum NextAction: Equatable, Sendable {
        /// Not checked yet (or the address / keys changed and invalidated this round): start the check.
        case detect
        /// Checking: not tappable.
        case wait
        /// The check has finished: go to step 2; a failure or an empty catalog goes to the manual-add state.
        case models(manualAdd: Bool)
    }

    struct Card: Equatable {
        let detection: RelaySetupDetection
        let completedCount: Int
        let totalCount: Int
        let showsCancel: Bool
    }

    struct Input {
        var detection: RelaySetupDetection? = nil
        var canAct = false
    }

    /// nil = the check card is not shown (not checked yet, cancelled, or the address / keys changed).
    let card: Card?
    let primaryTitleKey: String
    let isPrimaryEnabled: Bool
    let nextAction: NextAction

    static func make(_ input: Input) -> Self {
        let next: NextAction
        if let detection = input.detection {
            next = detection.isFinished ? .models(manualAdd: !detection.succeeded) : .wait
        } else {
            next = .detect
        }
        let card = input.detection.map { detection in
            Card(
                detection: detection,
                completedCount: detection.completedCount,
                totalCount: RelaySetupDetection.ItemID.allCases.count,
                showsCancel: !detection.isFinished
            )
        }
        // After the check ends, going to step 2 no longer needs the input gate (the manual-add state has no catalog anyway); only starting a check looks at whether the input is usable.
        let enabled: Bool = switch next {
        case .detect: input.canAct
        case .wait: false
        case .models: true
        }
        return Self(card: card, primaryTitleKey: nextKey, isPrimaryEnabled: enabled, nextAction: next)
    }

    /// The line under the address slot: the root address obtained by the check takes priority, otherwise `previewAPIRoot(input)`; with "/..." appended. Not shown if it cannot be computed.
    static func previewLine(detectedRoot: String?, input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = detectedRoot ?? (trimmed.isEmpty ? nil : RelayEndpointResolver.previewAPIRoot(trimmed)) else {
            return nil
        }
        return root + "/…"
    }

    /// Time taken by this item: seconds with one decimal, in the number format of the interface language (the same exit as MCP step durations).
    static func elapsedText(seconds: TimeInterval) -> String {
        McpStepDetailSheet.durationText(milliseconds: Int((seconds * 1_000).rounded()))
    }
}

// MARK: - Local

/// Where "Detect" leads: if the fingerprint recognizes the engine, connect with it; generic / manual fall to manual selection.
enum LocalSetupDetectRoute: Equatable, Sendable {
    case connect(LocalEngineKind, channel: RelayTransport)
    case unrecognized

    static func route(for outcome: LocalEngineFingerprintOutcome) -> Self {
        switch outcome {
        case .engine(let engine, let channel): .connect(engine, channel: channel)
        case .generic, .manual: .unrecognized
        }
    }

    /// Skip the fingerprint when the user has already expanded manual selection (the engine in the engine menu is the one they picked).
    static func skipsFingerprint(showsManualPicker: Bool) -> Bool {
        showsManualPicker
    }
}

struct LocalSetupBoardModel: Equatable, Sendable {
    static let heroLabelKey = "Custom LLM · Local & LAN"
    static let heroTitleKey = "Connect a local or LAN engine"
    static let heroSubtitleKey = "Just the address. Engine, channel and models are detected for you."
    static let slots: [SetupInputSlot] = [.address, .apiKey]
    static let networkRowTitleKey = "Found on your network"
    static let recognizedKey = "Recognized as %@ · %d models"
    static let unrecognizedTitleKey = "Couldn't recognize this engine"
    static let unrecognizedBodyKey = "Choose the engine and channel below."
    static let channelTileKey = "Channel"
    static let contextTileKey = "Context"
    static let thinkingTileKey = "Thinking"
    static let contextUnavailableKey = "Not available"
    static let secondaryActionKey = "Choose engine and channel manually"

    enum Thinking: Equatable, Sendable {
        case chatTemplate
        case setByModel
        case unsupported
        case unavailable

        var valueKey: String {
            switch self {
            case .chatTemplate: "Chat template"
            case .setByModel: "Set by the model"
            case .unsupported: "Not supported"
            case .unavailable: "Not available"
            }
        }

        /// Production decision from the write-path table (`engine-expectations.v1.json` `thinking.writePaths`) -> cell value.
        init(_ writePath: ModelOptionCapabilityShape.LocalEngineThinking?) {
            switch writePath {
            case .chatTemplateToggle: self = .chatTemplate
            case .modelDefault, .nonChatNotice: self = .setByModel
            case .unsupported: self = .unsupported
            case nil: self = .unavailable
            }
        }
    }

    struct Summary: Equatable, Sendable {
        let engine: LocalEngineKind
        let modelCount: Int
        let channel: RelayTransport
        /// nil -> show "Not available" (the localized placeholder), never 0.
        let contextLength: Int?
        let thinking: Thinking

        /// Reads only the results the connector already obtained; the thinking cell uses the same write-path decision function as the chat page.
        static func make(_ connection: LocalEngineConnection) -> Self {
            var draft = RelayAddVerification.draftProvider(
                endpoint: connection.endpoint,
                requested: connection.requested,
                modelID: connection.selectedModelID
            )
            draft.models[0].engineDeclaration = connection.runtimeMetadata[connection.selectedModelID]?.engineDeclaration
            return Self(
                engine: connection.engine,
                modelCount: connection.modelIDs.count,
                // The channel is connection-level: use the resolver's connection-level exit instead of reading requested directly.
                channel: RelayEndpointResolver.connectionTransport(of: draft),
                contextLength: connection.contextLength,
                thinking: Thinking(ModelOptionCapabilityShape.localEngineThinking(
                    provider: draft,
                    model: draft.models[0]
                ))
            )
        }
    }

    enum Failure: Equatable, Sendable {
        /// Fingerprint generic / manual -> the manual-selection copy, and manual selection auto-expands.
        case unrecognized
        /// Connection failure: reuse the existing failure copy.
        case connection
    }

    struct Input: Equatable, Sendable {
        var isDetecting = false
        var summary: Summary?
        var failure: Failure?
        var engine: LocalEngineKind = .ollama
        var showsManualPicker = false
        var discoveredAddresses: [String] = []
        var canAct = false
    }

    let card: SetupDetectionCardState
    let summary: Summary?
    let failure: Failure?
    let primaryButton: SetupPrimaryButton
    let isPrimaryEnabled: Bool
    let showsManualPicker: Bool
    let showsChannelPicker: Bool
    /// Empty = the "Found on your local network" row is not shown.
    let networkChips: [String]

    static func make(_ input: Input) -> Self {
        let card: SetupDetectionCardState
        if input.isDetecting {
            card = .detecting
        } else if input.summary != nil {
            card = .succeeded
        } else if input.failure != nil {
            card = .failed
        } else {
            card = .hidden
        }
        let button: SetupPrimaryButton = switch card {
        case .detecting: .detecting
        case .succeeded: .connectAndSave
        case .hidden, .failed: .detect
        }
        let manual = input.showsManualPicker || (card == .failed && input.failure == .unrecognized)
        return Self(
            card: card,
            summary: card == .succeeded ? input.summary : nil,
            failure: card == .failed ? input.failure : nil,
            primaryButton: button,
            isPrimaryEnabled: input.canAct && button != .detecting,
            showsManualPicker: manual,
            showsChannelPicker: manual && LocalEngineChannelCandidates.showsSelector(engineProfile: input.engine.rawValue),
            networkChips: input.discoveredAddresses
        )
    }

    static func contextValue(_ contextLength: Int?) -> (text: String?, key: String?) {
        if let text = CatalogModelBuilder.compactContextText(contextLength) { return (text, nil) }
        return (nil, contextUnavailableKey)
    }
}
