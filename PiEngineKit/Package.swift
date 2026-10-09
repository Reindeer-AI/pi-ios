// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiEngineKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PiEngineKit", targets: ["PiEngineKit"]),
        .library(name: "PiRemote", targets: ["PiRemote"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
    ],
    targets: [
        .target(name: "PiEngineKit", dependencies: ["PiRemote"]),
        // Remote machines for Crabbox: an SSH client (swift-nio-ssh) for leased boxes and plain HTTP/1.1 for brokers that
        // iOS's App Transport Security would refuse (inside a WARP tunnel, say), both over Network.framework
        // (NIOTransportServices). Swift 5 mode for NIO's channel handlers.
        .target(
            name: "PiRemote",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Spike harness: runs the engine in macOS WebKit (same WebKit/URLSession code paths as iOS).
        .executableTarget(name: "pi-engine-harness", dependencies: ["PiEngineKit"]),
    ]
)
