// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "topbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopbarCore", targets: ["TopbarCore"]),
        .executable(name: "topbar-hook", targets: ["topbar-hook"]),
        .executable(name: "topbar-dev", targets: ["topbar-dev"]),
    ],
    targets: [
        .target(name: "TopbarCore"),
        .executableTarget(name: "topbar-hook", dependencies: ["TopbarCore"]),
        .executableTarget(name: "topbar-dev", dependencies: ["TopbarCore"]),
        .testTarget(name: "TopbarCoreTests", dependencies: ["TopbarCore"]),
    ]
)
