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
        // Atomic index loads and stores for the lock-free audio queue. Kept as a
        // C target so the memory orderings are the compiler's own builtins
        // rather than a deprecation-prone Swift wrapper, and so the package
        // resolves and builds with no network access.
        .target(name: "CSync"),
        .target(name: "SundayKeysCore", dependencies: ["CSync"]),
        .executableTarget(name: "SundayKeysApp", dependencies: ["SundayKeysCore"]),
        .testTarget(name: "SundayKeysCoreTests", dependencies: ["SundayKeysCore"]),
    ]
)
