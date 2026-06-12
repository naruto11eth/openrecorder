// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRecorder",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenRecorder",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/OpenRecorder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
