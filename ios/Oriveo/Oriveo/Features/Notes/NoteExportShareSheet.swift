import SwiftUI
import UIKit

enum NoteExporter {
    @MainActor
    static func share(note: Note, from appState: AppState) {
        let markdown = NoteMarkdownExporter.markdown(for: note)
        let filename = NoteMarkdownExporter.filename(for: note)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try markdown.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            return
        }

        guard let topVC = Self.topViewController() else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = topVC.view
            pop.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        topVC.present(activity, animated: true)
        ToastManager.shared.show(L10n.tr("Markdown exported", table: .notes), style: .success, duration: 3)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
