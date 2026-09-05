import Testing
import Foundation
@testable import Oriveo

@Suite("ISO8601 Parser Tests")
struct ISO8601ParserTests {

    @Test("Parse Web Millisecond ISO")
    func parseWebMillisecondISO() {
        let parsed = ISO8601Parser.date(from: "2026-05-09T10:30:45.123Z")
        #expect(parsed != nil)
    }

    @Test("Parse Android Nanosecond ISO")
    func parseAndroidNanosecondISO() {
        let parsed = ISO8601Parser.date(from: "2026-05-09T10:30:45.123456789Z")
        #expect(parsed != nil)
    }

    @Test("Parsei OSPlain ISO")
    func parseiOSPlainISO() {
        let parsed = ISO8601Parser.date(from: "2026-05-09T10:30:45Z")
        #expect(parsed != nil)
    }

    @Test("Parse Invalid String Returns Nil")
    func parseInvalidStringReturnsNil() {
        #expect(ISO8601Parser.date(from: "") == nil)
        #expect(ISO8601Parser.date(from: "not-a-date") == nil)
        #expect(ISO8601Parser.date(from: "2026-05-09") == nil)
    }

    @Test("Equivalent Timestamps Parse To Same Second")
    func equivalentTimestampsParseToSameSecond() {
        let webStyle = ISO8601Parser.date(from: "2026-05-09T10:30:45.000Z")
        let androidStyle = ISO8601Parser.date(from: "2026-05-09T10:30:45.000000000Z")
        let iosStyle = ISO8601Parser.date(from: "2026-05-09T10:30:45Z")
        #expect(webStyle != nil)
        #expect(androidStyle != nil)
        #expect(iosStyle != nil)
        if let w = webStyle, let a = androidStyle, let i = iosStyle {
            #expect(abs(w.timeIntervalSince1970 - i.timeIntervalSince1970) < 0.001)
            #expect(abs(a.timeIntervalSince1970 - i.timeIntervalSince1970) < 0.001)
        }
    }
}
