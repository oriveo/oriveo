import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Saving to the photo library: only the UIImageWriteToSavedPhotosAlbum system boundary is replaced,
/// everything else runs the production path. A failure must not show "Saved"; it shows an error toast.
@MainActor
@Suite("PhotoAlbumSaveResult", .serialized)
struct PhotoAlbumSaveResultTests {
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }

    /// Mimics UIKit: calls the target's completion asynchronously, with or without an error.
    private func writer(failing: Bool) -> PhotoAlbumWriter {
        { image, target, _, contextInfo in
            let completion = target as! PhotoAlbumSaveCompletion
            let error: Error? = failing ? NSError(domain: "ALAssetsLibraryErrorDomain", code: -3310) : nil
            DispatchQueue.main.async {
                completion.image(image, didFinishSavingWithError: error, contextInfo: contextInfo)
            }
        }
    }

    @Test("A failed write returns false, a successful one returns true")
    func writeReportsRealResult() async {
        #expect(await writeImageToPhotoAlbum(image, writer: writer(failing: true)) == false)
        #expect(await writeImageToPhotoAlbum(image, writer: writer(failing: false)) == true)
    }

    @Test("A failure does not show Saved and shows an error toast")
    func failureKeepsIdleAndShowsErrorToast() async {
        var saved = false
        let binding = Binding(get: { saved }, set: { saved = $0 })
        ToastManager.shared.show("seed", style: .neutral)

        await saveToPhotosReportingResult(image, saved: binding, writer: writer(failing: true))

        #expect(saved == false)
        #expect(ToastManager.shared.current?.style == .error)
        #expect(ToastManager.shared.current?.message == L10n.tr("Failed to save image"))
    }

    @Test("Only a success shows Saved, with no error toast")
    func successFlipsToSaved() async {
        var saved = false
        let binding = Binding(get: { saved }, set: { saved = $0 })
        ToastManager.shared.show("seed", style: .neutral)

        await saveToPhotosReportingResult(image, saved: binding, writer: writer(failing: false))

        #expect(saved == true)
        #expect(ToastManager.shared.current?.style == .neutral)
    }
}
