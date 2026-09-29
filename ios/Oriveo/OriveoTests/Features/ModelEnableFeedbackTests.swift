import Foundation
import Testing
@testable import Oriveo

/// Feedback after tapping "+" on a model catalog row: a toast on success, an error toast when
/// the model cannot be found, and silence when an equivalent model is already enabled.
@MainActor
struct ModelEnableFeedbackTests {
    @Test("added: success style with the model name in the copy")
    func addedShowsSuccessToast() throws {
        let feedback = try #require(ModelEnableFeedback.feedback(for: .added(modelName: "GPT-4.1")))
        #expect(feedback.style == .success)
        #expect(feedback.message.contains("GPT-4.1"))
    }

    @Test("not found: error style, never silent")
    func notFoundShowsErrorToast() throws {
        let feedback = try #require(ModelEnableFeedback.feedback(for: .notFound))
        #expect(feedback.style == .error)
        #expect(!feedback.message.isEmpty)
    }

    @Test("already enabled: idempotent, no toast")
    func alreadyEnabledIsSilent() {
        #expect(ModelEnableFeedback.feedback(for: .alreadyEnabled) == nil)
    }

    @Test("announce hands the feedback to the toast manager")
    func announceReachesToastManager() {
        ToastManager.shared.show("stale", style: .neutral)
        ModelEnableFeedback.announce(.added(modelName: "GPT-4.1"))
        #expect(ToastManager.shared.current?.style == .success)
        #expect(ToastManager.shared.current?.message.contains("GPT-4.1") == true)
    }

    /// The global `ToastOverlay` is mounted on AppRootView, while a `.sheet` is presented above it, so a
    /// toast raised from the model picker would be hidden. A unit test cannot render the sheet's layering
    /// on iOS, so this asserts on the source: the picker must mount its own `ToastOverlay`.
    @Test("model picker mounts its own ToastOverlay so the sheet does not cover the toast")
    func modelPickerHostsItsOwnToastOverlay() throws {
        let source = try String(contentsOfFile: modelPickerSourcePath(), encoding: .utf8)
        let start = try #require(source.range(of: "struct ModelPickerSheet: View {"))
        let end = try #require(source.range(of: "// MARK: - Content", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        #expect(
            body.contains(".overlay { ToastOverlay() }"),
            "ModelPickerSheet is presented by .sheet; the root ToastOverlay cannot reach it"
        )
    }

    private func modelPickerSourcePath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // project root
            .appendingPathComponent("Oriveo/Features/Home/HomeModelPickerSheet.swift")
            .path
    }
}
