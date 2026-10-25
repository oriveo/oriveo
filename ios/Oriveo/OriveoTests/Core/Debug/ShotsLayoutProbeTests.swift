#if DEBUG
import CoreGraphics
import Testing
@testable import Oriveo

/// Truncation estimate of the screenshot probe: the label of a merged accessibility element is the system's join
/// of its lines with the ideographic comma or ", ", and every line lays out on its own line, so it must not be
/// measured as one continuous run of text (a Chinese "recording interrupted" card was once falsely reported as truncated).
@Suite("Screenshot probe truncation estimate")
@MainActor
struct ShotsLayoutProbeTests {
    // Chinese "Recording interrupted" and "Recording saved" joined by the ideographic comma (U+3001)
    private static let mergedChinese = "\u{5F55}\u{97F3}\u{88AB}\u{6253}\u{65AD}\u{3001}\u{5F55}\u{97F3}\u{5DF2}\u{4FDD}\u{5B58}"

    @Test("combinedLabelNotTruncated: a merged two-line element (title, subtitle) is not truncated when every line fits")
    func combinedLabelNotTruncated() {
        let zh = ShotsLayoutProbe.estimateTruncated(Self.mergedChinese, in: CGRect(x: 0, y: 0, width: 74.67, height: 35.67))
        #expect(zh == false)
        let en = ShotsLayoutProbe.estimateTruncated("Recording interrupted, Recording saved", in: CGRect(x: 0, y: 0, width: 157.67, height: 35.67))
        #expect(en == false)
    }

    @Test("singleLineOverflowStillTruncated: long text that does not fit a single-line box is still truncated")
    func singleLineOverflowStillTruncated() {
        let long = ShotsLayoutProbe.estimateTruncated(
            "Recording interrupted and the recording has been saved on this device",
            in: CGRect(x: 0, y: 0, width: 120, height: 17.9)
        )
        #expect(long == true)
        let segments = ShotsLayoutProbe.estimateTruncated(Self.mergedChinese, in: CGRect(x: 0, y: 0, width: 74.67, height: 17.9))
        #expect(segments == true)
    }
}
#endif
