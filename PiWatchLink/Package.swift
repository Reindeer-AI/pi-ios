// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiWatchLink",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS(.v14)],
    products: [.library(name: "PiWatchLink", targets: ["PiWatchLink"])],
    targets: [.target(name: "PiWatchLink"), .testTarget(name: "PiWatchLinkTests", dependencies: ["PiWatchLink"])]
)
