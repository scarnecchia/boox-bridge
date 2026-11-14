// swift-tools-version:6.0
import PackageDescription

// Boox Bridge — SwiftUI macOS app + platform-neutral core.
//
// Layout (see plans/architecture.md):
//   CBooxSQLite        system-library shim over the host libsqlite3
//   BooxBridgeCore     platform-neutral library: parsing, path policy, ADB
//                      transport, SQLite catalog, provider wire codecs, OCR
//                      queue, search/export. Builds on macOS AND Linux so the
//                      `make test-core` gate runs anywhere.
//   BooxBridge         macOS app (SwiftUI/PDFKit/AppKit/Security). Excluded on
//                      Linux via `#if canImport(AppKit)` so Linux `swift test`
//                      never tries to build UI code.
//   BooxBridgeAppTests macOS-only bundle/scenario/accessibility harness.

#if canImport(AppKit)
let platformTargets: [Target] = [
    .executableTarget(
        name: "BooxBridge",
        dependencies: ["BooxBridgeCore"],
        path: "Sources/BooxBridge",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "BooxBridgeAppTests",
        dependencies: ["BooxBridge", "BooxBridgeCore"],
        path: "Tests/BooxBridgeAppTests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#else
let platformTargets: [Target] = []
#endif

let package = Package(
    name: "BooxBridge",
    platforms: [
        // macOS Tahoe 26.1 minimum — keep Resources/Info.plist
        // (LSMinimumSystemVersion) and the Makefile (MIN_MACOS) in agreement.
        .macOS("26.1"),
    ],
    products: [
        .library(name: "BooxBridgeCore", targets: ["BooxBridgeCore"]),
    ],
    dependencies: [
        // SHA-256 content hashing on both hosts. 3.x line is required for
        // Swift 6 strict-concurrency consumers.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CBooxSQLite", path: "Sources/CBooxSQLite"),
        .target(
            name: "BooxBridgeCore",
            dependencies: [
                "CBooxSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/BooxBridgeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BooxBridgeCoreTests",
            dependencies: ["BooxBridgeCore"],
            path: "Tests/BooxBridgeCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + platformTargets
)
