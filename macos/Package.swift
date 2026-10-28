// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Floorspace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Floorspace",
            path: "Sources/Floorspace"
        )
    ]
)
