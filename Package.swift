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
        // The licence gate is enforced in `AudioEngineController.noteOn`, which lives in the
        // executable target. Nothing in the core can prove that call refuses, so this target
        // depends on the executable - which SwiftPM supports - and drives the controller over a
        // recorder instead of an audio device. It stays a separate target from the core tests so
        // a failure says which layer broke.
        .testTarget(
            name: "SundayKeysAppTests",
            dependencies: ["SundayKeysApp", "SundayKeysCore"]
        ),
    ]
)
