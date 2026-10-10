// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ICloudCleaner",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ICloudCleaner",
            path: "Sources/ICloudCleaner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
