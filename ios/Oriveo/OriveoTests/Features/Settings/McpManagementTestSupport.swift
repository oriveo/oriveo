import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Oriveo

// MARK: - Shared setup for the add-server and management UI tests
//
// Protocol replay reuses `McpScriptedURLProtocol`, authorization replay reuses `FakeMcpAuthTransport` /
// `FakeMcpBrowserSession`, and the store is a temporary GRDB database that runs the full migrator. The objects under
// test are the production UI models (`McpAddServerModel` / `McpServerDetailModel`), `McpServerActions` and
// `McpServerDirectory`, not stand-ins.

nonisolated enum McpUiFixture {
    static let endpoint = "https://mcp.example.com/mcp"
    /// Storage partition used by the rig.
    static let uid = "u1"
    /// The client metadata document the authorization fixtures expect as `client_id`.
    static let clientMetadataDocumentURL = URL(string: "https://app.example.com/oauth/mcp-client.json")
    static let protectedResourceURL = "https://mcp.example.com/.well-known/oauth-protected-resource"
    static let authorizationServerURL = "https://auth.example.com/.well-known/oauth-authorization-server"
    static let registrationURL = "https://auth.example.com/register"
    static let tokenURL = "https://auth.example.com/token"

    static func unauthorized() throws -> McpScriptedURLProtocol.Stub {
        let fixture = try McpFixture.json("auth/401.www-authenticate.json")
        var headers: [String: String] = [:]
        if let object = fixture["headers"]?.objectValue {
            for key in object.keys { if let value = object[key]?.stringValue { headers[key] = value } }
        }
        return McpScriptedURLProtocol.Stub(status: 401, headers: headers, body: Data())
    }

    static func toolsList() throws -> McpScriptedURLProtocol.Stub {
        try McpClientFixture.stub("protocol/stateless/tools-list.response.json")
    }

    /// Rewrites the tools array in the `tools/list` fixture (everything else unchanged).
    static func toolsList(rewriting transform: ([JSONValue]) -> [JSONValue]) throws -> McpScriptedURLProtocol.Stub {
        func rewrite(_ value: JSONValue) -> JSONValue {
            guard case .object(let object) = value else { return value }
            return .object(JSONObject(object.keys.map { key in
                if key == "tools", case .array(let tools)? = object[key] { return (key, .array(transform(tools))) }
                return (key, rewrite(object[key]!))
            }))
        }
        return try McpClientFixture.stub(json: rewrite(McpFixture.json("protocol/stateless/tools-list.response.json")))
    }

    /// A minimal tool definition (JSON).
    static func tool(_ name: String, description: String, readOnly: Bool, title: String? = nil) -> JSONValue {
        var fields: [(String, JSONValue)] = [("name", .string(name))]
        if let title { fields.append(("title", .string(title))) }
        fields.append(("description", .string(description)))
        fields.append(("inputSchema", .object(JSONObject([("type", .string("object"))]))))
        if readOnly {
            fields.append(("annotations", .object(JSONObject([("readOnlyHint", .bool(true))]))))
        }
        return .object(JSONObject(fields))
    }

    /// An authorization server that supports CIMD.
    static func stubAuthorization(_ transport: FakeMcpAuthTransport) throws {
        let resource = try McpFixture.json("auth/protected-resource-metadata.json")
        transport.stub(status: 200, json: resource["body"] ?? .object(JSONObject()), at: protectedResourceURL)
        let server = try McpFixture.json("auth/authorization-server-metadata.cimd.json")
        transport.stub(status: 200, json: server["body"] ?? .object(JSONObject()), at: authorizationServerURL)
        let token = try McpFixture.json("auth/token.success.json")
        transport.stub(status: 200, json: token["body"] ?? .object(JSONObject()), at: tokenURL)
    }

    /// An authorization server that supports DCR only: registering leaves a client behind on the authorization server,
    /// which is what pins "no registration before consent".
    static func stubDCRAuthorization(_ transport: FakeMcpAuthTransport) throws {
        let resource = try McpFixture.json("auth/protected-resource-metadata.json")
        transport.stub(status: 200, json: resource["body"] ?? .object(JSONObject()), at: protectedResourceURL)
        let server = try McpFixture.json("auth/authorization-server-metadata.dcr.json")
        transport.stub(status: 200, json: server["body"] ?? .object(JSONObject()), at: authorizationServerURL)
        let dcr = try McpFixture.json("auth/dcr.json")
        transport.stub(status: dcr["status"]?.intValue ?? 201, json: dcr["body"] ?? .object(JSONObject()), at: registrationURL)
        let token = try McpFixture.json("auth/token.success.json")
        transport.stub(status: 200, json: token["body"] ?? .object(JSONObject()), at: tokenURL)
    }

    /// A successful browser sign-in: the callback carries the authorization code and the correct state / iss.
    static func approvingBrowser() -> FakeMcpBrowserSession {
        let browser = FakeMcpBrowserSession()
        browser.callbackBuilder = { authorizeURL in
            let state = McpOAuthCallbackRouter.state(in: authorizeURL) ?? ""
            return URL(string: "oriveo://mcp/oauth/callback?code=ac_123&state=\(state)&iss=https://auth.example.com")!
        }
        return browser
    }
}

/// A wired-up set of production objects: temporary database + in-memory credentials + directory + authorizer + actions.
@MainActor
struct McpUiRig {
    let database: McpTestDatabase
    let storage: InMemoryMcpCredentialStorage
    let credentials: McpCredentialStore
    let directory: McpServerDirectory
    let transport: FakeMcpAuthTransport
    let browser: FakeMcpBrowserSession
    let authorizer: McpAuthorizer
    let runtimeConfig: McpRuntimeConfig
    let reauthorization = McpReauthorizationCoordinator()

    init(
        transport: FakeMcpAuthTransport = FakeMcpAuthTransport(),
        browser: FakeMcpBrowserSession = FakeMcpBrowserSession(),
        runtimeConfig: McpRuntimeConfig = .fallback
    ) throws {
        let database = try McpTestDatabase.make()
        let storage = InMemoryMcpCredentialStorage()
        let credentials = McpCredentialStore(storage: storage)
        self.database = database
        self.storage = storage
        self.credentials = credentials
        self.transport = transport
        self.browser = browser
        self.runtimeConfig = runtimeConfig
        directory = McpServerDirectory(credentialStore: credentials, openStore: { _ in database.store })
        authorizer = McpAuthorizer(
            transport: transport, browser: browser, credentialStore: credentials,
            clientMetadataDocumentURL: McpUiFixture.clientMetadataDocumentURL
        )
    }

    var store: McpServerStore { database.store }

    func makeClient() -> @Sendable (URL) -> McpClient {
        let runtimeConfig = runtimeConfig
        return { McpClient(endpoint: $0, runtimeConfig: runtimeConfig, session: McpScriptedURLProtocol.session()) }
    }

    func actions() -> McpServerActions {
        let reauthorization = reauthorization
        return McpServerActions(
            store: database.store, credentialStore: credentials, uid: McpUiFixture.uid, runtimeConfig: runtimeConfig,
            authorizer: authorizer, makeClient: makeClient(),
            onReauthorized: { await reauthorization.serverReauthorized($0) }
        )
    }

    /// The production add-flow model, with dependencies wired the way `McpAddServerView.makeModel` does (only the
    /// network is replaced by replay).
    func addModel() -> McpAddServerModel {
        let directory = directory, credentials = credentials, authorizer = authorizer
        let runtimeConfig = runtimeConfig, makeClient = makeClient()
        return McpAddServerModel(dependencies: .init(
            uid: McpUiFixture.uid,
            makeCoordinator: {
                let probe = McpAddProbe(
                    runtimeConfig: runtimeConfig, authorizer: authorizer, credentialStore: credentials,
                    makeClient: makeClient
                )
                return try directory.makeAddCoordinator(probe: probe, uid: McpUiFixture.uid, runtimeConfig: runtimeConfig)
            }
        ))
    }

    /// The production detail-page model, with dependencies wired the way `McpServerDetailView.makeModel` does.
    func detailModel(_ serverId: UUID, intent: McpServerDetailIntent = .view) -> McpServerDetailModel {
        let directory = directory, actions = actions()
        return McpServerDetailModel(serverId: serverId, intent: intent, dependencies: .init(
            uid: McpUiFixture.uid,
            loadDetail: { try directory.detail(serverId: $0, uid: McpUiFixture.uid) },
            actions: { actions },
            setPermission: { permission, serverId, toolName in
                try directory.setToolPermission(permission, serverId: serverId, toolName: toolName, uid: McpUiFixture.uid)
            },
            remove: { try directory.remove(serverId: $0, uid: McpUiFixture.uid) },
            restoreEndpoint: { try directory.restoreEndpoint(serverId: $0, urlString: $1, uid: McpUiFixture.uid) }
        ))
    }

    /// Inserts a connected server directly (with tool snapshots and permissions) and returns its id.
    @discardableResult
    func seedServer(
        name: String = "Linear",
        url: String = McpUiFixture.endpoint,
        authKind: McpAuthKind = .auto,
        localOnly: Bool = false,
        status: McpConnectionStatus = .connected,
        lastSuccessAt: Date? = Date(timeIntervalSince1970: 1_790_000_000),
        tools: [McpToolDefinition] = McpUiRig.sampleTools,
        pendingReview: Bool = false,
        permissions: [String: McpToolPermission]? = nil
    ) throws -> UUID {
        let id = UUID()
        let snapshots = McpToolCatalog.snapshots(serverId: id, definitions: tools, runtimeConfig: runtimeConfig).map {
            var snapshot = $0
            snapshot.pendingReview = pendingReview
            return snapshot
        }
        try store.addServer(
            McpServerAddition(
                id: id, name: name, url: url, authKind: authKind, localOnly: localOnly, iconURL: nil,
                createdAt: Date(timeIntervalSince1970: 1_789_000_000), snapshots: snapshots,
                permissions: permissions ?? McpToolCatalog.defaultPermissions(for: snapshots),
                connectionState: McpConnectionState(
                    serverId: id, status: status, lastSuccessAt: lastSuccessAt,
                    negotiatedVersion: McpProtocol.modernVersion, generation: .stateless
                )
            ),
            maxServers: 100
        )
        return id
    }

    static let sampleTools: [McpToolDefinition] = [
        readTool("search_issues", "Search issues"),
        readTool("get_issue", "Read issue"),
        readTool("list_projects", "List projects"),
        readTool("list_teams", "List teams"),
        readTool("list_labels", "List labels"),
        writeTool("create_issue", "Create issue", "Create a new issue in a team. Requires a title; description, assignee, labels and priority are optional."),
        writeTool("update_issue", "Update issue", "Update fields on an existing issue."),
    ]

    static func readTool(_ name: String, _ title: String, description: String = "Read-only lookup.") -> McpToolDefinition {
        McpToolDefinition(
            name: name, title: title, description: description,
            annotations: .object(JSONObject([("readOnlyHint", .bool(true))]))
        )
    }

    static func writeTool(_ name: String, _ title: String, _ description: String) -> McpToolDefinition {
        McpToolDefinition(name: name, title: title, description: description)
    }

    /// No row remains in any MCP table and the credential store holds no token (a cached DCR registration does
    /// not count).
    func expectNothingLeft(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(
            try database.nonEmptyTables() == [:],
            "\(label): no row should remain in the tables", sourceLocation: sourceLocation
        )
        #expect(
            storage.accounts().filter { !$0.contains(":dcr:") } == [],
            "\(label): no token should remain in the credential store", sourceLocation: sourceLocation
        )
    }

    func cleanUp() { database.cleanUp() }
}

/// Actually renders production views. PNGs are exported for visual comparison when `ORIVEO_MCP_SNAPSHOT_DIR` is set.
@MainActor
enum McpUiSnapshot {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["ORIVEO_MCP_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @discardableResult
    static func render<Content: View>(
        _ content: Content,
        name: String,
        height: CGFloat = 844,
        style: UIUserInterfaceStyle = .light
    ) throws -> UIImage {
        let size = CGSize(width: 390, height: height)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: content.background(OriveoTheme.Palette.background))
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        return image
    }

    /// The rendered image is not a single solid color (the view really drew something).
    static func hasContent(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let length = CFDataGetLength(data)
        guard bytesPerPixel >= 3, length >= bytesPerPixel else { return false }
        var seen = Set<UInt32>()
        var offset = 0
        let stride = bytesPerPixel * 97
        while offset + 2 < length {
            seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            if seen.count > 8 { return true }
            offset += stride
        }
        return false
    }
}

/// Polls a condition on the main actor (UI model state can only be read on the main actor).
@MainActor
enum McpUiWait {
    static func until(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
