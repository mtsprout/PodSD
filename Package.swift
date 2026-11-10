// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PodSD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PodSD", path: "Sources/PodSD")
    ]
)
