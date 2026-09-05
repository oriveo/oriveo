import Foundation

struct BlockCommitCadence: Sendable {
    var wordChunkLenASCII = 12
    var wordChunkLenCJK = 6

    var chunkDelay: TimeInterval = 0.10
    var lineEndDelay: TimeInterval = 0.14
    var paragraphDelay: TimeInterval = 0.18
    var tableRowDelay: TimeInterval = 0.10

    var fadeDuration: TimeInterval = 0.25
    var maxActiveChunkFades = 24

    var fadeStaggerThresholdUTF16 = 16
    var fadeStaggerSegmentUTF16 = 12
    var fadeStaggerStep: TimeInterval = 0.045
    var fadeStaggerMaxDelay: TimeInterval = 0.30

    var catchupBacklogUTF16 = 400
    var catchupDelayScale = 0.5

    var maxInlineHoldUTF16 = 120

    var maxWordHoldUTF16 = 48

    var multiLineBacklog = 1_500
    var multiLineMax = 3

    static let `default` = BlockCommitCadence()
}
