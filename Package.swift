// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CleanShotClone",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CleanShotCore",
            targets: ["CleanShotCore"]
        ),
        .executable(
            name: "CleanShotClone",
            targets: ["CleanShotClone"]
        )
    ],
    targets: [
        .target(
            name: "CleanShotCore",
            path: "Sources/CleanShotCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "CleanShotClone",
            dependencies: ["CleanShotCore"],
            path: "Sources/CleanShotClone"
        ),
        .testTarget(
            name: "CleanShotCloneTests",
            dependencies: ["CleanShotCore"],
            path: "Tests/CleanShotCloneTests"
        )
    ]
)
