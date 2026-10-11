// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SamsungTV4Mac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SamsungTV4Mac",
            path: "SamsungTV4Mac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SamsungTV4MacTests",
            dependencies: ["SamsungTV4Mac"],
            path: "Tests/SamsungTV4MacTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
