// swift-tools-version:5.9
// SwiftTerm 1.11.2, vendored for HiveMinds with one added file (HiveMindsAccess.swift) and one visibility change
// (Terminal.mouseProtocol is internal instead of private). See Vendor/README.md.
import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v13), .macOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm", exclude: platformExcludes + ["Mac/README.md"]),
    ],
    swiftLanguageVersions: [.v5]
)
