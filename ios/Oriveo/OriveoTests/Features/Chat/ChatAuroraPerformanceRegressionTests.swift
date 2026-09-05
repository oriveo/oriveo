import Foundation
import Testing

@Suite("Chat idle rendering performance regression")
struct ChatAuroraPerformanceRegressionTests {

    @Test("Aurora Has No Continuous Animation Driver")
    func auroraHasNoContinuousAnimationDriver() throws {
        let source = try source(named: "ChatEmptyStateAurora.swift")

        #expect(!source.contains("repeatForever"))
        #expect(!source.contains("TimelineView"))
        #expect(!source.contains("@State private var breathing"))
    }

    @Test("Static Visual And Finite Transitions Remain")
    func staticVisualAndFiniteTransitionsRemain() throws {
        let auroraSource = try source(named: "ChatEmptyStateAurora.swift")
        let chatViewSource = try source(named: "ChatView.swift")

        #expect(auroraSource.contains("Canvas"))
        #expect(auroraSource.components(separatedBy: "RadialGradient(").count - 1 == 3)
        #expect(auroraSource.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: prominent)"))
        #expect(auroraSource.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: appeared)"))
        #expect(chatViewSource.contains(".background(ChatEmptyStateAurora(prominent: projection.messages.isEmpty))"))
    }

    @Test("Focused Composer Has No Continuous Animation Driver")
    func focusedComposerHasNoContinuousAnimationDriver() throws {
        let composerSource = try source(named: "ChatComposerBar.swift")

        #expect(!composerSource.contains("TimelineView"))
        #expect(!composerSource.contains("minimumInterval: 1.0 / 60.0"))
        #expect(composerSource.contains("aiFocusBorder(shellShape)"))
        #expect(composerSource.contains("AngularGradient("))
    }

    @Test("Composer Capability Controls Use Facade Projection")
    func composerCapabilityControlsUseFacadeProjection() throws {
        let chatViewSource = try source(named: "ChatView.swift")
        let composerSource = try source(named: "ChatComposerBar.swift")

        #expect(chatViewSource.contains("CapabilityEvidenceProductionAdapter.uiDispatchIdentity("))
        #expect(chatViewSource.contains("CapabilityEvidenceProductionAdapter.capabilityProjection("))
        #expect(chatViewSource.contains("CapabilityEvidenceObservationBridge.shared.contentRevision"))
        #expect(composerSource.contains("let visibleCapabilityKeys: Set<String>"))
        #expect(composerSource.contains("let generationProjection: GenerationParameterEvidenceProjection?"))
        #expect(composerSource.contains("CapabilityEvidenceObservationBridge.shared.contentRevision"))
        #expect(!composerSource.contains("currentModel?.reasoningModeAvailable == true"))
        #expect(!composerSource.contains("currentModel?.supportsWebSearchControl == true"))
        #expect(!composerSource.contains("currentModel?.capabilities.contains(.image) == true"))
        #expect(!composerSource.contains("RelayRuntimeSupport.supportsWebSearch("))
    }

    @Test("Generation Defaults Sheet Uses Observed Facade Scope")
    func generationDefaultsSheetUsesObservedFacadeScope() throws {
        let sheetSource = try providerFeatureSource(named: "GenerationParameterDefaultsSheet.swift")

        #expect(sheetSource.contains("CapabilityEvidenceObservationBridge.shared.contentRevision"))
        #expect(sheetSource.contains("partitionID: appState.sessionPartitionUID"))
        #expect(sheetSource.contains("CapabilityEvidenceProductionAdapter.uiDispatchIdentity("))
        #expect(sheetSource.contains("identity: capabilityEvidenceIdentity"))
        #expect(!sheetSource.contains("Timer.scheduledTimer"))
        #expect(!sheetSource.contains("TimelineView"))
    }

    @Test("Empty State Logo Has No Continuous Animation Driver")
    func emptyStateLogoHasNoContinuousAnimationDriver() throws {
        let messageListSource = try source(named: "ChatMessageList.swift")

        #expect(!messageListSource.contains("repeatForever"))
        #expect(!messageListSource.contains("logoBreathing"))
        #expect(messageListSource.contains(".scaleEffect(emptyStateAppeared ? 1.06 : 0.92)"))
    }

    private func source(named filename: String) throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent(filename)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func providerFeatureSource(named filename: String) throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Providers")
            .appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
