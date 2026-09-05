//  ProviderKeyInputTests.swift
//  OriveoTests

import Foundation
import Testing
@testable import Oriveo

@Suite("Provider Key Input Tests")
struct ProviderKeyInputTests {

    @Test("Accepts Common Keys")
    func acceptsCommonKeys() {
        #expect(ProviderKeyInput.isPrintableASCII("sk-1234567890ABCDEFabcdef"))
        #expect(ProviderKeyInput.isPrintableASCII("sk-ant-api03-AaBbCc1234"))
        #expect(ProviderKeyInput.isPrintableASCII("AIzaSy0123-_AAAA1234"))
        #expect(ProviderKeyInput.isPrintableASCII("yls-64164880eb21a6377e77349ae9ecd5b0fc6200ef0a3d0c8120260413"))
    }

    @Test("Rejects Empty")
    func rejectsEmpty() {
        #expect(!ProviderKeyInput.isPrintableASCII(""))
    }

    @Test("Rejects Newline And Pasted Junk")
    func rejectsNewlineAndPastedJunk() {
        #expect(!ProviderKeyInput.isPrintableASCII("yls-64164880eb21a6377e77349ae9ecd5b0fc6200ef0a3d0c8120260413\nI'll compile this into a final checklist for you."))
        #expect(!ProviderKeyInput.isPrintableASCII("sk-test\nabc"))
        #expect(!ProviderKeyInput.isPrintableASCII("sk-test\tabc"))
        #expect(!ProviderKeyInput.isPrintableASCII("sk-test\r\nabc"))
    }

    @Test("Rejects Non Ascii")
    func rejectsNonAscii() {
        #expect(!ProviderKeyInput.isPrintableASCII("sk-かなkey"))
        #expect(!ProviderKeyInput.isPrintableASCII("sk-test\u{3000}abc"))
        #expect(!ProviderKeyInput.isPrintableASCII("sk-test\u{200B}abc"))
        #expect(!ProviderKeyInput.isPrintableASCII("\u{FEFF}sk-test"))      // BOM
    }

    @Test("Accepts Inner Half Width Space")
    func acceptsInnerHalfWidthSpace() {
        #expect(ProviderKeyInput.isPrintableASCII("sk a"))
    }
}
