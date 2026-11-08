// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Spike",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
        // 1.4+ gates code on compiler(>=6.4), which needs a newer SDK than Command Line Tools ship (26.5).
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0"..<"1.4.0"),
        .package(path: "../../Vendor/SwiftTerm"),
    ],
    targets: [
        .target(name: "CSpake", dependencies: [.product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .executableTarget(name: "Spike", dependencies: [
            "CSpake",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
