// swift-tools-version: 6.0
import PackageDescription

// HiveMindsCore: the agent logic shared by the app and HiveMinds Host. Foundation plus SwiftTerm's
// headless terminal only, so it builds on macOS and Linux. The app itself is macOS only.
// HiveMindsProtocol and HiveMindsNet: how the app and a host talk (docs/HOST-PROTOCOL.md).
var targets: [Target] = [
    // System calls needed from C: starting a program in a pseudo-terminal (the child may only make
    // async-signal-safe calls) and the Unix socket peer check.
    .target(
        name: "CHiveMindsSystem",
        path: "Sources/CHiveMindsSystem",
        linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]
    ),
    .target(
        name: "HiveMindsCore",
        dependencies: ["CHiveMindsSystem", .product(name: "SwiftTerm", package: "SwiftTerm")],
        path: "Sources/HiveMindsCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // The messages of the host protocol, as Codable types. Foundation only.
    .target(
        name: "HiveMindsProtocol",
        path: "Sources/HiveMindsProtocol",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // BoringSSL's SPAKE2, which swift-nio-ssl already links (see docs/HOST-PHASE0-REPORT.md). swift-nio-ssl is
    // pinned exactly below because this relies on its vendored BoringSSL.
    .target(
        name: "CSpake2",
        dependencies: [.product(name: "NIOSSL", package: "swift-nio-ssl")],
        path: "Sources/CSpake2"
    ),
    // Bonjour/Avahi through the dns_sd API: the system's on macOS, Avahi's compatibility library on Linux
    // (loaded at run time, so the host still starts where it's missing, just without discovery).
    .target(
        name: "CDNSSD",
        path: "Sources/CDNSSD",
        linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux]))]
    ),
    // TLS, WebSocket, pairing, private-address checks and discovery, for the host and (later) the app.
    .target(
        name: "HiveMindsNet",
        dependencies: [
            "HiveMindsProtocol", "CSpake2", "CDNSSD", "CHiveMindsSystem",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            // Listed so its version pin below applies (swift-nio uses it).
            .product(name: "DequeModule", package: "swift-collections"),
        ],
        path: "Sources/HiveMindsNet",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // HiveMinds Host: runs projects and agents on a machine with no window (Linux first). See docs/LINUX-HOST-SPEC.md.
    .executableTarget(
        name: "hiveminds-host",
        dependencies: ["HiveMindsCore", "CHiveMindsSystem", "HiveMindsProtocol", "HiveMindsNet",
                       .product(name: "SwiftTerm", package: "SwiftTerm")],
        path: "Sources/hiveminds-host",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "HiveMindsCoreTests",
        dependencies: ["HiveMindsCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
        path: "Tests/HiveMindsCoreTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "HiveMindsNetTests",
        dependencies: ["HiveMindsNet", "HiveMindsProtocol"],
        path: "Tests/HiveMindsNetTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// The app needs the macOS 26 SDK (see scripts/build-app.sh), while the tests need the default SDK for
// Swift Testing's macros. scripts/test-core.sh sets HIVEMINDS_CORE_ONLY=1 so the tests build without the app.
#if os(macOS)
if Context.environment["HIVEMINDS_CORE_ONLY"] == nil {
targets.append(
    .executableTarget(
        name: "HiveMinds",
        dependencies: ["HiveMindsCore", "HiveMindsProtocol", "HiveMindsNet",
                       .product(name: "SwiftTerm", package: "SwiftTerm"),
                       .product(name: "Crypto", package: "swift-crypto")],
        path: "Sources/HiveMinds",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
}
#endif

let package = Package(
    name: "HiveMinds",
    platforms: [.macOS("26.0")],
    dependencies: [
        // SwiftTerm 1.11.2 with HiveMinds' small patch; see Vendor/README.md.
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/apple/swift-nio.git", "2.80.0"..<"3.0.0"),
        // Exact: CSpake2 calls the BoringSSL inside it.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.0"..<"4.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", "1.10.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", "1.3.0"..<"2.0.0"),
        // 1.4+ gates code on compiler(>=6.4), which then needs the macOS 27 SDK; Command Line Tools ship 26.5.
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.4.0"),
    ],
    targets: targets
)
