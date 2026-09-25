// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoteTaker",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NoteTaker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
