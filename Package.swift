// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPhoto2YouTubeNativeApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "iPhoto2YouTubeNativeApp",
            targets: ["iPhoto2YouTubeNativeApp"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "iPhoto2YouTubeNativeApp",
            path: "Sources/iPhoto2YouTubeNativeApp",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "iPhoto2YouTubeNativeAppTests",
            dependencies: ["iPhoto2YouTubeNativeApp"],
            path: "Tests/iPhoto2YouTubeNativeAppTests"
        ),
    ]
)
