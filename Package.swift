// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Catch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CatchCore",
            targets: ["CatchCore"]
        ),
        .executable(
            name: "Catch",
            targets: ["Catch"]
        )
    ],
    targets: [
        .target(
            name: "CatchCore",
            path: "Sources/CatchCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Network"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("Speech"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Catch",
            dependencies: ["CatchCore"],
            path: "Sources/Catch"
        ),
        .testTarget(
            name: "CatchTests",
            dependencies: ["CatchCore"],
            path: "Tests/CatchTests"
        )
    ]
)
