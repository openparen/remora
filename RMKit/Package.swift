// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RMKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RMKit", targets: ["RMKit"]),
        .executable(name: "remora-cli", targets: ["remora-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "RMKit", dependencies: [
            // CryptoKit's API, for Linux; macOS keeps CryptoKit
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]),
        .executableTarget(name: "remora-cli", dependencies: ["RMKit"]),
        .testTarget(name: "RMKitTests", dependencies: ["RMKit"], resources: [.copy("Fixtures")]),
    ]
)
