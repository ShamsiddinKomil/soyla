// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "soyla",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SoylaCore", path: "Sources/SoylaCore",
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "soyla", dependencies: ["SoylaCore"], path: "Sources/soyla",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SoylaCoreTests", dependencies: ["SoylaCore"], path: "Tests/SoylaCoreTests",
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
