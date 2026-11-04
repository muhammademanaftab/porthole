// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "porthole-host", targets: ["PortholeApp"]),
        .executable(name: "porthole-tile", targets: ["PortholeTile"]),
        .executable(name: "porthole", targets: ["PortholeCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "PortholeCore"),
        .target(name: "VirtualDisplayBridge", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "PortholeApp", dependencies: [
            "PortholeCore", "VirtualDisplayBridge", .product(name: "LiveKit", package: "client-sdk-swift"),
        ]),
        .executableTarget(name: "PortholeTile", dependencies: ["PortholeCore"]),
        .executableTarget(name: "PortholeCLI", dependencies: ["PortholeCore"]),
        .executableTarget(name: "PortholeSelfTest", dependencies: ["PortholeCore"]),
        .executableTarget(name: "PortholeProbe", dependencies: [
            "PortholeCore", .product(name: "LiveKit", package: "client-sdk-swift"),
        ]),
    ]
)
