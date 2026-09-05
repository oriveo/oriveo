import UIKit
import SwiftUI

enum NoteMessageHighlighter {
    @MainActor
    static func flash(_ view: UIView, cornerRadius: CGFloat = 14) {
        let overlay = UIView()
        overlay.backgroundColor = UIColor(OriveoTheme.Palette.primary).withAlphaComponent(0.16)
        overlay.layer.cornerRadius = cornerRadius
        overlay.isUserInteractionEnabled = false
        overlay.alpha = 0
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        UIView.animate(withDuration: 0.25, animations: { overlay.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.7, delay: 0.9, options: []) {
                overlay.alpha = 0
            } completion: { _ in
                overlay.removeFromSuperview()
            }
        }
    }
}
