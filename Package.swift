// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LidFold",
    platforms: [.macOS(.v14)],   // NSScreen.displayLink needs macOS 14
    targets: [
        .executableTarget(
            name: "LidFold",
            path: "Sources/LidFold",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("Metal")]
        )
    ]
)
