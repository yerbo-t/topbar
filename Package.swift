// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "topbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TopbarCore", targets: ["TopbarCore"]),
        .executable(name: "topbar-hook", targets: ["topbar-hook"]),
        .executable(name: "topbar-dev", targets: ["topbar-dev"]),
        .executable(name: "topbar", targets: ["topbar"]),
    ],
    dependencies: [
        // Автообновление приложения (проверка подписи обновления — EdDSA).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(name: "TopbarCore"),
        .executableTarget(name: "topbar-hook", dependencies: ["TopbarCore"]),
        .executableTarget(name: "topbar-dev", dependencies: ["TopbarCore"]),
        .executableTarget(
            name: "topbar",
            dependencies: ["TopbarCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework лежит в Contents/Frameworks собранного приложения (его кладёт scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "TopbarCoreTests", dependencies: ["TopbarCore"]),
    ]
)
