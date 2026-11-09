// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SundayKeys",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SundayKeysCore", targets: ["SundayKeysCore"]),
        .executable(name: "SundayKeysApp", targets: ["SundayKeysApp"]),
    ],
    targets: [
        .target(name: "SundayKeysCore"),
        .executableTarget(name: "SundayKeysApp", dependencies: ["SundayKeysCore"]),
        .testTarget(name: "SundayKeysCoreTests", dependencies: ["SundayKeysCore"]),
    ]
)
