// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quartzite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Quartzite", path: "Sources/Quartzite")
    ]
)
