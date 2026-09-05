import XCTest
@testable import Oriveo

final class StreamingPacerLanguageProfileTests: XCTestCase {
    func testDetectCJKDominantContent() {
        let cjk = "にほんご hello"  // 4 kana / 9 letter = 44% > 30%
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: cjk), .cjk)
    }

    func testDetectAsciiDominantContent() {
        let ascii = "hello world あ"  // 1 kana / 11 letter = 9% < 30%
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: ascii), .ascii)
    }

    func testEmptyDefaultsToAscii() {
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: ""), .ascii)
    }

    func testOnlyPunctuationDefaultsToAscii() {
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: "!@#$ ,. "), .ascii)
    }

    func testKanaIsCJK() {
        let kana = "こんにちは hello"  // 5 kana / 10 letter = 50% > 30%
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: kana), .cjk)
    }

    func testHangulIsCJK() {
        let hangul = "안녕 hello"
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: hangul), .ascii)

        let majorityHangul = "안녕하세요 hi"  // 5 hangul / 7 letter = 71% → cjk
        XCTAssertEqual(StreamingPacerLanguageProfile.detect(in: majorityHangul), .cjk)
    }

    func testCJKStepSizeNotGreaterThanAscii() {
        let cjkHighBacklog = StreamingPacerLanguageProfile.cjk.stepSize(for: 1000)
        let asciiHighBacklog = StreamingPacerLanguageProfile.ascii.stepSize(for: 1000)
        XCTAssertLessThanOrEqual(cjkHighBacklog, asciiHighBacklog)

        let cjkExtreme = StreamingPacerLanguageProfile.cjk.stepSize(for: 5000)
        let asciiExtreme = StreamingPacerLanguageProfile.ascii.stepSize(for: 5000)
        XCTAssertLessThan(cjkExtreme, asciiExtreme)
    }

    func testCJKDelayLongerThanAscii() {
        XCTAssertGreaterThan(
            StreamingPacerLanguageProfile.cjk.frameDelay,
            StreamingPacerLanguageProfile.ascii.frameDelay
        )
        XCTAssertGreaterThan(
            StreamingPacerLanguageProfile.cjk.lineDelay,
            StreamingPacerLanguageProfile.ascii.lineDelay
        )
        XCTAssertGreaterThan(
            StreamingPacerLanguageProfile.cjk.finalFrameDelay,
            StreamingPacerLanguageProfile.ascii.finalFrameDelay
        )
        XCTAssertGreaterThan(
            StreamingPacerLanguageProfile.cjk.finalLineDelay,
            StreamingPacerLanguageProfile.ascii.finalLineDelay
        )
    }

    func testStepSizeMonotonic() {
        for profile in [StreamingPacerLanguageProfile.ascii, .cjk] {
            var prev = 0
            for backlog in stride(from: 0, through: 2000, by: 100) {
                let step = profile.stepSize(for: backlog)
                XCTAssertGreaterThanOrEqual(step, prev, "profile=\(profile) backlog=\(backlog)")
                prev = step
            }
        }
    }
}
