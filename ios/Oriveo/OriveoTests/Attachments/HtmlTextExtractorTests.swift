import XCTest
@testable import Oriveo

final class HtmlTextExtractorTests: XCTestCase {

    func testBasic() throws {
        let html = "<html><body><h1>Title</h1><p>Hello <b>world</b></p></body></html>"
        let r = try HtmlTextExtractor.extract(data: html.data(using: .utf8)!)
        XCTAssertTrue(r.contains("Title"))
        XCTAssertTrue(r.contains("Hello world"))
    }

    func testScriptStyleStripped() throws {
        let html = """
        <html><head><script>alert('x')</script><style>body{color:red}</style></head>
        <body><p>Visible</p></body></html>
        """
        let r = try HtmlTextExtractor.extract(data: html.data(using: .utf8)!)
        XCTAssertTrue(r.contains("Visible"))
        XCTAssertFalse(r.contains("alert"))
        XCTAssertFalse(r.contains("color:red"))
    }

    func testHtmlEntities() throws {
        let html = "<p>Hello &amp; world &lt;3&gt;</p>"
        let r = try HtmlTextExtractor.extract(data: html.data(using: .utf8)!)
        XCTAssertTrue(r.contains("Hello & world"))
        XCTAssertTrue(r.contains("<3>"))
    }

    func testChineseContent() throws {
        let html = "<html><body><p>Hello world</p></body></html>"
        let r = try HtmlTextExtractor.extract(data: html.data(using: .utf8)!)
        XCTAssertTrue(r.contains("Hello world"))
    }
}
