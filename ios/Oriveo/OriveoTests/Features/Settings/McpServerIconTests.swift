import Foundation
import Testing
import UIKit
@testable import Oriveo

// MARK: - Loading server icons: https only, cached, falling back to the initial-letter tile when unavailable

@Suite("MCP server icon loading", .serialized)
struct McpServerIconTests {
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData() ?? Data()
    }

    @Test("Only https addresses are accepted: http, other schemes and URLs without a host are never fetched, and the view falls back to the initial-letter tile")
    func onlyHTTPS() async {
        #expect(McpServerIconLoader.acceptedURL("https://cdn.example.com/icon.png") != nil)
        for rejected in ["http://cdn.example.com/icon.png", "data:image/png;base64,AAAA", "file:///etc/passwd", "javascript:alert(1)", "https://", "", nil] as [String?] {
            #expect(McpServerIconLoader.acceptedURL(rejected) == nil, "\(rejected ?? "nil")")
        }
        McpScriptedURLProtocol.reset()
        let loader = McpServerIconLoader(protocolClasses: [McpScriptedURLProtocol.self])
        #expect(await loader.image(for: URL(string: "http://cdn.example.com/icon.png")!) == nil)
        #expect(McpScriptedURLProtocol.requests().isEmpty, "a non-https address does not even send a request")
    }

    @Test("A fetched icon is cached: the second load sends no request; requests carry no cookies or credentials")
    func cachesLoadedIcons() async throws {
        McpScriptedURLProtocol.reset()
        McpScriptedURLProtocol.enqueue(McpScriptedURLProtocol.Stub(
            status: 200, headers: ["Content-Type": "image/png"], body: png(), rewriteID: false
        ))
        let loader = McpServerIconLoader(protocolClasses: [McpScriptedURLProtocol.self])
        let url = try #require(URL(string: "https://cdn.example.com/icon-\(UUID().uuidString).png"))
        #expect(loader.cachedImage(for: url) == nil)
        #expect(await loader.image(for: url) != nil)
        #expect(loader.cachedImage(for: url) != nil)
        #expect(await loader.image(for: url) != nil)
        let requests = McpScriptedURLProtocol.requests()
        #expect(requests.count == 1, "the second load is served from the cache")
        #expect(requests.first?.header("Cookie") == nil && requests.first?.header("Authorization") == nil)
    }

    @Test("Unavailable, not an image, too large: all return nil (the view shows the initial-letter tile) and nothing is cached")
    func failuresFallBack() async throws {
        let loader = McpServerIconLoader(protocolClasses: [McpScriptedURLProtocol.self])
        let cases: [(String, McpScriptedURLProtocol.Stub)] = [
            ("404", McpScriptedURLProtocol.Stub(status: 404, body: Data(), rewriteID: false)),
            ("not an image", McpScriptedURLProtocol.Stub(status: 200, body: Data("<html></html>".utf8), rewriteID: false)),
            ("too large", McpScriptedURLProtocol.Stub(
                status: 200, body: Data(count: McpServerIconLoader.maxBytes + 1), rewriteID: false
            )),
            ("network failure", McpScriptedURLProtocol.Stub(errorCode: .cannotConnectToHost)),
        ]
        for (label, stub) in cases {
            McpScriptedURLProtocol.reset()
            McpScriptedURLProtocol.enqueue(stub)
            let url = try #require(URL(string: "https://cdn.example.com/bad-\(UUID().uuidString).png"))
            #expect(await loader.image(for: url) == nil, "\(label)")
            #expect(loader.cachedImage(for: url) == nil, "\(label)")
        }
    }
}
