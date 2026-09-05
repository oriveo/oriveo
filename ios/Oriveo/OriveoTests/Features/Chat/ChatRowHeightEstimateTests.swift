import CoreGraphics
import Foundation
import Testing
@testable import Oriveo

/// Pure-function tests for `ChatListViewController.estimatedRowHeight`.
///
/// Replacing a flat `.estimated(80)` in `sizeForItem` with a content-aware estimate keeps the
/// layout's content size close to the truth from the start, so a cell resolving its real height
/// while scrolling barely corrects anything and the list does not jump.
///
/// The estimate is a heuristic, so these tests pin invariants only - much better than a flat 80,
/// monotonic in length, code and tables taller, CJK taller, plus a lower bound and an absolute
/// upper bound - and never a fragile exact pixel value, because cell self-sizing supplies the real
/// height anyway.
@Suite("Chat Row Height Estimate Tests")
struct ChatRowHeightEstimateTests {
    private static let width: CGFloat = 390

    private func row(_ text: String, role: ChatRole = .assistant) -> ChatCollectionProjectionBuilder.MessageRow {
        let message = ChatMessage(
            id: UUID(), role: role, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        return ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty)[0]
    }

    private func height(_ text: String, role: ChatRole = .assistant) -> CGFloat {
        ChatListViewController.estimatedRowHeight(for: row(text, role: role), width: Self.width)
    }

    @Test("Min Floor")
    func minFloor() {
        #expect(height("Hi") >= 44)
    }

    @Test("Monotonic In Length")
    func monotonicInLength() {
        let short = height(String(repeating: "word ", count: 5))
        let long = height(String(repeating: "word ", count: 500))
        #expect(long > short)
    }

    @Test("Long Content Much Taller Than Flat80")
    func longContentMuchTallerThanFlat80() {
        let long = height(String(repeating: "あいうえおかきくけこさしす。", count: 80))
        #expect(long > 400)
    }

    @Test("Short Code Block Taller Than Plain")
    func shortCodeBlockTallerThanPlain() {
        let body = String(repeating: "let x = compute(value)\n", count: 3)
        let plain = height(body)
        let code = height("```swift\n\(body)```")
        #expect(code > plain)
    }

    // MARK: - Magnitude bounds
    //
    // Everything above asserts monotonicity (long > short, code > plain, CJK > ASCII), but the whole
    // point of this function is that the magnitude is right. Monotonic assertions cannot catch a
    // systematic overestimate: three separate overestimates each stayed monotonic while together
    // they inflated the estimate fourfold and passed every existing assertion. The tests below pin
    // absolute upper bounds.

    @Test("Long Code Block Is Capped At Preview Height")
    func longCodeBlockIsCappedAtPreviewHeight() {
        let line = "    let value = compute(input, index)\n"
        let long = height("```swift\n\(String(repeating: line, count: 200))```")
        #expect(long < 600)
        let shorter = height("```swift\n\(String(repeating: line, count: 60))```")
        #expect(abs(long - shorter) < 1)
    }

    @Test("Newlines Are Not Double Counted")
    func newlinesAreNotDoubleCounted() {
        let text = String(repeating: "- あいのうえおです\n", count: 40)
        #expect(height(text) > 900)
        #expect(height(text) < 1200)
    }

    @Test("Single CJK Character Does Not Widen Whole Message")
    func singleCJKCharacterDoesNotWidenWholeMessage() {
        let ascii = String(repeating: "the quick brown fox ", count: 60)
        #expect(height(ascii + ".") < height(ascii) * 1.15)
    }

    @Test("Wrapped Line Scan Is Bounded")
    func wrappedLineScanIsBounded() {
        let budget = ChatListViewController.maxEstimateScanCharacters
        let within = String(repeating: "a", count: budget / 2)
        let beyond = String(repeating: "a", count: budget * 4)
        #expect(ChatListViewController.estimatedWrappedLines(
            in: beyond, contentWidth: 358, fullCharWidth: 16, halfCharWidth: 8.5
        ) > ChatListViewController.estimatedWrappedLines(
            in: within, contentWidth: 358, fullCharWidth: 16, halfCharWidth: 8.5
        ))
    }

    @Test("Full Width Classification")
    func fullWidthClassification() {
        for character in ["🙂", "あ", "ア", "한", "。", "，", "Ａ"] as [Character] {
            #expect(ChatListViewController.isFullWidth(character))
        }
        for character in ["a", "Z", "0", " ", "-", "|", "é"] as [Character] {
            #expect(!ChatListViewController.isFullWidth(character))
        }
    }

    @Test("Cjk Taller Than Ascii")
    func cjkTallerThanAscii() {
        let cjk = height(String(repeating: "あ", count: 200))
        let ascii = height(String(repeating: "a", count: 200))
        #expect(cjk > ascii)
    }

    @Test("Both Roles Produce Reasonable Height")
    func bothRolesProduceReasonableHeight() {
        #expect(height("Hello there", role: .user) >= 44)
        #expect(height("Hello there", role: .assistant) >= 44)
    }


    private func imageRow(_ text: String, role: ChatRole = .assistant) -> ChatCollectionProjectionBuilder.MessageRow {
        let att = Attachment(id: UUID(), kind: .image, fileName: "img.png", mimeType: "image/png")
        let message = ChatMessage(
            id: UUID(), role: role, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: [att], citations: nil
        )
        return ChatCollectionProjectionBuilder.makeRows(from: [message], metadata: .empty)[0]
    }

    @Test("Image Attachment Adds Height")
    func imageAttachmentAddsHeight() {
        let textOnly = height("look at this image")
        let withImage = ChatListViewController.estimatedRowHeight(for: imageRow("look at this image"), width: Self.width)
        #expect(withImage > textOnly + 150)
    }


    @Test("Failed Last Row Includes Recovery Card Height")
    func failedLastRowIncludesRecoveryCardHeight() {
        let failed = ChatMessage(
            id: UUID(), role: .assistant, text: "",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .failed,
            errorTitle: "Send Failed",
            errorDetail: "HTTP 429 rate limited"
        )
        let delivered = ChatMessage(
            id: UUID(), role: .assistant, text: "",
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            state: .delivered
        )
        let failedRow = ChatCollectionProjectionBuilder.makeRows(from: [failed], metadata: .empty)[0]
        let deliveredRow = ChatCollectionProjectionBuilder.makeRows(from: [delivered], metadata: .empty)[0]
        let withCard = ChatListViewController.estimatedRowHeight(for: failedRow, width: Self.width)
        let withoutCard = ChatListViewController.estimatedRowHeight(for: deliveredRow, width: Self.width)
        #expect(withCard > withoutCard + 150)
        #expect(withCard > 200)
    }

    @Test("Non Last Failed Row Excludes Recovery Card Height")
    func nonLastFailedRowExcludesRecoveryCardHeight() {
        let failed = ChatMessage(
            id: UUID(), role: .assistant, text: "", providerKind: .openAI,
            providerName: "OpenAI", modelName: "GPT-4o", state: .failed
        )
        let follow = ChatMessage(
            id: UUID(), role: .user, text: "try again", providerKind: .openAI,
            providerName: "OpenAI", modelName: "GPT-4o", state: .delivered
        )
        let rows = ChatCollectionProjectionBuilder.makeRows(from: [failed, follow], metadata: .empty)
        #expect(rows[0].isLastInConversation == false)
        let h = ChatListViewController.estimatedRowHeight(for: rows[0], width: Self.width)
        #expect(h < 150)
    }

    @Test("Recovery Card Height Pure Invariants")
    func recoveryCardHeightPureInvariants() {
        let wide = ChatListViewController.estimatedRecoveryCardHeight(charsPerLine: 70)
        let narrow = ChatListViewController.estimatedRecoveryCardHeight(charsPerLine: 18)
        #expect(narrow > wide)
        #expect(ChatListViewController.estimatedRecoveryCardHeight(charsPerLine: 0) > 0)
    }

    @Test("Images Height Pure Invariants")
    func imagesHeightPureInvariants() {
        let one = ChatListViewController.estimatedImagesHeight(imageWidth: 300, ratios: [1.0])
        let two = ChatListViewController.estimatedImagesHeight(imageWidth: 300, ratios: [1.0, 1.0])
        #expect(two > one)
        let portrait = ChatListViewController.estimatedImagesHeight(imageWidth: 300, ratios: [0.5])
        let landscape = ChatListViewController.estimatedImagesHeight(imageWidth: 300, ratios: [2.0])
        #expect(portrait > landscape)
        #expect(ChatListViewController.estimatedImagesHeight(imageWidth: 300, ratios: [0]) > 0)
    }
}
