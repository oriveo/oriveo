import SwiftUI
import UIKit

struct ChatExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ChatExportShareSheet: UIViewControllerRepresentable {
    let item: URL
    let onCompletion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onCompletion(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
