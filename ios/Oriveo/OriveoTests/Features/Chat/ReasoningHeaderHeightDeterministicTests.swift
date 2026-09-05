import Testing
import UIKit
@testable import Oriveo

/// The reasoning block header must have an unambiguous height, so the whole block does not change
/// height on every frame.
///
/// The defect: the header's `UIButton(type: .system)` brought its own intrinsic height of about
/// 30pt, which fought the roughly 19.7pt the inner header stack computed - an ambiguous height
/// system. While streaming, the cell re-solves its size every frame and flip-flops:
/// `systemLayoutSizeFitting` returns one value and the real layout pass another, so the block
/// oscillated between roughly 41.7 and 52 points and the indicator bar visibly grew and shrank.
/// Earlier tests only exercised `systemLayoutSizeFitting`, which is self-consistent, and never
/// compared it with the real layout. This suite pins "measured height == laid-out height" and
/// "repeated layout passes give a constant height".
@Suite("Reasoning header height is deterministic")
@MainActor
struct ReasoningHeaderHeightDeterministicTests {
    private static let width: CGFloat = 332

    private func makeHostedBlock(reasoning: String, streaming: Bool) -> (UIKitReasoningBlock, UIView) {
        let block = UIKitReasoningBlock()
        block.configure(text: reasoning, durationMs: nil, isStreaming: streaming, hasMainText: false)
        block.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 600))
        host.addSubview(block)
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            block.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            block.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutIfNeeded()
        return (block, host)
    }

    @Test("Measure Equals Layout")
    func measureEqualsLayout() {
        let (block, _) = makeHostedBlock(
            reasoning: "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほま", streaming: true)
        let measured = block.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        let laidOut = block.bounds.height
        #expect(abs(measured - laidOut) < 1.0,
                Comment(rawValue: "measured height differs from the laid-out height, which is what makes it jump every frame: measured=\(measured) laidOut=\(laidOut)"))
    }

    @Test("Height Stable Across Self Size Cycles")
    func heightStableAcrossSelfSizeCycles() {
        let (block, host) = makeHostedBlock(
            reasoning: "かきくけこさしすせそたちつてとなにぬねのはひふへほまみむ", streaming: true)
        var heights: [CGFloat] = []
        for _ in 0..<8 {
            let measured = block.systemLayoutSizeFitting(
                CGSize(width: Self.width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            host.frame = CGRect(x: 0, y: 0, width: Self.width, height: measured)
            block.setNeedsLayout()
            host.layoutIfNeeded()
            heights.append(block.bounds.height)
        }
        let distinct = Set(heights.map { ($0 * 2).rounded() / 2 })
        #expect(distinct.count == 1,
                Comment(rawValue: "the block height changes between layout passes: distinct=\(distinct.sorted()) heights=\(heights.map { Int($0) })"))
    }
}
