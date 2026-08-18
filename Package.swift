// swift-tools-version: 6.0
import PackageDescription

// Protocol conformance is pinned to this Synapse release. Bump here, regenerate
// vectors with tools/genvectors.py, and update README + CLAUDE.md together.
// SYNAPSE_PINNED_VERSION = 2.249.0

let package = Package(
    name: "swift-telepath",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Msgpack", targets: ["Msgpack"]),
        .library(name: "Telepath", targets: ["Telepath"]),
        .library(name: "Synapse", targets: ["Synapse"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Dependency-free by contract so it stays extractable.
        .target(name: "Msgpack"),
        .target(
            name: "Telepath",
            dependencies: [
                "Msgpack",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "Synapse", dependencies: ["Telepath", "Msgpack"]),
        // Shared by the long-running fuzz executable and the fast property tests.
        .target(name: "MsgpackFuzzCore", dependencies: ["Msgpack"]),
        .executableTarget(name: "msgpack-fuzz", dependencies: ["MsgpackFuzzCore", "Msgpack"]),
        .target(
            name: "TelepathTestKit",
            dependencies: [
                "Msgpack",
                "Telepath",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "MsgpackTests", dependencies: ["Msgpack", "MsgpackFuzzCore"], resources: [.copy("vectors.json")]),
        .testTarget(
            name: "TelepathTests",
            dependencies: ["Telepath", "Msgpack", "TelepathTestKit"],
            resources: [.copy("protocol-vectors.json")]
        ),
        .testTarget(name: "SynapseTests", dependencies: ["Synapse", "Telepath", "Msgpack", "TelepathTestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
