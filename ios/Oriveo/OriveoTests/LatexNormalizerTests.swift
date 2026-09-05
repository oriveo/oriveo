import XCTest
@testable import Oriveo

final class LatexNormalizerTests: XCTestCase {

    func test_inlineDelimiters_converted() {
        let input = #"Euler: \(e^{i\pi} + 1 = 0\)"#
        let expected = #"Euler: $e^{i\pi} + 1 = 0$"#
        XCTAssertEqual(LatexNormalizer.normalize(input), expected)
    }

    func test_blockDelimiters_converted_singleLine() {
        let input = #"Consider \[x^2 + y^2 = z^2\] above."#
        let expected = "Consider $$x^2 + y^2 = z^2$$ above."
        XCTAssertEqual(LatexNormalizer.normalize(input), expected)
    }

    func test_blockDelimiters_converted_multiLine() {
        let input = """
        Display:
        \\[
        x = \\frac{-b}{2a}
        \\]
        end
        """
        let expected = """
        Display:
        $$
        x = \\frac{-b}{2a}
        $$
        end
        """
        XCTAssertEqual(LatexNormalizer.normalize(input), expected)
    }

    func test_multipleInline_inSameText() {
        let input = #"\(a\) plus \(b\) equals \(c\)"#
        let expected = "$a$ plus $b$ equals $c$"
        XCTAssertEqual(LatexNormalizer.normalize(input), expected)
    }

    func test_mixedBlockAndInline() {
        let input = #"Solve \(ax^2\) then \[bx + c = 0\] later."#
        let expected = "Solve $ax^2$ then $$bx + c = 0$$ later."
        XCTAssertEqual(LatexNormalizer.normalize(input), expected)
    }


    func test_noLatex_returnedUnchanged() {
        let input = "Hello world, no math here."
        XCTAssertEqual(LatexNormalizer.normalize(input), input)
    }

    func test_inline_acrossNewline_notConverted() {
        let input = "Try \\(x +\ny\\) here."
        XCTAssertEqual(LatexNormalizer.normalize(input), input)
    }

    func test_unclosedBlock_notConverted() {
        let input = "Begin \\[ x^2 without close"
        XCTAssertEqual(LatexNormalizer.normalize(input), input)
    }

    func test_unclosedInline_notConverted() {
        let input = "Try \\( something without close"
        XCTAssertEqual(LatexNormalizer.normalize(input), input)
    }


    func test_fencedCodeBlock_protected() {
        let input = """
        Math inline: \\(x\\)
        ```python
        # comment with \\(not_math\\) inside
        print("\\[also_not_math\\]")
        ```
        After: \\[y\\]
        """
        let result = LatexNormalizer.normalize(input)
        XCTAssertTrue(result.contains("# comment with \\(not_math\\) inside"))
        XCTAssertTrue(result.contains("\"\\[also_not_math\\]\""))
        XCTAssertTrue(result.contains("Math inline: $x$"))
        XCTAssertTrue(result.contains("After: $$y$$"))
    }

    func test_tildeFencedCodeBlock_protected() {
        let input = """
        ~~~
        \\(should_stay\\)
        ~~~
        \\(should_convert\\)
        """
        let result = LatexNormalizer.normalize(input)
        XCTAssertTrue(result.contains("\\(should_stay\\)"))
        XCTAssertTrue(result.contains("$should_convert$"))
    }

    func test_inlineCode_protected() {
        let input = "Use `\\(x\\)` to write inline math. Then \\(y\\) outside."
        let result = LatexNormalizer.normalize(input)
        XCTAssertTrue(result.contains("`\\(x\\)`"))
        XCTAssertTrue(result.contains("$y$"))
    }

    func test_doubleBacktickInlineCode_protected() {
        let input = "Code: ``\\[stay\\]`` and math \\[go\\]."
        let result = LatexNormalizer.normalize(input)
        XCTAssertTrue(result.contains("``\\[stay\\]``"))
        XCTAssertTrue(result.contains("$$go$$"))
    }


    func test_blockTakesPrecedence_overInlinePattern() {
        let input = #"\[a + \(b\) = c\]"#
        let result = LatexNormalizer.normalize(input)
        XCTAssertEqual(result, "$$a + $b$ = c$$")
    }


    func test_emptyString() {
        XCTAssertEqual(LatexNormalizer.normalize(""), "")
    }

    func test_onlyOpeningEscapeSlash() {
        let input = #"\just a slash"#
        XCTAssertEqual(LatexNormalizer.normalize(input), input)
    }

    func test_consecutiveInlineFormulas() {
        let input = #"\(a\)\(b\)"#
        XCTAssertEqual(LatexNormalizer.normalize(input), "$a$$b$")
    }


    func test_realisticAssistantOutput() {
        let input = """
        The Pythagorean theorem states that \\(a^2 + b^2 = c^2\\) where \\(c\\) is the hypotenuse.

        For a right triangle:
        \\[
        c = \\sqrt{a^2 + b^2}
        \\]

        Example: if \\(a = 3\\) and \\(b = 4\\), then \\(c = 5\\).
        """
        let result = LatexNormalizer.normalize(input)
        XCTAssertTrue(result.contains("$a^2 + b^2 = c^2$"))
        XCTAssertTrue(result.contains("$c$"))
        XCTAssertTrue(result.contains("$$\nc = \\sqrt{a^2 + b^2}\n$$"))
        XCTAssertTrue(result.contains("$a = 3$"))
        XCTAssertTrue(result.contains("$b = 4$"))
        XCTAssertTrue(result.contains("$c = 5$"))
        XCTAssertFalse(result.contains("\\("))
        XCTAssertFalse(result.contains("\\["))
    }
}
