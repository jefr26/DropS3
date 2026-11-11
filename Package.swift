// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DropS3",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DropS3", path: "Sources/DropS3")
    ]
)
