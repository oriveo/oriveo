import CoreGraphics

struct ProviderDetailFeedbackGeometry {
    static func sourcePoint(
        rowFrame: CGRect,
        viewport: CGRect
    ) -> CGPoint {
        if !rowFrame.isNull {
            return CGPoint(
                x: min(rowFrame.maxX - 30, viewport.maxX - 28),
                y: rowFrame.midY
            )
        }

        return CGPoint(x: viewport.maxX - 28, y: max(viewport.midY, 120))
    }

    static func destinationPoint(
        enabledModelsFrame: CGRect,
        viewport: CGRect
    ) -> CGPoint {
        guard !enabledModelsFrame.isNull else {
            return CGPoint(x: viewport.maxX - 42, y: 120)
        }

        return CGPoint(
            x: min(enabledModelsFrame.maxX - 44, viewport.maxX - 32),
            y: max(enabledModelsFrame.minY + 22, 96)
        )
    }

    static func isEnabledModelsFrameVisible(
        _ frame: CGRect,
        viewport: CGRect
    ) -> Bool {
        frame.isVisible(in: viewport)
    }
}
