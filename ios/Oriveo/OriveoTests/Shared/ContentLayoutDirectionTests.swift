import SwiftUI
import Testing
@testable import Oriveo

// Content direction follows the first strong character.

@Suite("ContentLayoutDirection")
struct ContentLayoutDirectionTests {
    @Test func arabic_text_is_right_to_left() {
        #expect(ContentLayoutDirection.layoutDirection(for: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", fallback: .leftToRight) == .rightToLeft)
    }

    @Test func english_text_is_left_to_right() {
        #expect(ContentLayoutDirection.layoutDirection(for: "Hello world", fallback: .rightToLeft) == .leftToRight)
    }

    @Test func text_without_strong_characters_uses_the_fallback() {
        #expect(ContentLayoutDirection.layoutDirection(for: "123 ?!", fallback: .rightToLeft) == .rightToLeft)
        #expect(ContentLayoutDirection.layoutDirection(for: "", fallback: .leftToRight) == .leftToRight)
    }

    @Test func leading_latin_command_wins_over_later_arabic() {
        #expect(ContentLayoutDirection.layoutDirection(for: "/weekly \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", fallback: .rightToLeft) == .leftToRight)
    }
}
