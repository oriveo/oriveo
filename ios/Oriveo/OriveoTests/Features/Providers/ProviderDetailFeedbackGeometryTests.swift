import CoreGraphics
import Testing
@testable import Oriveo

@Suite("ProviderDetailFeedbackGeometry")
@MainActor
struct ProviderDetailFeedbackGeometryTests {
    @Test("Source point uses the tapped row frame when available")
    func sourcePointUsesCatalogFrame() {
        let viewport = CGRect(origin: .zero, size: CGSize(width: 200, height: 240))
        let rowFrame = CGRect(x: 10, y: 20, width: 50, height: 30)

        let point = ProviderDetailFeedbackGeometry.sourcePoint(
            rowFrame: rowFrame,
            viewport: viewport
        )

        #expect(point.x == min(10 + 50 - 30, viewport.maxX - 28))
        #expect(point.y == rowFrame.midY)
    }

    @Test("Source point falls back to viewport edge when no frame exists")
    func sourcePointFallbacksWhenFrameMissing() {
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 240)

        let point = ProviderDetailFeedbackGeometry.sourcePoint(
            rowFrame: .null,
            viewport: viewport
        )

        #expect(point.x == viewport.maxX - 28)
        #expect(point.y == max(viewport.midY, 120))
    }

    @Test("Destination point anchors to enabled models frame when visible")
    func destinationPointUsesEnabledModelsFrame() {
        let viewport = CGRect(origin: .zero, size: CGSize(width: 220, height: 400))
        let enabledFrame = CGRect(x: 50, y: 40, width: 100, height: 40)

        let point = ProviderDetailFeedbackGeometry.destinationPoint(
            enabledModelsFrame: enabledFrame,
            viewport: viewport
        )

        #expect(point.x == min(enabledFrame.maxX - 44, viewport.maxX - 32))
        #expect(point.y == max(enabledFrame.minY + 22, 96))
    }

    @Test("Destination point falls back when enabled frame is null")
    func destinationPointFallbacksOnNullFrame() {
        let viewport = CGRect(origin: .zero, size: CGSize(width: 200, height: 300))

        let point = ProviderDetailFeedbackGeometry.destinationPoint(
            enabledModelsFrame: .null,
            viewport: viewport
        )

        #expect(point == CGPoint(x: viewport.maxX - 42, y: 120))
    }

    @Test("Enabled models frame visibility tracks viewport intersection")
    func enabledModelsFrameVisibility() {
        let viewport = CGRect(origin: .zero, size: CGSize(width: 200, height: 400))
        let visibleFrame = CGRect(x: 0, y: 100, width: 50, height: 30)
        let hiddenFrame = CGRect(x: 0, y: 500, width: 50, height: 30)

        #expect(
            ProviderDetailFeedbackGeometry.isEnabledModelsFrameVisible(
                visibleFrame,
                viewport: viewport
            )
        )
        #expect(
            ProviderDetailFeedbackGeometry.isEnabledModelsFrameVisible(
                hiddenFrame,
                viewport: viewport
            ) == false
        )
    }
}
