// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Autoleveler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutolevelerCore", targets: ["AutolevelerCore"]),
        .executable(name: "AutolevelerApp", targets: ["AutolevelerApp"]),
        .executable(name: "autoleveler", targets: ["AutolevelerCLI"])
    ],
    targets: [
        .target(name: "AutolevelerCore"),
        .executableTarget(name: "AutolevelerApp", dependencies: ["AutolevelerCore"]),
        .executableTarget(name: "AutolevelerCLI", dependencies: ["AutolevelerCore"]),
        .testTarget(name: "AutolevelerCoreTests", dependencies: ["AutolevelerCore"])
    ]
)
