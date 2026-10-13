// swift-tools-version: 6.0
import PackageDescription

// Home Screen widgets that extensions draw: the layout they describe (JSON), its native renderer, and the files the app
// and its widget extension share (an App Group).
let package = Package(
    name: "PiWidgetLayout",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "PiWidgetLayout", targets: ["PiWidgetLayout"])],
    targets: [.target(name: "PiWidgetLayout"), .testTarget(name: "PiWidgetLayoutTests", dependencies: ["PiWidgetLayout"])]
)
