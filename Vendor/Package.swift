// swift-tools-version: 5.9
import PackageDescription

// Native components built or fetched into Vendor/:
// - ios_system (a-Shell's command engine; run `./fetch-ashell.sh` and `./build-dash.sh` first). Only ios_system is
//   linked. The command frameworks (files, text, dash, lg2, ...) are embedded by the app's "Embed a-Shell commands"
//   build phase without being linked: ios_system loads a command's framework when the command runs and releases it
//   afterwards, which resets the command's global state.
// - LlamaServer (llama.cpp's llama-server as a static library; run `./build-llama.sh` first).
let package = Package(
    name: "AShell",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ios_system", targets: ["ios_system"]),
        .library(name: "LlamaServerSupport", targets: ["LlamaServerSupport"]),
    ],
    targets: [
        .binaryTarget(name: "ios_system", path: "ashell/ios_system.xcframework"),
        .binaryTarget(name: "LlamaServer", path: "llama/LlamaServer.xcframework"),
        .target(
            name: "LlamaServerSupport",
            dependencies: ["LlamaServer"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
