import CoreGraphics
import Foundation

///    `inset = max(minBottomPadding, anchorTopY + viewportHeight − contentHeight)`.
@MainActor
final class ChatStickToBottomController {


    static let atBottomThreshold: CGFloat = 80

    static let streamingRunwayViewportRatio: CGFloat = 0.75

    nonisolated static let minBottomPadding: CGFloat = 8


    private weak var geometry: ChatStickToBottomGeometry?

    private let writeBottomInset: (CGFloat) -> Void

    private let writeOffset: (_ y: CGFloat, _ animated: Bool) -> Void

    private let hasStreamingContent: () -> Bool


    private(set) var isFollowing = true

    private(set) var isStreamingMode = false

    private var lastWrittenInset: CGFloat = .nan
    private var lastWrittenOffset: CGFloat = .nan
    private let dedupEpsilon: CGFloat
    private let displayScale: CGFloat

    private var currentRunway: CGFloat = 0

    private var runwayOpenedThisRound = false

    // MARK: - Init

    private let minPadding: CGFloat

    init(
        geometry: ChatStickToBottomGeometry,
        minBottomPadding: CGFloat = ChatStickToBottomController.minBottomPadding,
        displayScale: CGFloat = 1.0,
        hasStreamingContent: @escaping () -> Bool = { true },
        writeBottomInset: @escaping (CGFloat) -> Void,
        writeOffset: @escaping (_ y: CGFloat, _ animated: Bool) -> Void
    ) {
        self.geometry = geometry
        self.minPadding = minBottomPadding
        self.displayScale = displayScale > 0 ? displayScale : 1.0
        self.dedupEpsilon = displayScale > 1.0 ? (1.0 / displayScale) : 0.1
        self.hasStreamingContent = hasStreamingContent
        self.writeBottomInset = writeBottomInset
        self.writeOffset = writeOffset
    }

    private func pixelAlign(_ value: CGFloat) -> CGFloat {
        guard displayScale > 1.0 else { return value }
        return (value * displayScale).rounded() / displayScale
    }


    func desiredBottomInset() -> CGFloat {
        let obstruction = geometry?.bottomObstruction ?? 0
        guard let geometry, let top = geometry.anchorTopY else {
            return minPadding + obstruction
        }
        let needed = top + geometry.viewportHeight - geometry.contentHeight
        return max(minPadding, needed) + obstruction
    }

    func maxOffset(bottomInset: CGFloat) -> CGFloat {
        guard let geometry else { return 0 }
        return max(0, geometry.contentHeight + bottomInset - geometry.viewportHeight)
    }


    func reconcile(animated: Bool = false) {
        let base = reconcileInset()
        guard isFollowing else { return }
        let target = pixelAlign(maxOffset(bottomInset: base))
        if !lastWrittenOffset.isFinite || abs(target - lastWrittenOffset) >= dedupEpsilon {
            writeOffset(target, animated)
            lastWrittenOffset = target
        }
    }

    func reconcileInsetOnly() {
        _ = reconcileInset()
    }

    @discardableResult
    private func reconcileInset() -> CGFloat {
        refreshRunway()
        let base = desiredBottomInset()
        let inset = pixelAlign(base + currentRunway)
        if !lastWrittenInset.isFinite || abs(inset - lastWrittenInset) >= dedupEpsilon {
            writeBottomInset(inset)
            lastWrittenInset = inset
        }
        return base
    }

    func streamingRunway() -> CGFloat {
        currentRunway
    }

    private func refreshRunway() {
        guard isStreamingMode, let geometry else {
            currentRunway = 0
            return
        }
        if !runwayOpenedThisRound, hasStreamingContent() {
            runwayOpenedThisRound = true
        }
        currentRunway = runwayOpenedThisRound
            ? geometry.viewportHeight * Self.streamingRunwayViewportRatio
            : 0
    }

    func reconcileForViewportChange(animated: Bool = false) {
        if !isStreamingMode,
           let geometry,
           geometry.distanceFromBottom < Self.atBottomThreshold {
            isFollowing = true
            lastWrittenOffset = .nan
        }
        reconcile(animated: animated)
    }

    func setStreamingMode(_ enabled: Bool) {
        guard isStreamingMode != enabled else { return }
        isStreamingMode = enabled
        if enabled {
            isFollowing = false
            currentRunway = 0
            runwayOpenedThisRound = false
        } else {
            if let geometry {
                isFollowing = geometry.distanceFromBottom < Self.atBottomThreshold + currentRunway
            }
            currentRunway = 0
            runwayOpenedThisRound = false
        }
    }

    func pinToAnchor(animated: Bool) {
        refreshRunway()
        let base = desiredBottomInset()
        let inset = pixelAlign(base + currentRunway)
        writeBottomInset(inset)
        lastWrittenInset = inset
        let target = pixelAlign(maxOffset(bottomInset: base))
        writeOffset(target, animated)
        lastWrittenOffset = target
    }

    func settle() {
        guard let geometry else { return }
        guard !isStreamingMode else { return }
        isFollowing = geometry.distanceFromBottom < Self.atBottomThreshold
    }

    func userDidGrab() {
        isFollowing = false
        lastWrittenOffset = .nan
    }

    func invalidateOffsetBaseline() {
        lastWrittenOffset = .nan
    }

    func resumeFollowing(animated: Bool) {
        isFollowing = true
        lastWrittenOffset = .nan
        reconcile(animated: animated)
    }

    func reset() {
        isFollowing = true
        isStreamingMode = false
        currentRunway = 0
        runwayOpenedThisRound = false
        lastWrittenOffset = .nan
        let aligned = pixelAlign(minPadding)
        writeBottomInset(aligned)
        lastWrittenInset = aligned
    }
}
