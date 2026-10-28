// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// The Rust engine as a static library, built by scripts/build-rust.sh.
let rustLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("rust").path

let package = Package(
    name: "Floorspace",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CFloorspace", path: "Sources/CFloorspace"),
        .executableTarget(
            name: "Floorspace",
            dependencies: ["CFloorspace"],
            path: "Sources/Floorspace",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibrary]),
                .linkedLibrary("floorspace_ffi"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
