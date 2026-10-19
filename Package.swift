// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiveMinds",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .executableTarget(
            name: "HiveMinds",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/HiveMinds",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
