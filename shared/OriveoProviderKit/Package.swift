// swift-tools-version: 6.1
// OriveoProviderKit - the provider wire-protocol kernel for the Apple clients.
//
// Scope:
//   In: Foundation-only wire knowledge - SSE line splitting, OpenAI-compatible chunk assembly,
//       tool-name escaping, credential redaction, upstream error classification, thinking tags,
//       streaming JSON path extraction, and per-provider quirk profiles (ProviderWireProfile).
//   Out: app models, UI, database, telemetry, localization. Each client keeps a thin binding
//       around this package so that wire behaviour has exactly one implementation.
import PackageDescription

let package = Package(
    name: "OriveoProviderKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "OriveoProviderKit", targets: ["OriveoProviderKit"]),
    ],
    targets: [
        .target(name: "OriveoProviderKit"),
        .testTarget(name: "OriveoProviderKitTests", dependencies: ["OriveoProviderKit"]),
    ]
)
