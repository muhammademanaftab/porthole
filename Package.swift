// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Porthole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "porthole-host", targets: ["PortholeHost"]),
        .executable(name: "porthole-view", targets: ["PortholeView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "PortholeCore"),
        .executableTarget(name: "PortholeHost", dependencies: [
            "PortholeCore", .product(name: "LiveKit", package: "client-sdk-swift"),
        ]),
        .executableTarget(name: "PortholeView", dependencies: [
            "PortholeCore", .product(name: "LiveKit", package: "client-sdk-swift"),
        ]),
        .executableTarget(name: "PortholeSelfTest", dependencies: ["PortholeCore"]),
        .executableTarget(name: "PortholeProbe", dependencies: [
            "PortholeCore", .product(name: "LiveKit", package: "client-sdk-swift"),
        ]),
    ]
)
