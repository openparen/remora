// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RMKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RMKit", targets: ["RMKit"]),
        .executable(name: "remora-cli", targets: ["remora-cli"]),
    ],
    targets: [
        .target(name: "RMKit"),
        .executableTarget(name: "remora-cli", dependencies: ["RMKit"]),
        .testTarget(name: "RMKitTests", dependencies: ["RMKit"], resources: [.copy("Fixtures")]),
    ]
)
